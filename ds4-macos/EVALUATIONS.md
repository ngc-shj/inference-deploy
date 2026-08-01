# ds4-server evaluations (macOS / Apple Silicon — Metal)

Measured on a MacBook Pro **M5 Max, 128 GB unified memory** running
[ds4 (DwarfStar)](https://github.com/antirez/ds4) at `54b36ed`, built with the
Makefile's default target (Metal). Served through the LaunchAgent documented in
[README.md](README.md); requests go to the server's OpenAI-compatible API.

This is a separate runtime lineage from the MLX numbers in
[`../llama.cpp/EVALUATIONS-macos.md`](../llama.cpp/EVALUATIONS-macos.md) — same
box, different engine — so the two are not directly comparable.

---

## 2026-08-02 — DeepSeek V4 Flash 0731 vs the previous chat-v2 build

Trigger: DeepSeek published `DeepSeek-V4-Flash-0731` on 2026-07-31 — the April
preview retrained through a reworked post-training pipeline, with the gains
claimed on coding, agents and tool use. antirez re-quantized the same recipes as
`-0731` files on 07-31 / 08-01; the `-0731` GGUFs are byte-for-byte the same
size as their predecessors, so the recipe is unchanged and only the base weights
differ.

Prompts: three coding tasks — `merge_intervals` + 5 pytest cases, a Rust
`parse_duration` with four rejection classes, and a `lower_bound` bug hunt with
a single correct answer. `temp 0.2`, `max_tokens 8192`, one sample each. Each
model runs the set twice, because throughput turned out not to be stationary.

### Quality — no difference on these three tasks

Both builds solve the bug hunt correctly and near-identically (`hi = len(a) - 1`
should be `len(a)`). Both write the same `merge_intervals`, and both carry the
same two defects: `intervals.sort()` mutates the caller's list, and all five
tests feed already-sorted input, so nothing pins the "returns them sorted"
requirement. On the Rust task each has one edge the other lacks — 0731 keeps
intermediates in `u128` and so separates "overflow" from "not a number", while
the older build's three overflow tests actually trip `u64` parse failure rather
than the multiplication overflow their comments claim, but it is the only one
of the two to test addition overflow, with a correctly computed
`5124095576030372h` boundary.

Output lengths match (4636 vs 4572 tokens on the longest task). On this sample
the retrained weights are not distinguishable. The 0731 gains are claimed for
agentic and tool-use work; three single-shot prompts are the wrong instrument
for that, and one sample per prompt with unseeded sampling would not resolve a
small difference anyway.

### Throughput — not stationary, and not attributable to the model

Decode rate, completion tokens ÷ wall-clock, `--ctx 131072`:

| Configuration | task 1 | task 2 | task 3 |
| --- | --- | --- | --- |
| mixed q2+q4 **0731**, MTP — pass 1 | 31.3 | 28.7 | 9.9 |
| mixed q2+q4 **0731**, MTP — pass 2 | 9.1 | 11.4 | 13.4 |
| mixed q2+q4 **previous**, MTP — pass 1 | 13.7 | 13.1 | 13.0 |
| mixed q2+q4 **previous**, MTP — pass 2 | 13.2 | 14.3 | 14.7 |
| **q2** 0731, MTP — pass 1 | 33.2 | 19.1 | 9.0 |
| **q2** 0731, MTP — pass 2 | 9.6 | 12.7 | 13.8 |
| **q2** 0731, **no MTP** — pass 1 | 35.9 | 26.9 | 10.5 |
| **q2** 0731, **no MTP** — pass 2 | 11.7 | 13.5 | 13.6 |

**Findings**

- **There is a fast phase and a slow phase, and only the slow one is
  representative.** The first one or two requests after a load run at 27–36
  tok/s; everything after settles at 9–15 tok/s. Sustained throughput on this
  box is the second number.
- **Restarting the server does not reliably restore the fast phase.** Both the
  previous-build load and a mid-session reload of 0731 started out already slow.
  The fast phase reappeared only after the machine had been idle overnight,
  which points at machine-level state rather than anything the process owns.
- **Not the quantization.** The mixed q2+q4 quant (90.88 GiB resident) and the
  q2 quant (80.76 GiB) show the same curve. The 10 GiB saved buys footprint, not
  speed.
- **Not MTP.** Dropping `--mtp` leaves the collapse intact, so speculative
  decoding is not what degrades.
- **Not swap.** During the q2 run swap went 9246 → 9206 → 9198 MB — it *fell*
  while throughput was collapsing. An earlier reading of 14.3/15.36 GB is not
  comparable: macOS resizes the swap file, and total had dropped to 10.24 GB by
  the later run.
- **Not the KV disk cache filling up.** `~/.cache/ds4/server-kv` was already at
  its 16 GB budget before pass 1, evicting on every request throughout, so its
  fullness is not what changes between the passes.
- **Not thermal, as far as can be seen.** `pmset -g therm` recorded no warning —
  which is weak evidence, since it only logs warnings that did fire.

The shape is consistent with the Metal residency requested at load
(`residency requested in 15557 ms` in the startup log) being given up and the
weights falling back to mmap reads, but nothing here observes residency
directly, so that remains a hypothesis. Worth reporting upstream with these
numbers rather than bisected further from the deployment side.

### MTP costs throughput on reasoning-heavy prompts

Comparing the two pass-1 rows, which are the only ones measured before the
collapse, MTP is slower on all three tasks, and worst on the longest generation
— 19.1 vs 26.9 tok/s on task 2, a 40% penalty. ds4's own guidance says draft
acceptance is high on predictable output and low on divergent free-form text;
these prompts are thinking-heavy, so they sit on the bad side of that split. In
the degraded state the difference washes out. MTP is left enabled by default
since the tasks here are not representative of all use, but it is the first flag
to drop for a reasoning workload.

### Footprint

| Quant | file | resident model | planned total (`--ctx 131072`) |
| --- | --- | --- | --- |
| mixed q2+q4 layers 37–42 | 97.6 GB | 90.88 GiB | 93.25 GiB |
| q2 (`IQ2XXS-w2Q2K`) | 86.7 GB | 80.76 GiB | 83.12 GiB |

KV is only 1.36 GiB of that at 128K context (0.36 raw + 1.00 compressed), so
lowering `--ctx` is not a meaningful lever on this engine — the resident model
dominates. Dropping to the q2 quant is the only footprint lever that matters,
and it costs nothing measurable in quality on the tasks above.
