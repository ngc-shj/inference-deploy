# 引き継ぎ: DeepSeek V4.1 Flash / Metal 4 と実行器（10日目）

## 目的

**品質を変えず、持続 wall time/token を削ること。** Metal 4 の正解化そのものは成果ではない。

到達目標は会話の中で三度変わった。最終的に置かれたのは次である。

> **単一session 100 tok/s。**

これは逐次実行では物理的に不可能であることが算術で確定している。

```
active weights 10.496 GB/token ÷ 614 GB/s = 17.1 ms/token = 58.5 tok/s
```

attention・KV・SSD・dispatch を全部ゼロにした床。Metal 4、placement sparse、MTLIO、
Neural Accelerator はこの床を破らない。**1回のweight走査で複数tokenを検証する以外に
道がない。** よって最終形は multi-session wavefront ではなく、単一sessionの
**speculative block executor**（rowの意味を「独立session」から「同一session内の
speculative position」へ変える）。

30 tok/s なら逐次経路の改善でも視野に入る。100 は畳み込みが必須。

## 作業場所

- 主worktree: `~/ghq/github.com/antirez/ds4-v41-mtl4dag`、branch `perf/v41-mtl4-dag`
- HEAD: `0980a5b`（clean）
- Metal 3 対照: `~/ghq/github.com/antirez/ds4-v41`、branch `perf/v41-metal-apple`、`91b18e5`
- 旧shim（検証資産として残置）: `~/ghq/github.com/antirez/ds4-v41-mtl4`、`8377a54`
- 記録・ハーネス: この repository、branch `docs/v41-tuning`
- 全て未 push / 未 PR

### `perf/v41-mtl4-dag` の履歴

| commit | 内容 |
|---|---|
| `91b18e5` | Metal 3 continuous encode-ahead（対照の基準） |
| `5a2430b` | DS4Encoder protocol（facade、cherry-pick） |
| `6a61ec7` | Metal 4 backend が全40層でバイト一致 |
| `65b50a6` `33163b4` | concurrent section復活、空Metal 3 CB省略、seamをGPU eventへ |
| `fa699b0` | scaffold-only session batch |
| `daf5a68` | 欠陥をoutput headに局在 |
| `6c25a41` | `EXACT_VOCAB_ROWS`、byte-exact multi-row oracle |
| `cc97c5c` | head専用 exact weight-reuse kernel（rows2 / rows4） |
| `aa8d047` | shape別の共有上限測定 |
| `5d212dc` | lockstep stall exposure の測定 |
| `0980a5b` | **row wavefront（動作していない）** |

## 確定した事実

### Metal 4 は正しいが速くない

全40層・実weight・実運用経路で baseline とファイル単位一致。8日間 barrier をいじっても
動かなかった byte-wrong の原因は **encoder内の順序ではなく、Metal 3↔4 境界の未順序付け
2箇所**（region内の `tensor_copy` blit、region入口に残る batch buffer）。

静穏機で事前登録 A–B–B–A（`bench/campaign-mtl4.sh`、同一バイナリで `MTL4=0/1` のみ差）:

| | on (Metal 4) | off (Metal 3) | 差 |
|---|---:|---:|---:|
| raw wall mean | 65.72 | 65.03 | +0.70 ms/token |
| median | 67.98 | 66.22 | +1.77 |

95% CI [-2.75, +4.15]、3ブロック中1つだけ有利。**有意な劣化ではないが利得の兆候も無い。**
host encode だけが CI で0を除外して悪い（+0.24 ms、[+0.19, +0.30]）。

GPU envelope が on 1.44 / off 49.27 と出るのは**計器の故障**。`ds4_gpu_take_span_ms()` は
Metal 3 buffer の span を測り、Metal 4 経路ではそれが空だから小さいだけ。読んではいけない。

### byte-exact multi-row oracle

`DS4_METAL_V41_EXACT_VOCAB_ROWS=1`。`ds41_matmul_batch` が `outputs != DS4_N_VOCAB` で
語彙headだけを exact-rows kernel から除外していたのが、session batch が単一行と
食い違った唯一の原因。**dispatch policy だった。**

検証は生logitsで行う（テキストhashでは弱い）。`DS4_METAL_V41_LOGITS_DUMP=<path>` が
両経路で位置ごとに head 出力全体を書き出す。**512位置 × 129,280 float × 全行が memcmp 一致**
（count=2/4/8）。位置19は単一行側に2レコードある（prefill frontier と最初のdecode）ので
どちらかに一致すればよい。

batch側の dump には専用drainが要る。step復帰時点で `s->logits` へのコピーは未実行。

