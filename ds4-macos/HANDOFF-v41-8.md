# 引き継ぎ: DeepSeek V4.1 Flash / gate encode-ahead（9日目）

## 目的と今回の結論

目的は **品質を変えず、実モデルの持続 wall time/token を削ること**。Metal 4 の
正解化そのものは成果ではないため凍結し、既に実装されていた gate encode-ahead を
production 条件で正解化した。

今回の到達点:

- encode-ahead は全40層・実weight・実loaderで **baseline と全出力バイト一致**
- 400 token の同一仕事 smoke pair は **38.648 s → 28.727 s**
  （request wall -25.7%、throughput +34.5%）
- ただし性能値は **1 pair**。方向を示す実走結果であり、確定した改善率ではない
- 現実装は毎 segment を連続して隠しておらず、次の実装対象は
  **1-buffer lookahead の連続パイプライン化**

## 作業場所と固定点

- コード: `~/ghq/github.com/antirez/ds4-v41`
- branch: `perf/v41-metal-apple`
- encode-ahead 正解化: `29ccc9d` (`Make gate encode-ahead safe across missing experts`)
- 記録・ハーネス: `~/ghq/github.com/ngc-shj/inference-deploy`
- branch: `docs/v41-tuning`
- 全て未 push / 未 PR

Metal 4 の現状は `HANDOFF-v41-7.md`。`ds4-v41-mtl4` の byte-wrong 経路は
今回触っていない。現時点では encode-ahead の方が、同じ host encode 2.5 ms/token を
critical path から外す安い機構であり、こちらを先に完成させる。

## 直した正しさの穴

変更箇所は `ds4.c` の `ds41_graph_step()`、gate segment loop。

旧実装の ahead segment は FFN overlap のグローバル switch だけを見ており、
`ds4_gpu_routed_moe_one_gated_available()` を確認していなかった。residency set が無い、
または gated routed path が使えない場合、host-driven `ds41_moe_experts_row()` へ落ちる。
しかし selected IDs を作る router は、まだ走行中の先行 command buffer にある。
その未完成値を CPU が読むため、これは encode-ahead ではなく不正な同期だった。

実際、residency set 無しの試験は quicksort が29 tokenで止まり、次の出力は invalid UTF-8、
ahead encode は約116.6 ms/tokenになった。ログにも
`gated routed path declined at layer 0: no residency set` が出た。

`29ccc9d` は次を行う。

1. ahead 対象の全層で gated routed path の可用性を事前確認
2. 使えない層または Engram 層の手前で speculation を止める
3. ahead 経路を `route_only + validate + experts_overlapped` に限定
4. ahead buffer が abort したとき、その buffer の execution shape を
   `spec_resume_overlap` から continuation へ復元

最後の点も実バグ。旧コードは前 segment の `resume_overlap` を残していたため、ahead
buffer の abort 後だけ shared/routed layout が、その buffer を作った形と食い違いうる。

## 正しさの固定

production 条件:

```sh
DS4_METAL_V41_ABORT_GATE=40 \
DS4_METAL_V41_ABORT_GATE_SEG=3 \
DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 \
DS4_METAL_V41_FFN_OVERLAP=1 \
DS4_METAL_V41_GATE_ENCODE_AHEAD=1
```

`bench/correct.sh` の6プロンプト、最長2048 tokenで、既知 baseline
`bench/co-full-base.json` と `bench/co-ea-full-on.json` がファイル単位で一致した。

| prompt | sha256 |
|---|---|
| breakout | `d68de436f26c7913e6a758f0296216a994e4544b6131a30d15e635b3b90407a2` |
| quicksort | `c6453f195ef62ce32fedd2c6348c2af1097e8317687c5ed6548b43ef3dd913c4` |
| haiku | `7a706776a8529f39c5c62384f28f19eabab0f2229a631aac3f72326fb55ce228` |
| json | `412ef20f1f431007466615d51b419fbde104069dd41b9a7ccfbba902400ff969` |
| proof | `be6e3525eefa1738645249416f2a3458d00fdbcd5b0e1aa141fc7468edf9f620` |
| long | `c7456ea2ec55204714ecc5db79e657f6dcaeda28bcc8a13acc98ed8e6e60b144` |

全窓で gate failure 0、ungatable 0、accounted expert IDs 240/token。
`make -j8` も成功。既存の `unused variable gate_done` warning のみ。

