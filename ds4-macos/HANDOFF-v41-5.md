# 引き継ぎ: DeepSeek V4.1 Flash の Metal デコード最適化（6日目）

## 作業対象

- ワークツリー: `~/ghq/github.com/antirez/ds4-v41`（ブランチ `perf/v41-metal-apple`、**未push**）
- モデル: `~/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf`（340.6 GiB）
- 記録: `~/ghq/github.com/ngc-shj/inference-deploy` の `ds4-macos/V4.1-TUNING.md`（ブランチ `docs/v41-tuning`、**未PR**）
- 計測ハーネス: **`ds4-macos/bench/`（今日リポジトリに入れた）**。以前は scratchpad にしかなく、セッションが変わると消える状態だった
- 機体: MacBook Pro / Apple M5 Max / 128 GB、GPU 40コア

起動（新しいフラグは2つとも既定 OFF なので baseline は5日目までと同一）:

```
DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 DS4_METAL_ZERO_COPY_EXPERTS=1 \
DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 \
DS4_METAL_V41_ABORT_GATE_SEG=3 \
./ds4-server -m <gguf> --ssd-streaming --ctx 8192 --host 127.0.0.1 --port 8013
```

## 唯一の成果条件

> baseline と全出力バイト一致し、冷却・順序を対称にした paired 比較と長時間生成の
> 両方で、持続 ms/token を削る。

## 5日目の結論を先に

**4日目が最優先に据えた「狭い射影の統合（8.2倍）」は成立しない。前提が計器の誤りだった。**
実装・バイト一致・ABBA まで通して閉じた。以下はその全部と、代わりに開いたもの。

### 1. 8.2倍は、バイト量の違うアーム同士の率の比だった

`narrowmv.m` の融合アームは全 lane を最大幅（1280行）に padding していたので
8400 MiB 読み、直列アームは実際の 4410 MiB しか読んでいなかった。**同じバイト・
同じ encoder 数で測り直すと 4.4倍**（172.82 → 39.18 ms）。

ついでに `concur.m` の「効くのは threadgroup 数であって encoder ではない」も、
この規模では成立しない。**concurrent encoder は融合グリッドの2%以内**（39.92 対
39.18）。あれは 288 threadgroup での話だった。

### 2. そして幾何が違った。これが本体

`narrowmv.m` は「census が `attn_q_a` を 24 threadgroup と言うから」54行/threadgroup・
256スレッド（8 simdgroup）で測っていた。**24 は F16 matvec のもので、`attn_q_a` の
ものではない。**

- census は grid 形状を「呼び出しサイト」だけで keying していたので、
  **最初に来た dispatch の形をそのサイトの形として記録していた**
- `attn_q_a` は Q8_0。Q8_0 decode matvec は `N_R0_Q8_0` = 2行/threadgroup、32x4 スレッド
- したがって **1280行 = 640 threadgroup**、`attn_kv` 512行 = **256 threadgroup**

**どちらも threadgroup 不足ではない。** 「この5本が機械を遊ばせている」という前提は、
実在しない形を測って出てきたものだった。

census は grid を key に加えて直した（`ds4-v41` の `0ff6f35`）。

### 3. エンジンの A/B も同じことを言う

| アーム | 結果 |
|---|---|
| `DS4_METAL_V41_ATTN_LANES=1`（q_a と kv を1 dispatch の2 lane に） | **+2.16 ms/token**、dispatch は 44.9本/token 減。1 block で中止 |
| `DS4_METAL_V41_NARROW_SECTION=1`（5本を1つの concurrent section に） | **+0.70 ms**、中央値 +0.11、95% CI **[-1.16, +2.56]** = 何も起きない。5 block・20 run |

両方ともバイト一致 6/6（最長2048トークン）。lane 版が負ける理由は明快で、
`max(1280,512)/2 = 640` を2 lane 分 = **1280 threadgroup 要求する**のに対し、
別々の2 dispatch は 640 + 256 = 896 しか要求しない。余った threadgroup を買っただけ。

**この線は閉じた。** 「狭い射影の統合は割に合わない」ではなく、**この2本は狭くなかった**。

### 4. 残ったのは encoder 境界の値段

section アームは1層につき encoder を2つ余分に開く＝1トークン 80境界。それが
**測定限界以下**（上の CI）。`narrowmv.m` の 22.2 µs は「9〜17 MiB 読む dispatch を
drain した費用」であって境界そのものの費用ではなかった。`barrier.m` は小さい
dispatch では境界が実質ゼロだと言う。