### head専用 exact weight-reuse kernel

`metal/dense.metal` の `kernel_mul_mv_q8_0_f32_rows2/4`。weight blockのquantとscaleを
**明示的にregisterへ**読み、BR行へ適用。K walk・i順・FMA順・reduction treeは単一行のまま、
batch方向のreductionは無し。helper呼び出し間に `threadgroup_barrier`（helperは末尾に
barrierを持たない）。`DS4_METAL_V41_HEAD_ROW_TILE=2|4`、既定off、失敗は静かにfallbackせず error。

head単独（K=5120 N=129280、weight 0.703 GB/pass、専用CB、ABBA、`DS4_METAL_V41_DENSE_BENCH`）:

```
rows=2  B1 1.179   exact 1.400   rows2 1.184   （理想単一pass 1.145、597 GB/s ≈ 帯域97%）
rows=4          exact 2.853   rows2x2 2.074   rows4 1.463
```

**exact は B=2 では約1 pass しか読んでいない**（cache共有）。4行では崩れて2.5 pass。
つまり「exactは既に共有できている」はB=2限定の性質。

### 他shapeへの汎用化は上限不足で保留

| shape | K×N | GB | exact B2 | fused B2 | /token | B2回収 |
|---|---|---:|---:|---:|---:|---:|
| head | 5120×129280 | 0.703 | 1.400 | 1.184 | 1 | +0.216 ms |
| attn_output_b | 8192×5120 | 0.045 | 0.064 | 0.070 | 40 | **−0.255 ms** |
| shexp_gate | 5120×2304 | 0.013 | 0.019 | 0.017 | 40 | +0.110 |
| shexp_up | 5120×2304 | 0.013 | 0.019 | 0.018 | 40 | +0.056 |
| shexp_down | 2304×5120 | 0.013 | 0.026 | 0.020 | 40 | +0.245 |

**合計 0.371 ms/step = 0.186 ms/出力token。** 45 MB の `attn_output_b` は fused が遅い
（帯域でなくoccupancyが効く）。汎用化は局所最適で、退行を含む。

### continuous batching は実装済みだった

`--batched-session <n>`、`decode_worker_main` の coalesce、batched dense/attention、
そして `batch_stream_experts`（1つのaddress tableでbatch全体、`ds4.c:44088`）が全て存在し、
streaming では2枚のenvで閉じられていた。

| 構成 | 集計 tok/s |
|---|---:|
| 1 slot 逐次 | 14.92 |
| 2 slot（exact head） | 14.91 |
| 4 slot | 8.73 |
| 8 slot | 9.13 |

**Bを増やしても集計は増えない。** stage内訳（count=4、`DS4_V41_BATCH_STAGE_MS`、
CB境界で総額は膨らむので比率が要点）: pre 18.4% / per-row attention 31.8% / **moe 49.8%**。
3段とも行数にほぼ線形で、1行あたりは2→4行で5〜8%しか下がらない。

`BATCH_STREAM_EXPERTS=1` は約80 tokenで生成が崩壊する（未修正）。

### expert共有の期待値（独立route）

| rows | 選択総数 | 期待unique | 削減 |
|---:|---:|---:|---:|
| 2 | 12 | 11.91 | 0.8% |
| 4 | 24 | 23.44 | 2.3% |
| 8 | 48 | 45.46 | 5.3% |
| 16 | 96 | ~85 | ~11% |
| 32 | 192 | ~152 | ~21% |

MoEが49.8%を占めることと、MoEに改善余地があることは別。expert-major は B=16以上で初めて意味を持つ。

### lockstep stall exposure

`DS4_METAL_V41_WAVE_PROBE=1`。2行・異種prompt・20,000 row-layer:
**37.5%の層で missing row と resident row が混在**し、その層で missing 15,487 ms /
resident 107 ms。78.8 s の run に対する 15.5 s は **stall exposure であって
recoverable time ではない**。実際の回収量は resident row が次のmissへ到達するまでの
仕事量と修復の重なりで決まる。それでも row-tile の 0.186 ms/token より二桁大きい。

### repair-load の正体は未分離

steady window 90本の回帰: `repair = 0.0995 ms/MiB × MiB + 3.60 ms`、r² 0.529、
傾きは 9.58 GB/s（原点通しなら 6.00）。1 missあたり median 9.49 MiB で分散がほぼ無く、
**MiBとmiss数は同一変数**なので「帯域」と「per-miss overhead」を統計的に分離できない。
mincore は 92.8% in-core。切片3.60 msを「VM税の上限」とは呼べない。

## 撤回した主張（同じ穴に落ちないため）

