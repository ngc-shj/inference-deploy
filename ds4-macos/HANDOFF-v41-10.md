# 引き継ぎ: DeepSeek V4.1 Flash / 100 tok/s の律速はどこか（11日目）

`HANDOFF-v41-9.md` の続き。**v41-9 の「次にやること」の順序は誤っているので、
そちらの §「次にやること」は読まなくてよい。** それ以外の確定事項・撤回済み主張・
計測の作法は v41-9 が有効で、ここでは繰り返さない。

## v41-9 から変わったこと（要約）

| v41-9 の記述 | 現在 |
|---|---|
| 「最優先は draft 品質の独立測定」 | **誤り。** perfect draft でも K=8 verifier は 255 ms/step、上限 31.3 tok/s。先に verifier を速くする |
| row wavefront は壊れている（`0980a5b`） | **修正済み。** 出力一致・違反 0。ただし遅く、凍結対象 |
| expert 共有は B=8 で 5.3% | **撤回。** 独立 route の算数だった。実測は層あたり 48 選択 → 26.4 unique（約45%重複） |
| （v41-10 初版）本命は expert-major | **半分だけ正しい。** moe は step の 42% で、ゼロにしても 54 tok/s 止まり。per-row attention が同じだけ効く |
| （v41-10 初版）hoist は weight 再読を止めた | **誤り。** exact-rows は行ごとに weight を読み直す。確立したのは「1 dispatch が 8 dispatch より速い」までで、理由は未確定 |
| （v41-10 初版）hoist は −11.2% | **過大。** A/B の順序バイアスだった。真の ABBA で約 −6% |
| （v41-10 初版）次は `attn_output_a` の hoist と長文脈計測 | **違う。** 個々の matmul ではなく executor の抽象化を直す。§0b |

結果として、v41-9 の「やらないこと」に入っていた2項目が、測り直した数字で昇格した——
**expert-major 化**と、**per-row attention の multi-row 化**である。どちらも
「共有できる weight は無い」という判断で閉じられていたが、その判断が独立 session の
前提で書かれていた点が共通している。どちらか一方では 100 tok/s に届かない（§0）。

## 作業場所

- 主worktree: `~/ghq/github.com/antirez/ds4-v41-mtl4dag`、branch `perf/v41-mtl4-dag`
- HEAD: `7c4ec2e`（clean）
- 記録・ハーネス: この repository、branch `docs/v41-tuning`、`8714389`
- 対照・旧shim の位置は v41-9 のまま。全て未 push / 未 PR

| commit | 内容 |
|---|---|
| `0980a5b` | wave 修正 + dense row-tile。**メッセージが事実と食い違う**（下記） |
| `0066bc7` | perfect-draft 上限の表示、`0980a5b` のメッセージ訂正 |
| `7c4ec2e` | K=8 の stage 内訳、attn_output_b の hoist、batch 用 in-process A/B |

`0980a5b` の "A row wavefront that does not produce the right answer yet" は誤り。
wave 修正と dense row-tile 実験がメッセージを書いた後にこのコミットへ入った。
amend せず `0066bc7` のメッセージで訂正済み。

## 決定的な数字: verifier は帯域律速ですらない

`DS4_V41_VERIFY_SELFTEST=<k>` に上限を直接表示する計器を足した（`ds4.c:45450`、未コミット）。

```
perfect-draft ceiling: %.2f tok/s (100 tok/s requires <= %.2f ms/step)
   = 1000 * k / bm                        = 10 * k
```

K=8 の実測（静穏時、3本: 254.2 / 255.3 / 262.2 ms、spread 約3%）:

| | 値 |
|---|---:|
| median 8-row step | 255 ms |
| perfect draft での上限 | 31.3 tok/s |
| 100 tok/s に必要な step 時間 | ≤ 80 ms |
| 必要な短縮 | **3.2x** |

**前セッションの 361 ms / 22.2 tok/s は再現しない。** この機体は同じ K=8 step が
3時間差で 255 ms と 427 ms になる。絶対値を一本の run から引用してはいけない——
本文書の絶対値も同様で、判断に使うのは比率と同一プロセス内の対である。

