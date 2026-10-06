# Final measurements of the prefill work: decode ABBA and cold time to first token

Fixed before any arm runs. A change to this file after the first arm makes the
run exploratory, not a result.

The candidate is a33097f (or the commit the final regression ran on, if later):
db73bc0's batched prefill tail, and a33097f's one exact batch step of up to 800
rows with the block attention, expert reads through the mapped descriptor.

## Precondition

The final regression (regM.out) passes items 1-14 of m4accept.sh M on the
candidate. Without that, neither measurement runs.

## 1. Sustained decode (acceptance item 15)

As abba-plan-final.md in every rule - m4abba.sh, 2 blocks of a-b-b-a, NOGATE=1,
COOL=300, 2048 tokens, text and token ids equal in every arm, the same
invalidity rules and decision - with a = 0e4eac7 at the decode cache size b's
sentinel (sentM) reaches, b = the candidate at 10268. Run as abba-m.

## 2. Cold time to first token for the 4795-token prompt

- Arms: a = 6749f95 (ds4-v41-metal4-native-exact-production, the token-major
  tail), b = the candidate; the capacity test (m4capab.sh, one process an arm)
  at cache 10268 and 256 steps.
- Order a b b a b a a b. Before every arm: wired memory under 8 GiB, the
  thermal reference reached, and the model file dropped from the file cache
  (pagecache drop, its before/after recorded).
- Every arm's ids, logits and saved state must be the frozen baseline's
  production output (m4st-frozen-m3 "long"); an arm that differs stops the
  run.
- Metric: the prefill's wall ("prefill ... in X s"), and ms per input token.
- Decision: d = mean(b) - mean(a), and the four pair differences. An
  improvement is stated only if every pair is negative; it is stated as d
  seconds and d / 4795 ms per input token. Anything else is reported as it is,
  with no improvement claimed.

## Amendment before any arm (2026-10-05)

The final regression of a33097f (regM.out) failed items 11 and 13 - self-
tests, vision, the in-process long prompt - and neither measurement ran. The
fix is 899f47c: batched tails only for 256-1023-row appends,
none for sessions with images, the wide gathers allocated before the batch).
The candidate is that commit; every rule above stands.

## Second amendment before any arm (2026-10-05)

No arm of the amended plan ran: the candidates with a 1 ms an input token
ceiling were evaluated first (records a3aa502). The candidate is now
7cfffd8 - 899f47c, the eight-output Q8_0 tile (cba0262) and test hooks.
The final regression is run Q (regQ.out, m4accept.sh Q), the decode ABBA
abba-q.

The cold time-to-first-token baseline is no longer 6749f95. Arm a is the
32-row batched tail with the two-output Q8_0 tile in the candidate's own
binary - m4capab.sh with ARM_MODE="prev q8nr2", which reproduces the
frozen oracle's ids, logits and state (capab-Q-prevnr2) - so the pair
differs only in what is measured, not in build, I/O path or any other
commit. Arm b is the candidate's production. Arms are named V-<n>-<old|new>.
Every other rule above stands.

## Stopped before any arm (2026-10-05)

The final chain on 7cfffd8 was stopped during its first state check; no
ABBA arm and no cold pair ran. 7cfffd8 is a development baseline, not the
candidate: performance work continues on it, and this plan is amended again
with the final commit before its arms run. What did complete on 7cfffd8 is
kept as the baseline's evidence - the long prompt at caches 4096, 5400 and
10268, each with the frozen oracle's ids, logits and state.

## Third amendment before any arm (2026-10-05)

The candidate is 625b3a7: the layer-interleaved prefill (98811c5), the
batched indexer top-k (93364a3), the every-block selection and the
attention row tiles (9e7255d), and test hooks. Every other improvement
evaluated since 7cfffd8 is recorded and not in it. The final regression is
run R (regR.out, m4accept.sh R), the decode ABBA abba-r.

