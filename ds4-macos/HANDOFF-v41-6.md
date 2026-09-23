# 引き継ぎ: DeepSeek V4.1 Flash の Metal デコード最適化（7日目）

## 作業対象

- ワークツリー: `~/ghq/github.com/antirez/ds4-v41`（ブランチ `perf/v41-metal-apple`、**未push**）
- モデル: `~/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf`（340.6 GiB）
- 記録: `~/ghq/github.com/ngc-shj/inference-deploy` の `ds4-macos/`（ブランチ `docs/v41-tuning`、**未PR**）
- 機体: MacBook Pro / Apple M5 Max / 128 GB、GPU 40コア

先に読むこと: `ds4-macos/V4.1-TUNING.md` の「Day 6」節、`ds4-macos/bench/README.md`。

起動（新しいフラグは全て既定 OFF なので baseline は不変）:

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

## 6日目にやったこと

per-expert 投機再利用を**正解化**した（`983a8d3`）。6プロンプト・最長2048トークンで
baseline / 投機して捨てる（`ORACLE_MODE=2`）/ 投機して再利用（`ORACLE_MODE=1`）の
3アームが全てバイト一致。

5日目は「残りは route weight 1点」と引き継いだが、**欠陥は4つあり、route weight は
その中で最も浅いものだった**。詳細は `V4.1-TUNING.md` の Day 6 節。要点のみ:

1. **seam の位置が違った。** `silu*u` を保存して match で重みを掛ける設計は
   バイト一致しない。カーネルの式は `g/(1+exp(-g)) * u * route_weight` で、
   fast math はこの**鎖全体を1つの丸めとして畳む**。半分に切っても半分にならない。
   2048幅の行のうち1066個が相違、うち93%がちょうど1 ulp。
   `proto/assoc.m` が「乗算の結合則は無実」を示したのでこれが残った
   → **seam を GEMV の出力側へ移した。** 投機は専用の gate/up へ GEMV を書き、
   match がその行を実レーンへ複写し、validate 後のパスは埋まったレーンの
   **GEMV だけ**を飛ばして活性化は全レーンで出荷どおり走る。相違ゼロ
2. **router は鎖で、それを concurrent section に入れていた。** 射影が
   `route_logits` を書き、選択がそれを読む。section は中の2 dispatch を順序づけない。
   **`ORACLE_MODE=2`（投機を捨てる）まで答えが変わっていたのが発見の糸口**。
   今は section に「投機 ∥ 射影」だけを入れ、選択は section の外
3. **resident 判定が gate だけだった。** masked カーネルは gate/up のどちらが
   欠けても何も書かないので、gate だけ resident な予測が前トークンの行を返していた
4. **oracle を語彙IDで引いていた。** `ds41_graph_step` の `token` は入力トークンの
   語彙IDで、log 中の位置ではない。デコード済みトークン数で引くよう修正

修正後の oracle は本物の完全予測器として振る舞う（定常域・1トークンあたり）:

| | |
|---|---|
| 投機して resident だったレーン | 240 中 235.2 |
| 再利用したレーン | 235.2 |
| 実パスに残ったレーン | 4.8 |

残る 4.8 は expert cache の miss と同数。**完全予測器でも 2% は再利用できず、
それは予測ではなくストリーミングキャッシュの側**。

### 新しい診断

| | |
|---|---|
| `DS4_METAL_V41_SPEC_SECTION=0` | 投機と射影を直列に発行する対照。同じ dispatch・同じ結果・重なりだけ無し |
| `DS4_METAL_V41_ORACLE_MODE=3` | 全レーンを実パスで計算した上で、match に「再利用していたら同じビットだったか」を数えさせる |
| 同 `=4` | 実 route を予測として使う。投機と実パスが seam 以外で一切違わない状態にする |
| window report の `speculation:` 行 | 投機/再利用/残りのレーン数を毎窓印字。recall 率からの推論ではなく実数 |

### ハーネスの不具合を1つ直した

`abba.sh` と `correct-fast.sh` の `wait_for_no_server` が `ds4-v41/ds4-server` を
見ていたが、サーバは `./ds4-server` として起動されるのでこの文字列は
**コマンドラインに現れない**。5日目に「`ds4-server -m` は待ち合わせシェル自身に
マッチする」を直した際、逆方向に振り切れて**ガードが何もしない状態**になっていた。
`pgrep -x ds4-server`（プロセス名の完全一致）に変更。

**規則: 静かに失敗しうるガードには、発火することを確かめる試験が要る。**

