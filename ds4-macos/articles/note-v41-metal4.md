# 341 GiBのDeepSeek V4.1 FlashをM5 Maxで動かす――bit-exactのままMetal 4化・高速化した記録

**SSD streaming、gated decode、prefill superbatch、GPU race、熱ドリフトまで**

## 結論

128 GBのM5 Max 1台で、DeepSeek V4.1 Flash Q2（ディスク上341 GiB）を、expertの重みをSSDから読みながら動かしています。エンジンはDwarfStar（`ds4`）をforkしたもので、今回の作業の制約は1つだけです。

**出力を、基準とする凍結済みビルド（frozen oracle）とビット単位で一致させたまま速くすること。**

token idだけでなく、logitを全語彙ぶん、それに保存したKV/carry状態まで、1ビットも変えません。この条件のもとで、次の結果を得ました。

- まずdecodeを、着手時のupstream mainの12.7 tok/sから、凍結したexact版で24.1 tok/sまで改善しました（2048トークンの持続生成、約1.9倍）。
- その後、productionのGPU submissionをMetal 3からMetal 4へ移し、冷却した同条件の比較で40.4 ms/token前後から38.7 ms/token前後へ、さらに約4.3%短縮しました。
- 長いprompt（4,795トークン）の初回prefillは、条件によって次のとおりです。条件の違いは後述します。
  - 新しいprefill経路を切った同一バイナリでは約101秒、入れると約67秒でした。
  - 5分休ませた冷えた状態では約35秒です。
- 短いprompt（18トークン）では、最初のトークンまでの時間が上流mainの約4.6秒に対して約1.7秒です。decodeも約2倍速く、出力の文章は一致しました。
- 長いpromptでは、冷えた状態ならmainとほぼ同速です（差は約1秒）。ただし連続で処理すると、こちらだけ発熱で35秒から55秒まで落ちます。
- 途中で「mainより25〜37秒遅い」という誤った結論を一度出しました。原因は機体の温度状態で、測り直して訂正しています。その経緯も書きます。

再現手順はfork（`ngc-shj/ds4`）のtag `ds4-v41-metal4-superbatch-exact-production-documented` のREADMEにあります。

## 環境と前提

- **機体:** Apple M5 Max（GPU 40コア）、ユニファイドメモリ128 GB、macOS 26.6.2
- **モデル:** DeepSeek V4.1 Flash Q2（`DeepSeek-V4.1-Flash-Q2.gguf`、約341 GiB）
- **実行方式:** SSD streaming。常駐する重みは9.37 GiBだけで、routed expertは必要なものをSSDから読んでキャッシュします
- **メモリ予算:** エンジン全体で80 GiB（KV、バッファ、常駐重み、expertキャッシュ約58 GiB＝7,034個、prefill用予約7.12 GiB。計画値77.99 GiB）
- **基準:** 以前のMetal 3版productionを凍結したビルド（frozen oracle）

V4.1は384個のrouted expertから1トークンあたり6個を選ぶMoEです。expertは全部でメモリに入る大きさではないので、prefillは各層について「次の層の重みを先読みしつつ、今の層を計算する」ストリーミング処理になります。

「ビット一致」は次の3つで確認しています。

- 生成したtoken idのハッシュ
- 全logitのハッシュ（各評価のlogitをそのままmemcmp）
- セッションが保存するKV/carry状態のハッシュ

最終確認では、受け入れ項目15個すべてで、これらが基準と一致することを確かめました。

## 成果：数字と、その測定条件

この記事の数字は、測定条件ごとに意味が違います。条件を分けて示します。

### A. 持続decode

着手時のupstream mainは12.7 tok/sでした。expert cache、ゲート付きdecode、host round tripを改善した凍結Metal 3版は、2048トークンの持続生成で41.5 ms/token（24.1 tok/s）です。

