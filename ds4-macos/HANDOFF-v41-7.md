# 引き継ぎ: DeepSeek V4.1 Flash / Metal 4（8日目）

## 目的と合格条件

目的は計器や Metal 4 移植そのものではない。**実モデル・全40層・実運用経路で
baseline と出力バイトが完全一致し、持続 wall time / token を削ること**。

Metal 4 経路が byte-wrong の間は性能値を出さない。正解化後も E2E で利益がなければ
閉じる。

## 作業場所

- Metal 4 worktree: `~/ghq/github.com/antirez/ds4-v41-mtl4`
- branch: `perf/v41-metal4`
- 現在の HEAD: `8377a54` (`Metal 4 is byte-wrong in a way no ordering or visibility change moves`)
- この worktree は引き継ぎ時点で clean
- HC worktree: `~/ghq/github.com/antirez/ds4-v41-hc`, HEAD `0efa2d2`
- 通常 worktree: `~/ghq/github.com/antirez/ds4-v41` は `ds4.c` が dirty。勝手に戻さない
- 記録: この repository の `ds4-macos/V4.1-TUNING.md`
- standalone prototype: `ds4-macos/proto/mtl4.m`（引き継ぎ時点では未追跡）

全て未 push / 未 PR。

## 現在地

Metal 4 経路は**落ちなくなり、実仕事を運んでいるが不正解**。

- Metal 4 OFF: baseline とバイト一致
- `DS4_METAL_V41_ABORT_GATE_SEG=1`, `DS4_METAL_V41_MTL4=1`:
  1層だけ Metal 4、約 **50.47 dispatch/token** が実走し、出力 hash が不一致
- 複数層では約 3.36 segment/token、416.06 dispatch/token が Metal 4 を通ることを
  カウンタで確認済み
- 現在の wrong hash は `3922d49f`

したがって「Metal 4 path が engage していない」「compute encoder を作るだけで落ちる」
という段階ではない。

## 直した実バグ

### 1. 同じ encoder を二度 `endEncoding`

`g_batch_enc` と `g_mtl4_enc` が同じ実体を別々に所有し、flush/end で二重終了していた。

### 2. 終了済み encoder の再利用

engine は concurrent section の境界で同じ command buffer 内の encoder を閉じて再度開く。
shim は終了済みの encoder を返していた。各 reopen で新しい encoder と argument table を
作り、全て command buffer 完了まで保持するよう修正した。

この2点が `AGXG17XFamilyComputeContext` fault の原因だった。`NOENC` が動いたことは
encoder作成自体の故障を意味していなかった。

### 3. encoder 間順序

Metal 3 と違い、Metal 4 は同一 command buffer 内で後から開いた encoderも並行しうる。
encoder先頭の queue-stage barrier で encoder 間を順序づけ、短い生成で17 tokenに
切れる故障を解消した。

### 4. residency set の確定時期

setを空のままbegin時にcommitしていた。encoding中に発見したscratch/resourceを含め、
encoderを閉じた後にcommit/useするよう修正。hashは動いたが、まだ不一致。

### 5. argument table の基本semantics

- `maxBufferBindCount=32` は上限超過なので31へ修正
- `initializeBindings=YES`
- `setBuffer:nil` はno-opではなく該当slotをclear
- binding index超過は即abort

いずれも必要な修正だが、最終hash不一致は残る。

## 試して否定されたもの

同じwrong hashに対して以下は結果を動かさなかった。

- encoder-stage barrierを全edgeへ追加
- queue-stage barrierを双方向へ追加した`HARDSERIAL`
- visibilityに`ResourceAlias`を追加
- command bufferを`before_attention` / `after_attention` / `before_moe`で分割
- argument table初期化、nil unbind

`NOTGMEM`でhashは動くため、`setThreadgroupMemoryLength`は無視されてはいない。

stage checksum probe は使わないこと。4 probeと7 probeでMetal 3側の計算自体も変わり、
両armが同じ別計算をして一致しただけだった。bare drainでやり直すと正解化しない。

結論は「ordering/visibilityではない可能性が高い」まで。API全体が正しいとは言えない。

## 次にやること

prototypeへtensor APIやtimelineなどの「engine固有状態」を闇雲に足さない。次は
**1層50.47 dispatchのうち、どのproduction dispatchをMetal 4へ置換すると初めて
出力が変わるか**を絞る。

推奨手順:

1. Metal 3を既定のまま使い、指定したdispatch ordinalまたはcall-siteだけをMetal 4へ
   渡す診断モードを作る
2. 切替前にMetal 3をcommit/wait、対象1 dispatchをMetal 4で実行してwait、その後
   Metal 3へ戻す。遅くてよい。これは原因特定専用
3. pipeline label/call-site、grid、threadgroup size、buffer index、GPU address、offset、
   setBytes長、threadgroup memory長を1 dispatch分だけ記録する
4. 1層の約50 dispatchを二分またはsite単位で絞り、最初にbyte差を作るkernel/bindingを
   得る
5. その1本をstandaloneへ移してMetal 3/4の出力bufferを直接比較する

production graph全体を一度に通したままflagsを増やすのは止める。現状の差は
「何を読むか」に寄っており、kernelを特定しない追加実験は正解化へ直結しない。

## 正解化後の順序

1. 1層 Metal 4でbaselineと全出力バイト一致
2. 2/3層、次に40層で一致
3. 6プロンプト、最長2048 token、経路counter一致
4. 最初はMetal 3相当の完全直列barrier構造でE2E A/B
5. 利益がある、またはDAG並列化の上限が1 ms/token以上なら、証明できる依存辺だけ
   barrierを外す

Metal 4の価値はAPI変更によるindirect税除去ではない。prototypeでは完全直列化した
Metal 4はMetal 3より安くなかった。価値があるとすれば、真の依存辺だけをbarrierで
表してDAGの独立部分を重ねること。

## 他候補の状態

- shared expert || routed expert: Metal 3で約1 ms/tokenを回収済み
- HC fork: `0efa2d2`。level 2はbyte一致するが約0.11 ms/token相当。優先しない
- per-expert投機: 完全oracle、compact completion、240 lane、byte一致でも速くならず閉じた
- Engram非同期化: 0.82 ms/token上限で閉じた

Metal 4の正解化に長く掛かり、DAGで新たに回収できる額が1 ms/token未満と分かった時点で
閉じる。正解化そのものを成果扱いしない。