v41-9 の表は K=8 の帯域床を約63 ms/step と置いていた。**255 ms はその4倍**で、
verifier は帯域の近くにいない。だから draft 品質を先に測っても意思決定に使えない——
accepted 長が 8/8 であっても 31 tok/s で頭打ちになる。

**judgment: K=8 を 80 ms/step 以下へ入れることが、他の何よりも先に来る。**

### 80 ms は上限であって条件ではない

本当の条件は次である。

```
verifier step + draft 生成 + accept/rollback  <=  10 ms × 平均前進トークン数
```

80 ms/step は **K=8 を全採択し、draft 費用がゼロの場合だけ**の上限である。平均前進が
6 なら総予算は 60 ms で、そこから draft と accept/rollback を引いた残りが verifier の
取り分になる。本文書の「perfect-draft ceiling」はすべて**その上限側**の数字であり、
達成可能な tok/s ではない。実 drafter の平均前進数と掛け合わせるのは最後の工程である
（§5）。

## expert-major の賞金は実在する（v41-9 の 5.3% を撤回）

v41-9 の共有期待値の表は「独立 session が独立に route する」前提の算数だった。
speculative block は同一 session の連続 token なので、route は独立ではない。

実測（`DS4_METAL_V41_GATE_ROUTE_LOG`、連続 token の層ごとの選択 id を突き合わせ）:

| | 値 |
|---|---:|
| K=8 の層あたり選択総数 | 48（6 experts × 8 rows） |
| 層あたり平均 unique | **26.4** |
| 重複率 | 約 45% |

routed weight は 2.389 GB/token。K=8 で共有しなければ 19.1 GB、26.4/48 まで畳めば
**約10 GB**。dense は K 行で共有済みなので **約8 GB**。合計約18 GB/block。

| 想定帯域 | 18 GB の所要 |
|---|---:|
| 614 GB/s（peak） | 29 ms |
| 416 GB/s（v41-9 の床の表が暗に使っていた実効値） | 45 ms |

どちらでも 80 ms の内側にある。**routed weight の側から見れば K=8 で 100 tok/s は
射程に入る。**

**ただしこれは moe が step を支配していれば、の話である。実測では 42% しか無い**（§0）。
上の 18 GB は「weight をどれだけ読まずに済むか」の上限であって、step 時間の上限では
ない。両方を読むこと。

## Metal API は実機で揃っている

設計が API の有無で崩れないことを先に確認した。いずれも作成成功:

- placement-sparse buffer
- Metal 4 command queue
- concurrent MTLIO queue
- shared event
- **MTL4 queue と MTLIO の双方が event の wait / signal を持つ**

最後の1点が設計の要。GPU 側の routed pass を事前 commit したまま event で止め、
MTLIO の完了 signal で再開できる。

**注意: この確認に使った probe プログラムは scratchpad にあり repository に無い。**
次のセッションで再確認するなら書き直しになる。残すなら `ds4-macos/proto/` へ。

## 次にやること（この順）

### 0. 内訳（取った。結論が変わった）

`DS4_V41_BATCH_STAGE_MS=1` を K=8 の selftest 経路で2本。計器は CB 境界で総額を
膨らませる（255 → 341 / 404 ms）ので、読むのは比率だけである。**総額が 18% 違う
2本の間で、比率は 0.5 ポイント以内で一致した。**

| stage | 内容 | share |
|---|---|---:|
| pre | `ds41_before_attention_batch` + `ds41_attention_project_batch`（batch済・weight共有） | 14.8% |
| per-row attention | **行ごとの直列ループ**（`ds41_attention` + `ds41_attention_output`） | 30.2% |
| moe | router / shared / routed | **42.4%** |
| rest | head + logits publish（層ループの外、bucket 無し） | 12.6% |

**moe は 42% であって、半分ではない。** よってこの §0 が置いた判定に従う:

> moe を**ゼロにしても** 255 ms の 58% = 148 ms が残る。これは 54 tok/s であり、
> 80 ms には届かない。**expert-major は必要だが十分ではない。**

