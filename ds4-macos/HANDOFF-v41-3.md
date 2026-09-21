# 引き継ぎ: DeepSeek V4.1 Flash の Metal デコード最適化（3日目）

## 作業対象

- ワークツリー: `~/ghq/github.com/antirez/ds4-v41`（ブランチ `perf/v41-metal-apple`、**未push**）
- モデル: `~/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf`（340.6 GiB）
- 記録: `~/ghq/github.com/ngc-shj/inference-deploy` の `ds4-macos/V4.1-TUNING.md`（ブランチ `docs/v41-tuning`、**未PR**）
- 機体: MacBook Pro / Apple M5 Max / 128 GB、GPU 40コア
- 現状: 実生成で持続 **22 tok/s 前後**、1トークン 45 ms 前後
  （3日目の BF16 融合で 20.09 → 22.17 tok/s。融合前は 19〜20 tok/s）
- コミット済み: `ds4-v41` の `6c21cac`（BF16 融合、**未push**）、
  `inference-deploy` の `c639e8e`（記録、**未PR**）

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
| prefill headroom 貸与 | miss は減るが時間が出ない | abort 4.94 → 4.03（決定的、バイト一致）。16 run で平均 +0.05 ms・中央値 −0.71・上位4本 −0.83。最遅2本が貸与側（ロック +7.12 GiB）。既定 OFF |
| **reactive** な置換 policy | 終了 | LRU / TinyLFU / 2Q / 層別配分のいずれも現行を上回らない。7 policy を offline replay |
| route prediction（**無条件** top-6 prefetch） | **不採算** | lead 1 で miss recall 38.2%、隠せる abort 1.93 に対し無駄ロード 10.66/token。lead を伸ばすと精度が落ち無駄が増える |
| route prediction（置換保護） | **利益なし** | 予測 entry を touch するだけの無コスト版でも abort 5.52 → 5.50。lead を増やすと悪化 |
| route prediction（**閾値つき選択的** prefetch） | **未検証・優先外** | 信号自体はある（miss recall 38.2%）。負けているのは precision であって recall ではない。ただし fetch が間に合う lead 2 の賞金が 1.45 abort＝1.6〜1.8 ms しかなく、完璧な filter でも 2 ms 基準に届かない |
| predicted segment の shadow 実行 | **終了** | segment 全層一致率 2層 0.450%、3層 0.010%。commit がほぼ起きない |
| 単純な容量追加 | 保留 | abort は 4.94 → 4.03 と確かに減るが wall 利益が未確定（16 run で平均 +0.05、中央値 −0.71）。テールは悪化 |
| BF16 丸めの独立 dispatch | **完了・コミット済み** | 586.5 dispatch/token 削除、バイト一致、20.09 → 22.17 tok/s |
| 行タイル IQ2 / 全アドレステーブル / expert readahead / ディスク律速 | 終了 | 2日目までの記録参照 |

数値の詳細はすべて `V4.1-TUNING.md` にある。

## 現在の分解（同一64トークン窓、飽和後）

```
gate over tokens N-N+63: 17.5 command buffers, 5.20 aborts, 240.0 expert ids,
  entry 0.00 + encode 2.8 + commit-to-done 38-46 + repair-load 3.5-5.3
  + accounting 0.3 + tail 1.4 = wall 47-55 ms, residual 0.01
  5.65 misses, 5.65 evictions a token
```

**この限界費用は取り直した。**「0.19〜0.38 ms/miss」は *cache が充填中* の値で、
定常の値ではない。同一 run を regime で割ると、充填中（tok<449、abort 7〜28）の
repair〜abort 傾きは 0.222 ms、cache 満杯後の11窓では 1.51 ms。7倍違う。

**定常の値は wall 1.08 ms/abort**（7 run・77窓、run ごとに中心化して run 間ドリフトが
混入しない形でプール、R²=0.48）、run 内回帰の中央値 1.26。
一度報告した 2.19 ms/abort は1 run 11窓の値で、これも撤回した。

