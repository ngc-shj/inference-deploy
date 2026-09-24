# 引き継ぎ: DeepSeek V4.1 Flash / decode attention は何に時間を使っていたか（12日目）

`HANDOFF-v41-10.md` の続き。v41-10 の計測作法・凍結項目・撤回済み主張はそのまま
有効で、ここでは繰り返さない。**変わったのは v41-10 の §「効くものの型」と
§「K-wide attention」の2節で、どちらも読み方が誤っていた。**

## v41-10 から変わったこと

| v41-10 の記述 | 現在 |
|---|---|
| `BLOCK_ATTN_K=1` は「K-wide attention」 | **誤り。** K 個の独立 attention を 1 grid に載せた exact-rows 版。KV 走査は一度も共有していない（§1） |
| 「K-wide attention は null」 | **測定対象が違った。** null が価格を付けたのは dispatch 統合だけで、重複走査については何も測っていない |
| 「per-row attention の 25% は overhead ではなく実仕事」 | **成立しない。** raw-only operator の時間は鍵数にほぼ依存せず、支配しているのは split-K の partial buffer（§3） |
| 「効くのは host 往復と実走査量。GPU dispatch 数と overlap は効かない」 | **広すぎた。** dispatch は約 5 µs/本で、8→1 は実在の 0.04 ms。走査共有も実在。どちらも split-K より小さい（§2, §3） |
| gathered 経路の「8 groups は次の FFN を 50 µs 遅くした、原因不明」 | **その腕は遅かったのではなく間違っていた。** reduce が NWG 未満の lane で隣の行の統計を読んでいた（§3） |

## 作業場所

- 主worktree: `~/ghq/github.com/antirez/ds4-v41-mtl4dag`、branch `perf/v41-mtl4-dag`
- HEAD: `93ffa05`（clean、未 push）
- 記録・ハーネス: この repository、branch `docs/v41-tuning`

| commit | 内容 |
|---|---|
| `bfac7d9` | raw-only 3形 operator、`ROWTILE_CHECK=7`、reduce の lane guard、`FIT_SPLITS` |
| `93ffa05` | layer 0–1 を共有 staging へ結線、`BLOCK_ATTN_K` の呼び名を事実に合わせた |

## 1. `BLOCK_ATTN_K` は KV を共有していない（コードから確定）

`ds4_gpu_attention_decode_heads_block_tensor`（`ds4_metal.m`）:

- `kv_stride = keys_max * head_dim * 2`、`nb13 = nb23 = kv_stride`、`ne_12_3 = rows`。
  つまり **行 i は staging の i 番目の複製を読む**
- その staging を作るのは関数内の `for (i = 0; i < rows; i++)` で、**mask fill と
  `encode_flash_kv_stage_f16` を行ごとに発行している**

host の row loop は消えたのではなく backend へ移った。block の行は raw prefix を
ほぼ全部共有しているのに、buffer にはその複製が K 本入る。

**したがって null が言えるのは「K 本の dispatch を 1 grid に畳んでも速くならない」
までで、重複走査の価格については何も言っていない。** `ds4_gpu.h` と `ds4_metal.m` の
説明文はこの内容に書き換え、engage 行も `queries in one dispatch over one key copy
each` にした。**性能 primitive ではなく batch-axis レイアウトの byte-exact oracle
として残す。**

## 2. 判別実験: layer 0–1 raw-only、6アーム（`DS4_V41_ROWTILE_CHECK=7`）

compressed KV の無い2層は交絡が無い。同じ鍵・同じ query に対して形だけを変え、
head 出力を operator 境界で memcmp し、round の偶奇でアーム順を入れ替える。

共有形が**新カーネル無しで**書けるのは `g->raw_prefill` が ring ではなく線形で、
block の行が連続位置だからである。`raw_start = avail - min(avail, SWA)` なので、
窓が埋まった後の base は **1 鍵ずつの等差**、埋まる前は全行 0。等差なら `nb13`
1本で表せる。各行は自分の base から自分の鍵数ぶんを読むので、chunk の切れ目も
canonical のままで、**6アームすべてが per-row と bit 一致した。**

### 窓が埋まった後（8行 × 128鍵、starts 0..7）

| アーム | forward | reversed | staged key rows |
|---|---:|---:|---:|
| per-row | 0.239 | 0.222 | 1024 |
| batch-axis（現行 `BLOCK_ATTN_K` の形） | 0.211 | 0.181 | 1024 |
| shared（union を1回 staging） | 0.171 | 0.171 | **135** |
| per-row/fit | 0.240 | 0.180 | 1024 |
| batch-axis/fit | 0.157 | 0.127 | 1024 |
| **shared/fit** | **0.100** | **0.101** | **135** |

### 窓が埋まる前（8行 × 32..39鍵、starts 全て 0）