expert-major の現実的な取り分（routed を 26.4/48 へ畳む = routed weight −45%）で見ると、
moe 108 ms のうち routed weight 律速の部分が最大 45% 減る。step 255 → 約 207 ms、
上限 31.3 → 38.5 tok/s。**100 には遠い。**

### 0b. per-row attention が本当の壁で、executor の抽象化が間違っていた

per-row attention は 30.2% = 静穏時で約 77 ms。**100 tok/s の予算は 80 ms 全部である。**

しかも per-row attention は K に比例し、予算 `10*K` ms も K に比例する。**K をいくつに
しても予算に占める割合は変わらない**（K=8 で 77/80、K=16 で 154/160）。K を上げても
attention は一切改善しない。

**根本は個々の matmul ではなく executor の抽象化である。** K 行は「単一 session の
連続 K token」なのに、`ds41_graph_step_batch_logits` は K 個の独立 session のように
attention を1行ずつ実行していた（`ds4.c:45050` 付近のループ）。独立 session は
KV が独立だから行ごとに回すしかないが、**speculative block の K 行は prefix KV を
完全に共有する。** これは prefill が既に扱っている形であり、`ds41_attention_batch()`
（`ds4.c:42049`）が最初から存在する。

v41-9 は「attention core の multi-row 化」を「共有weightなし」として除外していた。
**weight の有無は判定軸として誤っている。** 共有されるのは weight ではなく KV である。
expert 共有を独立sessionの算数で見誤ったのと同じ型の誤りである。

#### 段階1: `attn_output_b` を行ループの外へ（既定 ON、byte 一致）

`DS4_METAL_V41_BATCH_ATTN_OUT`、既定 ON、`=0` で元に戻る。

| | 結果 |
|---|---|
| K=8 step、真の ABBA、6 round | 6/6 で per-row loop が遅い。unset-first 中央値 −11.0%、set-first −2.6%、**順序を均して約 −6%** |
| head logits の byte 一致（k=2 / 4 / 8） | **完全一致**（`LOGITS_DUMP` を memcmp） |

**帰属に注意。** これは「weight を一度だけ読むようになった」のではない。exact
decode-rows kernel は batch 行を grid の Y 軸に置くだけで、**各行が weight 全体を
読み直す**（`metal/dense.metal:202` がそう書いている）。weight を実際に再利用するのは
fused kernel（`HEAD_ROW_TILE` / `DENSE_ROW_TILE`）の側で、そちらはここで退行した。
**確立したのは「8個の dispatch を1個にすると速い」までで、理由は未確定**——dispatch
削減か、行が同時 resident になることか、coalescing か。

#### 段階2: contiguous-block attention（賞金は大きい、まだ byte 一致しない）

`DS4_METAL_V41_BLOCK_ATTN=1`、**既定 OFF**。`graphs[i] == graphs[0]` かつ
`positions[i] == positions[0] + i` を条件に、block 全体を `ds41_attention_batch()` へ
送り、output A は block 一括、output B は exact-rows のまま。output A 単独の entry
point は新カーネルではなく、既存 batch impl が `out == NULL` を受けるようにして得た。

| | 結果 |
|---|---:|
| K=8 step | 255 → **202 ms** |
| perfect-draft ceiling | 31.3 → **39.7 tok/s** |

**正しさは通っていない。** そして原因は特定済みである:

- per-row decode 経路は選択済み compressed KV を `ds4_gpu_dsv41_gather_kv` で
  gather し、その複製に対して `ds4_gpu_attention_decode_heads_tensor` を回す
- batch 経路は compressed store に index を渡して
  `ds4_gpu_attention_indexed_mixed_batch_heads_tensor` を回す
- **別のカーネルが別の materialisation を読んでいる。** bit 一致するはずがない

`DS4_METAL_V41_BLOCK_ATTN=2`（output A は行ごと）でも同じ位置で割れるので、
原因は core であって low projection ではない。

**argmax は再びここで粗すぎた。** k=4 は「identical argmax」と報告するが、logits dump を
memcmp すると **64 の batch 位置すべてが相違**し、しかも block 先頭の行から違う。
head のときと同じで（`6c25a41`）、判定は dump でしか行えない。

