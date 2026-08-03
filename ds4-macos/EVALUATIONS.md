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

- **There is a fast phase and a slow phase.** The first one or two requests
  after a load run at 27–36 tok/s; everything after settles at 9–15. This entry
  originally called the second number the representative one. It is not — it is
  what the machine does under memory contention, as the Docker test below
  shows, and with the desktop quiet `ds4-bench` measures 34.5 tok/s sustained
  over 2048 decode tokens (see the 08-03 entry). Quote 34.5 for a quiet machine
  and 9–15 for a crowded one.
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
— M5 Max 128 GB, ds4 — reports 18.02 tok/s on the MXFP4 build, and makes a claim
worth chasing: DeepSeek V4 Flash was trained QAT-native in MXFP4 for its routed
experts (~90% of the parameters), so the published MXFP4 weights carry no
post-hoc quantization error where almost all the model lives.

Setup notes. The 156 GB MXFP4 file needs `--ssd-streaming`; under full residency
it does not fit 128 GB, which is why the 08-02 entry wrongly dismissed it.
`main` cannot read it at all (`tensor blk.0.ffn_gate_exps.weight has type 39
(unknown)`) — MXFP4 lives on the `ds4f-mxfp4` branch, built here at `4893e0c`.
`--ssd-streaming` also refuses to start alongside `--mtp`.

### Generation length is the whole story

`ds4-bench`, ctx 2048, MXFP4 streaming with the auto budget:

| decode tokens | steady tok/s |
| --- | --- |
| 128 | 7.83 |
| 256 | 7.95 |
| 512 | 13.95 |
| 2048 | **18.61** |

The expert cache warms *during* a generation, and it takes on the order of a
thousand tokens. Measure 128 and MXFP4 looks broken; measure 2048 and it
reproduces the write-up's 18.02 average almost exactly. An entire day of
measurements on this page's first draft — "MXFP4 runs at 6–9 tok/s", "the
write-up does not reproduce", "the streaming path has an unexplained 2x" — were
all artifacts of a 128- or 256-token benchmark. The write-up says plainly that
its rate climbs from 15.08 to 20.55 as the cache warms; that was read early and
not acted on.

q2 warms too, and by more than expected: 20.01 tok/s over 128 tokens against
34.53 over 2048. Any short benchmark on this engine understates both models.

### The cost is the streaming path, not MXFP4

All at ctx 2048, 2048 decode tokens, `--ctx-alloc` left at its default of 4,097:

| Configuration | steady | prefill | first token |
| --- | --- | --- | --- |
| q2 0731, full residency | **34.53** | 497.8 | 30 ms |
| q2 0731, `--ssd-streaming` | 17.99 | 230.4 | 6,091 ms |
| MXFP4 0731, `--ssd-streaming` | **18.61** | 117.7 | 10,989 ms |

The allocation matters for the streamed rows and is not what the LaunchAgent
runs — at the deployed 131,072 the MXFP4 figure is 14.00, not 18.61. See
"Context allocation" below. The residency row is unaffected.

**Findings**

- **Streaming costs ~1.9x, and it is the only thing that costs.** q2 loses half
  its rate to `--ssd-streaming` alone, with its routed weights (72.56 GiB)
  small enough that the auto budget caches 10496 of 11008 experts — so this is
  not miss traffic, it is the path.
- **MXFP4 is not slower than q2; under streaming it is slightly faster.** 18.61
  against 17.99, despite 1.15x the per-token bytes and a cache that covers only
  ~52% of its routed weights. IQ2_XXS dequantization is table-driven where
  MXFP4 is a scale and a 4-bit field, which is the likely reason.
- **So MXFP4 costs nothing in speed.** What it costs is that it *requires*
  streaming, because 145 GiB will not sit resident in 128 GB. Choose MXFP4 and
  you pay the streaming penalty; choose q2 and you can avoid it — but if you are
  streaming either way, MXFP4 is the better of the two and carries no
  quantization error in 90% of the weights.
- **Time to first token is the real tax.** 10.9 s for MXFP4 and 6.1 s for q2
  under streaming, against 30 ms resident. Long generations amortize it; an
  interactive session does not.
- **The write-up's 47–62% figure compares different execution modes.** It puts
  q2 at 29–38 (full residency) against MXFP4 at 18.02 (streaming), which reads
  as MXFP4 being half as fast. Both numbers reproduce here — 34.53 and 18.61 —
  but the ratio between them is the streaming path, not the quantization. This
  page made the same conflation for two days.

