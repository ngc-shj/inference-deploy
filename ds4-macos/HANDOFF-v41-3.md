# 引き継ぎ: DeepSeek V4.1 Flash の Metal デコード最適化（3日目）

## 作業対象

- ワークツリー: `~/ghq/github.com/antirez/ds4-v41`（ブランチ `perf/v41-metal-apple`、**未push**）
- モデル: `~/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf`（340.6 GiB）
- 記録: `~/ghq/github.com/ngc-shj/inference-deploy` の `ds4-macos/V4.1-TUNING.md`（ブランチ `docs/v41-tuning`、**未PR**）
- 機体: MacBook Pro / Apple M5 Max / 128 GB、GPU 40コア
- 現状: 実生成で持続 **19 tok/s 前後**、1トークン 46〜55 ms

現行 baseline の起動:

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

microbenchmark、帯域表、coverage 表は実装先を選ぶ証拠であって成果ではない。

## 探索終了（再挑戦不要、理由は測定済み）

| 対象 | 判定 | 根拠 |
|---|---|---|
| routed kernel | 終了 | cold sweep 6.38 ms / 375 GB/s。推定 7.02 との差 0.64 ms < 判定線 1.0 ms |
| 大規模 dense 投影3種 | 終了 | 574/525 GB/s（GPU span と host wall の両方で確認済み） |
| 投機デコード / MTP | 終了 | 損益分岐が 81〜88% 採択。gate 導入で 66〜76% から**悪化**した |
| readahead 前倒し | 終了 | miss 対象ページの 92.8% が既に in-core。前倒す相手がいない |
| router 直後 signal-only | 優先外 | shared expert の runway が約 0.35 ms/token しかない（40層 encoder 分割税を引く前） |
| residency commit のバッチ化 | 利益検出できず | 11.29 → 6.18 commit/token、時間は動かず。既定 OFF |
| token 末尾一括 prune | 利益検出できず | miss/abort/CB が4アーム同一。既定 OFF |
| prefill headroom 貸与 | 機構は確認、値は 0.25 ms | 既定 OFF |
| 行タイル IQ2 / 全アドレステーブル / expert readahead / ディスク律速 | 終了 | 2日目までの記録参照 |

数値の詳細はすべて `V4.1-TUNING.md` にある。

## 現在の分解（同一64トークン窓、飽和後）

```
gate over tokens N-N+63: 17.5 command buffers, 5.20 aborts, 240.0 expert ids,
  entry 0.00 + encode 2.8 + commit-to-done 38-46 + repair-load 3.5-5.3
  + accounting 0.3 + tail 1.4 = wall 47-55 ms, residual 0.01
  5.65 misses, 5.65 evictions a token
```

miss の限界費用は **wall 0.19〜0.38 ms/miss**（うち CPU 側 0.20、commit-to-done 側 0.00〜0.14）。
切片は主張しないこと（窓は 2.3〜13 miss、0-miss 窓は `gate_repair` が呼ばれない別レジーム）。

## 残っている候補（優先順）

### 1. ~~context 位置依存~~ — 終了。本命ではない

生成256トークンを固定し、context 長だけを変えた ABBA を2周（short-long-long-short x2、
`D-*`）。`PAD=0` と `PAD=400`（プロンプト先頭に無意味な行を400行挿入）。

ストリームの実 token 間隔（プレフィルを含まない、`rs-D-*.lat` の中央値）:

| | inter-chunk 中央値 |
|---|---|
| short 1/2/3/4 | 80.58 / 80.11 / 76.62 / 77.87 ms |
| long 1/2/3/4 | 76.90 / 86.45 / 83.03 / 84.46 ms |

ABBA 平均は short 78.8、long 82.7 ms。**差は +3.9 ms（+5%）で、アーム内ばらつき
（約4 ms）と同程度。** `ds41_graph_step` 内の wall は両者 75-87 ms で分離しない。

したがって **先に見えた位置傾き（5.8-26.2 ms / 1000 token）の大半は熱ドリフト**である。
この比率なら 800 トークンでは 0.8 ms にしかならない。
**attention core / KV / candidate filter / indexer は本命ではない。**

注意: stream の tok/s（short 10.2-11.0、long 3.48-3.70）で判断してはいけない。
long アームの wall 69-74 s のうちストリーム中は 22 s で、残り約 50 s は
パディング済みプロンプトのプレフィル1回分が計測窓に入っているだけである
（`stream(64)` の後に checkpoint が生成分だけ長くなり、次リクエストで
`ds4_tokens_starts_with` が成立せず全再プレフィルになる）。
**一度これを「約190 ms/token が graph step の外にある」と誤読し、撤回した。**

**結果として、`38 ms 窓と 50-55 ms 窓の差は依然として未説明`。** miss（限界 0.3 ms/個）
でも context 長でもない。次の候補2・3はこの差を説明できるとは限らないことに注意。

### 2. 40層本体の kernel fusion

2,736 dispatch/token。GPU command processor の固定費が 2〜5 µs/dispatch なら 5.5〜13.7 ms。
**未測定の仮説だが、routed の 0.64 ms よりはるかに大きい。** 先に固定費を実測すること
（例: 空カーネルを N 個並べた CB の GPU span を N で回帰）。