## 最初の計測は「捨てた仕事」を測っていた

最初の paired campaign は +1.52 ms/token を出し、「投機が隠れていないから」と
結論した。**その帰属は誤りで、根拠にした「追加仕事は 2%」も誤りだった。**

abort 後の continuation が `l1_mask` を `0x3f` に戻していた。投機は validate の
**前**に発行されるので abort gate に落とされない。つまり abort 層では
投機が走り、match がレーンを埋め、そのうえで continuation が6レーン全部を
計算し直していた。window report の `reused` はこれを隠していた——
あれは「match が複写した行数」であって「計算を免れた GEMV の数」ではない。

`DS4_METAL_V41_SPEC_RESUME=0` で旧挙動を残し、**routed カーネル自身の中で**
数える新カウンタ（gate に落とされた dispatch では発火しない）で実測:

| | |
|---|---|
| match したレーン | 224.70 /token |
| **実際に省けた GEMV** | **163.50** |
| 捨てた分 | **61.20** |
| その run の abort | 12.75 /token |

`6 × 12.75 − 15.30 miss = 61.2`。定常域（abort 4.45/token）では routed gate/up の
約 9%。

修正: lane mask を層ごとのスロットにし（共有1ワードでは continuation まで
残らない）、`spec_filled` でどの層に投機の行が残っているかを持ち、
continuation では `0xffffffff` を渡して**repair が持ってきたレーンだけ**計算する。
再利用レーンは address table を**一切読まない**ようにした——これは整理ではなく
必要な修正で、continuation は `gate_repair` の後に走り、repair がそのレーンの
もう要らない expert を evict している可能性があり、旧来の「null address なら
早期 return」だと `mid` が書かれないまま静かに誤る。

これで `matched` と `saved` が一致し、両アームの演算量が揃う:

```
235.23 省いた + 4.77 計算した = 240.0 lane（baseline と同じ 240）
```

## そして、半分になってなお負けた



3 ブロック・12 run、`ORACLE_MODE=1` 対 oracle なし（両アームとも overlap ON）。
検査は全通過（全12 run で1ハッシュ、gate failure 0、22窓で仕事量一致、
両アームとも section が毎回開いた）。宣言差は投機自身の dispatch のみ。

continuation の carry を入れて再測（3 ブロック・12 run、両アーム overlap ON）。
検査は全通過（12 run で1ハッシュ、gate failure 0、22窓で仕事量一致）。

| | on − off | 95% CI | on 有利 block |
|---|---|---|---|
| **raw wall（主）** | **+0.98**（中央値 +0.93） | **[+0.25, +1.70]** | **0/3** |
| commit-to-done | +0.84 | [+0.35, +1.32] | 0/3 |
| GPU envelope | +0.81 | [+0.20, +1.43] | 0/3 |
| host encode | +0.09 | [+0.06, +0.12] | 0/3 |
| repair-load | +0.01 | [-0.51, +0.53] | 1/3 |

効果は +1.52 → +0.98 と半減した。捨てていた仕事がおよそ半分だったということで、
routed gate/up の 9% という見積もりと合う。**残りは捨てた仕事でも追加演算でもない
——両アームは同じ 240 lane を計算している。** そして主指標の区間が 0 を含まなく
なった（最初の campaign では含んでいた）。

### 残り 0.8 ms がどこにあり、どこにないか

設計の土台である overlap を単独で測った。`ORACLE_MODE=1` で
`SPEC_SECTION=1` 対 `=0`（同じ dispatch を section ではなく順に発行）。
仕事量は全窓で最終桁まで一致するので宣言は不要。

| | section − serial | 95% CI | block |
|---|---|---|---|
| raw wall | +0.25 | [-1.60, +2.09] | 1/3 |
| commit-to-done | -0.00 | [-1.15, +1.14] | 2/3 |
| GPU envelope | -0.31 | [-1.23, +0.61] | 3/3 |

**concurrent section の価値は envelope で高々 0.3 ms、0 と区別できない。**
理由ははっきりしている。投機が重なれるのは router の射影だけ（選択は鎖なので
後ろに置くしかない）で、その射影は 384 行への Q8_0 matvec 1本。
1728 threadgroup の IQ2_XXS を隠せる相手ではない。

つまり残り 0.8 ms は**構造**であって演算ではない。+56.4 gated dispatch、
+47 section/token、そして routed パスが相変わらず 1728 threadgroup を起動して
その 98% が mask 判定で即 return する。

