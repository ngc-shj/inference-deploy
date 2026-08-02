# ds4-server (DwarfStar) evaluations — GB10 / DGX Spark

Measured on the on-demand `ds4-server` service (`localhost:8000`), GB10 / 128 GB
unified memory, ~273 GB/s. Linked from [README.md](README.md). For the llama.cpp
router set on the same box see
[../llama.cpp/EVALUATIONS.md](../llama.cpp/EVALUATIONS.md) — the throughput law
there (**bandwidth ÷ resident bytes**) holds here too and explains most of what
follows.

DeepSeek V4 Flash is a single ~81 GiB resident model; it cannot share the pool
with the llama.cpp router or vLLM, so every number below was taken with
`ds4-server` alone (the unit's `Conflicts=` evicts the others).

## Method

Four configurations, changing exactly one thing at a time, all with identical
prompts, budgets, sampling and seed:

| | engine | model | DSpark |
| --- | --- | --- | --- |
| L0 | e34a808 (2026-06-15) | Preview | — |
| L1 | e34a808 | **0731** | — |
| L2 | **54b36ed** (2026-07-28) | 0731 | — |
| L3 | 54b36ed | 0731 | **on** |

Five prompts (`merge_intervals` + doctests; LRU cache + unittest; merge-sort
bugfix; a four-paragraph prose explanation; a ~10.5k-token prompt for prefill),
3 repetitions each, `temperature=0`, `seed=1234`, thinking left at its default
(on), `--ctx 131072`, discarded warm-up request first and a repeat of the first
prompt last as a drift check.

Three things had to be controlled explicitly, each of which silently corrupted a
run before it was pinned down:

- **Thinking tokens stream as `delta.reasoning_content`, not `delta.content`.**
  Keying TTFT off the first `content` chunk reports the entire reasoning phase as
  prefill latency and divides all tokens by only the post-thinking window — it
  inflated decode by ~2× and produced a literal `1e11 tok/s` for a prompt whose
  answer never started. TTFT must key off the first token of *either* kind.
- **The on-disk KV cache survives model swaps** and is `cross-quant=accept`, so
  a 10 240-token prefix computed under Preview weights was loaded and used under
  0731 weights (`kv cache hit text tokens=10240 ... quant=2`). Prefill has to be
  measured with `/var/lib/ds4/kv` emptied, and a production model swap should
  clear it too.
- **`--warm-weights` is not free headroom.** It was added for measurement
  hygiene and is *not* what caused the OOMs below, but it does force the whole
  mapped set resident at startup on a box with no margin.

`~/a.sh` (not in this repo) wraps the stop → change → clear KV → start → wait
cycle for these switches.

---

## 2026-08-02 — DeepSeek-V4-Flash 0731 vs Preview, DwarfStar engine bump, DSpark

`deepseek-ai/DeepSeek-V4-Flash-0731` is the official release superseding the
preview, same architecture, MIT. Vendor benchmarks move a long way:
Terminal-Bench 2.1 **61.8 → 82.7**, DeepSWE **7.3 → 54.4**, NL2Repo 39.4 → 54.2
— above GLM-5.2 and within reach of Opus-4.8. Quantized by antirez as
`...-chat-v2-imatrix-0731.gguf` (86.7 GB / 80.76 GiB), the same recipe as the
Preview file already deployed, so this is a drop-in weights swap.

Unsloth also published [UD quants of the same
model](https://huggingface.co/unsloth/DeepSeek-V4-Flash-0731-GGUF) and mainline
llama.cpp merged `deepseek4` (PR #24162, dedicated `llama-kv-cache-dsv4.cpp`) —
that path is untested here and has **no MTP/DSpark** (`src/models/deepseek4.cpp`
has no nextn tensors), so it would trade speculative decoding for router
integration.

| Workload (decode tok/s, median of 3) | L0 old+Preview | L1 old+0731 | L2 **new**+0731 | L3 new+0731+DSpark |
| --- | --- | --- | --- | --- |
| code generation (`merge_intervals`) | 14.83 | 14.80 | **16.58** | 14.74 |
| code + tests (LRU cache) | 14.46 | 14.52 | **16.54** | 13.74 |
| bugfix (merge sort) | 14.86 | 15.07 | **16.70** | 14.35 |
| natural language (prose) | 14.92 | 14.94 | **16.67** | 15.38 |
| generation after a 10.5k prompt | 13.60 | 13.66 | **14.33** | 12.31 |
| cold prefill, 10 458 tok | **385.2** | — | 362.4 | 320.8 |
| resident (`free` used, of 121 GiB) | 111 | 111 | **110** | 117 |
| drift recheck vs first row | 14.70 | 14.84 | 16.65 | 14.92 |

**Findings**

- **0731 is a free quality upgrade — decode is unchanged.** Same quant, same
  architecture, so 14.8 tok/s either way and cold prefill within 3%. Output is
  correct: the generated `merge_intervals` passes its own doctests 6/6, and the
  merge-sort answer names the real defect ("the remaining elements from either
  `left` or `right` are never appended") and fixes it.
- **It thinks considerably more, and that is the real cost.** At equal budgets
  0731 was truncated where Preview finished: code generation 1 643 → 2 363 chars
  of reasoning (answer 1 395 → 581 chars, cut mid-expression at
  `intervals.sort(key`), and prose spent all 600 tokens reasoning and emitted a
  **zero-character answer** where Preview answered in 600. Given 2 500–5 000
  tokens it completes everything; prose needed 2 154 tokens against Preview's
  600. **Raise `max_tokens` client-side before swapping**, or answers arrive
  truncated at settings that used to work.
- **The engine bump is worth +11–14% decode and costs correctness on greedy.**
  61 upstream commits (20 ROCm, 15 GLM, and among the rest `Add resident IQ2 MoE
  sorted-path isolation`, which touches exactly the path this quant uses) lift
  every workload by 11–14% at unchanged residency, and cost 6% of cold prefill.
  But on the LRU prompt the new engine falls into a degenerate repetition loop:
  407 sentences of reasoning, **72 unique, one four-sentence block repeated 85×**,
  still looping at 10 000 tokens / 669 s. The old engine answered 4/4 on the same
  prompt (reasoning 1.6k–14.9k chars, answer always ~3.2k chars). Sampling breaks
  the loop — `temperature=1.0, top_p=0.95` escaped it, but needed 7 199 tokens
  where the old engine took 2 171–4 989. One prompt of five; the other four are
  fine on the new engine.
- **DSpark loses on every workload here — −8% to −17%.** It is not
  workload-dependent the way Laguna's DFlash was (code +57%, prose negative);
  it is uniformly negative, because the 5.57 GiB support model costs **+7 GiB
  resident** (110 → 117 GiB) and on this box throughput tracks resident bytes.
  DFlash bought its +57% with a 2.2 GB draft; DSpark cannot pay for itself at
  3× the footprint. Prefill drops too (362 → 321 tok/s).
- **DSpark also destroys greedy determinism.** Without it, three repetitions at
  `temperature=0` were byte-identical (2 210 chars of reasoning, 702-char answer,
  every time). With it, the same three runs gave 2 901/2 702/2 803 chars and
  answers of 0/173/0 characters. `temperature=0` stops being a reproducibility
  guarantee — which matters both for evaluation and for any client relying on
  stable output. And DSpark *requires* greedy ("Sampled decoding does not use
  DSpark proposals"), so its only operating point is the one where the new
  engine loops.

**Verdict**: adopt **0731 on the old engine (e34a808), DSpark off** — the model
quality moves a long way for free, and both engine-side changes cost more than
they return. The engine bump is a genuine +12% held hostage by one reproducible
repetition loop; it has a minimal repro (single prompt, `temperature=0`, fixed
seed, deterministic) and is worth reporting upstream, after which it becomes a
clear win. Revisit DSpark only if the support model's footprint drops or the
box's memory pressure changes.

---

## The production context length no longer fits

`--ctx 1048576`, the deployed setting, **OOMs on load** and did so twice before
the cause was clear:

```
context buffers 22319.75 MiB (ctx=1048576, ...)
CUDA using managed KV cache for ctx=1048576 (kv cache 13.79 GiB,
  context buffers 21.79 GiB); this may degrade performance
kernel: NVRM: Out of memory [NV_ERR_NO_MEMORY] ... _memdescAllocInternal
```

Model 80.76 + KV 13.79 + context buffers 21.79 + a ~19 GiB baseline ≈ **135 GiB
against 121**. The June 21 journal shows the same setting serving 130k-context
tool-calling requests, so this is a regression in available headroom (driver
reservation, or simply more resident desktop/container load), not a config that
was never viable.

At `--ctx 131072` context buffers fall to 3.04 GiB, total residency is 110–111
GiB, and the `managed KV cache ... may degrade performance` fallback does not
trigger at all — so the shorter context is not only what fits, it avoids a
degraded path. **Pick a production ctx that measurably loads**; 1M is not it
today.

Two smaller notes from the same sessions:

- `ds4-server` sets `oom_score_adj=1000` on itself, so under pressure the kernel
  kills it first — a dev server started alongside is enough to take it out.
  `ps` RSS is useless for judging this (the model lives in CUDA managed memory;
  `ds4-server` shows ~1 GiB); use `free` and the NVRM lines in `dmesg`.
- `install.sh` installs `$SRC/ds4-server` on **every** run, `NO_BUILD=1`
  included, and repoints `$MODELS/ds4flash.gguf` at whatever `$SRC/ds4flash.gguf`
  resolves to. Swapping only the model, or only the binary, means doing it by
  hand — otherwise a model swap silently upgrades the engine too, or a stale
  checkout symlink silently reverts the model.