#### 段階3（次にやること）: decode attention の exact-rows 化

必要なのは「速い indexed-mixed kernel」ではない。**`6c25a41` が語彙 head に対して
行ったのと同じ手**である——gather 済み KV に対する
`ds4_gpu_attention_decode_heads_tensor` の rows 版を作り、batch 行を grid の Y 軸に
置き、単一行の reduction 順序をそのまま保つ。現在の宣言（`ds4_gpu.h:2272`）に
行数引数は無いので、そこから。

### 0c. 計器で割ろうとして失敗した記録

`DS4_V41_BATCH_STAGE_MS=2` は attention を core と output に割る。**使ってはいけない。**
行ごとに CB 境界が2本増え（層あたり +16、step あたり +600）、測ろうとした attention が
110 ms から 235 ms へ膨らんだ。**計器が答えを、測ろうとした量より大きく変えた。**

残してあるのは、次に同じことを思いつく人のためである。割りたいなら計器ではなく
**flag を置いて A/B する**——それが 0b でやったことである。

### 1. expert-major routed pass（必要、ただし単独では届かない）

1. 層ごとに expert ID を固定仮想アドレスへ割り当てる placement-sparse buffer
2. router が K 行の selected と **expert-major worklist** を GPU 上に生成
3. service thread は event 通知で **missing unique だけ**を MTLIO へ投入
4. MTLIO が完了 event を signal
5. 事前 commit 済みの Metal 4 routed pass が event 待ちから再開
6. kernel は 48 の `(row, expert)` を回さず、**26.4 unique expert ごとに該当 row へ適用**

未解決の設計点、着手前に潰すもの:

- **selected id の host readback。** 現在の routed 経路は id を host へ戻してから
  expert を load する。2 は「GPU 上に worklist を生成」と書いているが、3 の service
  thread は host 側にいる。どこで同期を1回払うのか、払わずに済むのかが未決
- placement-sparse の page 粒度と expert 1本のバイト数の関係（端数が丸ごと1 page を
  掴むと畳んだ分が戻る）
- v41-9 §「いま壊れているもの」の未修正4点のうち **2（load 前の予約・pin）と
  3（cache 操作の単一所有）は expert-major でも必要**。wave を凍結しても消えない。
  1（per-slot generation）と 4（HEAD_INFLIGHT）は wave 固有なので凍結してよい

### 順序（確定）

1. **decode attention の exact-rows 化**（§0b 段階3）。これが通るまで先へ進まない
2. contiguous-block executor を byte 一致で通す
3. output A/B の一括化を block 経路へ畳み込む
4. expert-major MoE
5. **短文脈と長文脈の両方で全 logits memcmp**
6. 最後に実 drafter の平均前進数と総 wall を掛け合わせる

長文脈の追加計測を先に増やす必要はない。**per-row executor が構造的に誤っていることは
コードから既に確定している**（同一 session の連続位置を独立 session として扱っている）
ので、測って確かめる対象ではない。

### 旧2. per-row attention ループを畳む（§0b に統合済み、参考）

0b で weight 1本を外に出して −11.2% が取れた。ループに残るのは `ds41_attention` 本体
（KV scan）と `ds41_attention_low`（`attn_output_a`、4096×1024×groups の Q8。これも
**行で共有できる weight**）である。

- `attn_output_a` を同じやり方で hoist できるか。`low` は行ごとの連続 view なので
  形は同じ。次に手を付けるならここが最短
- `ds41_attention` 本体は KV scan。**speculative block では K 行が同一 session の
  KV を共有する**ので、8行が同じ KV を8回走査している。weight ではなく KV を共有
  する multi-row attention は、v41-9 が「共有weightなし」として閉じた対象ではない
- 現在の計測は ctx 8192・position 31〜95 と KV が極小である。**KV scan の共有利得は
  長文脈でしか見えない。**長い prompt で内訳を取り直すこと

### 3. draft 品質の測定（1・2 の後）

v41-9 §1 の手順はそのまま有効で、**順序だけが後ろへ動いた**。verifier が 80 ms/step
に入って初めて、accepted 長が成否を決める変数になる。
`DeepSeek-V4.1-Flash-Q2.gguf` が drafter 重みを持つかは依然として未確認。