### これで何が決まり、何が決まっていないか

**設定された基準では、この機構は割に合わない。** 基準は「GEMV 仕事量を
baseline の 240 lane に戻したうえで、なお oracle が遅いこと」だった。戻したし、
遅い——主指標で区間が 0 を含まない。予測器では救えない: 不完全な予測器は
投機を同じだけ行って省ける GEMV が減るので、すでに負の天井から悪い方へ動く。

**決まっていないのは「投機という形」そのもの。** 残った費用は層ごとの
dispatch/起動のオーバーヘッドで、重なれる相手が小さい射影1本しかなかった。
**segment 丸ごとを1 dispatch で投機する形**や、**HC fork や shared expert のように
大きい相手と重ねる形**は別の実験で、ここでは何も測っていない。
戻る道は「良い予測器」ではなく「隠れる相手が大きい構造」。

## Engram も閉じた: 0.82 ms/token

5日目が「まず1回走らせて大きさを見る」と書いた項目。走らせた:

```
ds4: v41 decode 288 steps: engram 0.817 + ... = 83.014 ms/token
```

**0.82 ms/token。** 非同期化しても上限がこれ。**割に合わないので閉じる。**

## トークンがどこへ行っているか

定常域・paired campaign の baseline アームから、55.7 ms/token:

| | ms | |
|---|---|---|
| commit-to-done | 41.1 | GPU |
| **repair-load** | **10.9** | **ホストが expert をロードしている** |
| host encode | 2.5 | |
| entry/tail | ~1.2 | |

10.9 はトークンの 1/5 で GPU の仕事ですらない。中身は 4.8 miss/token ——
完全 oracle が再利用できなかった 4.8 と同じ数字。

**ただしここは既に最も掘られている場所でもある。** prefill headroom の貸与は
実施済み、`mincore` は「欠けた expert のページの 92.8% は既に core にある」と
言っているので readahead を前倒しする余地はなく、`cachesim.py` は LRU 対
TinyLFU・2Q・層ごと配分・Belady・無限容量まで回してある（**現方針 4.91 miss 対
Belady 3.12**、シミュレータは実機を 4.91 対実測 4.94 で当てている）。
床は分かっていて、近い。`V4.1-TUNING.md` の 2209 行目から読むこと。

## 次にやること（有望度順）

1. **投機を別の形で。** 残った費用は層ごとの dispatch/起動であって演算ではない。
   40層 × 1 dispatch ではなく segment 丸ごと1 dispatch なら +56.4 dispatch/token は
   消える。重ねる相手も射影1本ではなく HC fork か shared expert を取る
2. **HC fork**（1層2回・80回/token）。address-table カーネルを含まないので
   shared∥routed と同じ section 構造が使える見込み。ただし shared∥routed は
   見込み 2.7 ms に対し実収 1.0 ms だったので期待値は割り引くこと
3. **Metal 4。** queue 対応は検出済み・未使用。AGX の
   `insertIndirectTGOptKernel` クラッシュを踏まない設計への道でもある

### 閉じた項目（再挑戦不要）

| 対象 | 判定 |
|---|---|
| per-expert 投機再利用 | **閉**。compact 化（launch も削減）と shared 三者並列化まで実装しても速くならず。完全 oracle・240 lane・バイト一致で、3 block とも遅い側。精度では解決しない |
| 層内の投機的 expert 並列化そのもの | **閉**。隠れる相手が router 射影1本しかなく、shared を並べても足りない |
| continuous batching | **対象外**（単一ストリーム改善が目標）。なお既に実装済みで、grouped MoE も `DS4_METAL_V41_BATCH_STREAM_EXPERTS` にあり未検証 |
| grouped GEMM による weight 再利用 | **実測済み・見送り**。幅4で gate/up の 81.7%、限界行の約6%。24.6/48 のうち 14.58 が単一行 expert |
| Engram の非同期化 | **閉** 0.82 ms/token しかない |
| 狭い射影5本の統合 | **閉**（5日目）前提が計器の誤り |
| encoder 境界が高いという見立て | **撤回**（5日目）測定限界以下 |

## 最終状態

- `ds4-v41`: 7 コミット、**未push**、作業ツリーはクリーン、ビルド可。
  既定経路は6プロンプトでバイト一致
- `inference-deploy`: 記録・ハーネス・prototype をコミット済み、**未PR**
- プロセス 0。`bench/thermal --until 0.97` で落ち着きを確認してから次を測ること
