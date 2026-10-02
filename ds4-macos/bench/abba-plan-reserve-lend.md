# Physical prefill-reserve lending: fixed ABBA plan

## Question

Does lending the prefill *device-memory reserve* to decode, in addition to the
existing logical expert-entry headroom, reduce sustained production wall time?

This compares two paths in the same binary:

- A: `DS4_METAL_V41_DECODE_LEND_HEADROOM=1` — existing logical lending; the
  physical prefill reserve remains charged during decode.
- B: `DS4_METAL_V41_DECODE_LEND_HEADROOM=2` — logical lending plus setting the
  physical reserve to zero during decode, restored before every prefill.

Both request 10,268 cache entries and use the same Metal 4 production path.

## Evidence before the timed run

- A stops physical cache growth at 6,504 entries because 7.12 GiB remains
  reserved for a future prefill.
- B reached 7,207 entries in the lifecycle path and 7,041 entries in the
  ordinary server path, with zero refused allocations.
- The guarded server check of B had peak wired 78.47 GiB, pressure level 1,
  zero swap growth, and its output hash matched the existing oracle.
- Offline replay of the production route gives steady abort/token 9.69 at
  6,504 entries and 7.84 at 7,041 entries. At the measured historical cost of
  about 0.96 ms per avoided abort, the optimistic E2E recovery is about
  1.8 ms/token, above the 1 ms implementation threshold.

## Timed design fixed before execution

- Same `ds4-server` binary for A and B.
- Two `a b b a` blocks: eight 2,048-token production generations.
- 480 seconds idle before every arm; no result-dependent reruns.
- The first attempt stopped before any GPU work because the quiet gate's
  `loadlog.sh` input was not running. The run therefore uses `NOGATE=1`, while
  retaining the fixed 480-second idle and recording CPU ticks, thermal state,
  and GPU load for every arm.
- Metric: whole-generation wall time / generated token, not a selected window.
- Record output hash, token-ID hash, effective live cache entries, cache-growth
  stops, abort/miss counters, pressure, wired memory, swap growth, CPU ticks,
  and GPU sampler output for every arm.

## Validity and acceptance fixed before execution

An arm is invalid if output/token IDs differ from the oracle, Metal 3 work or
GPU feedback errors occur, pressure exceeds normal, swap grows, the requested
path is not observed, or unrelated CPU/GPU load breaches the harness's existing
quiet-run criteria. Exclusions must be made from these criteria, not from the
measured speed.

B is adopted only if:

1. all valid B arms are byte/token identical to A and the oracle;
2. B observes physical growth beyond A (expected about 7,041 versus 6,504),
   with the reserve restored before each later prefill and lifecycle release at
   close;
3. both paired order summaries favor B; and
4. the mean sustained improvement is at least 1.0 ms/token and exceeds the
   same-configuration variation.

Otherwise the change is closed and the code is reverted.
