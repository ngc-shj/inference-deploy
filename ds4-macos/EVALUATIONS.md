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
- **Not the KV disk cache filling up.** `~/.cache/ds4/server-kv` was already at
  its 16 GB budget before pass 1, evicting on every request throughout, so its
  fullness is not what changes between the passes.
- **Not thermal, as far as can be seen.** `pmset -g therm` recorded no warning —
  which is weak evidence, since it only logs warnings that did fire.
- **Not the July Metal rework.** Built `80ebbc3` (Jun 17, the last revision
  before any of it) and ran the same set: 12.8 → 7.9 → 6.1 → 6.6 tok/s. It
  collapses too, from a lower starting point — in the same machine state the
  newer build is 1.5-2x faster throughout, so `427e281` "Optimize Metal prefill
  and decode kernels" is a win, not the cause.
- **It *is* contention for physical memory** — see below. An earlier revision of
  this file ruled that out because `vm.swapusage` held flat at ~9.2 GB through a
  collapse. Wrong instrument: `vm.swapusage` reports the size of the swap
  *file*, which macOS grows and shrinks on its own, and says nothing about the
  compressor or about free pages.

### It is contention for physical memory

The decisive test: quit Docker (7.92 GB resident, the largest non-ds4 consumer)
and re-send the prompt that had just run at 4.2 tok/s.

| | free | compressor | same prompt |
| --- | --- | --- | --- |
| before | 0.17 GB | 12.45 GB | 4.2 tok/s |
| after quitting Docker | 7.82 GB | 7.02 GB | **30.7 tok/s** |

A 7x recovery from freeing 8 GB, with nothing about ds4 touched. At the low
point `vm_stat` showed 151 MB free, 38.2 GB of application data squeezed into
13.4 GB of compressor, and 168 GB of cumulative swapouts since boot.

The mechanism follows. ds4 wires ~90 GB for the model — Activity Monitor counts
it under *wired*, not against the process, so the `ds4-server` row showing ~5 GB
is misleading and should not be used to judge headroom. That leaves ~35 GB for
everything else on a 128 GB machine. Once the desktop working set grows past it
the compressor engages, model pages get evicted, and weight reads start hitting
the SSD. Nothing re-wires them afterwards, which is why the slow state persists,
why restarting the server does not clear it, and why idling does: idle time lets
the OS compress and evict *other* applications and hand the physical pages back.

This is a capacity finding, not an engine defect — a ~90 GB working set and a
normal desktop session do not both fit in 128 GB. Keep heavy applications
(Docker especially) closed while serving, and read `vm_stat` free/compressor
rather than `vm.swapusage` when throughput drops. The one question still worth
putting upstream is whether Metal residency, once lost, is ever re-requested;
the startup log's `residency requested in 15557 ms` happens exactly once.

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

---

## 2026-08-03 — MXFP4 0731 and `--ssd-streaming`

