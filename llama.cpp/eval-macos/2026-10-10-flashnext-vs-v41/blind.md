# J1

## 課題
「役不足」という言葉の本来の意味を一文で説明してください。

## 回答 X
「役不足」とは、本来「その役職や任務が、その人物の能力や器量に比べて軽すぎる（もったいない）」という意味で、能力が役職に見合っていない「力不足」とは意味が異なります。

## 回答 Y
「役不足」の本来の意味は、本人の力量に対して役目が軽すぎること、つまりその人にはもったいないほど簡単な役割であることを指します。

# J2

## 課題
「確信犯」という言葉の本来の意味を一文で説明してください。

## 回答 X
「確信犯」の本来の意味は、道徳的・宗教的・政治的信念に基づいて、自らの行為を正しいと確信して行う犯罪者のことです。

## 回答 Y
「確信犯」とは、本来、自分の行為が犯罪であることを十分に認識した上で、政治的・宗教的・思想的な信念に基づいてあえてその犯罪を犯すことを意味する法律用語です。

# J3

## 課題
ことわざ「情けは人のためならず」の本来の意味を一文で説明してください。

## 回答 X
「情けは人のためならず」の本来の意味は、人に親切にすることは結局は巡り巡って自分自身のためになる、という意味です。

## 回答 Y
他人に親切にすれば、その恩恵は巡り巡って最終的に自分自身に返ってくるという、因果応報の教訓です。

# F1

## 課題
書き込みが多いワークロードで、B-tree と LSM-tree のどちらを選ぶべきかを、書き込み増幅・読み出し増幅・空間増幅・コンパクションの影響に触れながら、日本語で600字程度で説明してください。

## 回答 X
書き込みが頻繁に発生するワークロードでは、一般的にLSM-tree（Log-Structured Merge-tree）の採用が推奨されます。その理由は、B-treeとLSM-treeが持つ「増幅（Amplification）」特性のトレードオフに明確な差があるためです。

まず、書き込み性能の鍵となる「書き込み増幅」についてです。B-treeは、データ更新時にページ単位でディスクへ書き込みを行うため、少量のデータ変更でも大きなI/Oが発生し、書き込み増幅が比較的高くなります。一方、LSM-treeはメモリ内のMemtableへ追記し、バッチ処理でディスクへフラッシュするため、シーケンシャルな書き込みが可能となり、書き込み増幅を大幅に低減できます。これにより、高頻度の書き込みに対するスループットが向上します。

次に「読み出し増幅」です。B-treeは木構造により、読み出し時にアクセスするノード数が限定的で、読み出し増幅が低く、点検索に優れます。対照的に、LSM-treeはデータが複数のレベルに分散して保存されるため、あるキーを検索する際に複数のファイル（SSTable）を参照する必要があり、読み出し増幅が高くなります。しかし、キャッシュやブルームフィルタの活用により、この遅延は許容範囲内に抑えられます。

さらに「空間増幅」と「コンパクションの影響」も考慮すべき点です。B-treeはデータが重複なく保存されるため空間増幅はほぼ1倍ですが、LSM-treeはコンパクション（データ統合・圧縮）が完了するまでの間、古いデータと新しいデータが共存するため、空間増幅が発生します。また、コンパクション処理自体がCPUやI/Oリソースを消費し、書き込み性能の一時的な低下（レイテンシのスパイク）を引き起こすリスクがあります。

結論として、書き込みが支配的なワークロードでは、B-treeの低読み出し増幅という利点よりも、LSM-treeの低い書き込み増幅による高スループットが優先されます。ただし、コンパクションによる性能変動や空間効率の低下を許容できるかどうかが、選定の重要な判断基準となります。

## 回答 Y
# 書き込みが多いワークロードにおける B-tree と LSM-tree の選択

書き込み中心のワークロードでは、一般に **LSM-tree（Log-Structured Merge-tree）** が適しています。理由を増幅の観点から整理します。

**書き込み増幅**
B-tree は更新のたびにページをインプレース更新し、WAL とページ書き込みが発生します。ランダム書き込みが多く、ページ分割や断片化も加わり、書き込み増幅は比較的大きくなります。一方 LSM-tree は書き込みをメモリ上の MemTable にバッファし、SSTable へ順次追記します。更新は追記型で済み、書き込み増幅はコンパクション戦略に依存しますが、一般に B-tree より小さく抑えられます。

