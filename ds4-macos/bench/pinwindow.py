#!/usr/bin/env python3
"""Bound a pinned-expert window before changing the production engine.

The pinned directory and the ordinary expert cache share one capacity.  A pin
therefore has two effects: accesses to that expert can no longer miss, but one
fewer entry is available to the evictable cache.  This replays both effects.

The production hotlist is causal: it was generated from other prompts before
this route ran.  The two oracle orders use the route being scored and are only
ceilings; they must never be used as a production selector.

Usage:
    pinwindow.py ROUTE HOTLIST_INC [--capacity 6504] [--steady 1024]
"""

import argparse
import array
import collections
import heapq
import re


N_LAYER = 40
N_EXPERT = 384
N_SELECTED = 6
DECAY_TOKENS = 16
EXPERT_MIB = 9.49


def load_route(path):
    raw = array.array("i")
    with open(path, "rb") as f:
        raw.frombytes(f.read())
    tokens, token, previous_layer = [], [], -1
    for off in range(0, len(raw) - 7, 8):
        layer, count = raw[off], raw[off + 1]
        if layer <= previous_layer and token:
            tokens.append(token)
            token = []
        ids = tuple(raw[off + 2 + i] for i in range(min(count, N_SELECTED)))
        token.append((layer, ids))
        previous_layer = layer
    if token:
        tokens.append(token)
    return tokens


def load_hotlist(path):
    text = open(path, encoding="utf-8").read()
    match = re.search(r"STREAMING_HOTLIST_TOKENS (\d+)u", text)
    if not match:
        raise ValueError(f"no hotlist token count in {path}")
    tokens = int(match.group(1))
    rows = [(int(layer), int(expert), int(hits)) for layer, expert, hits in
            re.findall(r"\{(\d+), (\d+), (\d+)\}", text)]
    return rows, tokens


class Result:
    def __init__(self):
        self.tokens = 0
        self.misses = 0
        self.aborts = 0
        self.pinned_hits = 0
        self.cache_hits = 0
        self.loads = 0
        self.miss_by_key = collections.Counter()

    def add(self, misses, pinned_hits, cache_hits, missed_keys):
        self.tokens += 1
        self.misses += sum(misses)
        self.aborts += sum(bool(value) for value in misses)
        self.pinned_hits += pinned_hits
        self.cache_hits += cache_hits
        self.loads += sum(misses)
        self.miss_by_key.update(missed_keys)

    def rates(self):
        n = max(self.tokens, 1)
        return self.misses / n, self.aborts / n, self.pinned_hits / n


def unique_order(keys):
    seen = set()
    out = []
    for key in keys:
        if key not in seen:
            seen.add(key)
            out.append(key)
    return out


def initial_cache(hotlist, pinned, dynamic_capacity):
    """The real prewarm walks the frequency-sorted list and skips pins."""
    cache = {}
    hotness = {}
    clock = 0
    for layer, expert, hits in hotlist:
        key = (layer, expert)
        score = max(1, int(32.0 * hits / hotlist.tokens + 0.5))
        hotness[key] = score
        if key in pinned or key in cache:
            continue
        if len(cache) >= dynamic_capacity:
            break
        clock += 1
        cache[key] = clock
    return cache, hotness, clock


class Hotlist(list):
    pass