**充填中の限界費用で定常の変更を値付けしないこと。** miss が何をするかが regime で違う。
切片は依然として主張しないこと。

## 3日目に閉じた候補

### ~~context 位置依存~~ — 終了。本命ではない

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

### ~~40層本体の kernel fusion~~ — 完了。コミット済み

`ds4-v41` の `6c21cac`。

呼び出し元別 census（`DS4_METAL_V41_GATE_CENSUS=1`、2フレーム記録）で、1トークンの
gated dispatch 2,666.6 のうち **759.5（28%）が `ds4_gpu_dsv41_quantize`** だった。
decode 経路のほぼ全ての matmul と norm の直後に、書いたばかりの行を読み直して BF16 に
丸めるだけの dispatch が1本ついていた。producer が store 直前に丸めれば同じビットになる。

`helper_mv_reduce_and_write`（全 matvec が通る唯一の store）で Q8_0 / F16 / F32 を一括、
weighted RMS norm・HC expand・shared SwiGLU・MoE add を個別に。matvec 系は丸められたかを
`*rounded` で返し、できない経路では呼び出し側が従来 pass に落ちる。

- **2,666.6 → 2,080.1 dispatch/token**（減少分は全て quantize: 759.5 → 373.0）
- 6プロンプト（最長2048トークン生成）で gate ON/OFF ともバイト完全一致
- 8本ずつの ABBA ×2、定常 wall **49.79 → 45.10 ms、20.09 → 22.17 tok/s**、アーム間に重なりなし
- `DS4_METAL_V41_FUSE_BF16=0` で従来経路に戻る（2,666.6 に戻ることを確認済み）

`rms_norm_plain_rows_tensor` は融合対象なし（唯一の呼び出し元 `ds41_hc_mix` の後続に丸め pass がない）。

**残り 373 のうち、なお畳めるのは約80本（flash attention heads、attn_out_low_q8_direct）で
0.18 ms 相当、着手基準未満。** 残りは block 幅の `simd_max` を要する FP8/FP4 で producer に畳めない。

### ~~ghost-view cache~~ / ~~reactive な置換 policy~~ — 終了

**閉じたのは reactive な置換だけで、cache 系統ではない。**
`Belady = 無限容量` を「cache 終了」の根拠にしたのは誤りだった。Belady が示したのは
**未来の route が分かれば現容量のまま abort を 4.91 → 3.12 にできる**ことである。

**ただしその「未来」は手の届く未来ではなかった。** 4日目に候補1を実測して閉じた
（下記）。Belady が使っている未来は数百トークン先までの route であって、
同一トークン内の数層先ではない。evict された expert の最終使用は中央値 571 トークン前
なので、トークン内の予測が届く範囲に答えはない。

- ghost-view が狙う view 再生成は `load_prepare_avg=0.165 ms/load`（0.8 ms/token）で基準未満。
  しかも `buffer_allocs=0 / buffer_reuses=1722` で**既に再利用されている**。
  repair の内訳も `0.00 already resident, 全て genuinely absent` で、想定した churn は起きていない。
  高いのは `load_install_avg=0.658 ms`（residency 更新側）。
- route log の offline replay（追加トレース不要、`cachesim.py`）。指標は expert miss ではなく
  **miss を含む層数＝abort 数**（同一層の複数 miss は1 abort・1 repair にまとまるため）。

| policy | cap 7,930 | cap 8,698 |
|---|---|---|
| current（実装どおり再現） | 4.91 | 3.82 |
| global LRU | 4.91 | 3.82 |
| TinyLFU admission | 4.91 | 3.82 |
| 2Q | 5.25 | 3.88 |
| 層別 LRU（均等） | 6.21 | 5.16 |
| 層別 LRU（working set 比例） | 5.29 | 4.03 |
| Belady | 3.12 | 3.12 |
| 無限容量 | 3.12 | 3.12 |

シミュレータは実機と2度一致（4.91 vs 実測 4.94、貸与後 3.82 vs 実測 4.03）。

