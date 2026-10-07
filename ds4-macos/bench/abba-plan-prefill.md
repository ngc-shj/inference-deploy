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
- valid: rc 0 at pressure level 1; ids, logits and state the same in all
  four arms (the oracle has 256 decode steps, which run T matched; none
  exists at 2048); superbatch 40 in on arms and 0 in off arms during the prefill, and
  0 during the decode in every arm; other processes' CPU recorded beside it.
- d = mean(on) - mean(off) of the decode's ms a token, and per order (D-1
  against D-2, D-4 against D-3). A regression is d > max(0.3 ms, 2 x the
  larger arm spread) with both orders the same sign; then the superbatch's
  allocations and residency that outlive prefill are separated from decode.
  Otherwise abe4ceb is kept and item 15 is taken as no regression.

## Seventh amendment before any arm (2026-10-06): the one confirming run

abe4ceb is adopted (decD: no decode regression). The final chain runs once
more, as run X (regX.out, m4accept.sh X, decode ABBA abba-x, cold arms
Y-<n>-<old|new>), on the tree b9bd1e1 - abe4ceb's engine sources and the
capacity test's nosb - under every rule of run T, including arm a's cache at
the sentinel's N and one block rerun for an invalid arm. It confirms: frozen
oracle identity, cold time to first token (absolute and saved), no decode
regression, 40 of 40 superbatched layers and 0 in the old arms, no
token-major tail fallback, pressure level 1 within the 80 GiB budget, and
15 of 15. No code or plan changes while it runs.

## abe4ceb withdrawn (2026-10-06)

Run X's item 13 failed (the short prompt's two sessions disagree from
evaluation 1298), so abe4ceb is not adopted. The tag
ds4-v41-metal4-prefill-superbatch-exact-production - tag object
8682b376aefcb757a74ba602220b277a95951700, on commit
abe4ceb594ca7141e239c4f561ba9d97fb9265d7, pushed to fork after decD - is
deleted from fork and from the local tree: its name says exact production,
which run X did not show. A fixed candidate gets a tag of a new name. The
cause is investigated first: the two-session test alternated on abe4ceb and
625b3a7 at the same cache, prewarm and order; on a reproduction, per-layer
state hashes near evaluation 1298, then the first differing layer's
selection, addresses, slab slots, generations and load completion, the
weight bytes resident against just loaded, and the cache/residency state a
session leaves for the next.

## Eighth amendment before any arm (2026-10-06): run Z on d34264a

The candidate is d34264a: abe4ceb's prefix superbatch, the router
publication barrier (b2bd8d1, the race the item-13 audit found), and the
cache busy invariant and per-token history (diagnostic, no GPU work). Six
short two-session runs on it give the oracle in both sessions with 0 of
73,875 busy checks failing (pair3f). The final chain runs once as run Z
(regZ.out, m4accept.sh Z, decode ABBA abba-z, cold arms Q-<n>-<old|new>)
under every rule of run X. Fixed only if 15 of 15, cold time to first token
shorter in both blocks, no decode regression, every arm the oracle's, 40 of
40 superbatched layers in new arms and 0 in old, pressure level 1. A fixed
d34264a gets a tag of a new name, pushed to fork only.

## Ninth amendment before the cold arms are run again (2026-10-07)

Run Z's cold arms stopped at Q-1-old on the harness, not the candidate: the
capacity test now prints two "superbatch" lines (the prefill's, and the
decode's count from b9bd1e1), and regZ.sh read both as the count ("0\n0").
Q-1-old itself was valid (superbatch 0, the oracle's ids/logits/state, cold
prefill 92.9 s, pressure level 1). The count is now read from the prefill's
line alone, and the eight cold arms run again as P-<n>-<old|new> in run R's
order and cooling, followed by m4accept.sh Z with the sentinel's N; run Z's
regression items and decode ABBA (no regression, blocks -0.300/-0.150 ms)
stand. Every other rule of the eighth amendment stands.

## Final (2026-10-07)

d34264a, tagged ds4-v41-metal4-superbatch-router-barrier-exact-production on
fork, is the fastest exact production and what production runs. Evaluated
after it and not adopted: per-row weight re-reads (none clears 1 ms a token),
exact Q8_0 tiles at thermal steady state (none beats 48), I/O overlap (the
next layer's read is already hidden), FFN overlap scheduling and thermal
pacing (no gain on back-to-back prompts). What remains between it and main
under sustained load is the oracle's arithmetic itself (SIMD Q8_0 projections,
the shared expert's Q8_0, the tail's per-row kernels); an inexact MPP build is
out of scope. The engine branch's later diagnostic commit d767aa9 is not part
of production.
