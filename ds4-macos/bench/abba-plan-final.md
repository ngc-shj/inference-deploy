# Sustained wall-time ABBA: 0e4eac7 against the final Metal 4-native candidate

Fixed before any arm runs. A change to this file after the first arm makes the
run exploratory, not a result. It replaces abba-plan-window.md: window mode
was removed from V4.1 (e56ab96), so that plan has nothing left to measure.

## Precondition

The candidate's outputs equal the clean frozen baseline's on every path
(capacity comparison, in-process 2048, m4paths, budget), on the revision
measured here. Without that, no arm runs.

## Builds and capacity

- b: the candidate as committed when the run starts (cbad991 or later, the
  revision every correctness run before it used; revision, dirty count and
  binary hash recorded per arm), `--ssd-streaming-cache-experts 10268`, the
  production request, no extra environment.
- a: 0e4eac7 (ds4-v41-m4base), at the decode cache size b measurably runs at.
  a has no memory budget, so it is never run at 10268.

## Capacity sentinel

One arm of b alone (sustained.sh TOKENS=2048 under gpurun.sh) before the
ABBA, not part of the result. N is the last "N of M entries live" in its log;
a runs at `--ssd-streaming-cache-experts N`. If N is above 7041 (a's sentinel
at 7041 peaked at 79.36 GiB wired), a first gets its own sentinel at N, and if
that is stopped by gpurun.sh both arms are compared at the largest size a
sentinel of a completes at, with b's server argument set to it, and the
result says so.

## Procedure

- m4abba.sh, BIN_A / BIN_B as above, EXTRA_A / EXTRA_B the cache sizes,
  MTL4_A=1 MTL4_B=1, 2 blocks of a-b-b-a (8 arms), NOGATE=1, COOL=300, each
  arm sustained.sh TOKENS=2048 (greedy, temperature 0).
- The whole run under gpurun.sh. Nothing else is built or run on the machine
  while it runs, and no other GPU client (vllm-mlx included) is up.
- Recorded per arm by m4abba.sh: provenance, other processes' CPU ticks,
  vm_stat before and after (page-ins), thermal reading, the gap since the
  previous arm, the server's per-token split and cache counters; gpurun.sh
  samples pressure, wired and swap.

## Metric

Wall time per generated token over the whole 2048-token generation, as
sustained.sh reports it. Not a best window.

## When an arm is invalid

- its response did not generate 2048 tokens, or its text differs from the
  first a arm's (every arm must produce the same output: the same request,
  greedy, and a cache that does not change the model's arithmetic); or
- other processes' user CPU ticks during the arm exceed 1.5 times the median
  of the eight arms; or
- gpurun's samples during the arm show a pressure level above 1 or swap growth
  above 0.5 GiB; or
- the arm fails or is stopped; or
- a b arm's last "entries live" N differs from the sentinel's.

An invalid arm is not dropped: the block containing it is run again once after
the eight arms. If the rerun is also invalid the comparison is reported as
inconclusive. An arm whose text differs is not a timing problem: the run stops
and the difference is investigated before any number is reported.

## Decision

d = mean(b) - mean(a) over the valid arms, and separately d1 and d2 for the
two blocks (each block is one a-b-b-a, so each has both orders). A regression
is d > max(0.3 ms, 2 x s), where s is the larger of the two arms' standard
deviations. An improvement is claimed only if d < -max(0.3 ms, 2 x s) and d1
and d2 are both negative; anything else is "no regression", with d, d1, d2
and s reported.