## 凍結したもの（動くが本線ではない）

### row wavefront —— 正しくなった、そして遅い

v41-9 の「breakout 一致 / quicksort 不一致」の原因は **routed 完了時に drain されず、
layer 0 で失敗した後、変更済みの KV に対して lockstep fallback を二重実行していた**
こと。片方の row だけが一貫して誤るという症状はこれで説明がつく。

さらに、**失敗後の fallback 自体を禁止した**（`ds4.c:82837`）。wave の戻り値を3値にし、
開始後に失敗したら負値を返して同一 token を再実行しない。

```
/* A negative result means wave started and mutated session state.
 * Falling back would execute the token twice and can silently produce
 * a plausible but wrong answer. Zero alone is a safe decline. */
```

検証結果（wave ON/OFF、同時2 session）:

| | 結果 |
|---|---|
| breakout / quicksort 各160 token の出力 hash | **完全一致** |
| 256 token, 10,240 scheduler step | order / lease violation **0** |
| 所要 | ON **39.6 s** / OFF **25.7 s** |

**wave は 100 tok/s 経路ではない。** 正しさは資産として残すが、ここで開発を止める。
v41-9 §2 の「row を speculative position へ置き換える」は生きている——置き換えるのは
state machine ではなく、row の意味である。

### 全 Q8 projection への明示 row-tile —— 実装済み・退行

`DS4_METAL_V41_DENSE_ROW_TILE=2|4`（既定 OFF、`ds4.c:40522`）。head 専用だった
byte-exact row-tile を全 Q8 projection へ広げた。

| | ms/step |
|---|---:|
| 既定（Y-grid 実行） | 361.0 |
| DENSE_ROW_TILE | **390.5** |

（前セッションの計測。絶対値は当時の機体状態のもので、再現していない §「決定的な数字」
の 361 ms と同じ run 由来である。比 +8.2% だけを読むこと。同一プロセス paired で
取り直すには先に `ds41_matmul_batch` の `static int dense_tile` を外すこと——
現状はキャッシュされるので、`DS4_V41_VERIFY_SELFTEST_BATCH_AB` にかけても
**両腕が同じ腕になり、「差が無い」と報告される**。）

192行の argmax は一致しており、**正しいが遅い**。既存の Y-grid 実行がキャッシュ上で
すでに weight load を共有しており、tile 化は並列度だけを落とした。

これは v41-9 §「他shapeへの汎用化は上限不足で保留」の実測による確認であり、
**保留ではなく否定**になった。同じ実験を繰り返さないこと。

## 計測の作法（v41-9 に追加）

v41-9 の項目は全て有効。今回の作業で足されるのは1点:

- **「正しくなった」と「速くなった」を同じ run で判定しない。** wave は出力 hash が
  完全一致した同じ run で 1.54x 遅かった。正しさの検証は温度も thermal も
  揃えなくてよいが、速度の判定には `bench/campaign-*.sh` の事前登録が要る。
  39.6 対 25.7 は差が大きいので凍結判断には足りるが、**この数字を 10% の議論に
  使ってはいけない**
- **10% を見たいなら同一プロセス内の対にする。** 同じ K=8 step がこの機体で 3時間差で
  255 と 427 ms になった。サーバを腕ごとに起動する A/B はこの幅を越えられない。
  `DS4_V41_VERIFY_SELFTEST_BATCH_AB` はそのために足した
- **flag の綴りを、使う前に code で確認する。** v41-9 が production env として挙げた
  `EXPERT_RESIDENCY_SET` の実名は `DS4_METAL_V41_EXPERT_RESIDENCY_SET` である。
  読まれない env を置いた A/B は両腕が同一になり、**「差が無い」という結果を出す**。
  `ds4.c` だけを grep しても足りない（この変数は `ds4_metal.m` 側にある）
- **argmax を正しさの判定に使わない。** `batch vs single: identical argmax` は
  contiguous-block attention を「一致」と報告したが、logits dump を memcmp すると
  64 位置すべてが相違していた。head のときも同じだった（`6c25a41`）。**判定は
  `DS4_METAL_V41_LOGITS_DUMP` の memcmp でのみ行う**