### Where the time goes during a cold cache

Sampled with `powermetrics` while a 128-token benchmark ran, i.e. in the cold
regime that produced the misleading 7–9 tok/s:

| phase | GPU residency | GPU power | CPU P0 | CPU power |
| --- | --- | --- | --- | --- |
| prefill | 93% at 1620 MHz | 24.9 W | 97% | 6.3 W |
| decode (cold) | 0.9–2.7% | 6–27 mW | 26–38% at 1344 MHz | 1.0–1.6 W |

Neither engine is working — the GPU is idle and the CPU sits at its lowest
frequency step. That is the signature of blocking on page faults, not of a
thermal or bandwidth limit, and it rules out the 14-inch chassis (no High Power
Mode) as an explanation: prefill draws 24.9 W on the same machine minutes
earlier. It also corrects an earlier reading of this file, which used the
engine's `pread_ms` counter to argue I/O was only 13.5% of wall clock —
`pread_ms` counts time inside `pread`, and misses served through mmap faults do
not appear in it.

Expert cache counters at 50 GiB budget, for reference: `hit_rate=0.863` with
uniform per-layer rates, against the ~91% the write-up reports.

### Practical upshot

q2 0731 with full residency remains the default: 34.5 tok/s and a 30 ms first
token beat anything streaming can offer, and it fits. MXFP4 is the choice when
the priority is weight fidelity over latency — it gives up 1.9x throughput and
11 seconds of first-token latency, but not because of MXFP4; the same bill comes
with q2 if you stream it.

Measure with at least 1000 decode tokens. Nothing on this page from a shorter
run should be trusted, which is why the earlier figures have been removed rather
than annotated.

### Context allocation: free for residency, ruinous for streaming

`--ctx 1048576` is what the Linux sibling runs; macOS defaults to 131072. Cost
of the allocation alone, measured at the same 2048-token frontier and 2048
decode tokens so only the allocation changes:

| Configuration | ctx-alloc | KV | buffers | planned | steady |
| --- | --- | --- | --- | --- | --- |
| q2, residency | 4,097 | 1.36 | 1.00 | 83.12 GiB | 34.53 |
| q2, residency | **131,072** | 1.36 | 1.00 | 83.12 GiB | **35.59** |
| q2, residency | 1,048,576 | 8.39 | 8.00 | 97.15 GiB | 34.63 |
| MXFP4, streaming, auto budget | 4,097 | 1.36 | 1.00 | 79.28 GiB | 18.61 |
| MXFP4, streaming, auto budget | **131,072** | 1.36 | 1.00 | 81.16 GiB | **14.00** |
| MXFP4, streaming, auto budget | 1,048,576 | 8.39 | 8.00 | 95.18 GiB | 4.50 |
| MXFP4, streaming, 60 GiB budget | 1,048,576 | 8.39 | 8.00 | 77.37 GiB | 7.88 |

131,072 is what the LaunchAgent runs. `ds4-bench` defaults `--ctx-alloc` to
`ctx-max + gen-tokens + 1`, which for this sweep is 4,097 — so a benchmark left
on its default is not measuring the deployed configuration, and every MXFP4
figure elsewhere on this page was taken there.

- **Full residency is indifferent to the allocation.** 34.53 / 35.59 / 34.63
  across three orders of magnitude. Only the plan grows, to 97.15 GiB at 1M,
  which leaves ~31 GB for the desktop — the regime where the 08-02 collapse
  begins.
- **Streaming degrades monotonically with it.** 18.61 → 14.00 → 4.50. The
  automatic expert budget does not account for the context allocation: it asks
  for the same 77.81 GiB at every size, so KV and buffer growth comes straight
  out of the room the cache actually needs. Even the 1.9 GiB step from 4,097 to
  131,072 costs a quarter of the throughput.
- **1M costs ~14 GiB, and only half of it is KV.** Buffers go 1.00 → 8.00 GiB
  alongside KV's 1.36 → 8.39.
- **Capping the budget does not rescue 1M.** 60 GiB brings the plan down to
  77.37 GiB and recovers only to 7.88, because the cache holds 4306 experts
  instead of 5737 and misses more. Raise the budget and memory thrashes; lower
  it and the hit rate falls. No setting on this machine gets 1M streaming near
  14.

So 128K is not a conservative default to be raised when convenient — it is
already costing a streamed model 25% against a small allocation, and 1M is out
of the question. For q2 at full residency the allocation is free, and 1M is
available if the desktop can live in 31 GB.
