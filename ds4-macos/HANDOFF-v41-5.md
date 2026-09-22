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

## 次にやること（順に）

1. **層の antichain を数える。機械不要。** 488.7本 × 2.16 µs = 1.06 ms、上の帯も
   合わせればもっとある。ただし回収できるのは互いに独立な分だけで、デコード層は
   ほぼ鎖である（`ds41_hc_mix` は norm→matmul→sinkhorn の3連鎖、`ds41_norm` は
   直後の matmul に食われる）。**はっきりした antichain は
   `q_a→norm→q_b` と `kv→norm` の2本だけで、しかも太い方が支配する。**
   まずグラフを読んで、独立な隣接対が1層に何本あるかを数えること。数が出ない限り
   次の実装に進まない
2. **数が出たら: segment 全体を1つの concurrent encoder にし、グラフの実際の辺
   にだけ barrier を置く。** section を広げるのではなく、serial encoder をやめる。
   1,511.7本を無条件に順序づけているのを、必要な所だけにする。今週試したどれより
   大きい変更で、賞金はまだ未知
3. **encode-ahead（4日目の (b)）。ワークツリーに未コミットで残っている（268行、
   既定 OFF、未検証）。** `DS4_METAL_V41_GATE_ENCODE_AHEAD=1`。投機的中率 78〜79%、
   GPU の下に隠した encode 0.92 ms/token を実測済み。バイト一致と仕事量一致を
   取り直してから ABBA。4日目の欠陥修正2件が入った後の検証はまだ
4. continuous batching（単一ストリームの目的外だが、集約目標では未着手）

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

- **`ds4-v41`**: 3コミット（`0ff6f35` census の grid keying / `bfda5d9` concurrent
  section と lane 形式の道具 / `a48d690` 2つの重ね方、両方とも既定 OFF・測定済み）。
  **未push。** 未コミットは encode-ahead の268行のみ（上の3）。ビルドは通る
- **`inference-deploy`**: 記録2コミットと `bench/` の追加。**未PR**
- プロセス: サーバ・計測とも 0。最後の ABBA が 11:02 に終わっているので、
  次の測定前に休ませること（規則22）