**concurrent section は開くのが安い。** 問題は中に入れるものがあるかどうか。

### 5. 本当に細い dispatch がどこにあるか（census 再取得）

1トークン 1,511.7 gated dispatch（定常1窓）:

| 1 dispatch あたり threadgroup | 本/token | |
|---|---|---|
| **1** | **488.7** | **32.3%** |
| 2-8 | 86.9 | 5.7% |
| 9-32 | 420.6 | 27.8% |
| 33-128 | 104.2 | 6.9% |
| 129-512 | 77.4 | 5.1% |
| >512 | 333.9 | 22.1% |

上位は `ds4_gpu_rms_norm_weight_rows_round < ds41_norm` 114.1本、
`ds41_hc_mix` の row norm と Sinkhorn が各 55.7本、rope と quantize。
Q8_0 射影は表の反対側（640〜16,384）。

### 6. 1 threadgroup の dispatch の値段（`proto/barrier.m`、今日追加）

`ds41_norm` と同じ形（1 threadgroup・1024スレッド）を512本、64ラップ:

| アーム | µs/dispatch |
|---|---|
| 独立・serial encoder 1本 | 2.16 |
| 独立・concurrent encoder 1本 | **0.11** |
| 独立・dispatch ごとに encoder | 1.88 |
| 依存・間に encoder | 2.06 |
| 依存・concurrent encoder 内で barrier | 2.48 |

**独立な1 threadgroup dispatch は20.5倍重なる**（2.06 µs/本 回収）。
依存を順序づける費用は **barrier 0.31 µs**、encoder 境界はこの規模では測定不能。

## 層は鎖ではなかった（5日目の後半に判明、上の「次にやること」は差し替え）

上の第1項「層の antichain を数える」は**答えが出た。層は鎖ではない。**
私は `ds41_hc_mix` の内部（norm→matmul→sinkhorn）を見て鎖と判断したが、
**見るべきは枝の内部ではなく、枝の出力がいつ消費されるか**だった。出力で読むと:

- `ds41_hc_mix(ffn=false)` は `attn_split` を書く。直後の `hc_weighted_sum_bf16` が
  読むのは `residual` と `pre` で `attn_split` ではない。最初の消費者は
  `ds41_graph_after_attention` の `hc_expand`、つまり**attention 全体の後**。
  → **HC-attn 枝は attention を跨いで fork している**
- `ds41_hc_mix(ffn=true)` は `ffn_split` を書き、消費者は MoE 後の `hc_expand`。
  → **HC-ffn 枝は MoE を跨いで fork している**
- shared expert と routed experts は同じ `ffn_norm` しか読まず、
  `ds41_moe_finish` の加算まで独立。→ **互いに fork している**

**1層に2つ、1トークンに80の fork。** 最大は shared ∥ routed で、
shared は 1.50 GB/token（gate/up [5120→2304]・down [2304→5120] の Q8_0 ×40層）、
routed は 2.19 GiB/token。どちらも帯域律速で、今は互いを待っている。

### shared/routed を level に切るところまでは通った

両者は同じ2レベル構造で、レベルが揃う:

| level | routed | shared |
|---|---|---|
| 1 | gate/up pair-SwiGLU、1728 threadgroup | gate 1152、up 1152 |
| 2 | （SwiGLU は level 1 に融合済み） | SwiGLU |
| 3 | down sum over six、640 | down 2560 |

`ds4_gpu_routed_moe_one_gated` は既に `which` ビットマスク（1=gate/up、2=down）を
持つので新カーネルは要らない。`DS4_METAL_V41_FFN_OVERLAP=2` で
この順に直列発行して**バイト一致 6/6**（最長2048トークン）。コミット済み（`b557ad3`）。

**構造上の制約が1つ。** 継続（abort 後の再開）は routed と finish しか再実行しない
ので、shared を自層の validate の後ろに置けるのは継続が shared も覆う場合だけ。
routed stage に入れるとそれが満たされ、費用もゼロ（abort した層の shared は
そもそも走らず、継続で1回走る）。

### そして driver が受け付けない

level を concurrent section に入れると **AGX が segfault する**
（`insertIndirectTGOptKernel` の NULL 参照）。落ちるのは必ず
**section の後の最初の indirect dispatch**。この経路の dispatch は全て indirect
（abort gate が grid table 経由で発行するため）。6通りの二分（各回サーバ起動）:

| section の中身 | 結果 |
|---|---|
| routed L1・shared gate/up・SwiGLU・routed L2・shared down、間に barrier | `ds41_moe_finish` の add で落ちる |
| 同、level 区切りを encoder 境界に | shared SwiGLU で落ちる |
| 同、level 区切りなし | shared SwiGLU で落ちる |
| **shared gate と up だけ、routed は外** | **正常** |
| shared の3レベル＋barrier、routed は外 | `ds41_moe_finish` の add で落ちる |
| 並べ替えのみ（`=2`、section なし） | 正常、バイト一致 6/6 |

`proto/indirconc.m` に最小再現を7通り書いた（concurrent encoder 内の indirect、
barrier 併用、encoder 境界跨ぎ、threadgroup メモリ有無の混在）が
**どれも再現しない**。エンジン側の別の状態が要る。候補は expert cache が入っている
residency set、host と kernel の両方が書く grid table、bind 数、timeline encoder 経路。

**これが塞いでいるもの:** Metal 3 が提供する唯一の overlap 手段が concurrent encoder で、
それが MoE では今使えない。**塞いでいないもの:** 並べ替えはバイト一致でコミット済みなので、
section が通る日には overlap は2行。HC fork は address-table カーネルに触らない。

## 次にやること（順に）

### 1. shared ∥ routed overlap — 完了・計測済み（`ds4-v41` の `83106f5`）

実装済み（`DS4_METAL_V41_FFN_OVERLAP=1`）。構造は section 2つで、**SwiGLU と finish の add は section の外**に置く。これを守らないと AGX が
`insertIndirectTGOptKernel` で落ちる（bisect は下の表）。

```
section   routed gate/up/SwiGLU 1728 群  ||  shared gate 1152, up 1152
------    shared SwiGLU（1 dispatch、重ねる相手がない）
section   routed down sum 640            ||  shared down 2560
------    producer が畳めなかった BF16 丸め（既定では発生しない）
```

producer が丸めを畳めない構成（`FUSE_BF16=0`、`SHARED_PAIR_MODE≠0`）では
丸め pass が発生するので **section の外に出す**（`ds41_matmul_deferred` と
`ds41_moe_shared_round`）。この扱いを含めて 7 構成でバイト一致 6/6 を確認済み。

**計測（10 block ABBA・40 run、mode 1 対 mode 0、全検査通過）**:

| 指標 | 差 | 95% CI | block |
|---|---|---|---|
| raw wall（主） | **−1.95**（中央値 −1.05） | [−3.98, +0.09] | **10/10** |
| commit-to-done | −1.95 | [−3.80, −0.11] | 10/10 |
| GPU envelope | −2.08 | [−4.02, −0.15] | 10/10 |
| host encode | +0.14 | [+0.10, +0.17] | 0/10 |

符号検定 両側 p=0.002。raw wall の区間が 0 を 0.09 だけ含むのは block 1 が
campaign 最初の run（3519秒アイドル、52.48 ms/token、他39本は59.9〜67.3）を
on アームに抱えているため。以降9 block は平均 −1.09。
**帳簿上は約 1.0 ms/token として扱う。**

既定は OFF（`DS4_METAL_V41_FFN_OVERLAP=1` で有効）。既定 ON にするかは
次セッションの判断。

### 2. 次は perfect oracle で expert 投機の上限を測る（予測器の改良ではない）

**前に閉じた expert prefetch とは別物。** 全 expert 集合の完全一致（7.9%）ではなく、
当たった expert の中間結果を個別に再利用する話。lead 1 の expert 単位 recall は 65.8%
＝平均 3.95/6 本が一致する。

ただしこの機体には構造的上限がある。

- expert の入力 `ffn_norm` はその層の attention 完了後にしか存在しない
- したがって expert GEMV を前層から走らせることはできない
- EP 通信がないので、**隠せるのは router → select → validate の窓だけ**
- routed GEMV は帯域律速なので、投機が router を遅くし得る

**手順0（安い事前判定、これを先にやる）**: `apply-router-shadow.py` を当てて
`DS4_METAL_V41_SHADOW_ROUTER=1` で router 射影と select を二重に encode し、
envelope の増分で窓を測る。idempotent なので答えは動かない。validate は
zero 範囲が位置依存で idempotent でないため二重化しない（窓の下限になる）。
**窓が 1 ms 未満なら oracle を作らずに閉じる。**

**手順1（oracle の実装）**:

- トレース: `DS4_METAL_V41_GATE_ROUTE_LOG=<path>` が層ごとに
  `int32 [層, n, id0..id5, pad]` を 40 件/token で書く。温度0なので再現する