その後のMetal 4移行は別の冷却ABBAで評価しました。同じ計算を行う凍結Metal 3版が40.3 / 40.5 ms/token、Metal 4版が38.7 / 38.6 ms/tokenでした。これはbackend移行の差を測った比較であり、前記の12.7→24.1 tok/sとは測定runが異なるため、両者を引き算して内訳には使っていません。

decodeについては、最終tagをMetal 4 baselineと比較したrun ZのABBAが−0.225 ms/tokenで、退行なしと判定しました。また、その直前版ではsuperbatchをon/offしたcapacity testをon/off/off/onの順で4回実行し、decode中の適用が0層であることを確認しました。この4回は61〜109 ms/tokenとばらつきが大きいため、速度差の主張には使わず、「退行を示す証拠はない」という確認だけに使っています。

### B. 新しいprefill経路のオン／オフ（同一バイナリ、連続実行）

最終確認の一部として、同じバイナリで新しいprefill経路を一式オフにした「基準側」とオンの「新側」を、old/new/new/old/new/old/old/newの順に交互に計測しました。オフにした経路はsuperbatch、層インターリーブ、indexerのbatch top-k、attention row tileなどです。

各回ともページキャッシュを捨て、短い落ち着き待ちのあと続けて走らせています。

**1ブロック目**

- 基準側（新経路オフ）：101.3秒、102.7秒
- 新側：64.6秒、68.2秒
- 差：−35.6秒

**2ブロック目**

- 基準側（新経路オフ）：101.8秒、99.5秒
- 新側：66.7秒、70.9秒
- 差：−31.9秒

平均は101.3秒から67.6秒で、約33%の短縮です。8アームすべてで出力は基準と一致しました。

この101秒と67秒は、重い計測を連続させた、機体が温まった状態での値です。

### C. 冷えた状態のcold run（5分休止後）

各回の前に5分休ませ、ページキャッシュを捨ててから1回ずつ計測しました。比較対象は上流main（`0aaea5a`）です。メモリ条件を揃えるため、mainのexpertキャッシュは7,034に指定しています。

- **main:** 34.06秒、34.26秒。長いpromptの出力は基準と**不一致**
- **今回の版:** 35.17秒、35.37秒。長いpromptの出力は基準と一致

差は約1秒です。mainは、Q8の行列積に別の演算方式（重みをhalfに丸めるtensor-op matmul）を使うので、出力が基準と一致しません。キャッシュを既定の10,268のまま起動した場合は、wired memoryが90 GiBに達し、計測ガードに止められて完走しませんでした。

### D. 短いprompt（新しいサーバー起動直後の1回目）

- **main:** prompt処理は4.74秒、4.54秒。decodeは8.1、10.9 t/s。回答文は一致
- **今回の版:** prompt処理は1.66秒、1.67秒。decodeは17.5、17.6 t/s。回答文は一致

この差は、本ブランチで作り込んだexpertキャッシュと、ゲート付きdecodeから来ています。

## 第一段階：1トークンずつ進むdecodeを速くする

LLMの実行は、大きくprefillとdecodeに分かれます。prefillは入力promptをまとめてモデルへ通し、各層のKV/carry状態を作る処理です。その後のdecodeは、その状態を使いながら、原則として1回の評価につき次の1トークンを生成します。

このモデルのdecodeでは、40のMoE層がそれぞれ384 expertから6個を選びます。全expertはメモリに収まらないため、選ばれたexpertがキャッシュになければモデルファイルからexpertを登録し、GPUから参照できる状態にして、その層を再開します。OSのpage cacheにhitしていれば、このmissが物理的なSSD readを伴うとは限りません。このため、単純な行列積の速度だけでなく、次の処理がwall timeを左右します。

- routerが選んだexpert IDをhostが受け取る
- expert cacheを検索し、missを修復する
- アドレス表を更新してGPU処理を再開する
- これを各層・各トークンで繰り返す

### decodeで効いた変更