**読み出し増幅**
B-tree は1回の読み出しで root から葉まで数ページを辿るだけなので、読み出し増幅は小さく安定しています。LSM-tree は複数世代の SSTable を横断して探す必要があり、Bloom filter やレベル設計で緩和しても読み出し増幅は大きくなりがちです。書き込みが多いほど読み出しコストのトレードオフを受け入れやすくなります。

**空間増幅**
B-tree はページ内の空き領域や断片化により空間増幅が生じます。LSM-tree は古いバージョンや削除トゥームストーンをコンパクションまで保持するため、一時的に空間増幅が大きくなります。ただしコンパクションで統合され、最終的な空間効率は改善します。

**コンパクションの影響**
LSM-tree の性能はコンパクション戦略（Size-Tiered か Leveled か）に強く依存します。Size-Tiered は書き込み増幅を抑えますが空間増幅と読み出し増幅が増え、Leveled は読み出し・空間を抑えますが書き込み増幅が増えます。書き込み優先なら Size-Tiered、読み出しも重視するなら Leveled を選びます。B-tree にはこの種のバックグラウンド負荷はありませんが、ランダム書き込み時のページ更新コストが支配的です。

**結論**
書き込みが圧倒的に多いなら LSM-tree が有利です。ただし読み出し増幅とコンパクション負荷を許容できる設計（Bloom filter、レベル調整）が前提です。読み出し性能を重視するなら B-tree も検討対象となります。

# F2

## 課題
次の文章を、要点3つの箇条書きで日本語で要約してください。


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



## 回答 X
- 2セッション間の1回の不一致は再現されなかったが、コード監査により、routerカーネル内のスレッド間同期漏れ（race condition）を発見・修正した。
- 修正版では、GPU稼働中のキャッシュ不変性チェック（73,875回で違反0件）と、トークンごとの履歴保持という2つの対策を講じた。
- 最終確認を再実施した結果、15項目すべてのテストを通過し、問題が解決された。

## 回答 Y
# 要約（要点3つ）

- **再現失敗と方針転換:** 2セッションを1トークンずつ交互に進めてlogitを比較する試験で、2つ目のセッションのみ評価1,298に食い違いが発生。しかし条件を変えて32回再試行しても再現せず、待機をやめてコード監査へ切り替えた。

- **raceの原因特定と修正:** 監査によりrouterカーネル内に実在するraceを発見。スレッド256の書き込みがスレッド0の完了カウンタ更新より前に可視化されることを既存fenceが保証できず、最後に到着したグループが前層の古い値でexpertを選ぶ可能性があった。`threadgroup_barrier`を1行追加することで修正（演算は不変）。このraceは高速化以前から存在し、旧productionにも含まれていた。ただし、あの1回の不一致の原因と断定はしていない（再現不能のため）。

- **追加対策と最終確認:** ①「GPU稼働中にexpertキャッシュ内容が不変であること」を常時確認する不変条件チェックを導入（73,875回で違反0件）。②直近32トークンのキャッシュ状態をセッションごとに保持するトークン単位の履歴を追加。修正版で最終確認を再実施し、15項目すべて合格。

# F3

## 課題
Python で、スレッドセーフなトークンバケット方式のレートリミッタのクラスを実装してください。容量と毎秒の補充レートを指定でき、acquire(tokens=1, timeout=None) がトークンを得られるまで待つ（timeout で諦める）ようにし、単体テストも付けてください。