融合候補（演算順序を保てばビット一致可能）:
- GEMV producer 内で BF16 丸めまで行い、独立 BF16 kernel を消す
- HC weighted sum + RMSNorm
- attention 後の expand → BF16 → HC mix → weighted sum → norm
- routed + shared 加算 → BF16
- shared gate/up → SwiGLU → BF16

1個の巨大 fusion より、40層すべてで 2〜4 dispatch ずつ消す方を優先。

### 3. ghost-view cache

miss の 92.8% が in-core なので、現在の miss はデータ不在ではなく
「exact `MTLBuffer` view を破棄 → GPU VA/residency を破棄 → 同じ expert で再生成」
というオブジェクト churn が主。

resident cache とは別に bounded ghost-view cache（residency set と address table
からは外すが `MTLBuffer` object だけ一定数保持）を持ち、再 miss 時に
`newBufferWithBytesNoCopy` をやり直さず既存 view を residency へ戻す。
GPU wiring がどれだけ保持されるかは A/B が必要。**限界 0.20 ms/miss × 5.65 miss が上限**
なので、期待値は 1 ms 程度であることを先に認識しておくこと。

### 4. 総スループットが目標なら continuous batching

単一ストリーム tok/s の最大化が目標なら MTP が第一だったが、それは上で終了した。
aggregate throughput が目標なら複数 session の continuous batching が残る。

## 計測の作法（このセッションで実際に踏んだ罠）

1. **限界と平均を混同しない。** repair-load ÷ miss 数（平均 0.79 ms）を限界費用と誤って
   1.5〜2.9 ms/miss と報告した。正しくは回帰の傾き 0.20 ms。
2. **切片を外挿しない。** 観測範囲外（0 miss）へ外挿した固定費 3.36 ms を一度主張し、
   0-miss 窓が別レジームであることに気づいて撤回した。
3. **床を実時間として引かない。** all-hit 窓 38.13 ms は「最良観測窓」であり hardware floor
   ではない。50-55 ms との差 12〜17 ms を miss に帰属するのは誤り（miss は 0.3 ms/個）。
4. **帯域を用途外に転用しない。** dense 投影の 560 GB/s は resident weight を GPU が読む
   帯域で、cache miss の搬入帯域ではない。miss 経路は page wiring 約 1.7 ms/expert
   （`ds4_metal.m` の `ds4_gpu_stream_full_expert_addr_prewire` のコメント）。
5. **窓の scope を揃える。** 累積平均と64トークン窓の値を割り算してはいけない。
   report は必ず当該トークンの wall を加算した**後**に出す。
6. **経路が走った証拠を数で出す。** routed sweep は最初 4025 GB/s を出した。laps に
   完全比例していたが救いにならない（`selected` は host 書き込みの共有バッファなので、
   1つの CB 内の全ディスパッチが最後の書き込みを読む）。アドレス監査と install 数で
   閉じること。
7. **GPU span は `waitUntilCompleted` 時のみ加算される。** 待たない CB の時間は別 CB の
   値を読む。必ず host wall を併記する。
8. **run をまたいで引き算しない。** 同一バイナリ・同一窓で 48.06〜68.10 ms（29%）ぶれる。
9. **連続起動でページキャッシュを壊さない。** 1400トークン×8本を連続で回したら
   0.88〜17.76 tok/s まで崩壊した。40〜60秒の間隔を空け、崩れた run は破棄する。
10. **A/B トグルが実際に効いているかを毎回確認する。** 印字で経路が走った証拠を出す。

## 有用な env と計器

| env | 用途 |
|---|---|
| `DS4_METAL_V41_ABORT_GATE=40` | abort gate（現 baseline の一部） |
| `DS4_METAL_V41_ABORT_GATE_SEG=3` | segment 長（2-3 が最良） |
| `DS4_METAL_V41_ROUTED_SWEEP=gate_up\|down\|both` + `_LAPS` | routed cold sweep |
| `DS4_METAL_V41_COLD_SWEEP=q_b\|output_a\|output_b` + `_LAPS` | dense cold sweep |
| `DS4_METAL_MISS_RESIDENCY=8 DS4_METAL_MISS_RESIDENCY_SAMPLE=16` | miss 時の in-core 率 |
| `DS4_METAL_V41_GATE_ROUTE_LOG=<path>` | route log（容量シミュレーション用） |
| `DS4_METAL_V41_REPAIR_BATCH=1` | residency transaction + 末尾 prune（既定 OFF） |
| `DS4_METAL_V41_DECODE_LEND_HEADROOM=1` | prefill headroom 貸与（既定 OFF） |
| `DS4_V41_VERIFY_SELFTEST=k` + `_ROUNDS` | batch 行コストと損益分岐 |
| `DS4_METAL_V41_WEIGHT_LEDGER=1` | shape からの weight bytes 積み上げ |

route log の容量シミュレータ（LRU、実測と一致）は前セッション scratchpad の `sim.py`。

## 仕様として残る発見

**巻き戻しは `previous_kv[0..2]` / `previous_score[0..2]` を復元しないと壊れる。**
`ratio==2` の層が2位置を1つの圧縮エントリに畳み、前半をこの2つに持ち越すため。
復元しないと静かに違う出力になる。投機デコードや任意のリトライ実装は必ず踏む。
