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

## Amendment, 2026-10-02, after arm 2 of the first run (abba8b2)

The capacity premise above was wrong. b at the production request does not
reach 7041 experts in decode: the budget holds the prefill reserve back, so
the cache stops adding slabs at 6504 entries ("6504 of 7041 entries live"),
while a held 7041. Arm 1 (a) 43.3 and arm 2 (b) 50.5 ms a token compared
different cache sizes, with b missing 5.0-10.6 experts a token against a's
4.2-6.7. The run was stopped there; those two arms are exploratory only.

Rerun (abba8b2r) with a at `--ssd-streaming-cache-experts 6504`, the size b
measurably runs at, and b unchanged at the production request 10268. All
other rules above stand. A sentinel of a at 6504 is not needed: it is below
the 7041 sentinel, which peaked at 79.36 GiB.

## Second amendment, 2026-10-02, after arm 2 of abba8b2r

Arm 2 (b) was 50.7 ms a token against arm 1 (a) at 44.9 with identical
misses. The candidate's own counters showed why: 38 ms a token of encoding
under the GPU against 2.7 in 1f5e2a9, from a host wait in the gate seed
reuse check (64e5cc6) that serialized encode-ahead. That is a defect in b,
fixed in e10ece8 and re-verified on every path; the run was stopped. The
measured run is abba-e10 with b = e10ece8, a and every rule as in the first
amendment. abba8b2r's two arms are exploratory only.

## Result of abba-e10 (2026-10-02 11:04-11:52)

All eight arms valid under the rules above: other processes' user ticks
3384-4636 against a median of 4031 (limit 6047), pressure level 1 throughout,
no swap growth. Every arm's provenance records its revision and server
arguments (a 0e4eac7 at 6504, b e10ece8 at 10268).

    a  44.9  45.4  45.5  45.3   mean 45.275  sd 0.263
    b  44.7  45.2  45.2  45.2   mean 45.075  sd 0.250

d = -0.200 ms a token; the regression threshold is max(0.3, 2 x 0.263) =
0.526 ms. No regression.

The ioreg sampler's sleep was left in the group when m4abba.sh exited;
gpurun.sh stopped it (ORPHANS), as in abba1f5.
