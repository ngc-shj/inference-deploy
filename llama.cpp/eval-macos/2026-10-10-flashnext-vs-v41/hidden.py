"""Hidden tests for the coding tasks. Each returns (passed, total).

Run against the candidate module `cand` (imported from the extracted code).
"""
import random, statistics


def _cases(cand, cases):
    ok = 0
    for f in cases:
        try:
            if f(cand):
                ok += 1
        except Exception:
            pass
    return ok, len(cases)


def t_merge_intervals(c):
    m = c.merge_intervals
    return _cases(c, [
        lambda c: m([[1, 3], [2, 6], [8, 10], [15, 18]]) == [[1, 6], [8, 10], [15, 18]],
        lambda c: m([[1, 4], [4, 5]]) == [[1, 5]],
        lambda c: m([]) == [],
        lambda c: m([[5, 7], [1, 2], [2, 3]]) == [[1, 3], [5, 7]],
        lambda c: m([[1, 10], [2, 3], [4, 5]]) == [[1, 10]],
        lambda c: m([[3, 3]]) == [[3, 3]],
    ])


def t_LRUCache(c):
    def seq1(c):
        x = c.LRUCache(2); x.put(1, 1); x.put(2, 2)
        r = [x.get(1)]; x.put(3, 3); r.append(x.get(2)); x.put(4, 4)
        r += [x.get(1), x.get(3), x.get(4)]
        return r == [1, -1, -1, 3, 4]

    def update(c):
        x = c.LRUCache(2); x.put(1, 1); x.put(2, 2); x.put(1, 10); x.put(3, 3)
        return x.get(1) == 10 and x.get(2) == -1

    def cap1(c):
        x = c.LRUCache(1); x.put(1, 1); x.put(2, 2)
        return x.get(1) == -1 and x.get(2) == 2

    def big(c):
        x = c.LRUCache(1000)
        for i in range(200000):
            x.put(i, i)
        return x.get(199999) == 199999 and x.get(198999) == -1 and x.get(199000) == 199000
    return _cases(c, [seq1, update, cap1, big])


def t_calculate(c):
    f = c.calculate
    return _cases(c, [
        lambda c: f("1 + 1") == 2,
        lambda c: f("2*(5+5*2)/3+(6/2+8)") == 21,
        lambda c: f("-(2+3)") == -5,
        lambda c: f("2*-3") == -6,
        lambda c: f("7/-2") == -3,
        lambda c: f("(1+(4+5+2)-3)+(6+8)") == 23,
        lambda c: f(" 14 - 3 / 2 ") == 13,
        lambda c: f("-7/2") == -3,
        lambda c: f("1-(-2)") == 3,
    ])


def _lvp_ref(s):
    best, st = 0, [-1]
    for i, ch in enumerate(s):
        if ch == "(":
            st.append(i)
        else:
            st.pop()
            if not st:
                st.append(i)
            else:
                best = max(best, i - st[-1])
    return best


def t_longest_valid_parentheses(c):
    f = c.longest_valid_parentheses
    rnd = random.Random(1)
    rand = ["".join(rnd.choice("()") for _ in range(rnd.randint(0, 40))) for _ in range(200)]
    return _cases(c, [
        lambda c: f("(()") == 2,
        lambda c: f(")()())") == 4,
        lambda c: f("") == 0,
        lambda c: f("()(())") == 6,
        lambda c: f("()(()") == 2,
        lambda c: all(f(s) == _lvp_ref(s) for s in rand),
    ])


def _match_ref(s, p):
    from functools import lru_cache

    @lru_cache(None)
    def dp(i, j):
        if j == len(p):
            return i == len(s)
        first = i < len(s) and p[j] in (s[i], ".")
        if j + 1 < len(p) and p[j + 1] == "*":
            return dp(i, j + 2) or (first and dp(i + 1, j))
        return first and dp(i + 1, j + 1)
    return dp(0, 0)