Trigger: [a write-up of this exact setup](https://qiita.com/sukimaengineer/items/c97f3e6aafdc63b7ac17)
— M5 Max 128 GB, ds4, SSD streaming — reports 18–20.55 tok/s on the MXFP4 build
and makes a claim worth chasing: DeepSeek V4 Flash was trained QAT-native in
MXFP4 for its routed experts (~90% of the parameters), so the published MXFP4
weights carry no post-hoc quantization error where almost all the model lives.

Two things had to be corrected before measuring. The 156 GB MXFP4 file was
dismissed in the 08-02 entry as too large for 128 GB — true only under full
residency; `--ssd-streaming` exists precisely for this. And `main` cannot read
the file at all (`tensor blk.0.ffn_gate_exps.weight has type 39 (unknown)`) —
MXFP4 lives on the `ds4f-mxfp4` branch, built here at `4893e0c` (2026-08-01).

Also: `--ssd-streaming` refuses to start alongside `--mtp`
("not compatible with --mtp yet"), so streaming runs have no speculative
decoding. The q2 reference numbers below do have it.

### Result: ~4 tok/s steady, against 30–31 for q2

Same prompt throughout (the `merge_intervals` task), `stream: true`, one server
lifetime per row unless noted.

| Configuration | planned | measured |
| --- | --- | --- |
| q2, full residency, MTP | 83.12 GiB | **30–31 tok/s** |
| MXFP4, streaming, auto budget | 81.16 GiB | 7.4 → 4.6 → 3.3 → 3.6 → 2.8 → 3.6 → 4.6 → 4.3 → 4.2 → 3.8 |
| MXFP4, streaming, `--ssd-streaming-cache-experts 50GB` | 53.34 GiB | 6.0, 6.2 (stable) |

**Findings**

- **Warming does not rescue it.** The write-up's 18–20 tok/s is a warm figure
  resting on a ~91% expert-cache hit rate, and every earlier measurement here
  restarted the server and so measured a cold cache. Ten requests in one
  lifetime settle the question: the rate falls from 7.4 and then oscillates
  between 2.8 and 4.6 with no upward trend. Free memory sits at 0.06 GB from the
  first request onward.
- **The auto budget saves no memory at all.** 81.16 GiB planned against full
  residency's 83.12 GiB — it asks for the same machine and then reads the SSD
  per token, which is strictly worse. `--ssd-streaming` only becomes a memory
  lever when the budget is capped explicitly.
- **Capping helps, and reverses the ordering.** At 50 GiB the collapse stops
  (6.0 → 6.2) — smaller cache, but enough page cache left to stream a 145 GiB
  file. Slower on the first request than auto, faster by the second, and it does
  not decay.
- **The real trade is 30 GiB for 5x.** Capped streaming leaves ~75 GiB to the
  desktop instead of ~45, at 6 tok/s instead of 30. There is also an asymmetry
  in how each recovers: q2 comes back when you quit an application (4.2 → 30.7
  tok/s on the 08-02 Docker test), while MXFP4 under the auto budget does not —
  quitting Docker and then Edge moved it from 6.5/2.9/2.2 to 3.0/2.8/2.6 to
  7.4/3.3/0.2.
- **18–20 tok/s did not reproduce, and it is not the cache and not the SSD.**
  See below — measured, not inferred. An earlier revision of this entry blamed
  machine headroom; the counters say otherwise.

### The cache is fine; the bytes are the problem

`ds4-server` never prints the streaming counters — `DS4_METAL_MEMORY_REPORT`
only reaches `ds4_gpu_print_memory_report` from a Metal test path — so the
worktree build was instrumented with a one-line call after each completion.
Note that streaming replies finish through a *different* log site than
non-streaming ones; patching the obvious one produces nothing.

Capped 50 GiB, four requests:

```text
hit_rate=0.863  hits=514297 misses=81832  evictions=78329 wraps=245496
miss_pread=975.29 GiB  pread_ms=49839
```

- **The expert cache works.** 86.3% against the ~91% the write-up claims, and
  per-layer rates are uniform (0.858–0.888), so no layer is starving. Whatever
  costs the missing 5x, it is not cache misses.
- **I/O is not the bottleneck either.** The delta for the last request alone was
  262.9 GiB in 15.6 s of a 115.3 s wall clock — 13.5%, at ~17 GiB/s, which is
  page-cache speed, not SSD speed. Freeing memory or resizing the budget cannot
  buy back the other 86%.
- **The "1.89x bytes" argument in an earlier revision of this file was wrong.**
  It divided q2's rate by the ratio of expert sizes (12.75 vs 6.75 MiB) and
  called the result a ceiling. Two errors. Routed experts are not the whole
  per-token working set: ds4 reports 8.20 GiB of non-routed weights, touched
  every token by both models, against 43 × 6 × expert_size of routed traffic —
  3.2 GiB for MXFP4, 1.7 for q2. Including it, per-token bytes are 11.4 vs 9.9
  GiB, a ratio of **1.15x**, not 1.89x. And neither model is near the ceiling
  anyway: at this machine's 614 GB/s (M5 Max, 40 GPU cores) 11.4 GiB/token
  allows ~50 tok/s, so the observed 20–30 is roughly half of a bandwidth limit,
  not against it.

### It is mostly the streaming path, not MXFP4

The comparison this entry was built on — MXFP4-streaming against
q2-full-residency — changes the quantization and the execution path at once and
then blames the quantization. Running **q2 0731 under `--ssd-streaming`**
separates them. Note that q2's routed weights total 72.56 GiB and the auto
budget caches 10496 of 11008 experts, so q2-streaming runs with essentially no
misses — it isolates the path's own cost.

| ctx 2048, `ds4-bench` | steady | vs previous row |
| --- | --- | --- |
| q2, full residency | 20.01 | — |
| q2, `--ssd-streaming` (cache holds ~everything) | 13.87 | 1.44x slower |
| MXFP4, `--ssd-streaming` (cache holds ~52%) | 7.83 | 1.77x slower |

Across frontiers q2-streaming runs 13.87 / 8.75 / 14.04 / 15.96 against MXFP4's
7.83 / 9.90 / 7.04 / 7.01.

So roughly 1.4x is the streaming path itself — paid even with the whole model
cached, so it is dispatch overhead, not I/O — and a further 1.8x is MXFP4, of
which 1.15x is bytes and the rest is real cache misses, since 137 GiB of routed
weights cannot fit a 71 GiB cache.

This also sharpens the disagreement with the write-up rather than resolving it.
Our q2-streaming reaches 13.9–16.0 tok/s with almost no misses; the write-up's
MXFP4 reaches 18.02 with 9% misses and 1.15x the bytes. On this machine that
ordering is not reachable.

One environmental difference is untestable here: this is a **14-inch** M5 Max,
which has no High Power Mode. The write-up does not state its chassis. A
sustained SSD-plus-GPU workload is where a sustained-power ceiling would show,
and the direction fits — their rate rises through a generation, ours falls.
Against it, `pmset -g therm` logs no warning and q2 at full residency holds
19–20 tok/s across every frontier without decay, which a package-wide throttle
should also have dragged down.

### Same tool, both models — and a decode/prefill asymmetry

`ds4-bench` rather than the server, `speed-bench/promessi_sposi.txt`, MXFP4 with
the auto budget against **q2 0731** with full residency:

| ctx | MXFP4 steady | q2 steady | MXFP4 prefill | q2 prefill | MXFP4 first token | q2 first token |
| --- | --- | --- | --- | --- | --- | --- |
| 2048 | 7.83 | 20.01 | 99.8 | 308.3 | 12,149 ms | 45.9 ms |
| 4096 | 9.90 | 19.64 | 79.0 | 222.3 | 46,922 ms | 48.6 ms |
| 6144 | 7.04 | 19.30 | 78.0 | 221.5 | 53,514 ms | 43.4 ms |
| 8192 | 7.01 | 19.98 | 64.1 | 217.3 | 101,235 ms | 52.7 ms |
| 32768 | 4.91 | 13.19 | 107.5 | 169.6 | 24,049 ms | 57.0 ms |

- **The server numbers were not an artifact.** Bench steady (7–9.9) matches what
  the HTTP path produced (6–9), so neither thinking mode nor the server is
  implicated. The write-up's figure is also a server measurement — 239 tokens,
  average 18.02 — so the two are comparable.
- **Time to first token is 12–101 seconds** against q2's ~50 ms. Long generations
  amortize it, which is why steady looks better than `gen_tps`, but for
  interactive use this is the number that decides it.
- **Prefill and decode disagree about who is slow.** At 32K the q2:MXFP4 ratio is
  1.58x on prefill but 2.69x on decode; the write-up reports 2.09x and 1.6–2.1x.
  Our prefill ratio is *better* than theirs and our decode ratio is worse. A
  uniformly slow MXFP4 path — bad kernels, slow I/O — would drag both equally,
  so something specific to decode is left over. The bandwidth arithmetic
  predicts 1.89x; the write-up sits on it, we are ~1.4x past it.

### Hypotheses tested and rejected

Recorded so the next attempt starts further along:

| Hypothesis | Verdict | Evidence |
| --- | --- | --- |
| Expert cache is thrashing | No | hit_rate 0.863 vs ~0.91 claimed, uniform per layer |
| SSD I/O is the bottleneck | No | 13.5% of wall clock, ~17 GiB/s = page-cache speed |
| Thinking mode / server overhead | No | ds4-bench (no-thinking) reproduces the same rates |
| Prefill seeds the cache and we never fed it one | No | 32K prefill gave 4.91 tok/s, *worse* than 2K's 7.83 |
| Fast MXFP4 kernel is gated off | No | it needs `expert_used_count == 6`; the model is 6 |
| Kernels are an unoptimized reference path | No | simdgroup kernels with fused `pair_swiglu`/`slots6`/`sum6` variants; `make test-mxfp4-metal` passes |
| Wrong build or a missing opt-in | No | same commit `4893e0c`; the only MXFP4 env var is a *disable* switch |

The machine is not generally slow: q2 0731 lands at 30–31 tok/s on short
contexts, inside the 29–38 the write-up quotes for its own q2. Whatever the gap
is, it is specific to MXFP4 decode here.

One asymmetry worth passing upstream: in the write-up the rate *rises* through a
generation (15.08 → 20.55 over 239 tokens) as the cache warms. Here it falls,
in every configuration tried.

MXFP4 is not the default here. Its argument is real — no quantization error in
90% of the weights — and a ~1.9x ceiling against q2 would be a defensible trade.
5–10 tok/s with a 12–101 second first token is not, and the shortfall is in
neither the cache, the SSD, the kernels, nor the measurement method. Worth
re-measuring against a later branch, or asking upstream directly — the ruled-out
list above is specific enough to make that a useful question.
