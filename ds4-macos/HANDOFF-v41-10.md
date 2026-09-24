# 引き継ぎ: DeepSeek V4.1 Flash / 100 tok/s の律速はどこか（11日目）

`HANDOFF-v41-9.md` の続き。**v41-9 の「次にやること」の順序は誤っているので、
そちらの §「次にやること」は読まなくてよい。** それ以外の確定事項・撤回済み主張・
計測の作法は v41-9 が有効で、ここでは繰り返さない。

## v41-9 から変わったこと（要約）

| v41-9 の記述 | 現在 |
|---|---|
| 「最優先は draft 品質の独立測定」 | **誤り。** perfect draft でも K=8 verifier は 361 ms/step、上限 22.2 tok/s。先に verifier を速くする |
| row wavefront は壊れている（`0980a5b`） | **修正済み。** 出力一致・違反 0。ただし遅く、凍結対象 |
| expert 共有は B=8 で 5.3% | **撤回。** 独立 route の算数だった。実測は層あたり 48 選択 → 26.4 unique（約45%重複） |

結果として、本命は **expert-major 化**になった。v41-9 の「やらないこと」に入っていた
項目が、測り直した数字で昇格している。

## 作業場所

- 主worktree: `~/ghq/github.com/antirez/ds4-v41-mtl4dag`、branch `perf/v41-mtl4-dag`
- HEAD: `0980a5b`。**未コミットは `ds4.c` の selftest 表示3行のみ**
- 記録・ハーネス: この repository、branch `docs/v41-tuning`、`299ecd4`
- 対照・旧shim の位置は v41-9 のまま。全て未 push / 未 PR

### `0980a5b` のコミットメッセージは現状と食い違う

"A row wavefront that does not produce the right answer yet" とあるが、**wave 修正と
dense row-tile 実験はこのコミットに含まれており、wave は正しい答えを出す。**
HEAD がこの状態で進んだため、メッセージは事実と合わない。amend せず、後続コミットの
メッセージで訂正すること。

## 決定的な数字: verifier は帯域律速ですらない

`DS4_V41_VERIFY_SELFTEST=<k>` に上限を直接表示する計器を足した（`ds4.c:45450`、未コミット）。

```
perfect-draft ceiling: %.2f tok/s (100 tok/s requires <= %.2f ms/step)
   = 1000 * k / bm                        = 10 * k
```

K=8 の実測:

| | 値 |
|---|---:|
| median 8-row step | 361 ms |
| perfect draft での上限 | 22.2 tok/s |
| 100 tok/s に必要な step 時間 | ≤ 80 ms |
| 必要な短縮 | **4.5x** |

v41-9 の表は K=8 の帯域床を約63 ms/step と置いていた。**実測 361 ms はその5.7倍**で、
verifier は帯域の近くにいない。だから draft 品質を先に測っても意思決定に使えない——
accepted 長が 8/8 であっても 22.2 tok/s で頭打ちになる。

**judgment: K=8 を 80 ms/step 以下へ入れることが、他の何よりも先に来る。**

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

どちらでも 80 ms の内側にある。**K=8 で 100 tok/s は、expert-major 化を前提にすれば
工学的な射程に入る。** これが v41-9 時点で存在しなかった唯一の新しい事実である。

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

### 0. 361 ms/step の内訳を取る（実装の前に）

**まだ取っていない。** expert-major が取り得る上限を数値で確定してから実装に入る。
`DS4_V41_BATCH_STAGE_MS=1` を K=8 の selftest 経路で読み、pre / per-row attention /
moe / head に割る。v41-9 の count=4 streaming では moe 49.8% だったが、K=8 の
verifier で同じ比率とは限らない。

**moe が 361 ms の半分に満たなければ、expert-major を完成させても 80 ms には届かない。**
その場合は attention と head の側に先に手を入れる判断になる。ここを飛ばさないこと。

### 1. expert-major routed pass（本命）

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

### 2. draft 品質の測定（1 の後）

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

## 有用な計器（v41-9 に追加）

| env | 何を出すか |
|---|---|
| `DS4_V41_VERIFY_SELFTEST=<k>` | k 行 verifier の median step、**perfect-draft 上限 tok/s**、100 tok/s に必要な step 時間、rollback / batch の argmax 一致 |
| `DS4_V41_VERIFY_SELFTEST_ROUNDS=<n>` | 1–9、既定3 |
| `DS4_METAL_V41_DENSE_ROW_TILE=2` または `=4` | 全 Q8 projection の row-tile（退行。再測定用に残す） |
| `DS4_METAL_V41_GATE_ROUTE_LOG=<path>` | 層ごとに 8 int32（layer, count, 6 ids）。**unique expert の実測はこれを連続 token で突き合わせて得た** |

## やらないこと（更新）

- Q8 row-tile の汎用横展開 —— **実測で退行（361.0 → 390.5）。保留ではなく否定**
- multi-session wavefront の性能開発 —— 正しいが 1.54x 遅い。凍結
- draft 品質を verifier より先に測る —— 22.2 tok/s の天井が先に効く
- Metal 4 を submission API として磨く（v41-9 のまま）
- per-expert 投機、Engram async、HC fork、cache policy 再探索（`HANDOFF-v41-6.md` で閉じている）

## 未着手のまま残るもの

- `DS4_METAL_V41_BATCH_STREAM_EXPERTS=1` は約80 token で生成が崩壊する。v41-9 から変化なし
- v41-9 §「いま壊れているもの」の未修正 2・3（load 前の予約・pin、cache 操作の単一所有）
- `361 ms/step` の stage 内訳（上の §0）
- Metal API probe の repository 化