- `ffn_norm` 完成直後に concurrent section を開き、
  **oracle の id を別バッファに入れた routed level 1** と **router 射影＋select** を並べる
- section を閉じ、実物の `selected` で validate
- GPU 側の比較カーネルで `selected` と oracle を突き合わせ、不一致数を数える。
  **perfect oracle では 0 でなければならない**（0 でなければ計測は無効）
- routed level 2（down + sum）は実物の `selected` と route weight のまま、
  投機が書いた `mid` を読む。**重み付き総和の順序を変えない**ので bit 一致が保てる
- gate/up だけを対象にする理由: routed 6.38 ms のうち 3.91 ms を占め、
  出力側の保存・重み付け・加算順に触らずに済む

**3アームで測る**: baseline / oracle 投機して結果を捨てる（競合と余分な帯域の費用）/
oracle 投機して再利用する（完全予測時の正味上限）。
**再利用でも 1 ms 未満なら、この機体では router 窓が短すぎる**と結論して閉じる。
1 ms 以上出たときだけ、投機数 m=1…6 の precision 曲線へ進む。

### 3. HC fork（1層2回、80回/token）

`hc_mix` の出力 `attn_split` は attention 後の `hc_expand` まで、`ffn_split` は
MoE 後の `hc_expand` まで消費されない。1トークンあたり 167 dispatch
（1 群の row norm・24 群の F16 射影・1 群の Sinkhorn が各 55.7 本）。
address-table カーネルを含まないので、上の section 構造がそのまま使える見込み。

### 4. Q/KV defer と source 層の compression/indexer fork

小さい（既存コメントで KV 側は約 9 µs/layer）。上の3つの後。

### 5. Engram の非同期化

decode 入口で `ds4_engram_read_batch` を2テーブル分、**GPU を開始する前に**
読み切っている（`ds41_graph_step` 冒頭）。table 0 は層1、table 1 は層14まで不要。
`DS4_V41_DECODE_PROFILE=1` が `engram` の ms/token を既に出すので、
**まず1回走らせて大きさを見る**こと。

### 6. Metal 4

現コードは Metal 4 queue 対応を検出しているが実行に使っていない。
concurrency-by-default で encoder 間依存を barrier で表現できる。
AGX のクラッシュ条件を踏まない設計に移す道でもある。

## 探索終了（再挑戦不要）

4日目までの表は `HANDOFF-v41-3.md` と `V4.1-TUNING.md`。5日目で追加:

| 対象 | 判定 |
|---|---|
| 狭い射影5本の統合（lane 形式） | **終了**。+2.16 ms。前提が計器の誤り |
| 同（concurrent section） | **終了**。+0.70 ms、CI が0を含む。何も起きない |
| encoder 境界が高いという見立て | **撤回**。80境界/token が測定限界以下 |

## 計測の作法（今日追加した3条）

1. **census の key に grid を入れる。** サイトだけで keying すると、1つのサイトが
   複数の幅を捌いているとき「最初に来た形」がそのサイトの形として記録される。
   1日分の作業がこれで飛んだ
2. **判定を計器の表示精度で壊さない。** `pair.py` の仕事量一致判定は abort と
   command buffer は厳密一致、「abort の後ろの dispatch 数」は1桁の平均値なので
   表示精度分だけ許容する（20 run 中1本の1窓が 200.7 対 200.6 で止まった）。
   許容の代わりに最大ばらつきを常に印字する
3. **pgrep は自分にマッチする。** `bench/*.sh` の `wait_for_no_server` は
   `pgrep -f "ds4-server -m"` を見る。この文字列を含むコマンドライン（待ち合わせの
   シェルループなど）を並走させると、サーバが居ないのに「まだ走っている」と誤判定して
   arm が落ちる。待ち合わせを書くなら別のパターンにすること

## 最終状態

- **`ds4-v41`**: 5コミット（`83106f5` shared ∥ routed overlap を追加）+ 従来の4（`0ff6f35` census の grid keying / `bfda5d9` concurrent
  section と lane 形式の道具 / `a48d690` 2つの重ね方、両方とも既定 OFF・測定済み /
  `b557ad3` shared expert の level 分割、既定 OFF・バイト一致）。**未push。**
  未コミットは encode-ahead の275行のみ。ビルドは通り、既定経路はバイト一致 6/6
- **`inference-deploy`**: 記録4コミットと `bench/`・`proto/` の追加。**未PR**
- プロセス: サーバ・計測とも 0。最後の ABBA が 11:02 に終わっているので、
  次の測定前に休ませること（規則22）