def t_is_match(c):
    f = c.is_match
    rnd = random.Random(2)
    pairs = []
    for _ in range(300):
        s = "".join(rnd.choice("ab") for _ in range(rnd.randint(0, 8)))
        p = ""
        for _ in range(rnd.randint(0, 5)):
            p += rnd.choice("ab.")
            if rnd.random() < 0.4:
                p += "*"
        pairs.append((s, p))
    return _cases(c, [
        lambda c: f("aa", "a") is False,
        lambda c: f("aa", "a*") is True,
        lambda c: f("ab", ".*") is True,
        lambda c: f("aab", "c*a*b") is True,
        lambda c: f("mississippi", "mis*is*p*.") is False,
        lambda c: f("", "a*b*") is True,
        lambda c: all(f(s, p) == _match_ref(s, p) for s, p in pairs),
    ])


def _mw_ref(s, t):
    best = None
    for i in range(len(s)):
        for j in range(i + 1, len(s) + 1):
            sub = s[i:j]
            if all(sub.count(ch) >= t.count(ch) for ch in set(t)):
                if best is None or len(sub) < len(best):
                    best = sub
                break
    return best or ""


def t_min_window(c):
    f = c.min_window
    rnd = random.Random(3)
    pairs = [("".join(rnd.choice("abc") for _ in range(rnd.randint(0, 15))),
              "".join(rnd.choice("abc") for _ in range(rnd.randint(1, 3)))) for _ in range(200)]
    return _cases(c, [
        lambda c: f("ADOBECODEBANC", "ABC") == "BANC",
        lambda c: f("a", "a") == "a",
        lambda c: f("a", "aa") == "",
        lambda c: f("aa", "aa") == "aa",
        lambda c: f("abcab", "ab") == "ab",
        lambda c: all(f(s, t) == _mw_ref(s, t) for s, t in pairs),
    ])


def _valid_order(n, pre, order):
    if sorted(order) != list(range(n)):
        return False
    pos = {v: i for i, v in enumerate(order)}
    return all(pos[b] < pos[a] for a, b in pre)


def t_course_order(c):
    f = c.course_order
    big_n = 20000
    big = [[i + 1, i] for i in range(big_n - 1)]
    return _cases(c, [
        lambda c: _valid_order(2, [[1, 0]], f(2, [[1, 0]])),
        lambda c: _valid_order(4, [[1, 0], [2, 0], [3, 1], [3, 2]], f(4, [[1, 0], [2, 0], [3, 1], [3, 2]])),
        lambda c: f(2, [[1, 0], [0, 1]]) == [],
        lambda c: sorted(f(3, [])) == [0, 1, 2],
        lambda c: f(3, [[0, 0]]) == [],
        lambda c: _valid_order(big_n, big, f(big_n, big)),
    ])


def _med_ref(nums, k):
    return [float(statistics.median(nums[i:i + k])) for i in range(len(nums) - k + 1)]


def t_sliding_median(c):
    f = c.sliding_median
    rnd = random.Random(4)
    small = [([rnd.randint(-50, 50) for _ in range(rnd.randint(1, 30))], None) for _ in range(100)]
    small = [(a, rnd.randint(1, len(a))) for a, _ in small]
    big = [rnd.randint(-10**9, 10**9) for _ in range(100000)]

    def close(a, b):
        return len(a) == len(b) and all(abs(x - y) < 1e-6 for x, y in zip(a, b))

    def perf(c):
        import time
        t0 = time.time()
        r = f(big, 1000)
        return time.time() - t0 < 10 and close(r[:50], _med_ref(big[:1049], 1000)) and len(r) == 99001
    return _cases(c, [
        lambda c: close(f([1, 3, -1, -3, 5, 3, 6, 7], 3), [1.0, -1.0, -1.0, 3.0, 5.0, 6.0]),
        lambda c: close(f([1, 2, 3, 4, 2, 3, 1, 4, 2], 4), [2.5, 2.5, 3.0, 2.5, 2.5, 2.5]),
        lambda c: close(f([2147483647, 2147483647], 2), [2147483647.0]),
        lambda c: all(close(f(a, k), _med_ref(a, k)) for a, k in small),
        perf,
    ])