Cold time to first token: arm a is m4capab.sh with ARM_MODE="prev q8nr2
base" - the 32-row batched tail, the two-output Q8_0 tile, and every prefill
path added since off - in the candidate's binary; it reproduces the frozen
oracle (capab-R-base). Arm b is the candidate's production. Arms are named
W-<n>-<old|new>. Every other rule above stands.

## Fourth amendment before any arm (2026-10-06)

625b3a7 passed regression items 1-14 (run R) and was kept as a checkpoint;
its chain was stopped before the ABBA for the prefix backend work. The
candidate is now the engine sources of 68a559a: 625b3a7 plus the paired
prefix routed experts (both 2048-row chunks of a layer in one dispatch).
The tree under test is 84909ac, which adds to it only the capacity test's
switch for the pairing in "base" and a line counting paired layers. The
final regression is run S (regS.out, m4accept.sh S), the decode ABBA
abba-s, the cold arms V-<n>-<old|new>, in the order and with the cooling
of run R.

The candidate is fixed only if all of these hold: 15 of 15; cold time to
first token shorter than the baseline arm in both blocks (old/new means of
each block of four); no decode regression in the ABBA; every arm's ids,
logits and saved state the frozen oracle's; every new arm printing 40 paired
prefix layers and every old arm 0; every run at pressure level 1, unstopped,
with no residency or memory anomaly. If the cold time to first token is not
shorter in both blocks, the pairing is taken out and 625b3a7 stays the
baseline.

## Fifth amendment before any arm (2026-10-06)

Run S was stopped after stS/stS4 (both rc 0) to merge the rest of the prefix
(prefix-superbatch.md). The candidate is abe4ceb: 625b3a7 plus the prefix
superbatch (every row-independent step of a 4096-row prefix once over both
chunks, attention a chunk at a time) and the tail's carried fields in their
own 57 MiB. The final regression is run T (regT.out, m4accept.sh T), the
decode ABBA abba-t, the cold arms U-<n>-<old|new>, in run R's order and
cooling; the old arms are "prev q8nr2 base", which turns the superbatch off.

The expert cache fits 14 fewer experts than at 625b3a7, so the sentinel's
live entries may no longer be 7041: arm a of the decode ABBA (the frozen
baseline) takes the sentinel's N, whatever it is, so both arms decode with
the same live cache, and abba-judge reads that N.

Fixed only if: 15 of 15; cold time to first token shorter than the old arms
in both blocks; no decode regression; every arm's ids, logits and state the
frozen oracle's; every new arm printing 40 superbatched layers and every old
arm 0; pressure level 1, unstopped, no residency or memory anomaly. If the
cold time to first token is not shorter in both blocks, the superbatch is
taken out and 625b3a7 stays the baseline.

## Sixth amendment before any arm (2026-10-06): run T's decode, once more

Run T's decode ABBA (item 15) was inconclusive: one b arm invalid for other
processes' CPU in abba-t, and one in its rerun abba-t2. The superbatch runs
in prefill only, so the one question left is whether a decode regression is
real. It is measured once, on one binary, the tree b9bd1e1 (abe4ceb's engine
sources; the capacity test gains "nosb", the superbatch alone off, and counts
superbatch layers during the decode):

- arms D-1-on, D-2-off, D-3-off, D-4-on: m4capab.sh at cache 10268, 2048
  decode steps after the long prompt, each its own process, settled (wired
  below 8 GiB, thermal back to 97%) before each; "off" is ARM_MODE=nosb.
- valid: rc 0 at pressure level 1; the oracle's ids/logits/state for the
  prompt; superbatch 40 in on arms and 0 in off arms during the prefill, and
  0 during the decode in every arm; other processes' CPU recorded beside it.
- d = mean(on) - mean(off) of the decode's ms a token, and per order (D-1
  against D-2, D-4 against D-3). A regression is d > max(0.3 ms, 2 x the
  larger arm spread) with both orders the same sign; then the superbatch's
  allocations and residency that outlive prefill are separated from decode.
  Otherwise abe4ceb is kept and item 15 is taken as no regression.
