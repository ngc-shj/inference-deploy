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

## Sentinel result, before any arm (2026-10-04)

sentF: b = cbad991 (dirty 0) at the production request, 2048 tokens, finish
"length", pressure level 1, peak wired 78.69 GiB. Decode cache "7041 of 7041
entries live", so N = 7041 and a runs at `--ssd-streaming-cache-experts 7041`,
the size its own sentinel already completed at. The sentinel's 57.3 ms a token
came straight after an hour of GPU runs and is not a result.

## Result of abba-final (2026-10-04)

All eight arms valid (abba-judge.py): every arm generated 2048 tokens with
text identical to the first a arm's; other processes' user ticks 2777-4018
against a median of 2932 (limit 4398); pressure level 1 and no swap growth in
every arm; every b arm at N = 7041. a = 0e4eac7 (dirty 0) at 7041, b =
cbad991 (dirty 0) at 10268.

    a  43.5  43.4  43.6  43.6   mean 43.525  sd 0.096
    b  43.6  43.4  43.5  43.5   mean 43.500  sd 0.082

d = -0.025 ms a token; block 1 +0.050, block 2 -0.100; threshold
max(0.3, 2 x 0.096) = 0.300 ms. No regression, and no improvement: the blocks
disagree in sign.

Exclusive split of a token, mean of the 32 windows of each arm, a / b:
encode 0.72 / 0.70, commit-to-done 30.76 / 30.16, miss repair-load 8.70 /
8.82, tail 1.40 / 1.40, residual 2.44 / 2.99 ms; misses 11.46 / 10.66 a
token.

## Amendment before the rerun (2026-10-04)

abba-final measured cbad991, which still let the expert cache's size choose
how a prefill tail is computed (fixed in 13c14ca; the tail is reported since
7dabfad). The rerun, abba-h, measures b = 7dabfad or later under every rule
above, with b's sentinel taken again first. Two rules are added:

- an arm is invalid unless its server log's "token ids: 2048, hash H" equals
  the first a arm's, as its text must;
- the b arms' "prefill tail ... runs token-major" lines are counted. With
  this 50-token prompt none is expected; if there are none, this ABBA checks
  for a regression and is no measure of 13c14ca's cost.

abba-final stays recorded as the measurement of cbad991.

## Second amendment before the rerun (2026-10-04)

abba-h was stopped during its second arm, before any decision: 7dabfad only
said a tail had started token-major, and 6749f95 replaces that with the
number of single steps the tail took, so the binary changed. Its arms are
exploratory. The rerun, abba-i, measures b = 6749f95 under every rule above,
with b's sentinel taken again first; a b arm's tail steps are the sum of its
"prefill tail ... ran N token-major steps" lines. Stopping abba-h also showed
that a TERM during COOL waited for the sleep to end; m4abba.sh now waits on
the cooling as on an arm.
