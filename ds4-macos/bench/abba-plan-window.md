# Sustained wall-time ABBA: 0e4eac7 against the candidate in window mode

Withdrawn, never run. Its sentinel (sentW, 2026-10-02) pinned windows on 14 of
40 layers, which left the other 26 about 1000 cache slots: 42 misses and
61.0 ms a token against 45.1. Window mode was then removed from V4.1
(e56ab96); abba-plan-final.md replaces this plan.

Fixed before any arm runs. A change to this file after the first arm makes the
run exploratory, not a result.

## Builds and configuration

- b: the candidate as committed when the run starts (0f2b937 or later, the
  binary every correctness run before it used; revision, dirty count and
  binary hash recorded per arm), `--ssd-streaming-cache-experts 10268`, the
  production request, with `ENV_B="DS4_METAL_ENABLE_STREAMING_FULL_EXPERT_ADDR_TABLE=1
  DS4_METAL_FULL_ADDR_LAYERS=40"`: every layer asks for a pinned window, and
  the 80 GiB budget decides how many it gets.
- a: 0e4eac7 (ds4-v41-m4base), no ENV_A, at the cache size b measurably runs
  at in decode, found as below. a has no memory budget, so it is never run at
  10268.

## Capacity sentinel

One arm of b alone (sustained.sh TOKENS=2048 under gpurun.sh, the same
environment) before the ABBA. It is not part of the result. From its log it
records:

- the decode cache size, N from the last "N of M entries live" line: a runs
  at `--ssd-streaming-cache-experts N`;
- the windows it opened with ("expert directory: pinned windows of E experts
  on L of 40 layers") and the closing directory line (pinned hits, pinned
  experts given back). If L is 0 or there are no pinned hits, window mode did
  not run and the ABBA is not started.

If N is above 7041 (a's sentinel at 7041 peaked at 79.36 GiB wired), a first
gets its own sentinel at N; if that peaks above 84 GiB wired, both arms are
compared at 7041 with b's server argument set to 7041, and the result says so.

## Procedure

- m4abba.sh, BIN_A / BIN_B as above, EXTRA_A / EXTRA_B the cache sizes,
  ENV_B as above, MTL4_A=1 MTL4_B=1, 2 blocks of a-b-b-a (8 arms), NOGATE=1,
  COOL=300, each arm sustained.sh TOKENS=2048.
- The whole run under gpurun.sh. Nothing else is built or run on the machine
  while it runs.

## Metric

Wall time per generated token over the whole 2048-token generation, as
sustained.sh reports it. Not a best window.

## When an arm is invalid

- other processes' user CPU ticks during the arm (cputicks, end minus start)
  exceed 1.5 times the median of the eight arms; or
- gpurun's samples during the arm show a pressure level above 1 or swap growth
  above 0.5 GiB; or
- the arm fails or is stopped; or
- a b arm's log shows a pinned-window line different from the sentinel's, no
  pinned hits, or a last "entries live" N different from the sentinel's (the
  arm then measured something else).

An invalid arm is not dropped: the block containing it is run again once after
the eight arms. If the rerun is also invalid the comparison is reported as
inconclusive.

## Decision

d = mean(b) - mean(a) over the valid arms. A regression is d > max(0.3 ms,
2 x s), where s is the larger of the two arms' standard deviations. Anything
else is "no regression", with d and s reported; a negative d is not reported
as an improvement.