最初に固定した大きな成果は、Metal 3版のexact productionです。2048トークンの持続生成で、着手時のupstream mainは12.7 tok/s、改善後は41.5 ms/token（24.1 tok/s）でした。出力を変えずに約1.9倍です。

主に効いた変更は次のとおりです。

**expert cacheの拡張と、prefill用予約領域の貸し出し**

−2.06 ms/token。abortは5.13回/tokenから2.98回/tokenへ減りました。

**router、HC処理、遷移処理などの融合**

dispatchを約2,045本/tokenから約1,285本/tokenへ減らし、−1.84 ms/tokenでした。同一プロセス内、64トークンのABBAで測った値です。

**不要なcache-slot待機とresident pass完了待ちの削除**

host round tripを短縮しました。

**expertのzero-copy viewとbf16丸めのproducerへの融合**

copyと中間passを削減しました。

dispatchを760本減らしても短縮は1.84 ms/tokenにとどまりました。1本あたりのdispatch costを足し上げればwall timeになるわけではなく、GPU実行、host処理、cache miss修復が重なっているためです。局所的なdispatch数ではなく、最終的なwall timeで採否を決めました。

### Metal 3互換実行から、Metal 4のsubmission構造へ

decodeを24.1 tok/sまで改善した時点では、productionはまだMetal 3 APIでGPUへ命令を送っていました。単に型をMetal 4へ置き換えただけでは約0.5 ms/token遅くなったため、命令の組み方も見直しています。

- command bufferごとにencoderを1つにし、section境界をencoder内barrierへ変更
- gate付きsegmentを、直前segmentの結果をhostが読む前にcommit
- command allocator、argument table、residency set、feedbackをMetal 4側で管理
- V4.1 single-host productionでは、Metal 4選択後のMetal 3 command実行を0にする

特に、次のgate付きsegmentを先にcommitする変更で、segment間にあった約1.05 ms/tokenのGPU停止が0になりました。冷却した2048トークンのABBAでは、凍結Metal 3版の40.3 / 40.5 ms/tokenに対し、Metal 4版は38.7 / 38.6 ms/tokenでした。出力は全armで一致し、約1.75 ms/token（4.3%）の短縮です。

この変更の初版では、abortで0にしたdispatch slotをhostの書き込みが再び有効にするraceがありました。停止すべきdispatchが2万件以上残ることをcounterで検出し、次segmentの先頭で前segmentのabortをGPU上で再適用するように直しています。以後、止め損ねは0です。

最終tagでは、single sessionだけでなく、native batch、vision、disk KV cache、engine reopen、failure injectionを含む15項目を通しています。最終tag自身のrun ZではMetal 4 baselineに対するdecode退行がないことを確認し、その直前版のon/off試験ではsuperbatchがdecode中に0層へ適用されることを確認しました。

一方、text-only draft、self-draft、attentionのhead統合、層内DAG、expert-ready continuation、小さなfusionなどは、exactなend-to-end性能が改善しなかったため閉じています。測りやすい局所処理を追い続けず、decodeを固定してからprefillへ移りました。

## 第二段階：prefill superbatch

最も効いたのは、長いpromptのprefillの組み方です。

8K文脈では、4,096行の前半（prefix）は2,048行ずつ2つのchunkに分けて、層ごとに処理していました。各層で2回ずつ、同じ処理を回していたことになります。

そこでprefill 1層の処理をすべて書き出し、行どうしが依存するかで分類しました。

**行に依存せず、4,096行で1回にまとめた処理**

- HC mixとnorm、q_a/q_b/kv投影、RoPE
- compressorの公開とindexerの投影（ペアは偶数位置から閉じる）
- attention出力の投影、router、shared expert、routed expert、HC展開

**因果的な依存があり、chunkごとの順番を維持した処理**

- raw window
- indexerの選択
- attention本体

行に依存しない処理はすべて4,096行で1回にまとめ、因果的なattentionだけをchunk単位に残しました。

