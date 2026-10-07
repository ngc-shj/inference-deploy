# d34264a against plain origin/main (0aaea5a), 2026-10-07

Same model, `--ssd-streaming --ctx 8192`, each server start after the model's
page cache was dropped and the machine settled; main with its defaults,
d34264a with the production environment. Requests at temperature 0,
`"think":false`, 64 tokens. Order main, d34, d34, main.

| | main | d34264a |
|---|---|---|
| short prompt (18 tokens), 1st request: prompt done | 4.74 s, 4.54 s | 1.66 s, 1.67 s |
| 　client total (prompt + 64 tokens) | 12.7 s, 10.4 s | 5.3 s, 5.3 s |
| 　decode | 8.1, 10.9 t/s | 17.5, 17.6 t/s |
| short prompt, 2nd request: prompt done | 1.62 s, 1.00 s | 0.83 s, 0.83 s |
| 　decode | 11.3, 10.1 t/s | 24.6, 13.5 t/s |
| short answer text | identical (66d5da8372) | identical |
| long prompt (4781 tokens), cold: prompt done | cache 10268: stopped by the memory guard at ~90 GiB wired, twice (main plans 82.9 GiB of expert cache, no 80 GiB budget); cache 7034: **34.6 s, 36.2 s** | **60.0 s, 71.3 s** |
| 　peak wired | 86.4-86.5 GiB (cache 7034) | 83.8-84.4 GiB |
| long answer text | dae9d97ebf | d8f1a29302 (the frozen oracle's arithmetic) |

Short prompts: d34264a is 2.7x faster to the first token on a fresh server and
about twice the decode rate, same text. Long prompts: main's prefill is about
1.8x faster cold at an equal cache size, with different arithmetic - its
answer differs from the frozen oracle's - and more wired memory; at the
production cache it does not run within the guard at all.

## Correction: the long-prompt gap was thermal state (2026-10-07)

The cold d34264a numbers above (60.0, 71.3 s) were taken in a sequence of
heavy runs. With the per-layer read profile (engine d767aa9) two identical
cold prompts back to back took 36.2 s and 51.1 s: the next layer's pread was
hidden in both (0.22 s of join waits over 40 layers), and the prefix's and
the tail's compute were both ~40% slower in the second. A short `./thermal`
probe read the same before each and does not see it.

With five minutes idle before every server start (cmpcool.out), cold, cache
7034 for main:

| run | main | d34264a |
|---|---|---|
| 1 / 4 | 34.06 s, 34.26 s | |
| 2 / 3 | | 35.17 s, 35.37 s |

At equal thermal state d34264a's exact long prefill is within 1.1 s (3%) of
main's inexact one; its answer is the frozen oracle's (d8f1a29302), main's is
not (dae9d97ebf). The difference that remains under load is the prefix's
SIMD Q8_0 projections running hotter and throttling more.

## Sustained runs and where the exact path's extra GPU work is (2026-10-07)

Three cold long prompts back to back after five minutes idle: main 34.64,
33.28, 34.41 s; d34264a 34.87, 40.88, 54.36 s. From the earlier back-to-back
pair's profile (36.2 then 51.1 s) the growth is GPU-side: prefix encode +4.9 s,
drain +4.4 s, the tail's later layers +52%, while the host-heavy first tail
layer (3.03 -> 3.09 s), the page-in (map 0.35 -> 0.30 s) and the pread joins
(0.22 s both) do not move. The Metal 4 encoder timeline's durations are not
usable for a per-kernel comparison.

Stage profile, each after five minutes idle, cold (cmp-cs-*; the superbatch is
off under the stage profile):

| stage | main prefix | d34264a prefix |
|---|---|---|
| attention projections (q_a/q_b/kv, Q8_0) | 0.83 s | 6.86 s |
| shared/routed ffn (shared Q8_0 + routed) | 5.67 s | 9.76 s |
| attention core/index | 3.59 s | 3.53 s |
| hc/engram | 0.85 s | 1.10 s |
| attention output | 0.69 s | 0.75 s |
| hc/ffn norm + hc expand | 0.52 s | 0.54 s |
| tail (685 rows) | 7.4 s layer-major | 12.9 s exact rows (wait) |
| prompt done | 34.7 s | 36.5 s |

The extra GPU work is the oracle's arithmetic itself - the SIMD Q8_0
projections, the shared expert's Q8_0 and the tail's per-row kernels, exactly
where main's output departs from the oracle. The other stages match main.
main stays I/O-bound (~19.5 s of compute) and cool; the exact path is
compute-bound (~32 s) and throttles under back-to-back load.
