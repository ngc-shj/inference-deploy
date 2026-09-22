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

## そして負けた — この線は閉じた

3 ブロック・12 run、`ORACLE_MODE=1` 対 oracle なし（両アームとも overlap ON）。
検査は全通過（全12 run で1ハッシュ、gate failure 0、22窓で仕事量一致、
両アームとも section が毎回開いた）。宣言差は投機自身の dispatch のみ。

| | on − off | 95% CI | on 有利 block |
|---|---|---|---|
| raw wall（主） | +1.52（中央値 +1.13） | [-0.61, +3.65] | 0/3 |
| commit-to-done | +1.42 | [-0.34, +3.19] | 0/3 |
| **GPU envelope** | **+1.52** | **[+0.40, +2.63]** | **0/3** |
| host encode | +0.06 | [-0.08, +0.20] | 0/3 |
| repair-load | -0.05 | [-0.69, +0.60] | 1/3 |

**GPU が 1.5 ms/token 余計に使って、何も返ってこない。** envelope の区間は 0 を
含まない。raw wall の区間が 0 を含むのは run 間ばらつきが効果より大きいためで、
向きは全指標 0/3。host encode が動いていないので、dispatch を積む手間ではない。

### 理由と、予測器を作っても無駄な理由

再利用 235.2/240 なので、routed gate/up の演算は baseline の 6 lane に対し
**6 投機 + 0.12 実 = +2%** しかない。**+2% の仕事で +1.5 ms** 出るということは、
損失は仕事量ではなく**仕事が隠れていない**こと。

隠れる相手だったはずの router window が2つの理由で消えた:

1. router が鎖なので、上の修正後は投機が重なるのは**射影だけ**で選択とは重ならない
2. その射影が小さい。投機側は IQ2_XXS を読む 1728 threadgroup、射影は 384 行への
   Q8_0 matvec 1本。1.5 ms を隠せる規模ではない

**完全予測器が負けたので、精度の問題ではない。** 不完全な予測器は投機を同じだけ
行って再利用が減るだけなので、**黒字になる精度は存在しない。**
`DS4_METAL_V41_ROUTE_PREDICT` の lead-1 probe は接続不要。

機構は既定 OFF のままツリーに残す。再開の条件は「予測器の改善」ではなく
**投機が重なる相手が大きい構造**。

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

**6日間の作業は全部 41.1 の中で行われてきた。10.9 はトークンの 1/5 で、
GPU の仕事ですらなく、まだ何も試されていない。** 中身は 4.8 miss/token ——
完全 oracle が再利用できなかった 4.8 と同じ数字。このセッションで2回、
残っているのはルーティングではなく**ストリーミングキャッシュ**だと出た。

## 次にやること（有望度順）

1. **repair-load 10.9 ms。** 4.8 miss/token を減らすか、ホストのロードを
   GPU の実行に重ねるか。`bench/cachesim.py` が route log に対して
   キャッシュ方針をオフラインで再生できる（既存・未活用）。
   まず「4.8 は方針で減るのか、容量で決まっているのか」を replay で分ける
2. **HC fork**（1層2回・80回/token）。address-table カーネルを含まないので
   shared∥routed と同じ section 構造が使える見込み。ただし shared∥routed は
   見込み 2.7 ms に対し実収 1.0 ms だったので期待値は割り引くこと
3. **Metal 4。** queue 対応は検出済み・未使用。AGX の
   `insertIndirectTGOptKernel` クラッシュを踏まない設計への道でもある

### 閉じた項目（再挑戦不要）

| 対象 | 判定 |
|---|---|
| per-expert 投機再利用 | **閉** 完全 oracle で GPU +1.5 ms/token。精度では解決しない |
| Engram の非同期化 | **閉** 0.82 ms/token しかない |
| 狭い射影5本の統合 | **閉**（5日目）前提が計器の誤り |
| encoder 境界が高いという見立て | **撤回**（5日目）測定限界以下 |

## 最終状態

- `ds4-v41`: 7 コミット、**未push**、作業ツリーはクリーン、ビルド可。
  既定経路は6プロンプトでバイト一致
- `inference-deploy`: 記録・ハーネス・prototype をコミット済み、**未PR**
- プロセス 0。`bench/thermal --until 0.97` で落ち着きを確認してから次を測ること