一番効いたのはrouted expertです。1回の呼び出しで1 expertに来る行が平均32行から64行に増え、expertの重みの展開がchunkごとの2回から層ごとの1回になります。ある計測では、prefixのGPU時間が26.1秒から22.7秒に減りました。

各行の演算順序は変えていません。行数によってカーネルを切り替える箇所も、2,048行と4,096行で同じ選択になることを確かめています。そのため出力は1ビットも変わりません。

ただし、この分類を最初からできていたわけではありません。初期検討ではrouted expertだけを統合し、他の処理は「候補なし」と閉じかけていました。そこで局所的な候補探しを止め、prefillグラフ全体を行間依存の有無で分類し直したことで、superbatchにまとめられる範囲が見つかりました。

メモリ配置にも細工が要りました。prefixと並行して走る末尾699行（tail）が、arenaの同じ行を使っていたからです。arenaを800行ぶん広げると0.47 GiB増え、その分キャッシュできるexpertが約100個減りました。そこで、tailが層をまたいで持ち越す5つのフィールドだけを専用の領域（57 MiB）に移しています。

## 正しさ：一度の不一致と、GPUのrace

最終確認の1回目は通りませんでした。

2つのセッションを1トークンずつ交互に進め、logitを毎回比較する試験があります。この試験で、2つ目のセッションだけが評価1,298から食い違いました。ところが、その後に条件を変えて32回再現を試しても、一度も再現しませんでした。そこで待つのをやめ、コード監査に切り替えました。

監査で、routerのカーネル（`kernel_dsv41_route_schedule`）に実在するraceを見つけました。

- 1つのthreadgroupが2行を計算し、2行目はスレッド256が書き込みます。
- 一方、完了の数え上げ（atomic）はスレッド0だけが行います。
- 既存のfenceだけでは、スレッド256の書き込みがスレッド0の完了カウンタ更新より前に可視になることを保証できませんでした。
- そのため、最後に到着したグループが、前の層の古い値でexpertを選ぶ可能性があります。

`threadgroup_barrier` を1行入れれば直り、演算は変わりません。このraceは今回の高速化より前からあり、以前のproductionにも含まれていました。

あの1回の不一致の原因がこれだと断定はしていません。再現できていないからです。

代わりに、次の2つを入れました。

- **不変条件チェック:** 「GPUが動いている間にexpertキャッシュの中身が変わらないこと」を常時確かめます。73,875回のチェックで違反は0件でした。
- **トークンごとの履歴:** 直近32トークンのキャッシュの状態を、セッションごとに保持します。

修正版で最終確認をやり直し、15項目すべてを通しました。

## 失敗と訂正：25〜37秒差は熱だった

mainと比べたとき、長いpromptのcold runは、mainが約35秒、こちらが60〜71秒でした。差は25〜37秒あり、一度は大きな改善余地があると判断しました。

実際には、こちらの計測は重い試験を続けた直後で、機体が温まっていました。決め手になったのは次の3つです。

1. 同じ条件のcold runを2回続けると、36.2秒から51.1秒に伸びました。
2. 同じ2回で、次の層の重みの先読み（pread）は2回とも完全に計算の陰に隠れていました。40層ぶんの待ちの合計は0.22秒です。I/Oは原因ではありません。
3. 伸びた時間の内訳は、GPUが重い部分（prefixの計算、tailの2層目以降）だけが36〜52%遅くなっていました。ホスト側の処理（tailの最初の層の準備は3.03秒から3.09秒）、ページイン、先読み待ちは変わっていません。

各回の前に5分休ませて測り直すと、差は約1秒でした（前掲C）。計測前に使っていた短い熱プローブは、温まった状態でも同じ値を返していて、この差を検知できていませんでした。

この後は「長いpromptの数字は、同じ熱状態どうしでしか比べない」と決めています。

### 連続実行での低下は、こちらだけ

5分休んだあと長いpromptを3回続けると、次のようになりました。