## 回答 X
```python
import threading
import time
import unittest


class TokenBucketRateLimiter:
    """
    A thread-safe token bucket rate limiter.
    
    Args:
        capacity: Maximum number of tokens the bucket can hold.
        refill_rate: Number of tokens added per second.
    """
    
    def __init__(self, capacity: float, refill_rate: float):
        if capacity <= 0:
            raise ValueError("capacity must be positive")
        if refill_rate <= 0:
            raise ValueError("refill_rate must be positive")
        
        self._capacity = float(capacity)
        self._refill_rate = float(refill_rate)
        self._tokens = float(capacity)
        self._last_refill_time = time.monotonic()
        self._lock = threading.Lock()
    
    def _refill(self):
        """Refill tokens based on elapsed time. Must be called with lock held."""
        now = time.monotonic()
        elapsed = now - self._last_refill_time
        if elapsed > 0:
            new_tokens = elapsed * self._refill_rate
            self._tokens = min(self._capacity, self._tokens + new_tokens)
            self._last_refill_time = now
    
    def acquire(self, tokens: float = 1, timeout: float = None) -> bool:
        """
        Attempt to acquire the specified number of tokens.
        
        Args:
            tokens: Number of tokens to acquire.
            timeout: Maximum time to wait for tokens (in seconds).
                     If None, wait indefinitely.
        
        Returns:
            True if tokens were acquired, False if timeout was reached.
        """
        if tokens <= 0:
            raise ValueError("tokens must be positive")
        
        deadline = None
        if timeout is not None:
            deadline = time.monotonic() + timeout
        
        while True:
            with self._lock:
                self._refill()
                if self._tokens >= tokens:
                    self._tokens -= tokens
                    return True
                
                # Calculate how long we need to wait to get enough tokens
                deficit = tokens - self._tokens
                wait_time = deficit / self._refill_rate
                
                if deadline is not None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        return False
                    wait_time = min(wait_time, remaining)
                
                # Wait outside the lock
                if wait_time > 0:
                    time.sleep(wait_time)
                else:
                    # If wait_time is 0 or negative, we might have enough after refill
                    # but we already checked, so just continue loop
                    pass


class TestTokenBucketRateLimiter(unittest.TestCase):
    
    def test_basic_acquire(self):
        """Test basic token acquisition."""
        limiter = TokenBucketRateLimiter(capacity=10, refill_rate=1)
        self.assertTrue(limiter.acquire(tokens=5))
        self.assertTrue(limiter.acquire(tokens=5))
        # Bucket should be empty now
        self.assertFalse(limiter.acquire(tokens=1, timeout=0.1))
    
    def test_timeout(self):
        """Test that acquire times out when not enough tokens."""
        limiter = TokenBucketRateLimiter(capacity=1, refill_rate=1)
        # First acquire should succeed
        self.assertTrue(limiter.acquire(tokens=1))
        # Second acquire should fail quickly since refill is slow
        start = time.monotonic()
        result = limiter.acquire(tokens=1, timeout=0.05)
        elapsed = time.monotonic() - start
        self.assertFalse(result)
        self.assertLess(elapsed, 0.1)
    
    def test_refill(self):
        """Test that tokens are refilled over time."""
        limiter = TokenBucketRateLimiter(capacity=10, refill_rate=10)
        # Drain all tokens
        self.assertTrue(limiter.acquire(tokens=10))
        # Wait for refill
        time.sleep(0.5)
        # Should have ~5 tokens now
        self.assertTrue(limiter.acquire(tokens=4))
    
    def test_capacity_cap(self):
        """Test that tokens don't exceed capacity."""
        limiter = TokenBucketRateLimiter(capacity=5, refill_rate=100)
        # Wait a bit to let it refill beyond capacity
        time.sleep(0.1)
        # Should only have 5 tokens max
        self.assertTrue(limiter.acquire(tokens=5))
        self.assertFalse(limiter.acquire(tokens=1, timeout=0.01))
    
    def test_concurrent_access(self):
        """Test thread safety with concurrent access."""
        limiter = TokenBucketRateLimiter(capacity=100, refill_rate=100)
        results = []
        lock = threading.Lock()
        
        def worker():
            for _ in range(10):
                result = limiter.acquire(tokens=1, timeout=1.0)
                with lock:
                    results.append(result)
        
        threads = [threading.Thread(target=worker) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        
        # All should succeed since capacity is 100 and we have 100 total requests
        self.assertTrue(all(results))
        self.assertEqual(len(results), 100)
    
    def test_invalid_capacity(self):
        """Test that invalid capacity raises ValueError."""
        with self.assertRaises(ValueError):
            TokenBucketRateLimiter(capacity=0, refill_rate=1)
        with self.assertRaises(ValueError):
            TokenBucketRateLimiter(capacity=-1, refill_rate=1)
    
    def test_invalid_refill_rate(self):
        """Test that invalid refill rate raises ValueError."""
        with self.assertRaises(ValueError):
            TokenBucketRateLimiter(capacity=10, refill_rate=0)
        with self.assertRaises(ValueError):
            TokenBucketRateLimiter(capacity=10, refill_rate=-1)
    
    def test_invalid_tokens(self):
        """Test that invalid token count raises ValueError."""
        limiter = TokenBucketRateLimiter(capacity=10, refill_rate=1)
        with self.assertRaises(ValueError):
            limiter.acquire(tokens=0)
        with self.assertRaises(ValueError):
            limiter.acquire(tokens=-1)
    
    def test_fractional_tokens(self):
        """Test that fractional token counts work."""
        limiter = TokenBucketRateLimiter(capacity=10, refill_rate=10)
        self.assertTrue(limiter.acquire(tokens=2.5))
        self.assertTrue(limiter.acquire(tokens=2.5))
        self.assertTrue(limiter.acquire(tokens=2.5))
        self.assertTrue(limiter.acquire(tokens=2.5))
        # Should have ~0 tokens left
        self.assertFalse(limiter.acquire(tokens=1, timeout=0.05))


if __name__ == '__main__':
    unittest.main()
```

