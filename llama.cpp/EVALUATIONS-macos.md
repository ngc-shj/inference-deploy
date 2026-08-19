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
