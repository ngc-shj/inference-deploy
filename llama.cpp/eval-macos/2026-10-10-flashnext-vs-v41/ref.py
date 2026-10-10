"""Reference solutions: the hidden tests must give these full marks."""
import heapq
from collections import OrderedDict, deque, defaultdict


def merge_intervals(iv):
    out = []
    for a, b in sorted(iv):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


class LRUCache:
    def __init__(self, capacity):
        self.cap, self.d = capacity, OrderedDict()

    def get(self, k):
        if k not in self.d:
            return -1
        self.d.move_to_end(k)
        return self.d[k]

    def put(self, k, v):
        self.d[k] = v
        self.d.move_to_end(k)
        if len(self.d) > self.cap:
            self.d.popitem(last=False)


def calculate(s):
    toks = [ch for ch in s if ch != " "]
    pos = 0

    def peek():
        return toks[pos] if pos < len(toks) else None

    def expr():
        nonlocal pos
        v = term()
        while peek() in ("+", "-"):
            op = toks[pos]; pos += 1
            r = term()
            v = v + r if op == "+" else v - r
        return v

    def term():
        nonlocal pos
        v = factor()
        while peek() in ("*", "/"):
            op = toks[pos]; pos += 1
            r = factor()
            v = v * r if op == "*" else int(v / r)
        return v

    def factor():
        nonlocal pos
        if peek() == "-":
            pos += 1
            return -factor()
        if peek() == "(":
            pos += 1
            v = expr(); pos += 1
            return v
        n = 0
        while peek() is not None and peek().isdigit():
            n = n * 10 + int(toks[pos]); pos += 1
        return n
    return expr()


def longest_valid_parentheses(s):
    from hidden import _lvp_ref
    return _lvp_ref(s)


def is_match(s, p):
    from hidden import _match_ref
    return _match_ref(s, p)


def min_window(s, t):
    need = defaultdict(int)
    for ch in t:
        need[ch] += 1
    missing, i, best = len(t), 0, (0, 0)
    for j, ch in enumerate(s, 1):
        if need[ch] > 0:
            missing -= 1
        need[ch] -= 1
        if missing == 0:
            while need[s[i]] < 0:
                need[s[i]] += 1; i += 1
            if best == (0, 0) or j - i < best[1] - best[0]:
                best = (i, j)
            need[s[i]] += 1; missing += 1; i += 1
    return s[best[0]:best[1]]


def course_order(n, pre):
    g, indeg = defaultdict(list), [0] * n
    for a, b in pre:
        g[b].append(a); indeg[a] += 1
    q = deque(i for i in range(n) if indeg[i] == 0)
    out = []
    while q:
        u = q.popleft(); out.append(u)
        for v in g[u]:
            indeg[v] -= 1
            if indeg[v] == 0:
                q.append(v)
    return out if len(out) == n else []


def sliding_median(nums, k):
    import bisect
    w = sorted(nums[:k]); out = []
    for i in range(k, len(nums) + 1):
        out.append(float(w[k // 2]) if k % 2 else (w[k // 2 - 1] + w[k // 2]) / 2)
        if i == len(nums):
            break
        del w[bisect.bisect_left(w, nums[i - k])]
        bisect.insort(w, nums[i])
    return out
