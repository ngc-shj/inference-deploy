# Sustained wall-time ABBA: 0e4eac7 against the Metal 4-native candidate

Fixed before any arm runs. A change to this file after the first arm makes the
run exploratory, not a result.

## Builds and capacity

- a: 0e4eac7 (ds4-v41-m4base), `--ssd-streaming-cache-experts 7041`
- b: the candidate as committed when the run starts (8b29679 or later, recorded
  per arm), `--ssd-streaming-cache-experts 10268`, the production request: the
  80 GiB budget fits it to 7041 experts in decode (6273 during prefill).
- a has no memory budget, so a is never run at 10268. Before the ABBA, one
  sentinel run of a at 7041 under gpurun.sh: if its peak wired exceeds 84 GiB,
  both arms run at `--ssd-streaming-cache-experts 6273` instead, and the
  result says it was compared below production capacity.

## Procedure

- m4abba.sh, BIN_A / BIN_B as above, MTL4_A=1 MTL4_B=1, 2 blocks of a-b-b-a
  (8 arms), NOGATE=1, COOL=300, each arm sustained.sh TOKENS=2048.
- The whole run under gpurun.sh. Nothing else is built or run on the machine
  while it runs.

## Metric

Wall time per generated token over the whole 2048-token generation, as
sustained.sh reports it ("wall per token"). Not a best window.

## When an arm is invalid

- other processes' user CPU ticks during the arm (cputicks, end minus start)
  exceed 1.5 times the median of the eight arms; or
- gpurun's samples during the arm show a pressure level above 1 or swap growth
  above 0.5 GiB; or
- the arm fails or is stopped.

An invalid arm is not dropped: the block containing it is run again once after
the eight arms. If the rerun is also invalid the comparison is reported as
inconclusive.

## Decision

d = mean(b) - mean(a) over the valid arms. A regression is d > max(0.3 ms,
2 x s), where s is the larger of the two arms' standard deviations. Anything
else is "no regression", with d and s reported.