- **main:** 34.6秒 → 33.3秒 → 34.4秒
- **今回の版:** 34.9秒 → 40.9秒 → 54.4秒

mainは1回あたり約8秒をI/O待ちに使っていて、その間GPUが自然に休んでいます。こちらはI/Oを計算の陰に隠し切ったので、GPUが休まず動き続けます。

計算量の差は、ステージ単位の計測（各ステージの境界で同期をとって測る壁時計時間）から見積もりました。冷えた状態の合計で、mainは約19.5秒です。こちらはprefixが22.5秒（計測中はsuperbatchが無効）、tailが約12.9秒です。superbatchぶんを差し引くと、**mainの約1.6倍と推定**しています。

増えている分は、ほぼ次の3つです。

- Q8_0の投影（q_a/q_b/kv）
- shared expertのQ8_0
- tailの1行ずつの演算

どれも基準と同じ演算順序・丸め位置を守るために必要な処理で、mainの出力が基準からずれる場所と同じです。

## 試して採用しなかったもの

主な代表例です。どれも出力は基準と一致したまま測りました。

- **Q8_0の別タイル（16×4、16×2、8×8、32×4など）:** 冷えた状態でも、温まった定常状態でも、現行の8×4より遅い（+0.8〜+23秒）
- **Q8_0のreductionを1回のbarrierにまとめる:** 同等か最大30%遅い
- **Q8_0の重みを整列した配置に詰め直す:** 同等か7〜17%遅い
- **routed expertのタイルを大きくする（64×64、128×64）:** 遅い
- **gate/up/SwiGLUを1つのカーネルに融合:** 遅い
- **tailのexpert-major化（行をexpertごとにまとめる）:** 速くならない
- **次の層の先読みを前倒しする:** 先読みは既に計算の陰に隠れていて、余地なし
- **FFNのoverlapを直列にする:** 変化なし（35.8 / 38.7 / 53.8秒）
- **層の境界で休止を入れる（thermal pacing）:** 3回の合計で、1回あたり計4秒の休止は+6.4秒、8秒の休止は+19.3秒と悪化
- **arenaを800行広げる:** 0.47 GiB増え、キャッシュできるexpertが約100個減るので不採用

これ以上速くするには、Q8をtensor-op化したり、tailをまとめてバッチ化したりする必要があります。どちらも演算順序が変わるので、今回の要件（ビット一致）と両立しません。ここで打ち止めとしました。

## 再現手順

詳しくはfork（`ngc-shj/ds4`）のtag `ds4-v41-metal4-superbatch-exact-production-documented` のREADMEにあります。要点は次のとおりです。

```bash
git clone https://github.com/ngc-shj/ds4.git ds4-v41
cd ds4-v41
git checkout ds4-v41-metal4-superbatch-exact-production-documented
make ds4-server
HF_HUB_DISABLE_XET=1 ./download_model.sh ds41f-q2
```

起動には、READMEにある環境変数15個と次の引数を指定します。

```text
--ssd-streaming --ctx 8192 --ssd-streaming-cache-experts 10268
```

前提は次のとおりです。

- 対象は128 GBのM5 Max、macOS 26以降（Metal 4が必要）です。他の機体では試していません。
- GPUを使うプロセスは、同時に1つだけにしてください。
- V4.1は既定でthinkingを行います。答えだけをすぐ返させたいときは、リクエストに `"think":false` を付けてください。

## おわりに

速くすること自体よりも、遅くなった・速くなったという結果が、何によって生じたのかを切り分ける作業が大半でした。熱、I/O、キャッシュ、GPUのrace、測定方法のどれなのかです。

ビット一致という制約があったおかげで、変更が出力を変えていないことは、token列、全logit、KV/carry状態の機械的な比較で確かめられました。そのぶん、残る疑問は「その計測は正しいか」に絞られました。25〜37秒差の誤りに気づけたのも、その姿勢のおかげです。