def simulate(tokens, hot_rows, hot_tokens, capacity, pinned, steady_from):
    dynamic_capacity = capacity - len(pinned)
    if dynamic_capacity < 0:
        raise ValueError("pinned set exceeds cache capacity")
    hotlist = Hotlist(hot_rows)
    hotlist.tokens = hot_tokens
    cache, hotness, clock = initial_cache(hotlist, pinned, dynamic_capacity)
    versions = collections.defaultdict(int)
    heap = []

    def push(key):
        versions[key] += 1
        heapq.heappush(heap, (hotness.get(key, 0), cache[key], versions[key], key))

    def rebuild_heap():
        heap.clear()
        for key in cache:
            push(key)

    def victims(count, protect):
        chosen = []
        protected = []
        while len(chosen) < count and heap:
            h, last, version, key = heapq.heappop(heap)
            if key not in cache or version != versions[key]:
                continue
            if h != hotness.get(key, 0) or last != cache[key]:
                continue
            if key in protect:
                protected.append((h, last, version, key))
                continue
            chosen.append(key)
        for row in protected:
            heapq.heappush(heap, row)
        return chosen

    rebuild_heap()
    whole, steady = Result(), Result()

    for token_index, token in enumerate(tokens):
        if token_index and token_index % DECAY_TOKENS == 0:
            for key in list(hotness):
                hotness[key] >>= 1
                if not hotness[key]:
                    del hotness[key]
            rebuild_heap()

        token_misses = []
        token_pinned_hits = 0
        token_cache_hits = 0
        token_missed_keys = []
        for layer, ids in token:
            keys = unique_order((layer, expert) for expert in ids)
            for key in keys:
                hotness[key] = hotness.get(key, 0) + 1
                if key in cache:
                    push(key)

            missing = []
            for key in keys:
                if key in pinned:
                    token_pinned_hits += 1
                elif key in cache:
                    token_cache_hits += 1
                    clock += 1
                    cache[key] = clock
                    push(key)
                else:
                    missing.append(key)

            # Production chooses all victims for one selected row together:
            # lowest hotness, then oldest, while protecting this row.
            protect = set(keys)
            needed = min(len(missing), dynamic_capacity)
            for victim in victims(max(0, len(cache) + needed - dynamic_capacity), protect):
                del cache[victim]
            for key in missing:
                if dynamic_capacity == 0:
                    continue
                # A six-way selection fits by construction once its victims
                # have been chosen.  Keep this fail-closed for malformed input.
                if len(cache) >= dynamic_capacity:
                    extra = victims(1, protect)
                    if not extra:
                        continue
                    del cache[extra[0]]
                clock += 1
                cache[key] = clock
                push(key)

            token_misses.append(len(missing))
            token_missed_keys.extend(missing)

        whole.add(token_misses, token_pinned_hits, token_cache_hits,
                  token_missed_keys)
        if token_index >= steady_from:
            steady.add(token_misses, token_pinned_hits, token_cache_hits,
                       token_missed_keys)
    return whole, steady


def route_frequency_order(tokens):
    counts = collections.Counter(key for token in tokens for layer, ids in token
                                 for key in ((layer, expert) for expert in ids))
    return [key for key, _ in counts.most_common()]


def id_layer_order():
    return [(layer, expert) for layer in range(N_LAYER)
            for expert in range(N_EXPERT)]


def fmt(result):
    miss, abort, pin = result.rates()
    return f"{miss:7.2f} {abort:7.2f} {pin:7.2f}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("route")
    parser.add_argument("hotlist")
    parser.add_argument("--capacity", type=int, default=6504)
    parser.add_argument("--steady", type=int, default=1024)
    parser.add_argument("--pins", default="0,64,128,256,384,512,768,1024,1536,2048,3072,4096,5502")
    args = parser.parse_args()

    tokens = load_route(args.route)
    hot_rows, hot_tokens = load_hotlist(args.hotlist)
    causal_order = unique_order((layer, expert) for layer, expert, _ in hot_rows)
    frequency_order = route_frequency_order(tokens)

    baseline_whole, baseline_steady = simulate(
        tokens, hot_rows, hot_tokens, args.capacity, set(), args.steady)
    miss_order = [key for key, _ in baseline_whole.miss_by_key.most_common()]
    orders = {
        "id-layer": id_layer_order(),
        "hotlist": causal_order,
        "oracle-freq": frequency_order,
        "oracle-miss": miss_order,
    }

    print(f"{len(tokens)} tokens; capacity {args.capacity}; steady from {args.steady}")
    print("hotlist is causal/held-out; oracle-* sees the scored route and is a ceiling")
    print(f"{'selector':<12} {'pins':>5} {'dynamic':>7} | whole: {'miss/t':>7} {'abort/t':>7} {'pin/t':>7} | "
          f"steady: {'miss/t':>7} {'abort/t':>7} {'pin/t':>7} | d_abort")
    print(f"{'baseline':<12} {0:5d} {args.capacity:7d} | {fmt(baseline_whole)} | "
          f"{fmt(baseline_steady)} | {0.0:+7.2f}")

    pin_counts = unique_order(int(value) for value in args.pins.split(",") if value)
    for name, order in orders.items():
        for pin_count in pin_counts:
            if pin_count == 0 or pin_count > args.capacity or pin_count > len(order):
                continue
            pinned = set(order[:pin_count])
            whole, steady = simulate(tokens, hot_rows, hot_tokens,
                                     args.capacity, pinned, args.steady)
            delta_abort = steady.rates()[1] - baseline_steady.rates()[1]
            print(f"{name:<12} {pin_count:5d} {args.capacity-pin_count:7d} | {fmt(whole)} | "
                  f"{fmt(steady)} | {delta_abort:+7.2f}", flush=True)


if __name__ == "__main__":
    main()
