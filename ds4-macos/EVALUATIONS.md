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

### MTP: no measurable effect either way

An earlier revision of this entry read a 40% penalty off the pass-1 rows above
(19.1 with `--mtp` against 26.9 without) and concluded MTP was the first flag to
drop for reasoning work. That comparison was one sample per arm on a
memory-contended machine, which the rest of this page has since shown to be
worth nothing.

Retested on 08-03 with the protocol the rest of these numbers now use: q2 0731
at full residency, `--ctx 131072`, through the server, one open-ended coding
prompt generating thousands of tokens, arms alternated, three reps each.

| | rep 1 | rep 2 | rep 3 | mean |
| --- | --- | --- | --- | --- |
| `--mtp ... --mtp-draft 2` | 17.1 | 15.2 | 15.9 | 16.1 |
| no MTP | 16.2 | 16.8 | 16.7 | 16.6 |

The arms overlap; the 3% gap sits inside the spread of the MTP arm alone
(15.2–17.1). Nothing here justifies changing the default in either direction, so
MTP stays enabled. ds4's own guidance — draft acceptance is high on predictable
output, low on divergent text — may well hold, but this workload does not
resolve it.

Worth noting separately: **15–17 tok/s is what the server delivers on a real
coding prompt**, against 34.5 from `ds4-bench` at the same quant and residency.
The difference is the context growing past 8,000 tokens mid-generation, the
thinking tokens, and KV persistence — none of which the benchmark does. Quote
the benchmark for comparing configurations and this number for what a user
sees.

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
thousand tokens. Measure 128 and MXFP4 looks broken; measure 2048 and it reaches
the write-up's 18.02 average — though repeats put 2048-token runs anywhere from
10.4 to 17.8, so "reaches" means the top of a wide range, not a stable match.
An entire day of measurements on this page's first draft — "MXFP4 runs at 6–9
tok/s", "the write-up does not reproduce", "the streaming path has an
unexplained 2x" — were all artifacts of a 128- or 256-token benchmark. The
write-up says plainly that its rate climbs from 15.08 to 20.55 as the cache
warms; that was read early and not acted on.

q2 warms too, and by more than expected: 20.01 tok/s over 128 tokens against
34.53 over 2048. Any short benchmark on this engine understates both models.

### The cost is the streaming path, not MXFP4

All at ctx 2048, 2048 decode tokens, `--ctx-alloc` left at its default of 4,097:

| Configuration | steady | prefill | first token |
| --- | --- | --- | --- |
| q2 0731, full residency | **34.53** | 497.8 | 30 ms |
| q2 0731, `--ssd-streaming` | 17.99 | 230.4 | 6,091 ms |
| MXFP4 0731, `--ssd-streaming` | **18.61** | 117.7 | 10,989 ms |

Every streamed number here is a single run, and repeats later on this page put
MXFP4 anywhere between 10.4 and 17.8 tok/s under identical settings. Read 18.61
as the top of that range, not as the figure. The residency rows are stable
across repeats (34.5–35.6).

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
`ctx-max + gen-tokens + 1`, which for these sweeps is 4,097 — so a benchmark
left on its default is not measuring the deployed configuration.

The single-run figures above suggested streaming degraded with the allocation,
18.61 → 14.00 → 4.50. Repeating the first two alternately, three times each,
does not support that:

| ctx-alloc | run 1 | run 2 | run 3 |
| --- | --- | --- | --- |
| 4,097 | 17.84 | 10.38 | 11.52 |
| 131,072 | 11.19 | 11.54 | 11.16 |

- **4,097 and 131,072 are indistinguishable.** Drop the first run of the session
  and both sit at 10.4–11.5. The 1.88 GiB the larger allocation costs is not
  worth 25% of anything, which is what the arithmetic said in the first place:
  81.16 GiB planned on a 128 GiB machine leaves ~47 GiB nominally spare.
- **Free memory does not predict the rate.** The slowest run of the six, 10.38,
  started with 73.5 GB free; the fastest, 17.84, started with 2.1 GB.
- **Streamed throughput is simply unstable — 10.4 to 17.8, a factor of 1.7 —
  where residency is not.** q2 measured 34.53 / 35.59 / 34.63 across the same
  three allocations. Any single streaming number on this page, including the
  18.61 quoted above, is one draw from a wide distribution.
- **1M is still worse, but on n=1.** 4.50 with the auto budget sits below the
  observed spread, and capping at 60 GiB moved it to 7.88 — consistent with the
  budget ignoring the allocation and the cache losing room, since 8.39 GiB of KV
  and 8.00 of buffers is a different order of intrusion than 1.88. It has not
  been repeated.

So the honest reading is that MXFP4 under streaming runs around 11 tok/s here,
occasionally 18 on a favourable first run, and the allocation does not matter up
to 128K. For q2 at full residency the allocation is free at any size; 1M only
costs the 97.15 GiB plan, which leaves ~31 GB for the desktop.