- **A/B は真の ABBA にする。** rewind は session を戻すが expert cache は戻さないので、
  毎 round 同じ順序だと後に走る腕が常に温かい。実測で −11.0% 対 −2.6%、つまり
  **順序が測ろうとした変化より大きかった**。round の偶奇で順序を入れ替え、順序別に
  報告すること。両順序で同符号なら本物、片方だけなら cache
- **効いたことを印字させる。** `BATCH_ATTN_OUT` は engage 時に1行出す。腕の log に
  その行が無ければ、その腕は測定ではない

## 有用な計器（v41-9 に追加）

| env | 何を出すか |
|---|---|
| `DS4_V41_VERIFY_SELFTEST=<k>` | k 行 verifier の median step、**perfect-draft 上限 tok/s**、100 tok/s に必要な step 時間、rollback / batch の argmax 一致 |
| `DS4_V41_VERIFY_SELFTEST_ROUNDS=<n>` | 1–9、既定3 |
| `DS4_METAL_V41_DENSE_ROW_TILE=2` または `=4` | 全 Q8 projection の row-tile（退行。再測定用に残す） |
| `DS4_METAL_V41_GATE_ROUTE_LOG=<path>` | 層ごとに 8 int32（layer, count, 6 ids）。**unique expert の実測はこれを連続 token で突き合わせて得た** |
| `DS4_V41_VERIFY_SELFTEST_BATCH_AB=<NAME>` | **k 行 step を同一プロセスで NAME の set/unset 交互に測る。**既存の `_AB` は `ds41_graph_step`（単一行）なので batch 限定の変更を一切見ない。NAME は毎回 getenv される変数であること |
| `DS4_METAL_V41_BATCH_ATTN_OUT=0` | `attn_output_b` を行ループへ戻す。**既定は ON**（byte 一致・約 −6%）。A/B は必ず `=0` の形で書く——unset は hoist を選ぶ |
| `DS4_METAL_V41_BLOCK_ATTN=1` | contiguous-block attention。255 → 202 ms。**byte 一致しないので既定 OFF** |
| `DS4_METAL_V41_BLOCK_ATTN=2` | 同上だが output A は行ごと。core と low projection の切り分け用 |
| `DS4_V41_BATCH_STAGE_MS=2` | attention を core/output に割る。**答えを変えるので使用禁止**（0c） |

## やらないこと（更新）

- Q8 row-tile の汎用横展開 —— **実測で退行（361.0 → 390.5）。保留ではなく否定**。
  0b の hoist はこれとは別物である：row-tile は kernel 内で行を束ねる話で、退行した。
  hoist は**行ループそのものから matmul を出す**話で、既存の exact-rows kernel を
  そのまま使う。混同しないこと
- multi-session wavefront の性能開発 —— 正しいが 1.54x 遅い。凍結
- draft 品質を verifier より先に測る —— 31 tok/s の天井が先に効く
- expert-major だけで 100 tok/s に届くと考えること —— moe 42% では届かない（§0）
- Metal 4 を submission API として磨く（v41-9 のまま）
- per-expert 投機、Engram async、HC fork、cache policy 再探索（`HANDOFF-v41-6.md` で閉じている）

## 未着手のまま残るもの

- `DS4_METAL_V41_BATCH_STREAM_EXPERTS=1` は約80 token で生成が崩壊する。v41-9 から変化なし
- v41-9 §「いま壊れているもの」の未修正 2・3（load 前の予約・pin、cache 操作の単一所有）
- **decode attention の exact-rows 化**（`ds4_gpu_attention_decode_heads_tensor` の
  rows 版）。これが contiguous-block executor を止めている唯一のもの
- expert-major MoE（block executor が byte 一致してから）
- 短文脈と長文脈の両方での全 logits memcmp
- 実 drafter の平均前進数と総 wall の掛け合わせ
- `DS4_V41_VERIFY_SELFTEST_AB`（単一 token 側）は固定順序のまま。batch 側だけ ABBA 化した
- Metal API probe の repository 化