| アーム | forward | reversed | staged |
|---|---:|---:|---:|
| per-row | 0.239 | 0.249 | 284 |
| batch-axis | 0.156 | 0.157 | 284 |
| shared | 0.137 | 0.138 | **39** |
| **shared/fit** | **0.069** | **0.070** | **39** |

**3つの別々の効果で、どれも両順序で同符号。**

| 何を変えたか | 価格 |
|---|---:|
| K 本の dispatch を 1 grid へ | −15%（約 5 µs/dispatch × 7） |
| union を 1 回 staging（走査共有） | さらに −13%、staging は 7.6分の1 |
| split-K workgroup を実在 chunk 数に合わせる | さらに **−41%** |

合計 0.230 → 0.100 ms、**−57%、bit 一致。**

## 3. 本命は split-K の partial buffer だった

アームが**鍵数にほぼ依存しない**（64鍵と128鍵が同じ時間）ことが指している。

`kernel_flash_attn_ext_vec` は鍵を 32 本の chunk に切り、workgroup `iwg` が
chunk `iwg, iwg+NWG, ...` を担当する。`NWG` は simd 幅に固定で **32**。
decode の 128 鍵窓では chunk は 4 本しか無いので、**32 本中 28 本の workgroup は
鍵を1本も見ずに、それでも DV 幅の partial と (sum,max) を書く。** rows=8 で
`nrows = 64 heads × 8 = 512`、`512 × 512 × 32 × 4 = 33.5 MB` を書き、reduce が
読み戻す。その 7/8 はゼロである。

`NWG` を実在 chunk 数に合わせると（128鍵なら 4、64鍵なら 2）partial は 8分の1 に
なる。**bit 一致する**——減らした workgroup が書いていたのは空の partial で、
それはこの reduction の単位元だからである（`M = -FLT_MAX/2`, `S = 0` →
`ms = 0`、寄与は厳密に 0）。

### なぜこの道が閉じていたか

gathered 経路には `DS4_METAL_FLASH_NWG` が最初からあり、コメントにこう書いてあった:

> 32 always: 8 groups at 128 keys saved 1 us in attention but made the later
> concurrent FFN block ~50 us slower (unexplained, measured)

`ds4_flash_attn_vec_reduce_row` は partial を `iwg = thread_index_in_simdgroup` で
読む。これは **NWG が何であれ 0..31 を走る**ので、`ss[rid*(2*NWG) + 2*iwg]` は
NWG < 32 のとき**次の行の統計を読んでいた**。つまりその腕は遅かったのではなく
**間違った答えを出していた**。「原因不明」はそこから来ている。

lane を split 数で守り、超えた lane には reduction の単位元を与えた
（`metal/flash_attn.metal`）。これで `DS4_METAL_FLASH_NWG=16` は全 logits 一致し、
single は 34.72 ms（既定 36.16 と同条件の run）になる。

**これも v41-10 §「計器由来の誤結論」と同じ型である——測定対象ではなく計器が
間違っていた。今回は計器がカーネル自身だった。**

## 4. `FIT_SPLITS` が通るまでに踏んだ2件

どちらも「間違った答えが再現する」のではなく **「2本の単一 pass が全 logits で
食い違う」** 形で出た。selftest の control（単一 pass をもう一度同じ比較にかける）が
無ければ、どちらも batch 側の問題として誤診していた。

1. **tmp scratch は伸びるだけ。** fit した NWG は層ごとに変わるので、鍵数の多い
   層が同じ command buffer の途中で buffer を拡張し、**既に encode 済みの dispatch の
   下で再確保**していた。v41-10 が KV slot 幅で踏んだのと同じ型。予約は常に最大
   split 数ぶんにし、fit するのは**使う量だけ**にした
2. **`NWG == 1` は別経路。** vec kernel は NWG==1 のとき自分で正規化し、統計を
   書かない（後段に reduce が無い前提）。この呼び出し側は常に reduce を出すので、
   書かれていない統計を読む。1 chunk でも split は 2 本にする（2本目は空で単位元）

## 5. いま入っているもの（すべて既定 OFF、すべて canonical single と byte 一致）

| flag | 中身 |
|---|---|
| `DS4_METAL_V41_FIT_SPLITS=1` | split-K workgroup 数を実在 chunk 数に合わせる。raw / gathered 両経路 |
| `DS4_METAL_V41_BLOCK_ATTN_RAW=1` | layer 0–1 を union 1回 staging の共有形へ。`FIT_SPLITS` と合成可 |
| `DS4_V41_ROWTILE_CHECK=7` | 上記6アームの判別実験（2 regime、memcmp + 両順序） |
| `DS4_METAL_FLASH_NWG=<n>` | 既存。**今回まで NWG<32 で壊れていた。** 直ったので再び使える |

検証: `BLOCK=1 EXACT_VOCAB_ROWS=1` に両 flag を足して
`control 0 of 8,273,920` / `batch logits identical to the single pass`。
layer 0–1 の engage 行 `8 raw-only rows over one staging of their union` を確認。

