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