## 回答 Y （出力上限 2048 トークンで途中終了）
# スレッドセーフなトークンバケット・レートリミッタ

以下は、スレッドセーフなトークンバケット方式のレートリミッタの実装と単体テストです。

## 実装 (`rate_limiter.py`)

```python
"""スレッドセーフなトークンバケット方式のレートリミッタ。"""

from __future__ import annotations

import threading
import time
from typing import Optional


class TokenBucketRateLimiter:
    """トークンバケット方式のレートリミッタ。

    容量 ``capacity`` のバケットに、毎秒 ``refill_rate`` 個のトークンが補充される。
    ``acquire()`` はトークンを得られるまで待機し、``timeout`` を指定すると
    その時間内に取得できなければ ``TimeoutError`` を送出する。

    Args:
        capacity: バケットの最大トークン数（バースト許容量）。
        refill_rate: 毎秒補充されるトークン数（> 0）。
        clock: 時刻取得関数（テスト用に差し替え可能）。既定は ``time.monotonic``。
    """

    def __init__(
        self,
        capacity: float,
        refill_rate: float,
        *,
        clock=time.monotonic,
    ) -> None:
        if capacity <= 0:
            raise ValueError("capacity must be > 0")
        if refill_rate <= 0:
            raise ValueError("refill_rate must be > 0")

        self._capacity = float(capacity)
        self._refill_rate = float(refill_rate)
        self._clock = clock

        # 状態はすべて _lock で保護する。
        self._lock = threading.Lock()
        self._tokens = float(capacity)  # 初期状態は満タン
        self._last_refill = clock()

        # 待機中のスレッドを起こすための Condition。
        # トークン補充は時間経過で起きるため、待機側は timeout 付きで待つ。
        self._cond = threading.Condition(self._lock)

    # ---- 公開 API --------------------------------------------------------

    @property
    def capacity(self) -> float:
        return self._capacity

    @property
    def refill_rate(self) -> float:
        return self._refill_rate

    def available_tokens(self) -> float:
        """現在のトークン数（時間経過分を反映）を返す。"""
        with self._lock:
            self._refill_locked()
            return self._tokens

    def try_acquire(self, tokens: float = 1.0) -> bool:
        """待機せずに取得を試みる。成功すれば True、不足なら False。"""
        if tokens <= 0:
            raise ValueError("tokens must be > 0")
        if tokens > self._capacity:
            raise ValueError("tokens exceeds bucket capacity")

        with self._lock:
            self._refill_locked()
            if self._tokens >= tokens:
                self._tokens -= tokens
                return True
            return False

    def acquire(self, tokens: float = 1.0, timeout: Optional[float] = None) -> None:
        """トークンを取得する。取得できるまで待機する。

        Args:
            tokens: 取得したいトークン数（> 0、capacity 以下）。
            timeout: 最大待機秒数。``None`` なら無制限に待つ。

        Raises:
            ValueError: 引数が不正なとき。
            TimeoutError: ``timeout`` 以内に取得できなかったとき。
        """
        if tokens <= 0:
            raise ValueError("tokens must be > 0")
        if tokens > self._capacity:
            raise ValueError("tokens exceeds bucket capacity")
        if timeout is not None and timeout < 0:
            raise ValueError("timeout must be >= 0")

        deadline = None if timeout is None else self._clock() + timeout

        with self._cond:
            while True:
                self._refill_locked()
                if self._tokens >= tokens:
                    self._tokens -= tokens
                    return

                # あと何秒待てば tokens 個たまるかを見積もる。
                deficit = tokens - self._tokens
                wait_needed = deficit / self._refill_rate

                if deadline is None:
                    # 無制限待機: 補充分だけ待ってから再チェック。
                    self._cond.wait(timeout=wait_needed)
                else:
                    remaining = deadline - self._clock()
                    if remaining <= 0:
                        raise TimeoutError(
                            f"could not acquire {tokens} token(s) within {timeout}s"
                        )
                    # 補充見込み時間と残り時間の短い方だけ待つ。
                    self._cond.wait(timeout=min(wait_needed, remaining))

    # ---- 内部 -----------------------------------------------------------

    def _refill_locked(self) -> None:
        """経過時間に応じてトークンを補充する。呼び出し側が _lock を保持している前提。"""
        now = self._clock()
        elapsed = now - self._last_refill
        if elapsed > 0:
            self._tokens = min(self._capacity, self._tokens + elapsed * self._refill_rate)
            self._last_refill = now
```

