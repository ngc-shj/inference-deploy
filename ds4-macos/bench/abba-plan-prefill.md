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
