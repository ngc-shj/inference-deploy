# ds4-server (DwarfStar) evaluations — GB10 / DGX Spark

Measured on the on-demand `ds4-server` service (`localhost:8000`), GB10 / 128 GB
unified memory, ~273 GB/s. Linked from [README.md](README.md). For the llama.cpp
router set on the same box see
[../llama.cpp/EVALUATIONS.md](../llama.cpp/EVALUATIONS.md) — the throughput law
there (**bandwidth ÷ resident bytes**) holds here too and explains most of what
follows.

Every model here takes most of the pool — V4 Flash as a ~81 GiB resident model,
V4.1 Flash as an 81–104 GiB SSD-streaming plan — so none can share it with the
llama.cpp router or vLLM, and every number below was taken with `ds4-server`
alone (the unit's `Conflicts=` evicts the others). The exception is the
2026-10-16 co-residency section. Qwen3.8-Flash-Next is the first ds4 model
small enough to share the pool, and it was measured beside the router.

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

## 2026-09-15 — DeepSeek-V4.1-Flash, SSD-streamed on one Spark

`deepseek-ai/DeepSeek-V4.1-Flash` (2026-09-10) is a new architecture, not a
weights swap. It is a 552B-parameter MoE built as a causal encoder–decoder,
with 8B parameters active on input and 16B on output, plus Engram tables.
DwarfStar added CUDA support in a04f46f (2026-09-13). antirez's Q2 is
**341 GiB**. 189 GiB of that is Engram, which is only ever read from disk. The
remaining 152 GiB of main weights still exceeds the 121 GiB pool, so on one
Spark V4.1 runs only with `--ssd-streaming`. Q4 (483 GiB), vision and DSpark
are not available on CUDA. The resident alternative is two Sparks over RoCE
tensor parallelism, which upstream measures at 21.9 tok/s.

Engine 6e4c285 ran with `--cuda --ssd-streaming --ctx 32768` against the same
five prompts: 3 repetitions, `temperature=0`, `seed=1234`, thinking at the
server default (high), `max_tokens` 6000, TTFT keyed off either token kind, and
`/var/lib/ds4/kv` emptied before each run. The four-configuration matrix above
does not apply. What varies is the expert-cache budget: automatic, then an
explicit `--ssd-streaming-cache-experts 64GB`. Swap was reset to 0 before the
64GB run; the automatic run started with 2.9 GiB already swapped.

| Median of 3 | V4.1 auto (80.12 GiB cache) | V4.1 **64GB** (56.88 GiB) | 0731 resident (L1) |
| --- | --- | --- | --- |
| decode, code generation | 8.92 | 7.70 | 14.80 |
| decode, code + tests (LRU) | 9.65 | 7.80 | 14.52 |
| decode, bugfix | 9.51 | 6.73 | 15.07 |
| decode, prose | 10.48 | 8.20 | 14.94 |
| decode after a 9.5k prompt | 9.39 | 6.80 | 13.66 |
| TTFT, 54–154-token prompts | 9–17 s | 12–26 s | — |
| cold prefill, 9 533 tok | 87 tok/s (109 s) | 77 tok/s (124 s) | 362–385 (10 458 tok) |
| continued prefill, 1 341 tok after an 8 192-tok disk-KV hit | 43 tok/s | 36 tok/s | — |
| planned resident (ds4 log) | 104.42 GiB | 81.18 GiB | 110–111 GiB used |
| swap | 2.9 → 8.7 GiB | peak 0.8 GiB | — |
| MemAvailable, minimum | ~5 GiB (end of run, not sampled) | 8 GiB (20 GiB outside the long prompt) | — |
| `NVRM ... NV_ERR_NO_MEMORY` lines | 8 | 0 | — |

**Findings**

- **Correct and stable.** The generated `merge_intervals` passes its doctests
  5/5, and the LRU cache passes its unittest 4/4. The bugfix answer names the
  missing leftover append. Reasoning and answer lengths were identical across
  all three repetitions and across both budgets. The LRU prompt that sent the
  54b36ed engine into a loop on 0731 finishes here in 3 269 tokens.
- **Decode is ~0.6× the 0731 resident speed, and it is SSD-bound.** Cutting the
  cache from 80 to 57 GiB costs 14–29% on every workload. At 7–10 tok/s the
  thinking phase dominates the wall clock: the LRU answer took 6–7 minutes.
- **Short prompts are the cost users will feel.** Prompts under 256 tokens are
  prefilled 8 rows at a time at 6–10 tok/s, so a 54-token prompt waits 8–12 s
  before its first token. A chat pays this on every turn. The disk KV cache
  only helps long shared prefixes: an 8 192-token aligned hit cut a 9.5k
  prompt's TTFT from 110 s to 32 s.
- **The automatic budget over-commits this box.** It sizes the cache to 80% of
  the CUDA working set as if nothing else were running. With the desktop and
  containers present, it pushed swap up 5.8 GiB, and the first large prefill
  logged 8 NVRM OOMs at `moe gateup y-indirect q8 staging engage`. ds4
  recovered and completed the request, but it sets `oom_score_adj=1000` on
  itself. The explicit 64GB budget logged no NVRM lines and kept swap under
  1 GiB.
- **`LimitMEMLOCK` is irrelevant on CUDA.** V4.1's encoder-residency path
  `mlock`s expert pages only on Metal; `ds41_encoder_acquire` returns
  immediately off Apple. It was briefly added to the unit on the opposite
  assumption.
- **Disk is the entry fee.** Fitting the 341 GiB file meant deleting the 0731
  model set, two unused container images, the pip/npm caches and a disabled
  gpt-oss-20b, and it still leaves 14 GiB free on the root filesystem.
  Upstream's `download_model.sh` also passes the stored HF token on the
  `hf download` command line (see README).

**Verdict**: deploy V4.1 Q2 as the on-demand, quality-first engine, with
`--ssd-streaming-cache-experts 64GB`. It is not an interactive replacement for
the resident models: 7–8 tok/s and a 12–26 s first token rule that out. Rolling
back to 0731 means re-downloading 81 GiB; the old engine is kept at
`/opt/ds4/ds4-server.e34a808`. Revisit if upstream speeds up short CUDA SSD
prefills, or if a second Spark makes resident TP possible.

---

## 2026-10-16 — GLM-5.3-Flash and Qwen3.8-Flash-Next Q2, resident on one Spark

Two more ds4-only GGUFs from antirez. Both fit resident, so neither needs SSD
streaming:

- [`antirez/glm-5.3-flash-gguf`](https://huggingface.co/antirez/glm-5.3-flash-gguf)
  is the Q2 build of `zai-org/GLM-5.3-Flash` (2026-08-26, MIT). That model is
  320B total with 18B active. Its layers mix KDA linear attention with DSA
  sparse attention, and it carries an embedded MTP block and vision.
- [`antirez/qwen3.8-flash-next-gguf`](https://huggingface.co/antirez/qwen3.8-flash-next-gguf)
  is the Q2 build of Qwen3.8-Flash-Next. It packs the original 95.37 GiB BF16
  n-gram table into the GGUF, and ds4 reads that table from disk instead of
  holding it in memory. The same model's llama.cpp numbers are in
  [../llama.cpp/EVALUATIONS.md](../llama.cpp/EVALUATIONS.md) (2026-08-28).

**Setup.** Engine fc80bd6 was built with `make cuda-spark` in a detached
worktree (`~/ghq/github.com/antirez/ds4-main`) and run from there as the
login user on `127.0.0.1:8001`, so `/opt/ds4` (6e4c285) and the unit were not
touched. Each run used `--ctx 32768`, with no disk KV cache and the router
stopped. The exceptions are the max-effort row (`--ctx 393216`, see below) and
the co-residency section.

**Prompts.** The prompts are not this file's five-prompt matrix:

- `merge_intervals`, with its doctests executed.
- An LRU cache plus a unittest, executed.
- The 8-item keigo probe from the llama.cpp files.
- A four-paragraph prose answer.
- A ~27–32k-token record lookup.

Every row ran 3 times at `temperature=0` and `seed=1234`, with thinking off
unless a row says otherwise. TTFT was keyed off either token kind. The keigo
items were re-typed for this run, so they are not byte-identical to earlier
entries. The resident Qwen3.6-35B-A3B took the same prompts in the same
session and scored 6/8, the figure recorded before.

| Median of 3 | GLM-5.3-Flash Q2 | Qwen3.8-Flash-Next Q2 | 35B-A3B *(router)* |
| --- | --- | --- | --- |
| file / resident weights | 89.88 / 89.87 GiB | 137.10 / **41.72 GiB** | 21.3 GiB |
| planned resident (ds4 log) | 93.21 GiB | **50.50 GiB** | — |
| decode, plain (code / prose) | 17.0 / 16.8 | 23.4 / 23.5 | — |
| decode, `--mtp` (code / prose) | 17.6 / **12.2** | **36.3 / 31.1** | 102–108 / 57–60 |
| prefill, long prompt | ~460 tok/s (26 754 tok) | ~755 tok/s (31 811 tok) | — |
| keigo, thinking off | **8/8** | 7/8 | 6/8 |
| keigo, thinking on | 7.5/8 (High) | 8/8 (3 of 4 runs; see below) | — |
| `merge_intervals` doctests | 6/6 | 5/5 | 5/5 |
| LRU unittest, thinking off | **fails 3/3** (`import unittest` missing; 10/10 with it) | 9/9 | 8/8 |
| long-context lookup | correct | **wrong** (answers 0, misses 1009) | — |

**Findings**

- **Neither model is a speed candidate.** Plain decode is 17 and 23 tok/s
  against the router's 102–108. The ds4 GLM figure matches upstream's 14.35
  tok/s Spark QA number. The Flash-Next figure is above the 17.3 / 19.9 tok/s
  that upstream's Spark guide reports.
- **GLM's MTP is a loss on this box, and it changes greedy output.**
  `--mtp-timing` over 841 cycles shows 66% acceptance. A two-row verify costs
  95 ms against ~60 ms for one plain step, and each rejection adds a further
  69 ms of head+draft, so the net is 13.2 tok/s. Output also stops being
  identical at temperature 0. Keigo item 8 became 「社長が**おいえに**なりました」,
  which is not a word, in all three runs. Upstream's docs warn that
  verifier reduction order can make greedy output differ from plain decoding.
  On this model that difference corrupts the answer.
- **Flash-Next's MTP is free.** It gives 1.3–1.6× and byte-identical
  content on every prompt.
- **ds4 rewrites GLM's reasoning effort without saying so.** `low`, `medium`
  and `high` all render `Reasoning Effort: High`
  (`ds4_glm_reasoning_effort_text`). The vendor template does have `Low`. The
  vendor default, `max`, is also downgraded to High unless `--ctx` ≥ 393 216
  (`DS4_THINK_MAX_MIN_CONTEXT`). At `--ctx 32768` the "max" run was
  token-for-token the High run. A real max run at `--ctx 393216` (97.42 GiB
  planned) scored the same as High (keigo 7.5/8, doctests 6/6, LRU 12/12) but
  spent **16 756 tokens and 19 minutes** on the LRU prompt, against 1 526
  tokens and 96 s at High.
- **GLM leads on Japanese with thinking off.** It scored 8/8 in all three
  runs, including 「拝見いたします」 and 「いらっしゃいました」, the two items the
  router's models miss. With thinking on it dropped to 「見られましたか」 on
  item 1. That is a valid but weaker honorific, scored ½.
- **Flash-Next with thinking on lost its answer once.** In 1 of 4 runs it
  finished inside `<think>` and returned an empty `content`, with the correct
  list sitting in `reasoning_content`. The other three runs scored 8/8. A
  client that reads only `content` will see this.
- **Scoring note.** The first pass marked 「ご覧いただけますか」 and
  「いらっしゃった」 wrong; both are correct honorifics. The table above uses
  the rescored figures.

### Co-residency with the llama.cpp router

The `Conflicts=` in `ds4-server.service` was written for models that took the
whole pool (see the top of this file). It is a policy, not something ds4
enforces. ds4 refuses only a second ds4 process. With 41.72 GiB resident,
Flash-Next is the first ds4 model that could share the pool.

The test set the router to its startup set only: the 35B-A3B at `ctx-size
262144`, ~47 GiB used. ds4 Flash-Next `--mtp` ran alongside it from the
worktree.

| tok/s (code / prose) | alone | co-tenant idle | both generating |
| --- | --- | --- | --- |
| 35B-A3B | 107 / 58 | 107 / 60 | **27 / 15** |
| Flash-Next | 37 / 31 | 37 / 31 | **23 / 20** |

- **It fits.** The pair used 98 GiB with 26 GiB available, and swap did not
  move.
- **NVRM lines appear only at startup on a tight pool.** Seven
  `NV_ERR_NO_MEMORY` lines came while ds4 was loading, and none came during
  generation. The solo GLM starts (93–97 GiB) logged them too. The solo
  Flash-Next start did not.
- **An idle co-tenant costs nothing; a busy one costs a lot.** While both
  generate, the 35B-A3B falls to a quarter of its speed and Flash-Next to
  ~60%. The two together make ~50 tok/s, which is less than the 35B-A3B alone.
  Why the router loses more was not investigated.
- **The router's on-demand models break the budget.** Loading the 27B adds
  ~15 GiB and would not fit. ds4 sets `oom_score_adj=1000`, so ds4 is the
  process that dies.

**Verdict**: neither model is adopted as resident.

- GLM-5.3-Flash Q2 is a candidate for the on-demand slot. It is the best
  Japanese result on these boxes with thinking off, but at 17 tok/s and
  90 GiB it is not interactive. Run it without `--mtp`, at High effort.
  Max effort needs `--ctx 393216` and costs 10× the tokens for no measured
  gain.
- Flash-Next Q2 on ds4 roughly matches llama.cpp's IQ1_S on speed (36 vs 33
  tok/s, now with MTP) and uses 17 GiB less memory.
- Co-hosting Flash-Next with the router works for occasional use. Doing it
  would mean dropping `Conflicts=` and capping the router to its startup set.
  That is not done here.

Not measured: GLM through llama.cpp (its support merged on 2026-09-30, and a
third party reports 17.7 tok/s at Q2_K_XL), batched serving, and long-horizon
agent use.

**Where the files live**: both GGUFs are in `~/ghq/github.com/antirez/ds4/gguf`,
not `/var/lib/ds4/models`, and both are SHA256-checked against the HF LFS oids.
Together they take 227 GiB.

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