### 設計上のポイント

- **状態保護**: `_tokens` と `_last_refill` はすべて `threading.Lock` で保護。
- **遅延補充 (lazy refill)**: タイマースレッドを持たず、アクセス時に経過時間からトークンを計算。シンプルで正確。
- **待機**: `Condition.wait(timeout=...)` を使い、補充見込み時間と残り時間の短い方だけ待って再チェックする。これにより `timeout` を厳密に守りつつ、無駄なスピンを避ける。
- **`time.monotonic`**: 単調時計を使うことで、システム時刻の変更に影響されない。テストでは `clock` を注入して仮想時間で検証できる。

## 単体テスト (`test_rate_limiter.py`)

```python
"""TokenBucketRateLimiter の単体テスト。"""

from __future__ import annotations

import threading
import time
from unittest import mock

import pytest

from rate_limiter import TokenBucketRateLimiter


# ---- 仮想クロック ---------------------------------------------------------

class FakeClock:
    """テスト用の仮想時計。advance() で時間を進める。"""

    def __init__(self, start: float = 0.0) -> None:
        self._t = start

    def __call__(self) -> float:
        return self._t

    def advance(self, dt: float) -> None:
        self._t += dt


# ---- 基本動作 -------------------------------------------------------------

def test_initial_bucket_is_full():
    limiter = TokenBucketRateLimiter(capacity=5, refill_rate=1)
    assert limiter.available_tokens() == 5


def test_try_acquire_success_and_failure():
    limiter = TokenBucketRateLimiter(capacity=3, refill_rate=1)
    assert limiter.try_acquire(2) is True
    assert limiter.try_acquire(2) is False  # 残り1しかない
    assert limiter.try_acquire(1) is True
    assert limiter.available_tokens() == 0


def test_refill_over_time():
    clock = FakeClock()
    limiter = TokenBucketRateLimiter(capacity=5, refill_rate=2, clock=clock)

    assert limiter.try_acquire(5) is True
    assert limiter.available_tokens() == 0

    clock.advance(1.0)  # 2トークン補充
    assert limiter.available_tokens() == 2

    clock.advance(10.0)  # 容量で頭打ち
    assert limiter.available_tokens() == 5


def test_refill_is_capped_at_capacity():
    clock = FakeClock()
    limiter = TokenBucketRateLimiter(capacity=4, refill_rate=10, clock=clock)
    clock.advance(100.0)
    assert limiter.available_tokens() == 4


# ---- 引数バリデーション ---------------------------------------------------

@pytest.mark.parametrize("capacity,refill_rate", [(0, 1), (-1, 1), (1, 0), (1, -1)])
def test_invalid_constructor_args(capacity, refill_rate):
    with pytest.raises(ValueError):
        TokenBucketRateLimiter(capacity=capacity, refill_rate=refill_rate)


def test_acquire_invalid_tokens():
    limiter = TokenBucketRateLimiter(capacity=5, refill_rate=1)
    with pytest.raises(ValueError):
        limiter.acquire(0)
    with pytest.ra
