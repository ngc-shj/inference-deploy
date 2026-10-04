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