- 「Metal 4 が遅い」→ 撤回。有意な劣化ではない。維持できるのは「Metal 3 の提出構造を
  Metal 4 で再現しても利益はない」だけ
- 「batched head は原理的にビット一致不能」→ 撤回。dispatch policy だった
- 「レースは `6a61ec7` から存在した」→ 撤回。清浄な `6a61ec7` は 3/3 一致。原因は
  空Metal 4 CB省略が `g_mtl4_cur` を残し、region外までMetal 4経路を握っていたこと
- 「11個の `DISABLE_V41_BATCH_*` を落としたので scaffolding に確定」→ 撤回。あの多くは
  `ds41_graph_prefill_sweep()` 側の解釈で、session batch関数では効かない
- 「abort gate が約30%の損失」→ 撤回。対で取ると gate ON/OFF は 51.0/51.8 s で同じ。
  25.8 s は expert cache の温度

## いま壊れているもの

### row wavefront（`0980a5b`）

`DS4_METAL_V41_WAVE=1`。park off（既定）で **breakout 一致 / quicksort 不一致**。
片方の row が一貫して正しく、片方が一貫して誤る。lockstep との差はあと1〜2の per-row 状態。

済んだ修正（各々必要だが不十分）:

- row配列をヒープへ。`ds41_gpu_graph` を値で8行はdecode threadのスタックを超え、
  最初の走行は `__chkstk_darwin` で死んだ
- `ds4_gpu_routed_moe_set_row_slot()` を呼ぶ（routed scratchは行ごと）
- `ds41_wave_refresh()` で層ごとに session から graph を再コピー（lockstepはそうしている）

未修正（ご指摘済み）:

1. **lease の global generation は正しさ判定に使えない。** 別layer・別expertのpublishでも
   失効する。per-slot generation（layer, expert, slot, slot_generation）をlease entryに
   保存し、submit時に slot同一性・generation一致・address非zero・READY・pin保持を確認する。
   そして pin が効いていれば不一致は起きない——不一致は fallback 条件ではなく
   **cache invariant違反**
2. **missing expert を load 前に予約・pin する。** 現在の `repin()` は遅い。missing A を
   ロードした後 missing B のロードが A を evict できる。`acquire_set()` で6本すべてを
   保護（resident は現entryをpin、missing は slot予約してLOADING+pin）
3. **cache操作を同一lock／owner threadへ限定。** `pins` の確認・増減・victim選択は同じ
   lock下で行わなければ service thread 化で壊れる。GPU completion handler から
   `release_set()` を直接呼ばず、ticketを owner thread の queue へ返す
4. `HEAD_INFLIGHT` を追加し、head は row が到着次第 submit。compatibility wrapper だけが
   全row完了を待つ

### `BATCH_STREAM_EXPERTS` の状態機械破綻

約80 tokenで生成停止。未着手。

## 次にやること（この順）

### 1. draft品質を独立に確定する（最優先）

**100 tok/s の成否はここで決まる。** verifier速度と分離して測る。

測定基盤は既にある: `accepted_len_hist[DS4_DSPARK_MAX_BLOCK_SIZE+1]` と `draft_len_hist`、
両方を出す統計行（`ds4.c:76050`）、`DS4_DSPARK_MAX_BLOCK_SIZE = 16`。

**ただし block size は env ではなくモデルメタデータ** `deepseek4.dspark_block_size`
（`ds4.c:3019`、`18263`）から来る。現在のログに dspark/MTP の痕跡は無く、
`DeepSeek-V4.1-Flash-Q2.gguf` が drafter 重みを持つかは**未確認**。まずそこを確認する。

取るもの: K=4/8/16、accepted prefix分布、平均前進token、prompt種別別、位置別、draft生成時間。

判定: **K=8 で平均6前後に届かなければ、カーネルをどう速くしても100 tok/sは不可能。**
その場合は MTP/draft model 自体を変える必要がある。既知の「平均1.79 token前進」が
正しいなら全く足りない。

必要weight量の概算（K行でdense共有、routed 2.389 GB/tokenは共有せず）:

| K | weight/step | 実測帯域からの床 | 100 tok/sに必要な平均前進 |
|---:|---:|---:|---:|
| 4 | 約17.4 GB | 約39 ms | ほぼ4 token |
| 8 | 約26.2 GB | 約63 ms | 6.3 以上 |
| 16 | 約42.2 GB | 約105 ms | 10.5 以上 |

### 2. wave を正しさまで通して役割を切り替える

draft が成立するなら、wave は本番アーキテクチャではない。ただし次までは通す価値がある。

