# Model evaluations (macOS / Apple Silicon — MLX)

Measured on a MacBook Pro **M5 Max, 128 GB unified memory** (~546 GB/s LPDDR5X)
via [`mlx-lm`](https://github.com/ml-explore/mlx-lm). This is a *separate
runtime lineage* from the GB10 / DGX Spark box documented in
[EVALUATIONS.md](EVALUATIONS.md): there the engines are CUDA-native (vLLM,
llama.cpp Metal is not in play); here everything runs on MLX's Metal kernels.
Cross-reference the two rather than merging them — the same quant format can win
on one and lose on the other.

## Why the format ranking flips vs GB10

Decode is bandwidth-bound on both boxes (active-parameter bytes ÷ memory
bandwidth), but the *fastest 4-bit format differs by hardware*:

- **GB10 (Blackwell)**: NVFP4 is the Tensor-Core-native FP4 path, so it is the
  quickest — see the 2026-07-11 NVFP4 eval in [EVALUATIONS.md](EVALUATIONS.md).
- **Apple Silicon (MLX)**: there is no NVFP4 hardware path; all three 4-bit
  modes run through the same Metal quantized-matmul kernels, so the winner is
  simply whichever keeps the smallest resident set. NVFP4's group-16 + FP8
  block scales make it the *heaviest* of the three, so on MLX it is the
  *slowest*, not the fastest. The optimum inverts across hardware.

---

## 2026-07-11 — MLX 4-bit formats for Qwen3.6-35B-A3B (nvfp4 / mxfp4 / 4bit)

Trigger: NVFP4 was evaluated on GB10 (vLLM) the same day; verifying whether the
"NVFP4" checkpoint transfers to Apple Silicon. It does **not** transfer as a
file — but MLX has had a native `nvfp4` quantization *mode* since mlx 0.32, and
`mlx-community` publishes MLX-native NVFP4/MXFP4 conversions of the same model.
Single-stream streaming decode, `temp 0.2`, code prompt (LRU cache + tests),
400-token cap, 2 runs each; numbers are steady-state (run-to-run within ~1%).

| Checkpoint (`mlx-community/`) | MLX mode / group | peak mem | decode tok/s |
| --- | --- | --- | --- |
| `Qwen3.6-35B-A3B-mxfp4` | mxfp4 / 32 | 18.6 GB | **138–140** |
| `Qwen3.6-35B-A3B-4bit`  | affine / 64 | 19.7 GB | 137 |
| `Qwen3.6-35B-A3B-nvfp4` | nvfp4 / 16 | 19.7 GB | 129–130 |

Reference — GB10 vLLM `nvidia/Qwen3.6-35B-A3B-NVFP4`: 116–122 tok/s (code),
single-stream, from [EVALUATIONS.md](EVALUATIONS.md).

**Findings**

- **NVFP4 *does* run on MLX** — via `mlx-community/Qwen3.6-35B-A3B-nvfp4`
  (`quantization.mode == "nvfp4"`, group_size 16). The nvidia/Unsloth
  *safetensors* NVFP4 checkpoints do **not** load (see the compatibility note
  below); the working path is the MLX-native re-quantization.
- **On MLX, mxfp4 ≈ 4bit > nvfp4** — the opposite of GB10. All three use the
  same Metal kernels, so decode tracks resident bytes: mxfp4 (18.6 GB) is
  fastest, nvfp4 (group-16 + FP8 scales, 19.7 GB) is the heaviest and slowest.
- **M5 Max single-stream beats GB10 single-stream** here (130–140 vs 116–122
  tok/s) — the M5 Max's wider LPDDR5X bandwidth shows directly. This is a
  single-user comparison only; GB10's advantage is batch concurrency, which was
  never the point of these numbers.
- **Correctness not scored** — with a 400-token cap the model spends the budget
  on reasoning (thinking mode; `/no_think` is *not* honored by `mlx-lm`, see
  below), so the runs measure decode speed, not code quality.

**Compatibility notes (the version matrix matters)**

- **Architecture**: `Qwen3.6-35B-A3B` reports `model_type: qwen3_5_moe`. Support
  landed in **mlx-lm 0.31.x**; older mlx-lm (0.29.x) fails at load with
  `Model type qwen3_5_moe not supported`.
- **`nvfp4` mode**: added in **mlx 0.32**; mlx 0.29 only knows `affine` / `mxfp4`.
- **transformers pin is the trap**: mlx-lm 0.31.3 declares `transformers>=5.0`,
  but 5.13 breaks its `AutoTokenizer.register(...)` call and 4.56 lacks the
  `TokenizersBackend` tokenizer class this model needs. **transformers 5.0.0**
  is the working sweet spot. Python 3.12.
- **nvidia safetensors NVFP4 (`quant_method: modelopt`) is not loadable by
  mlx-lm** — there is no `modelopt` branch in mlx-lm's quant dispatch. Use the
  `mlx-community` MLX-native conversion instead.

**Verdict**: on Apple Silicon, **`mlx-community/Qwen3.6-35B-A3B-mxfp4`** is the
throughput pick (fastest + smallest); `-4bit` is an effectively-equal fallback.
NVFP4 is worth keeping only for cross-hardware quality parity with the GB10
default — on MLX it costs ~7% decode for no speed benefit. For a thinking-off,
OpenAI-compatible endpoint that matches this repo's CUDA deployments, serve it
through `vllm-mlx` (next section).

---

## 2026-07-11 — Serving MLX-NVFP4 via `vllm-mlx` (thinking control + OpenAI API)

`mlx-lm`'s bare `generate` loop has no thinking/no-think toggle, so on
Qwen3.6-35B-A3B a 400-token cap is fully consumed by the reasoning preamble and
no code is emitted. [`vllm-mlx`](https://qiita.com/yosim/items/bbc8671d4295139c6e6d)
(PyPI `vllm-mlx`, 0.4.0) wraps the same MLX weights in an OpenAI-compatible
server with a real reasoning parser. Verified against the same
`mlx-community/Qwen3.6-35B-A3B-nvfp4` weights (already cached), Python 3.12:

```sh
vllm-mlx serve mlx-community/Qwen3.6-35B-A3B-nvfp4 \
  --host 127.0.0.1 --port 8000 --reasoning-parser qwen3
```

Port 8000 matches the vLLM and ds4 deployments in this repo; ds4-macos also
defaults to 8000, so pick a different `--port` if you run both on one Mac.

Toggle thinking per request with `chat_template_kwargs: {"enable_thinking": …}`:

| Request | completion tokens | decode tok/s | output |
| --- | --- | --- | --- |
| `enable_thinking: false`, 400 cap | 400 (then 181) | ~112 | correct LRU code, **no reasoning** |
| `enable_thinking: true`, 2000 cap | 2000 | 118 | reasoning + full rate-limiter + asserts |

**Findings**

- **thinking-off works here where `mlx-lm` couldn't** — with
  `enable_thinking:false` the model emits code directly (`s[::-1]`, then a
  full `lru_cache_decorator` with asserts). The flag is honored by the served
  chat template, not by a client-side string like `/no_think`.
- **Qwen3.6's reasoning is *inline*, not tag-delimited** — with thinking on,
  the "thinking process" appears in `content`, and `reasoning_content` stays
  empty even under `--reasoning-parser qwen3`. The parser strips a `<think>`
  block this model doesn't emit; budget a large `max_tokens` for thinking-on.
- **Serving overhead is small** — ~112–118 tok/s through the HTTP/OpenAI path
  vs ~129–130 for bare `mlx-lm` on the same NVFP4 weights. The convenience
  (API parity with the vLLM/llama.cpp deployments, per-request thinking,
  correct code within the token budget) is worth the ~10–15%.
- **Version note**: `vllm-mlx` 0.4.0 pulls `transformers 5.12.1` and drives
  `mlx-lm 0.31.3` cleanly — a *different* working pin than bare `mlx-lm`
  (which needed `transformers 5.0.0`). Let `vllm-mlx` own its venv.
- `vllm-mlx serve` also exposes `--enable-mtp`, KV-cache quantization,
  prefix cache, and continuous batching — the knobs to reach GB10-parity
  serving flags, not exercised in this pass.

**Verdict**: for interactive/agent use on Apple Silicon, **serve via `vllm-mlx`
with `--reasoning-parser qwen3`** and drive thinking per request; use bare
`mlx-lm` only for raw single-stream throughput measurement.

---

## 2026-07-11 — llama.cpp (Metal) vs vllm-mlx (MLX), same model, OpenAI API

Which serving engine is faster on Apple Silicon for the same model at the same
bit width? llama.cpp built from source with `-DGGML_METAL=ON` (upstream
`ggml-org/llama.cpp`, `llama-server`) vs `vllm-mlx serve`. Same M5 Max, same LRU
code prompt, `enable_thinking:false`, 400-token cap, both driven over their
OpenAI `/v1/chat/completions` endpoints — a *symmetric* comparison (not
`llama-bench` vs a Python call). Formats differ because the engines differ: GGUF
Q4_K_XL for llama.cpp, MLX mxfp4 for vllm-mlx — same model, same ~4-bit class.
Both servers were resident during the run. Median of 3 steady-state runs after a
warmup.

| Engine | Format | size | decode tok/s |
| --- | --- | --- | --- |
| vllm-mlx (MLX) | mxfp4 | 18.6 GB | **129** |
| llama.cpp | GGUF Q4_K_XL | 21.3 GB | 87 |

For reference, engine-native single measurements agree: `llama-bench` tg400 =
95 tok/s; bare `mlx-lm` = 138–140.

**Findings**

- **vllm-mlx is ~1.5× faster than llama.cpp/Metal here** (129 vs 87 tok/s),
  same model, both over the OpenAI API. Both emit correct LRU code — no quality
  gap visible on this task.
- **Same bandwidth law as everything above.** mxfp4 keeps 18.6 GB resident vs
  GGUF Q4_K_XL's 21.3 GB, and MLX's Metal quantized-matmul kernels are more
  efficient than llama.cpp's Metal backend for this MoE. Lighter resident set +
  tighter kernels → faster decode on the bandwidth-bound M5 Max.
- **Build**: `cmake -S llama.cpp -B build-metal -DGGML_METAL=ON -DLLAMA_CURL=ON`
  then `--build --target llama-server`; backend reports `MTL,BLAS`. Neither side
  used MTP spec-decode, so this is the plain-decode floor for both.

**Verdict**: on Apple Silicon, **vllm-mlx (MLX) beats a Metal-enabled
llama.cpp** at equal bit width for single-stream decode. Prefer vllm-mlx for MLX
checkpoints; llama.cpp/Metal remains the path for GGUF-only models or llama.cpp
features MLX lacks.

---

## 2026-08-19 — Qwen3.8-27B (dense, hybrid, VLM) vs resident 35B-A3B

First 27B dense evaluated on this box. Prompted by
[docs/QWEN3.8-27B-PREP.md](../docs/QWEN3.8-27B-PREP.md), which predicted 50–70
tok/s here and named `reasoning_effort` as the deciding axis. Neither held up.
Same `merge_intervals` prompt and harness as the GB10 lineage, no-think,
instruct sampling, run 1 discarded.

| Model | Format | resident | decode tok/s |
| --- | --- | --- | --- |
| `Qwen3.8-27B-mxfp4` | mxfp4 (14 GB on disk) | 8.6 GB | **34.9** |
| `Qwen3.8-27B-4bit` | affine/64 | — | 32.7 |
| `Qwen3.6-35B-A3B-mxfp4` *(resident, re-measured same day)* | mxfp4 | 17.8 GB | **138.7** |

The baseline reproducing 138.7 against the 138–140 recorded on 2026-07-11
is what makes the 34.9 trustworthy: same script, same day, same box.

**Quality vs the resident model** — everything mechanically scorable came out
level, exactly as the prep doc warned it would:

| Axis | Qwen3.8-27B | resident 35B-A3B |
| --- | --- | --- |
| Coding (doctests) / agent loop | 4/4; solved in 2 steps | same |
| Harder verifiable set, thinking OFF and ON (see [EVALUATIONS.md](EVALUATIONS.md)) | 9/9 both modes | 9/9 |
| Long-context needle retrieval, to 82,848 prompt tokens | correct at every depth | not measured |
| Vision (synthetic images: digits, count, colour) | **3/3** | n/a |
| **Japanese honorifics** (5 repeats of one 尊敬語 rewrite) | **1/5** | **5/5** |
| Japanese, 5 mechanically-scored tasks | 3/5 | 4/5 |

**Japanese is the only deficit anything here could measure**, and the failures
are not near-misses: 「お見になりました」 twice (not a Japanese form at all) and
「拝見された」 (humble form applied to a superior's action). The resident model
wrote 「ご覧になった」 every time. Independent Japanese coverage of this model
reports the same shape of problem — Simplified-Chinese bleed, and losing to
Gemma4 26B/12B on Japanese — so this is the model, not the harness.

On every other axis it is the resident model's equal, and the public verdict on
it is strongly positive. That verdict rests on open-ended generation quality and
long-horizon agentic work, which need a judge; nothing here provides one. "No
difference measured" is a statement about this harness.

**Findings**

- **The bandwidth law holds, the prep doc's arithmetic did not.** 27B dense at
  4 bits keeps ~13.5 GB of active weights against the MoE's ~2 GB; 138.7 / 34.9
  = 4.0× is the ratio that predicts. The 50–70 tok/s estimate assumed the MoE's
  penalty was milder than it is.
- **MTP buys nothing here, and the runtime is why** (32.4 with vs 32.7 without,
  same binary and model dir). `vllm_mlx/engine/simple.py` logs "Native mlx_lm
  MTP currently ignores num_draft_tokens; effective speculative draft depth
  remains 1" — at depth 1 the head's forward pass costs about what the extra
  token saves. This is not the model: the *same* MTP head gave **2.2×** through
  llama.cpp on GB10 (11.7 → 26.2 tok/s, acceptance 0.89–0.92, mean accepted
  length 2.8 — see [EVALUATIONS.md](EVALUATIONS.md)). Third-party claims of
  ~2.2× on Apple Silicon come from MTPLX, a different runtime, and are
  consistent with that figure rather than with anything vllm-mlx can do today.
- **Loading a local directory corrupts output on vllm-mlx 0.4.0.** The same
  checkpoint serves correctly by repo name (mlx_lm path, `MLLM=False`) and
  returns fluent nonsense from a local path (mlx_vlm path, `MLLM=True`).
  **Fixed in 0.4.1.** This matters beyond MTP: vision only routes on the MLLM
  path, so on 0.4.0 the model's vision half is unreachable by either route.
- **Standalone MTP sidecars need two conversions.** `mlx-community/
  Qwen3.8-27B-MTP-{4,8}bit` ship bare tensor names, but the injector keeps only
  keys prefixed `mtp.` (the layout its own `add_mtp_weights_qwen35.py` writes)
  and reads group_size/bits from the *base* model's config. Prefixing the keys
  and dequantizing the head to BF16 makes it load — full precision is what the
  injector's own comment asks for.
- **Long context is limited by prefill, not accuracy.** Retrieval was correct at
  every depth up to 82,848 prompt tokens, but that prompt took 288 s to read
  (~288 tok/s prefill). At that rate the native 262144 window costs ~15 minutes
  before the first token. Two runs returned HTTP 504 against vllm-mlx's 300 s
  request timeout, not a model failure.
- **Tool calling needs `--enable-auto-tool-choice --tool-call-parser qwen3_coder`**
  (the first flag errors without the second). Without them an agent driver gets
  a clean, silent no-op — opencode ran four turns and changed nothing.

**Verdict**: not adopted **on speed and on Japanese** — 4× slower than the
resident model, and the only model here that cannot reliably produce 尊敬語.
Vision is the one capability it adds, and reaching it requires upgrading
vllm-mlx to 0.4.1.

`reasoning_effort` was wired correctly (an invalid value raises from the chat
template) but produced *shorter* reasoning at `xhigh` than at `low`, with no
accuracy difference. **That was the task, not the knob**: published traces show
this model spending 22k reasoning tokens on a single SVG at `xhigh`, so a
question answered in ~2k characters was never going to separate the levels. The
prep doc's "only deciding axis" was not tested at a difficulty where it could
decide anything.

---

## 2026-08-28 — Qwen3.8-Flash-Next on Metal: the `qwen4exp` PR needs no new kernels

Cross-box run of the *same file*: unsloth `UD-IQ1_S` (67.56 GiB, 3 shards, byte-identical
to the copy on gx10-a9c0), same commit `b8bdf73` of llama.cpp
[PR #27742](https://github.com/ggml-org/llama.cpp/pull/27742), `c = 262144`, no
spec-decode, same bench script. Built into a detached worktree with
`-DGGML_METAL=ON`; the normal checkout was left alone.

| Box | decode | prefill (4189 tok) |
| --- | --- | --- |
| gx10-a9c0 (GB10) | 33.3 | 719 |
| **z1mn (M5 Max)** | **36.5** | **884** |
| ratio | 1.10x | 1.23x |

**Findings**

- **The PR touches no ggml backend and needs nothing from Metal that is not
  already there.** All 21 files it changes are `src/`, `gguf-py/`, `conversion/`
  and tests — the `qwen4exp` graph is built from stock ops. Every op it calls has
  a Metal path, including the two that look missing until you follow them:
  `ggml_repeat_4d` is `GGML_OP_REPEAT`, and `ggml_rope_multi` is `GGML_OP_ROPE`
  with mrope (`kernels/rope.metal`). It built and ran unmodified.
- **The 1.35x box ratio from the 35B-A3B does not carry over.** That figure —
  87 tok/s here on 2026-07-11 against 64.4 measured on GB10 the same week —
  predicted ~45 tok/s. The measurement is 36.5, a ratio of **1.10x**.
  *Superseded by the 2026-08-29 quant sweep below*: the explanation offered here
  ("this architecture does not collect the M5 Max's bandwidth advantage") was
  wrong — the comparison put an **i-quant** on this box against a **K-quant**
  baseline, and i-quants carry their own cost on Metal. Same file at IQ4_XS puts
  the box ratio at **1.29x**; the shortfall was the quant family, not the model.
- **Prefill is the Mac's stronger half here, not its weaker one** — 884 vs 719,
  23% ahead. The ~288 tok/s prefill recorded above is a different model on a
  different engine and does not generalise to this one.
- **Output correctness is unverified.** Token counts and throughput are sane and
  consistent with GB10, but nothing checked what the model actually wrote. IQ1_S
  is extreme quantisation, so a bad result would need separating from the quant
  before it could be blamed on Metal.

**Operational note — this box still runs one engine at a time.** The first run
reported 36.4 tok/s while the vllm-mlx agent still held Qwen3.8-27B-4bit: 72.5 GB
of weights plus 6.4 GB of KV on top of it drove ~10 GB of swap-out. Stopping the
agent and re-running changed **prefill by 15%** (770 → 884) and left **decode
untouched** (36.4 → 36.5) — mmap'd weights read steadily either way, while the
bursty prefill paid for the pressure. Check for a resident engine *and* watch
`sysctl vm.swapusage` across the load, not just free pages.

**MLX is not an option yet.** `mlx_vlm` 0.6.15 has no `qwen4_exp` at all (the
`*_flash` modules present are longcat and mimo). Reaching it needs mlx-vlm past
[#2040](https://github.com/Blaizzy/mlx-vlm/pull/2040) plus the unmerged
[#2045](https://github.com/Blaizzy/mlx-vlm/pull/2045), and vllm-mlx
[PR #735](https://github.com/waybarrios/vllm-mlx/pull/735), still a draft — into
the venv that currently serves this Mac. MLX checkpoints exist (86–113 GiB,
several carrying MTP, which no GGUF does), so it is the only route to testing MTP
for this model; #735's own numbers have that drafter *reducing* decode from 18.21
to 15.57 tok/s and breaking two of five strict tool calls, so the expected value
is low. Wait for the merges.

---

## 2026-08-29 — Flash-Next quant sweep on Metal: family beats bytes, and back-to-back runs lie

Prompted by the observation that **IQ-family quants are slow on Apple Silicon** —
which, if true, invalidated the 2026-08-28 box-ratio explanation above (an
i-quant here was compared against a K-quant baseline). Five quants of the same
model, same build (`b8bdf73`, PR #27742), `c = 65536`, no spec-decode, vllm-mlx
stopped.

Accepted values — **early-session positions only** (see the thermal note for why
that qualifier is load-bearing):

| Quant | Family | Bytes | decode | Confidence |
| --- | --- | --- | --- | --- |
| UD-IQ1_S | i | 72.5 GB | 36.9 | high (4 runs, ±1) |
| UD-Q2_K_XL | K | 78.9 GB | **38.6** | medium (one clean run) |
| UD-IQ3_XXS | i | 82.0 GB | 37.1 | medium |
| UD-Q3_K_XL | K | 90.0 GB | 34.7 | high (twice, spread 0.04) |
| UD-IQ4_XS | i | 93.7 GB | 35.0 | medium |

**Findings**

- **Back-to-back model benches on this MacBook are invalid — and `sudo purge`
  does not save them.** In two sweep attempts, later positions degraded
  monotonically regardless of quant, bottoming at **19.2 tok/s for a file that
  measures 36.9 fresh** (1.9x error); prefill fell in step (907 → 343), which
  page-cache effects cannot explain but sustained heat can. A 5-minute idle
  restored 36.4 exactly. The existing "discard run 1" practice is not enough
  here: **discard everything after the first model or two of a session**, and
  re-validate any suspicious number after a cooldown.
- **The quant family matters as much as the byte count.** Q2_K_XL is 8.7%
  *bigger* than IQ1_S and *faster* (38.6 vs 36.9) — impossible if decode were
  bytes-only. K-quants scale with bytes (~0.27 ms/token per GB, same behaviour
  as CUDA); the i-family's slope is far shallower (~0.07), i.e. **on Metal the
  i-quants are partly compute-bound in dequantisation, not purely
  bandwidth-bound**. The penalty is worst at the exotic low-bit end (IQ1_S runs
  ~12% behind the K-line at its size) and fades by IQ4_XS (on par with the
  K-line). So "IQ quants are slow on Apple Silicon" holds for IQ1/IQ2-class
  quants and largely washes out by IQ3/IQ4 — on this model and build.
- **The cross-box ratio is quant-dependent, which is what falsified the 08-28
  claim.** Same file, Mac/GB10: IQ1_S 1.11x, IQ4_XS 1.29x (35.0 vs 27.1, with a
  small context-length caveat — GB10 measured at 262144). CUDA's i-quant decode
  is bytes-linear, Metal's is flat, so the bigger the i-quant the more the Mac
  pulls ahead. No K-quant has been measured on GB10 yet; that point is queued.
- **Same-quant cross-machine, Q3_K_XL, short context**: 34.7 here vs 22.6
  reported on an M4 Max 128GB (third-party, same quant and engine lineage) —
  1.53x, a plausible generation gap now that the quant is held constant.

**Which quant for this box**: speed spans only 11% across a 21 GB range, so
bytes buy quality, not speed — take the highest-bpw file that fits. That is
**IQ4_XS (4.16 bpw effective) at `c = 65536`**, which grazes the default wired
limit; wanting the native 262144 context (KV 6.4 GB) means either raising
`iogpu.wired_limit_mb` or dropping to **Q3_K_XL**, the safe pick with
third-party agentic mileage (190/190 tool calls) on record. Quality across these
quants is otherwise unmeasured here, and the engine is still an unmerged PR —
this stays an experiment, not a deployment.

---

## 2026-08-29 — mlx-serve's external n-gram store: the intervention that proves the bottleneck

The quant sweep above established *that* Flash-Next decode is bytes-bound and the
n-gram table is the likely residual; [`ddalcu/mlx-serve`](https://github.com/ddalcu/mlx-serve)
(native Swift/Metal server, MIT) ships the intervention: its companion checkpoint
[`ddalcu/Qwen3.8-Flash-Next-MLX-Serve-4bit`](https://huggingface.co/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-4bit)
carries the 51B n-gram table as an **external 32 GB `ngram_table.bin`**, mmap'd
and gathered on the CPU (~16 rows/token) instead of living in the GPU-resident
set. Measured here on **v26.8.11-pre-release.1** (the stable brew formula,
26.8.10, predates `qwen4_exp` and dies with `MISSING WEIGHT:
model.embed_tokens.weight`), same prompts as every Flash-Next number in this
lineage, vllm-mlx stopped:

| Engine / quant | decode | prefill (4189 tok) |
| --- | --- | --- |
| **mlx-serve, MLX 4-bit + external n-gram** | **70.4–70.6** | 856–1499 (prefix cache moves it) |
| llama.cpp/Metal, best of five quants (Q2_K_XL) | 38.6 | ~900 |
| llama.cpp/Metal, closest quant class (Q3_K_XL) | 34.7 | 907 |
| GB10 llama.cpp, IQ4_XS *(ref)* | 27.1 | 693 |

**Findings**

- **Taking the n-gram table out of the weight stream nearly doubles decode**
  (34.7–38.6 → 70). That is the missing-bandwidth arithmetic from the GB10
  section made real: the "residual 1.38x" was the table, and an engine that
  gathers 16 rows on the CPU instead of streaming 32 GB per-token recovers it.
  This retires the llama.cpp-based "ties a dense 27B" verdict for Apple Silicon
  — on this box, through this engine, Flash-Next runs at 70 tok/s with vision
  and 262k context.
- **MTP is loaded but not wired** — `[qwen4] MTP head loaded (… spec wiring
  pending)`, and `--no-mtp` measures the same 70 tok/s, so both cases are serial
  decode. The model card's "78 tok/s with MTP" is not reproducible on this
  build; the repo's commit log shows the wiring in progress.
- **Consistency with the card**: 60 tok/s serial claimed on an M4 Max, 70
  measured here on the M5 Max — a 1.17x generation gap, in line with the 1.53x
  seen on llama.cpp between the same two chips being an upper bound.
- **Caveats**: pre-release binary (installed by hand from the GitHub release;
  brew's stable lags), single-session numbers, quality unmeasured — same
  standing as every other Flash-Next figure in this file. The checkpoint is
  ~99 GB on disk but the GPU-resident set stays near 70 GB by design, and swap
  stayed flat through both cases.

**Verdict**: first Flash-Next configuration on any box here that clears the
"usable, not just runnable" bar on speed. Worth re-evaluating against the
resident vllm-mlx Qwen3.8-27B once mlx-serve's MTP wiring and a stable 26.8.11
land — at 70 tok/s serial the remaining questions are quality, not throughput.

---

## 2026-08-30 — Flash-Next on 40GB of consumer VRAM (cross-box coda)

Not an Apple Silicon result, but it belongs with the other Flash-Next numbers.
The same unsloth `UD-IQ1_S` file, same prompts, on **RTX 4090 (24GB) + RTX 4090
Laptop (16GB)** under WSL2, llama.cpp from PR #27742 built for sm_89. The
question the Metal work raised: if taking the 51B n-gram table out of the
GPU-resident set is what makes this model fast, does that also let a 40GB box
run a 180B model at all?

| Box | Engine | decode |
| --- | --- | --- |
| M5 Max 128GB | mlx-serve (external n-gram) | **70.4** |
| M5 Max 128GB | llama.cpp/Metal | 36.9 |
| GB10 128GB | llama.cpp/CUDA | 33.3 |
| **4090 + 4090 Laptop, 40GB** | **llama.cpp/CUDA, `-ot` PLE→CPU** | **21.5** |

**Findings**

- **It runs.** 180B on 40GB of VRAM, at 65% of the GB10's speed, by pushing
  `per_layer_token_embd` (26.8 GiB, one tensor) and eight layers' experts to
  system RAM. llama.cpp already treats that tensor specially —
  `per_layer_token_embd.weight (size = 27465 MiB) lazy read enabled` — so the
  `-ot` route is doing the same thing mlx-serve does structurally.
- **The ceiling is ~5 GiB away.** Keeping every expert on GPU needs 40.03 GiB
  against 40.9 GiB of cards, and KV plus compute buffers do not fit in the
  0.9 GiB left. Each layer of experts pushed to DDR5 costs measurably: 8 layers
  → 21.5 tok/s, 12 → 15.5, 24 → 11.8.
- **How the offload is distributed matters more than how much.** See the `-ot`
  bullet in [README.md](README.md): a contiguous 24-layer offload measured 5.2
  tok/s, the same 24 layers spread across the index measured 11.8. That was
  three wasted runs before the placement was printed at `-lv 4`.

**Verdict**: viable for experiments on a 40GB box, not for daily use — 21.5
tok/s with 47 GiB streaming from system RAM is the shape of the thing, and no
placement fixes that. The interesting number remains mlx-serve's 70: the gap
between it and every llama.cpp figure here is the n-gram table, not the box.

**Postscript — 21.5 is this engine's ceiling, not the model's.**
[FreeToken](https://github.com/FlashML-org/FreeToken) merged `qwen4_exp` support
([#257](https://github.com/FlashML-org/FreeToken/pull/257), 2026-08-28 — the
first Flash-Next implementation to land in a mainline anywhere) and reports
**36 tok/s on a single RTX 4090 (24GB)** and 65 on a 5090, against the 21.5
measured here on *two* 4090s. Its design description is the same conclusion
reached from the other direction: *"PLE n-gram embedding (47.7 GiB table, kept
in pinned host memory, UVA gather)"* — the table off the GPU by construction,
which is what `-ot` was doing by hand and what mlx-serve ships as an external
file. Three independent implementations now treat that table as the thing to
move.

The catch is where the real constraint sits: FreeToken wants **~111 GiB of
pinned host RAM** (63 GiB expert banks + 48 GiB PLE) and recommends 128 GB. The
4090 box here has 48 GB, so it cannot run that path at all. **Host RAM, not
VRAM, is what gates this model** — which reframes every number in this file:
the 128GB boxes were never winning on GPU, they were winning on the table.
