#!/usr/bin/env python3
"""Expert-cache capacity curves from a recorded route, with the real prewarm.

    cachecurve.py ROUTE HOTLIST_INC [--steady FROM]

ROUTE is the binary log DS4_METAL_V41_GATE_ROUTE_LOG writes (records of eight
int32: layer, count, six expert ids; one record a gated layer a token).
HOTLIST_INC is ds4_streaming_hotlist_v41.inc: the cache starts holding its
first CAP entries, as the server's prewarm does.

For every capacity it reports misses, aborting layers (a layer with any miss
is one abort and one repair) and bytes read a token, over the whole route and
over the steady part from token FROM, for three policies:

  current   one pool, victim = least (hotness, last use), hotness seeded from
            the hotlist and halved every 16 tokens, the layer's own selection
            protected - the server's rule
  lru       one pool, least recently used
  layer     each layer its own LRU of CAP/40 (or the per-layer sizes asked for)

An abort costs about 1.53 ms of wall (the traced mean: detect 0.11, readahead
and slot preparation 0.56, reads 0.60, restart 0.26), so the last column is
aborts x 1.53 - an estimate of repair wall, not a measurement.
"""
import argparse
import array
import collections
import re

EXPERT_MIB = 9.49
ABORT_MS = 1.53
DECAY_TOKENS = 16
N_SEL = 6


def load_route(path):
    a = array.array("i")
    a.frombytes(open(path, "rb").read())
    toks, cur, last = [], [], -1
    for r in range(len(a) // 8):
        layer, n = a[8 * r], a[8 * r + 1]
        if layer <= last and cur:
            toks.append(cur)
            cur = []
        cur.append((layer, tuple(a[8 * r + 2 + k] for k in range(min(n, 6)))))
        last = layer
    if cur:
        toks.append(cur)
    return toks


def load_hotlist(path):
    text = open(path).read()
    tokens = int(re.search(r"STREAMING_HOTLIST_TOKENS (\d+)u", text).group(1))
    return [(int(l), int(e), int(h)) for l, e, h in
            re.findall(r"\{(\d+), (\d+), (\d+)\}", text)], tokens


class Tally:
    def __init__(self):
        self.miss = self.abort = self.tok = 0

    def add(self, misses):
        self.tok += 1
        self.miss += sum(misses)
        self.abort += sum(1 for m in misses if m)

    def cols(self):
        t = max(self.tok, 1)
        return (self.miss / t, self.abort / t, self.miss / t * EXPERT_MIB,
                self.abort / t * ABORT_MS)


def simulate(toks, hot, hot_tokens, cap, policy, steady_from, layer_caps=None):
    whole, steady = Tally(), Tally()
    if policy == "layer":
        per = collections.defaultdict(collections.OrderedDict)
        for l, e, _ in hot:
            c = per[l]
            if len(c) < layer_caps[l]:
                c[(l, e)] = 0
        # hottest last in the order = most recently used
        for l in per:
            per[l] = collections.OrderedDict(reversed(list(per[l].items())))
        for i, tok in enumerate(toks):
            mb = []
            for layer, ids in tok:
                c, m = per[layer], 0
                for e in ids:
                    k = (layer, e)
                    if k in c:
                        c.move_to_end(k)
                    else:
                        m += 1
                        c[k] = 0
                        if len(c) > layer_caps[layer]:
                            c.popitem(last=False)
                mb.append(m)
            whole.add(mb)
            if i >= steady_from:
                steady.add(mb)
        return whole, steady

    lru = collections.OrderedDict()
    hotness = {}
    for l, e, h in reversed(hot[:cap]):          # coldest first, hottest most recent
        lru[(l, e)] = 0
        if policy == "current":
            s = int(32.0 * h / hot_tokens + 0.5)
            hotness[(l, e)] = s if s else 1
    for i, tok in enumerate(toks):
        if policy == "current" and i and i % DECAY_TOKENS == 0:
            for k in list(hotness):
                hotness[k] >>= 1
                if not hotness[k]:
                    del hotness[k]
        mb = []
        for layer, ids in tok:
            if policy == "current":
                for e in ids:
                    hotness[(layer, e)] = hotness.get((layer, e), 0) + 1
            m = 0
            protect = {(layer, x) for x in ids}
            for e in ids:
                k = (layer, e)
                if k in lru:
                    lru.move_to_end(k)
                    continue
                m += 1
                if len(lru) >= cap:
                    if policy == "lru":
                        lru.popitem(last=False)
                    else:
                        # least hotness, then least recent: scan the LRU end
                        # first so ties break the server's way
                        best, bk = None, None
                        for rank, c in enumerate(lru):
                            if c in protect:
                                continue
                            key = (hotness.get(c, 0), rank)
                            if best is None or key < best:
                                best, bk = key, c
                                if key[0] == 0:
                                    break
                        del lru[bk]
                lru[k] = 0
            mb.append(m)
        whole.add(mb)
        if i >= steady_from:
            steady.add(mb)
    return whole, steady


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("route")
    ap.add_argument("hotlist")
    ap.add_argument("--steady", type=int, default=1024)
    a = ap.parse_args()
    toks = load_route(a.route)
    hot, hot_tokens = load_hotlist(a.hotlist)
    n_layer = 1 + max(l for tok in toks for l, _ in tok)
    print(f"{len(toks)} tokens, {n_layer} gated layers; hotlist {len(hot)} entries; "
          f"steady from token {a.steady}")
    print(f"{'policy':<8} {'cap':>6} {'GiB':>6} | whole: {'miss/t':>7} {'abort/t':>7} "
          f"{'MiB/t':>7} {'~ms/t':>6} | steady: {'miss/t':>7} {'abort/t':>7} {'MiB/t':>7} "
          f"{'~ms/t':>6}")
    rows = []
    for per_layer in (6, 8, 12, 16, 24, 32, 64, 128, 192, 256, 384):
        caps = [per_layer] * n_layer
        rows.append(("layer", per_layer * n_layer, caps))
    for cap in (7930, 8698, 9500, 10500, 12000, n_layer * 384):
        rows.append(("current", cap, None))
        rows.append(("lru", cap, None))
    for pol, cap, caps in rows:
        w, s = simulate(toks, hot, hot_tokens, cap, pol, a.steady, caps)
        wc, sc = w.cols(), s.cols()
        print(f"{pol:<8} {cap:>6} {cap * EXPERT_MIB / 1024:6.1f} | whole: {wc[0]:7.2f} "
              f"{wc[1]:7.2f} {wc[2]:7.1f} {wc[3]:6.2f} | steady: {sc[0]:7.2f} {sc[1]:7.2f} "
              f"{sc[2]:7.1f} {sc[3]:6.2f}", flush=True)


if __name__ == "__main__":
    main()