1. B=2 all-hit で wave state machine が正しい
2. 1 miss で lease transaction が正しい
3. pinned eviction・generation違反・release漏れが 0
4. **そこで multi-session 性能開発を止める**
5. row を speculative position へ置き換える
6. K=4/8 の layer-major verifier へ進む

### 3. speculative block executor

rowの意味を変える。shadow化が必要な状態:

- 4本の hyper-connection residual
- position-indexed KV / index state
- `previous_kv` / `previous_score`
- Engram history と2つの disk row
- compression ratio 2 の未完ペア
- route IDs / weights、token history

既存stateへ逐次書いてrollbackするのではなく、K位置のshadow arenaへ書き、検証後に
accepted prefix だけを本stateへpublishする。reject時の復元処理自体が消える。

## 計測の作法（何度も踏んだ）

- **単発の壁時計はこの機体では意味を持たない。** gate ON/OFF が 51.0 s で同じなのに
  単発では 25.8 対 51.0 に見えた。cache温度と thermal で40%動く
- `bench/campaign-mtl4.sh` のように**事前登録**し、`startable.sh` の凍結条件を満たすまで
  待つ。閾値は動かさない。`loadlog.sh` を起動しておく
- `startable.sh` は直近n窓が**連続**であることを検査する（`0e584b9` で追加）。以前は
  6時間前の窓が混ざっていた
- `pair.py` は窓ごとに header の次から最大24行を読む（`e247c5a` で修正）。以前は固定7行で、
  診断行1本が cache 行を押し出して**片腕の窓が全滅し、しかも合格と報告された**
- 片腕の窓が0本なら `REFUSING`（同じcommitで追加）
- **計器が答えを変えたら、その計器は使えない。** `ds41_gate_trace` に drain を入れると
  `11f8569e` と `c6453f19` に分かれる。既存の同期点で読むものだけを使う。
  `ds41_moe_probe`（`ds41_moe_partial` 復帰直後）は答えに中立
- probe を位置で揃える。呼び出し順で揃えると別sessionのtoken 1と比較する
- Defender は常駐分が残る。UIを閉じてもデーモンとシステム拡張は動く
- **ヘッダだけを触った実験は再ビルドを確認する。** `Makefile` の `ds4_metal.o` 依存は
  手書きで、`ds4_metal_mtl4.h` と `ds4_metal_enc_trace.h` は `6a61ec7` で追加した。
  他のworktreeはまだ手書きのまま

## 有用な計器

| env | 何を出すか |
|---|---|
| `DS4_METAL_V41_LOGITS_DUMP=<path>` | head出力全体を位置ごとに。memcmpの本体 |
| `DS4_METAL_V41_ENC_TRACE=<path>` | encoderに言われたことを1行ずつ。bufferは初出順の番号 |
| `DS4_METAL_V41_MOE_PROBE=<n>` | 層ごとに11 tensorのhash。答えに中立 |
| `DS4_METAL_V41_DENSE_BENCH=<laps>` | shape別 B1/exactB2/fusedB2/B4 |
| `DS4_METAL_V41_WAVE_PROBE=1` | 行ごとのmissと待ち時間 |
| `DS4_V41_BATCH_STAGE_MS=1` | pre / per-row attention / moe の比率 |
| `DS4_SERVER_BATCH_LOG=1` | `count=N row0=slotX row1=slotY` |

ハーネス: `bench/one.sh` 相当（1プロンプト512 token）、`bench/batch.sh` 相当（N並行、
`AA=`で同一プロンプト、`REPS=`で本数）は scratchpad にあり未コミット。
`bench/correct-fast.sh`（2プロンプト）、`bench/correct.sh`（6プロンプト・最長2048）、
`bench/abba.sh`、`bench/pair.py`、`bench/campaign-mtl4.sh` は repository にある。

既知hash: breakout `d68de436f26c7913`、quicksort `c6453f195ef62ce3`、
haiku `7a706776a8529f39`、json `412ef20f1f431007`、proof `be6e3525eefa1738`、
long `c7456ea2ec552047`。production env は
`ABORT_GATE=40 ABORT_GATE_SEG=3 EXPERT_RESIDENCY_SET=1 FFN_OVERLAP=1 GATE_ENCODE_AHEAD=1`。

## やらないこと

- Q8 row-tile の汎用横展開（上限0.186 ms/token、退行含む）
- attention core の multi-row 化と expert-major を先に作る（前者は共有weightなし、
  後者はB=8でも5.3%）
- Metal 4 を submission API として磨く（submissionとhost encodeで数百µsの段階ではない）
- per-expert投機、Engram async、HC fork、cache policy 再探索（`HANDOFF-v41-6.md` で閉じている）