- **現行 policy は LRU に退化している。** hotness を16トークンごとに半減するため
  ほぼ全エントリが 0 になり、タイブレークの `last_used` が支配する。TinyLFU が同値なのも同理由。
- **層別配分と admission はいずれも悪化させる。** 「global policy の層間干渉」「一度しか使われない
  expert が hot を追い出す」という仮説はデータが支持しなかった。
- **Belady が無限容量と一致する** ＝ 容量は足りており、差は全部「未来を知っているか」側。
  reactive な online policy はその 1.79 abort/token（2.0〜2.3 ms）を 1 本も回収しない。
  **そして predictive な policy も回収しない**（候補1、実測済み）。

## 候補（優先順）

**4日目で候補1（無条件版）と候補2が不採算と判明した。** 着手順の先頭は候補3に移る。

閉じきっていないものを閉じたことにしないこと: **閾値つき選択的 prefetch**（上表）、
**sparse attention の候補 ID 予測**、**Engram の hoisting** はいずれも未測定で、
賞金も見積もられていない。「残るのは候補3だけ」ではなく「今の最優先が候補3」である。

### ~~1. route prediction による predictive residency~~ — 無条件版は不採算

**実測した。** 予測子は「層 T 自身の router を、同一トークンの層 S が既に作った
norm に当てる」。代理ではなく本物の router なので、学習も offline 再実装も不要で、
予測 selection は実 selection と同じ規則から出る。

計器: `DS4_METAL_V41_ROUTE_PREDICT=<path>`（`ds4.c`、gate OFF で使う）。
offset 0 が self-check で、自分の norm から自分を予測すると 11,240/11,240 完全一致。
さらに、この probe を入れた build の route は、probe のない build で数日前に取った
route log と最初の 113 トークン（4,520/4,520）で完全一致する（それ以降は生成自体が
分岐するので比較の意味がない）。**計器は正しく、グラフを乱していない。**
route log は gate 内でしか書かれないので、この一致は同時に
**gate ON/OFF で routing が動かない**ことも示す。gate OFF で取ったトレースで
gate 裏の機構を値付けしてよい根拠はここにある。

| lead | recall | exact | **miss した expert の recall** | **欠損集合を全部当てた層** |
|---|---|---|---|---|
| 1 | 65.8% | 7.9% | 38.2% | 35.9% |
| 2 | 57.2% | 3.0% | 30.2% | 28.0% |
| 4 | 47.2% | 1.0% | 22.7% | 20.5% |
| 8 | 35.1% | 0.1% | 15.2% | 13.5% |
| 16 | 20.8% | 0.0% | 9.9% | 8.6% |

**当たるのは resident だった expert で、取りに行く価値のある expert には当たらない。**
miss 限定の recall は常に全体の約半分。miss の 62% が生成中の初出だという内訳の裏返し。

prefetch した場合の収支（定常価格 1.08〜1.26 ms/abort、baseline は 6.01 load/token）:

| lead | 隠せる abort/token | 無駄ロード/token | 比 |
|---|---|---|---|
| 1 | 1.93 | 10.66 | 0.18 |
| 2 | 1.45 | 16.04 | 0.09 |
| 4 | 1.01 | 20.61 | 0.05 |
| 8 | 0.58 | 26.34 | 0.02 |

しかも **lead 1 は fetch が間に合わない。** 1トークン 45.10 ms ÷ 40層 = 1.13 ms/層に対し
page wiring だけで約 1.7 ms/expert。間に合う最短 lead は 2 で、そこでは 1.45 abort
（1.6〜1.8 ms）のために 16.04 の余分なロードと 16.04 の余分な eviction を払う。

ロードを伴わない使い方（予測 entry を touch して LRU の victim から外すだけ）も試した。
abort 5.52 → 5.50、lead を増やすと 5.64 まで悪化。Belady はこの run で 5.15。
**evict された expert の最終使用は中央値 571 トークン前 ＝ 22,840 層アクセス前**なので、
数層先を守っても届かない。