## 6. まだ測れていないもの: step での価格

**これが次の1本。** operator 境界では −57% だが、step でいくらかは未確定である。
ABBA を1本取ったが、**run の中で step が 196 → 311 ms までドリフトし、両順序が
符号で食い違った**（unset-first −14.9%、set-first +12.1%）。機体が静穏でなかった。

`bench/abba-when-quiet.sh` を足した——`startable.sh` の凍結条件が通るまで待ってから
`selftest.sh` の in-process ABBA を始める。次のセッションはここから読むこと。

見積もりだけ置く（**判断に使わないこと**）: per-row decode は `nrows = 64`、
`64 × 512 × 32 × 4 = 4.2 MB`/行/層、8行 × 40層で 1.34 GB を書いて読み戻す。
fit で 8分の1 なら 2.3 GB ぶんの往復が消える。**ただしこれはバイト数であって
時間ではない**——v41-10 が一度この換算で存在しない 38 ms を出している。

## 7. compressed 層へ進めない理由（レイアウトではなくカーネルが要る）

layer 2–39 は同じ手では書けない。**鍵の順序が塞いでいる。**

canonical な1行の鍵列は `[raw window][selected compressed]` である（`encode_flash_
kv_stage_f16` が dst の先頭に raw、その後ろに comp を置く）。連続位置の raw 窓は
1鍵ずつずれるので、行 i の comp が始まるべき位置は行 i+1 の raw が占める。
**共有 raw 領域と各行の選択集合を1本の線形 buffer に並べる置き方は存在しない。**

したがって compressed 側の走査共有には **行ごとの鍵 descriptor を取るカーネル**が
要る——選択集合の union を作り、key ごとの query multiplicity を持ち、
**load だけ共有して reduction 順は各 query の canonical 順を保つ**形である
（expert-major と同じく、共有順で足してはいけない）。`ds4_gpu_attention_indexed_
mixed_batch_heads_tensor` が indexed 形として既にあるが、v41-10 の通り別の
materialisation を読むので bit 一致しない。**そこから始めること。**

なお raw 窓が chunk 境界（128 = 32×4）に揃うのは窓が埋まった後だけなので、
2範囲カーネル（前半を共有 raw、後半を行ごと comp）なら長文脈では chunk 整列する。
ただし §2 の内訳では staging 共有は −13% のうちの一部で、**先に step での
`FIT_SPLITS` の価格を知らないと、この新カーネルが割に合うか決められない。**

## 8. threadgroup レベルの query tile について

「1 threadgroup が raw KV tile を一度 load して BR query へ適用する」形は**まだ
作っていない**。§2 の shared は **staging の共有**であって load の共有ではない
（attend は依然 8 行が別々に読むが、同じ 135 鍵 = 135 KB を読むので cache が吸う）。

作るなら形は決まっている。`DK=DV=512` では K/V tile を threadgroup memory に置く
余地が無い（32鍵 × 512 × 2 = 32 KB）ので、共有するのは **register に載せた 1 float4 を
BR 回使う**形になる。窓がずれる regime でも bit 一致は取れる——union の鍵 `u` を
一度 load し、`c = u - r` が `[0,32)` に入る行 r へ配る「階段」indexing にすれば、
各行の `mqk[r][c]` は自分の chunk のまま自分の ii 順で積まれる。

代償は register である。`mqk[BR][32]` は BR=2 で 64 float。v41-10 が
`sumf[8][NR0]` で踏んだのと同じ壁が BR=4 で来ると見てよい。**§3 が出た今、
これは優先度で3番目である。**

## 9. 次にやること（この順）

1. **`FIT_SPLITS` の step 価格を静穏機で取る**（`bench/abba-when-quiet.sh`）。
   両順序で同符号なら既定 ON の候補。ここが決まるまで下は着手しない
2. **`BLOCK_ATTN_RAW` の step 価格**を同じ形で。2/40 層なので小さいはずで、
   小さいことの確認が目的
3. compressed 選択集合の **overlap を実測**する。expert id の
   `GATE_ROUTE_LOG` と同じ形で `selected_comp` を層ごと行ごとに落とし、
   key ごとの multiplicity を出す。descriptor カーネルの賞金はここで決まる
4. descriptor カーネル（§7）。union から load し、query ごとの canonical 順で
   reduce する。**共有順で足さないこと**
5. query tile（§8）
6. v41-10 §「次にやること」の残り（expert-major、長文脈 memcmp、実 drafter）

## やらないこと（追加）

- **`BLOCK_ATTN_K` を性能 primitive として磨くこと。** oracle としてのみ残す
- **operator 境界の −57% を step の −57% として引用すること。** §6 が未確定
- **`DS4_METAL_FLASH_NWG` の過去の測定を引用すること。** NWG<32 は壊れていた