## 性能 smoke pair

同一 binary、400 token、FFN overlap ON。違いは
`DS4_METAL_V41_GATE_ENCODE_AHEAD=0/1` のみ。

```sh
NTOK=400 DS4_BIN=~/ghq/github.com/antirez/ds4-v41 ./abba.sh ea-perf-off \
  DS4_METAL_V41_FFN_OVERLAP=1 DS4_METAL_V41_GATE_ENCODE_AHEAD=0

NTOK=400 DS4_BIN=~/ghq/github.com/antirez/ds4-v41 ./abba.sh ea-perf-on \
  DS4_METAL_V41_FFN_OVERLAP=1 DS4_METAL_V41_GATE_ENCODE_AHEAD=1
```

両 arm の出力は同じ400 chunks、sha256:
`ec789c95b0c0c47d96172c3fbb0cd0729e51f674ee612ca17707209f0e6bedf2`。

| | OFF | ON |
|---|---:|---:|
| request wall | 38.648 s | 28.727 s |
| throughput | 10.35 token/s | 13.92 token/s |

6個の64-token窓すべてで command buffers、aborts、expert IDs、loaded MiB、misses、
evictions が一致した。したがってこの pair で仕事量は同じ。後半窓では
ahead segment が約6.3--6.6/token使われ、dropは4.0→2.4/tokenまで下がった。

ログ:

- `bench/ab-ea-perf-off.log`
- `bench/ab-ea-perf-on.log`

### この数値を確定値にしない理由

- 1 pairのみで、ABBA・長時間持続試験ではない
- 充填中の miss が多い400-token runで、OFF/ONの絶対時間は機体状態にも動かされる
- `pair.py` は steady windowを token 449以降に固定しており、400-tokenログを正式解析
  できない

ただし、出力と全仕事量が一致した同一経路で約10秒差が出ているため、次に進むに十分な
性能信号はある。

## 計器の既知の不整合

encode-ahead ONでは排他内訳がwallに閉じず、後半で residualが約15--19 ms/token、
`GPU not running` が負になる。これは計算の故障ではなく、現計器が
**ahead CBをencodeしているCPU時間と、複数CB envelopeのoverlapを排他的に扱えていない**
ため。OFFでは残差0.1 ms以内に閉じる。

性能実装と混ぜて直さないこと。必要なら先に区間定義を直すが、主指標は request wall と
token timestampsのままでよい。

## 次に実装するもの

現在の encode-ahead は一段だけで、成功したahead bufferをcommitした後はその完了を
すぐ待つ。このため概ね「1 segmentを隠し、次のsegmentでは待つ」を繰り返す。

次は **連続 one-buffer lookahead** にする。

```text
current CBをcommit
  while currentがGPUで走る:
      next segmentをfresh CBへencode
  currentをwaitしてabort判定
  success:
      prepared nextをcommit
      その実行中にfollowing segmentを別CBへencode
  abort:
      prepared nextをdiscard
      missをrepairし、失敗層のrouted stageからcontinuation
```

守る条件:

1. GPUの正しさ判定はcurrent CB完了後だけ。CPU pollingを正しさに使わない
2. prepared CBは先行segmentがabortしたら必ず破棄。後続stateを書かせない
3. Engram drain境界（層14）を越えて先読みしない
4. `resume_overlap`、gate slot、route/accounting logを**CBごとのmetadata**として持つ
5. residency/address tableはencode中に変化させない。repair後のprepared CBは使わない
6. 合格は同じ6プロンプトのバイト一致、gate failure/ungatable 0、仕事量一致、
   その後に1000-token以上のABBA

現実装を測り足して止まらないこと。まず連続パイプラインを実装し、正解化してから
持続wallを取る。

## 現在の優先順位

1. gate encode-aheadを連続one-buffer lookaheadへ拡張
2. 6プロンプトbyte一致と1000-token paired/ABBAで効果を固定
3. 効果が残れば既定ON候補にし、overlap/gateの設定依存を整理
4. Metal 4はその後。`HANDOFF-v41-7.md` のbyte-wrong原因追跡は優先しない

per-expert投機、Engram async、HC fork、cache policyの再探索は
`HANDOFF-v41-6.md`で閉じている。そこへ戻らない。