**否定したのは無条件版だけである。** 全予測を必ず load するので precision で負けており、
recall で負けているのではない。router の margin を使った閾値つき選択的 prefetch は未検証。
ただし fetch が間に合う最短 lead 2 の賞金が 1.45 abort＝1.6〜1.8 ms なので、
完璧な filter でも 2 ms 基準に届かない。**未検証として記録し、今は追わない。**

### ~~2. predicted expert execution / transactional direct segment~~ — 不採算

候補1が当たらないので土台がない。加えて、segment 入口の state から全層を予測して
完全一致する率は **2層 0.450%、3層 0.010%**。現行 segment 長では shadow が
1000 トークンに 999 回捨てられる。自分の encode 分すら回収できない。

### 3. gate の indirect 税（上限 4.13 ms/token）

`proto/dispatchcost.m` で実測: plain 0.70 µs / indirect 2.25 µs / ゼログリッド 1.85 µs、
N に完全線形。gate は全ゲート対象 dispatch を indirect で出すので、実測 2,666.6 本に対し
2,666.6 × (2.25 − 0.70) = **4.13 ms/token**。GPU 項 39 ms の10%。

下がらないことが分かっている手: スロット配置（1スロット再利用 vs dispatch ごと別スロット）、
private storage。compute の `MTLIndirectCommandBuffer` は concurrent dispatch 専用で
40層の依存鎖に使えない。**唯一名前のついていた機構（候補2の shadow execution）は
上で閉じたので、現在この 4.13 ms に対する機構はない。**

未検証で残る唯一の方向は「全 dispatch を indirect で出すのをやめる」側。gate が
全部を indirect にしているのは abort 後の dispatch を切るためだが、切る必要があるのは
**キャリー状態（`previous_kv` / `previous_score` / KV 書き込み / Engram / residual）を
進めるもの**だけで、上書きされるだけの中間テンソルに書く dispatch は走らせても
continuation が上書きする。呼び出し元別の census（`DS4_METAL_V41_GATE_CENSUS=1`）は
既にあるので、どれがどちらかの分類は測れる。ただし分類を1本間違えると静かに壊れる種類の
変更で、バイト一致で守るしかない。着手前に、分類後に残る indirect 本数を census から
出して 4.13 ms のどれだけが残るかを先に見ること。

**上限であって保証ではない。** 実現率はカーネル依存で、matvec 386.5 本は予測の91%を回収したが、
小さい要素ごとカーネル200本を足すと 53% に落ちた（発行が隣の計算と重なって消える）。

### 4. continuous batching（現在の目標では主候補ではない）

aggregate throughput が目標なら残るが、**単一ストリーム tok/s の最大化が目標である限り
主候補に数えないこと。**

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
11. **同一仕事の窓が機体状態で2倍動く。** tok129 は 14.00 CB / 0.00 abort / 0.00 MiB で
    全 run 同一の仕事だが、commit-to-done は静かな機体で 35.08 ms、swap 24 GB 使用時に
    64.07〜77.31 ms。A/B の前に既知の窓を既知の値と照合し、各アームで `vm_stat` を記録する。
12. **routing は run をまたいで決定的。** 同一プロンプトなら窓ごとの abort が
    27.95 / 14.75 / 0.00 / 7.44 / 10.84 / 11.08 と全 run で一致する。解析で assert すること。
    窓を揃えた比較が厳密に paired になり、アームの取り違えも捕まる。
13. **共変量は「アームの影響を受けないもの」でなければならない。** run を捨てる代わりに
    0-abort 窓を機体状態の代理にしたが、**この窓自体が BF16 融合の影響を受ける**
    （同じ dispatch を含む）。post-treatment covariate であり、効果の一部を吸収する。
    実際それが起きた: 生の差は −4.57 ms（16 run 併合、分布に重なりなし）なのに、
    共変量モデルは −1.04 しか出さなかった。**3日目に「保守的な推定」として報告した
    −1.04 / −1.24 は 0 方向に偏っており、主結果は生の −4.57 の方である。**
    共変量にしてよいのは、アームで変化しないと確認できた固定 probe だけ。
14. **生の wall を必ず主結果として残す。** 「その変更が触れない項だから外す」を一般則に
    してはいけない。変更は GPU と CPU の重なりや資源競合を変えうる。加算的かつ独立だと
    確認できた項だけを、分散低減用の共変量または補助指標として使うこと。
    （3日目は repair-load を外して評価したが、これは補助指標として扱うべきだった。）
15. **上限は上限として扱う。** 空カーネルの 2.25 µs/dispatch は、matvec では91%回収できたが
    小さい要素ごとカーネルでは53%だった。発行が隣の計算と重なる分は取れない。
16. **予測子は、自分の出力ではなく、防ぎたい事象の上で採点する。** 全体 recall 65.8% に対し
    「実際に miss した expert」の recall は 38.2%。簡単な事例と役に立つ事例が重ならない。
    前者だけを報告していれば実装が正当化されていた。
17. **false positive を true positive と同じ単位で値付けする。** どの lead も recall は
    弁護できる値だが、全て損をする。コストを % ではなくロード数と eviction 数で数えると出る。
18. **lead time は、隠したい対象より長くて初めて lead。** lead 1 は全精度列で最良だが
    fetch が終わらない（1.13 ms/層 対 約 1.7 ms/expert の page wiring）。

## 有用な env と計器

| env | 用途 |
|---|---|
| `DS4_METAL_V41_ABORT_GATE=40` | abort gate（現 baseline の一部） |
| `DS4_METAL_V41_ABORT_GATE_SEG=3` | segment 長（2-3 が最良） |
| `DS4_METAL_V41_ROUTED_SWEEP=gate_up\|down\|both` + `_LAPS` | routed cold sweep |
| `DS4_METAL_V41_COLD_SWEEP=q_b\|output_a\|output_b` + `_LAPS` | dense cold sweep |
| `DS4_METAL_MISS_RESIDENCY=8 DS4_METAL_MISS_RESIDENCY_SAMPLE=16` | miss 時の in-core 率 |
| `DS4_METAL_V41_GATE_ROUTE_LOG=<path>` | route log（容量シミュレーション用） |
| `DS4_METAL_V41_ROUTE_PREDICT=<path>` | 層 L−d の hidden state から層 L の route を予測するトレース（gate OFF で使う） |
| `DS4_METAL_V41_REPAIR_BATCH=1` | residency transaction + 末尾 prune（既定 OFF） |
| `DS4_METAL_V41_DECODE_LEND_HEADROOM=1` | prefill headroom 貸与（既定 OFF） |
| `DS4_V41_VERIFY_SELFTEST=k` + `_ROUNDS` | batch 行コストと損益分岐 |
| `DS4_METAL_V41_WEIGHT_LEDGER=1` | shape からの weight bytes 積み上げ |
| `DS4_METAL_V41_FUSE_BF16=0` | BF16 融合を切り従来 pass に戻す（既定 ON） |
| `DS4_METAL_V41_GATE_CENSUS=1` | gated dispatch の呼び出し元別 census（2フレーム、既定 OFF） |
| `DS4_METAL_STREAMING_EXPERT_TIMING_SUMMARY=1` | expert ロードの prepare / pread / install 分解 |

route log の policy シミュレータは 3日目 scratchpad の `cachesim.py`
（7 policy、指標は abort 数、実機と2度一致）。dispatch 単価のプローブは
`ds4-macos/proto/dispatchcost.m`（README に表と build 行）。

## 仕様として残る発見

**巻き戻しは `previous_kv[0..2]` / `previous_score[0..2]` を復元しないと壊れる。**
`ratio==2` の層が2位置を1つの圧縮エントリに畳み、前半をこの2つに持ち越すため。
復元しないと静かに違う出力になる。投機デコードや任意のリトライ実装は必ず踏む。
