# Qwen3.8-27B — desk study and run-up (z1mn / gx10-a9c0)

> **Superseded by measurement (2026-08-19). Results:
> [llama.cpp/EVALUATIONS.md](../llama.cpp/EVALUATIONS.md) (GB10) and
> [llama.cpp/EVALUATIONS-macos.md](../llama.cpp/EVALUATIONS-macos.md) (z1mn).
> Not adopted.** What this desk study got wrong, up front:
>
> - **Speed**: predicted 50–70 tok/s on z1mn → measured 34.9. Predicted 25–30
>   on GB10 → measured 7.8. §1's arithmetic assumed Q4; the run used FP8, twice
>   the bytes. The bandwidth law was right, the format assumption was not.
> - **Biggest risk**: "can vllm-mlx read it" (§3.1) was a non-issue. The real
>   wall was a vllm-mlx 0.4.0 bug that **corrupts output when a model is served
>   from a local directory** — fixed in 0.4.1, and vision is only reachable on
>   that same code path.
> - **Deciding axis**: `reasoning_effort` (§5) was wired correctly but produced
>   *shorter* reasoning at `xhigh` than at `low`, with no accuracy difference.
>   The axis that did separate the models was **Japanese honorifics** (1/5 vs
>   5/5 against the resident 35B-A3B).
> - **Startup**: FP8 does not boot without `VLLM_USE_DEEP_GEMM=0` — not
>   anticipated anywhere in §4.2.

Both boxes were offline (last seen ~1 day ago on Tailscale) when this was
written, so everything below is a **desk study from model cards and this
repository's own measurements** — not measured. Run-up steps are in §4;
llama.cpp build requirements in §6.

Written 2026-08-16. Upstream issue status moves, so re-check §6.3 before running.

---

## 0. Conclusion (up front)

| Box | First choice | Format | Size | Why |
| --- | --- | --- | --- | --- |
| **gx10-a9c0** (DGX Spark GB10) | `Qwen/Qwen3.8-27B-FP8` or NVFP4 | FP8 / NVFP4 + vLLM | ~28GB / ~20GB | Blackwell-native FP4; the only path where MTP spec-decode works |
| **z1mn** (M5 Max 128GB) | `mlx-community/Qwen3.8-27B-mxfp4` | MLX mxfp4 | 15.2 GB | mxfp4 measured fastest on MLX (EVALUATIONS-macos.md) |

**But the format is not the real question — the model being 27B *dense* is.**

---

## 1. Architecture (this decides everything)

From [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B):

- **dense 27B** (not MoE) → active params = 27B
- 64-layer hybrid: 48 × Gated DeltaNet (linear attn) + 16 × Gated Attention
- Gated Attention: Q 24 heads / KV 4 heads / head_dim 256
- native ctx 262144 (1M via RoPE scaling)
- has an MTP head; supports `reasoning_effort` (xhigh/medium/low)
- sampling: thinking `temp 1.0 / top_p 0.95 / top_k 20`,
  instruct `temp 0.7 / top_p 0.80 / top_k 20`

### Prediction from the bandwidth law — the important part

This repository's own numbers (EVALUATIONS.md, 2026-06-21): **Qwen3.6-27B, the
same 27B dense + hybrid shape, ran at 24.4 tok/s on GB10** while the resident
35B-A3B (MoE, active 3B) ran at 90.5. The 3.5× gap was confirmed structural,
not warm-up.

Qwen3.8-27B is the same 27B dense. **With ~17–18 GB of active bytes at Q4 it
should land around 25–30 tok/s on GB10** — far slower than the resident
35B-A3B. Ternary-Bonsai-27B (1.6-bit, 6.7 GB) still only reached 25.7 tok/s,
which says the 27B dense ceiling is not something quantization lifts
(EVALUATIONS.md, 2026-07-20).

The M5 Max has ~546 GB/s, roughly twice GB10, so mxfp4 at 15.2 GB should give
**around 50–70 tok/s** (35B-A3B mxfp4 does 138–140; active bytes here are ~4–5×
larger, so the drop should be proportional).

→ **There is no speed case for adopting this.** The only question worth testing
is whether quality clearly beats 35B-A3B.

*(Measured: 34.9 on z1mn, 7.8 on GB10 at FP8. See the note at the top.)*

---

## 2. Choosing the quantization

### gx10-a9c0 (GB10)

The [official vLLM recipe](https://recipes.vllm.ai/Qwen/Qwen3.8-27B) is the
most trustworthy source:

```
vllm serve Inferact/Qwen3.8-27B-NVFP4 \
  --tensor-parallel-size 1 --max-model-len 262144 \
  --kv-cache-dtype fp8 --reasoning-parser qwen3 \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
```
MTP is `--speculative-config '{"method":"mtp","num_speculative_tokens":3}'`.

- Minimum vLLM 0.17.0+ (some sources say NVIDIA ModelOpt NVFP4 needs 0.24.0+;
  **following this repository's track record, `vllm/vllm-openai:nightly` is the
  safe choice**)
- The recipe's NVFP4 is `Inferact/...`. The `unsloth/Qwen3.8-27B-NVFP4` variant
  is Unsloth Dynamic V3.0 (preview) with no vLLM version requirement on its card
  → **unknown quantity. Start with the official `Qwen/Qwen3.8-27B-FP8`, then try
  NVFP4** to minimise rework.
- **⚠ Do not use MXFP4 on NVIDIA** — stated in the recipe's Known Issues:
  vLLM's MXFP4 implementation lacks linear method support on NVIDIA devices and
  does not work as intended. Use NVFP4 on NVIDIA.

FP8 (`Qwen/Qwen3.8-27B-FP8`) is fine-grained fp8 at block size 128, ~28GB,
quality "nearly identical to the original". Comfortable in a 128GB pool.

### z1mn (M5 Max)

Measured ranking (EVALUATIONS-macos.md): **mxfp4 ≈ 4bit > nvfp4**. MLX has no
NVFP4 hardware path, so resident bytes translate directly into speed.

- `mlx-community/Qwen3.8-27B-mxfp4` — **15.2 GB, first choice**
- `mlx-community/Qwen3.8-27B-4bit` — equivalent alternative
- `mlx-community/Qwen3.8-27B-8bit` / `-bf16` — for quality comparison (slower,
  bandwidth-bound)
- **NVFP4 safetensors (unsloth/nvidia) will not load in MLX** — known; mlx-lm's
  quant dispatch has no modelopt branch. MLX-native conversions only.

---

## 3. Sticking points to check on the day (not resolvable on paper)

In priority order. **Any of these could cost the session.**

1. **Whether vllm-mlx can read Qwen3.8** — the biggest risk. The
   `mlx-community/Qwen3.8-27B-mxfp4` card names **`mlx-vlm`** as its loader,
   which is a different path from the proven `vllm-mlx` / `mlx-lm` one. The
   model is vision-capable (the unsloth GGUF ships `mmproj-*.gguf` too).
   vllm-mlx's models.md does not mention Qwen3.5/3.6/3.8 — but **that is most
   likely stale documentation** (`qwen3_5_moe` was measured working on 0.4.0).
   → Just run `vllm-mlx serve` and see. Fall back to `mlx-vlm` if it fails.

2. **transformers pin** — a known landmine. Bare mlx-lm ran on transformers
   5.0.0; vllm-mlx 0.4.0 on 5.12.1. Qwen3.8 may shift it again. The venvs are
   already separated, so the blast radius is contained.

3. **llama.cpp version** — see §6 (upstream issues actually checked).

4. **MTP in GGUF** — the unsloth repo's file list has no MTP file, but
   **`--spec-type draft-mtp` does work with the unsloth GGUF** (upstream issue
   #27122 reproduces with `Qwen3.8-27B-UD-Q4_K_XL` + `draft-mtp`). The MTP
   tensors are embedded in the main GGUF, so it behaves like Qwen3.6-35B. The
   [ggml-org build](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF) ships MTP
   as a separate file (Q8_0 MTP 3.16GB etc.) — a different packaging, not needed
   with the unsloth build.

5. **MLX MTP is a sidecar too** — `mlx-community/Qwen3.8-27B-MTP-4bit` is a
   239 MB standalone drafter (`model_type: qwen3_5_mtp`, MTP block size 3). It
   does not run alone; it pairs with a target checkpoint. The card says
   `--draft-kind mtp` auto-detects from model_type.

*(Measured: 1 was a non-issue; 5 needed two undocumented conversions and still
yielded no speedup. See EVALUATIONS-macos.md.)*

---

## 4. Run-up steps (once the network is back)

### 4.1 Pre-download (both boxes, immediately)

Start this before any testing — it saturates the link.

```bash
# z1mn
huggingface-cli download mlx-community/Qwen3.8-27B-mxfp4

# gx10-a9c0
huggingface-cli download Qwen/Qwen3.8-27B-FP8
```

**Correction from the run**: on GB10 this is wasted work. `vllm-run.sh` mounts
`/var/lib/vllm/cache` as the container's `HF_HOME`, so the weights must land
there, not in the user's `~/.cache/huggingface`. Let the container download them
on first start.

### 4.2 gx10-a9c0 — vLLM

Edit `/etc/vllm/vllm-server.env` (the NVFP4 example in this repository's
`vllm-server.env.example` is the starting point):

```sh
VLLM_IMAGE="vllm/vllm-openai:nightly"
VLLM_MODEL="Qwen/Qwen3.8-27B-FP8"
VLLM_SERVE_ARGS="--kv-cache-dtype fp8 --gpu-memory-utilization 0.5 --max-model-len 262144 --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder"
VLLM_SPEC_CONFIG=''
VLLM_ENV="VLLM_USE_DEEP_GEMM=0"
```

`sudo systemctl start vllm-server` (llama-server stops automatically via
`Conflicts=`). Confirm it boots without MTP first, then add MTP.

**Two corrections from the run.** `VLLM_ENV` is mandatory, not optional: vLLM
logs `Auto-disabled DeepGemm for model_type=qwen3_5_text on Blackwell` and then
calls DeepGemm from kernel warmup anyway, dying with `Assertion error
(deepgemm .../layout.hpp:76): Unknown recipe` after a 190 s load and a 51 s
compile — on every restart. And if you start from the resident MoE config, drop
`--moe-backend` and the spec config's `moe_backend`: this model is dense.

### 4.3 z1mn — vllm-mlx

`~/.config/vllm-mlx/vllm-mlx-server.env`:

```sh
VLLM_MLX_MODEL="mlx-community/Qwen3.8-27B-mxfp4"
VLLM_MLX_ARGS="--host 127.0.0.1 --port 8000 --reasoning-parser qwen3"
```
`NO_BUILD=1 ./install.sh` regenerates the plist and reloads the agent.
On startup failure, read `~/.local/state/vllm-mlx/logs/vllm-mlx-server.err.log`.

**Correction from the run**: keep the model as a *repo name*. A local directory
path routes through mlx_vlm on 0.4.0 and returns fluent nonsense. Tool calling
also needs `--enable-auto-tool-choice --tool-call-parser qwen3_coder` — the
first flag errors out without the second, and without both an agent driver gets
a silent no-op.

### 4.4 Measurement (so it connects to the existing evaluations)

**Match the prompt and conditions to the existing evaluations**:
- the same coding tasks (`merge_intervals` doctest / bugfix / refactor)
- `enable_thinking: false`, temp 0.7 / top_p 0.80 / top_k 20 (instruct)
- discard run 1 (load+warmup dominated), keep runs 2–3
- single-shot decode tok/s

Compare against the resident `Qwen3.6-35B-A3B-MTP:Q4_K_XL` (GB10 77.8/63.3
tok/s; M5 Max mxfp4 138–140 tok/s).

**Worth adding**: re-measure the baseline on the same day with the same script.
Reproducing 138.7 against the recorded 138–140 is what made the new numbers
trustworthy.

---

## 5. What the evaluation is actually for (quality, not speed)

As above, the 27B dense is near-certain to be slower than 35B-A3B on both boxes,
so adoption turns on quality. The existing toy coding tasks **failed to separate
Qwen3.6-27B, Ornith, or Coder-Next** (all 3/3 pass), so repeating them decides
nothing.

→ Use tasks with more discriminating power:
- how `reasoning_effort` (xhigh/medium/low) behaves — new in Qwen3.8 and absent
  from 35B-A3B, so this is where a difference could show
- a real agent loop (read→edit→run→verify, like the RPN calculator used for
  Ornith) — proven more discriminating than toy generation
- actual long-context (262144) behaviour

*(Measured: `reasoning_effort` and the agent loop both failed to separate
anything. Japanese honorifics and vision did. Long context was limited by
prefill — ~288 tok/s, so the native window costs ~15 minutes of reading — not by
accuracy.)*

---

## 6. Latest llama.cpp build — detail

### 6.1 Conclusion: the architecture is already supported; it is not "unreadable"

An earlier draft said "a latest build is mandatory, existing builds probably
cannot read it". That was inference from a blog post. **Checking upstream
directly gives a clearer picture**:

- Qwen3.8-27B's GGUF arch is **`qwen35`** — it shares the implementation with
  the Qwen3.5/3.6 line. `Qwopus3.5-9B-v3`, already resident here, is also
  `qwen35` (see README.md)
- `GGML_OP_GATED_DELTA_NET` is **implemented on CUDA, Metal and Vulkan**
  (#19504 added the op → #20244 Metal backend, #20361 Metal GDN kernel, #20334
  Vulkan — all **closed = merged**)
- MTP spec-decode was merged in #22673

So this is **not waiting on a new architecture**. A build old enough will fail
with `unknown model architecture`, but a build that already runs `qwen35` will
probably load it. **The question is not "can it read it" but "which bugs will it
hit".**

### 6.2 Current versions (as of 2026-08-16)

- latest release tag: **b10442** (2026-08-15)
- master HEAD: `ad1de39e0`

### 6.3 Qwen3.8-27B-specific bugs actually reported (all open)

**This is the real reason to want a recent build.** They cluster in the last few
days:

| Issue | What | Trigger | Impact on us |
| --- | --- | --- | --- |
| [#27090](https://github.com/ggml-org/llama.cpp/issues/27090) | **silent crash** at ~520K prefill with YaRN ×4 (just past 2×yarn-orig-ctx) | rope-scale 4 for 1M ctx | **N/A at native 262144** |
| [#27122](https://github.com/ggml-org/llama.cpp/issues/27122) | **CUDA lockup** with `draft-mtp` + `--split-mode tensor` | multi-GPU split | **N/A — GB10 is single-GPU** |
| [#27107](https://github.com/ggml-org/llama.cpp/issues/27107) (closed) | chat template `raise_exception` makes Claude Code / Codex **die with 400** | `--jinja` + multiple system prompts | **could hit us** |
| [#27139](https://github.com/ggml-org/llama.cpp/issues/27139) | Codex errors, worked around with the Qwen3.6 template | same | same |
| [#27023](https://github.com/ggml-org/llama.cpp/issues/27023) | `reasoning_effort` suspected broken | reasoning control | **hits §5's main axis directly** |
| [#27109](https://github.com/ggml-org/llama.cpp/issues/27109) | 4-bit KV cache collapses prefill to ~34 t/s on qwen35 hybrid | `-ctk/-ctv q4_*` | avoided with q8_0 |

**Important side note in #27090**: prompts over ~90–100K were crashing the same
way on b10430 and **were fixed in b10434** (#26623, recurrent state rollback).
→ **Any build below b10434 is unusable for long context. Use b10434 at minimum,
b10442 or later if possible.** That is the concrete reason a recent build is
needed.

### 6.4 What our configuration hits and what it does not

**Not hit** (most of the serious reports need conditions we do not meet):

- #27090 → irrelevant if we run native 262144 without YaRN
- #27122 → both GB10 and M5 Max are **single-device**; we do not use
  `--split-mode tensor`
- #27109 → we use q8_0 KV quantization (as models.ini comments state); avoid q4

**Likely to hit**:

- **chat template `raise_exception`** — llama.cpp's autoparser (#18675) probes
  the template with a synthetic message sequence, but Qwen3.5-line templates
  assert "System message must be at the beginning", so **parser generation fails
  with a 400**. llama.cpp #20733 was closed as not planned, i.e. **this will not
  be fixed upstream**. Two workarounds:
  1. pass Unsloth's corrected template via `--chat-template-file`
  2. reuse the Qwen3.6 template (#27139)
- **`reasoning_effort` (#27023)** — this is the very axis §5 makes central, so
  evaluating it through llama.cpp risks measuring a llama.cpp bug.
  → **Evaluate `reasoning_effort` on vLLM / vllm-mlx instead.**

### 6.5 Build steps

**gx10-a9c0 (CUDA)** — this repository's `install.sh` works as-is. The existing
checkout is deliberately left alone (`install.sh` only clones, never pulls), so
**update it explicitly** before rebuilding:

```bash
cd ~/ghq/github.com/ggml-org/llama.cpp
git fetch origin && git checkout b10442      # or master
cd ~/ghq/github.com/ngc-shj/inference-deploy/llama.cpp
./install.sh                                  # CUDA_ARCH=121 is the default
sudo systemctl restart llama-server
/opt/llama/bin/llama-server --version         # confirm the build number
```

**z1mn (Metal)** — this repository has no Metal install.sh. Follow the steps
recorded in EVALUATIONS-macos.md:

```bash
cmake -S llama.cpp -B build-metal -DGGML_METAL=ON -DLLAMA_CURL=ON
cmake --build build-metal --target llama-server -j
```

That said, vllm-mlx (MLX) measured ~1.5× faster than llama.cpp/Metal on z1mn
(129 vs 87 tok/s), so **there is little reason to build llama.cpp there** —
only for GGUF-only models or llama.cpp-specific features.

### 6.6 Summary — why a recent build

Not "because Gated DeltaNet is unimplemented" (it is implemented). Because:

1. **b10434 fixed a long-context crash** — anything below it is unusable
2. Qwen3.8-27B-specific bugs are **being reported and fixed right now** (4 open
   in the last two days), so older builds carry more landmines

---

## References

- [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B)
- [Qwen/Qwen3.8-27B-FP8](https://huggingface.co/Qwen/Qwen3.8-27B-FP8)
- [unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF)
- [unsloth/Qwen3.8-27B-NVFP4](https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4)
- [ggml-org/Qwen3.8-27B-GGUF](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF)
- [mlx-community/Qwen3.8-27B-mxfp4](https://huggingface.co/mlx-community/Qwen3.8-27B-mxfp4)
- [mlx-community/Qwen3.8-27B-MTP-4bit](https://huggingface.co/mlx-community/Qwen3.8-27B-MTP-4bit)
- [vLLM Recipes — Qwen3.8-27B](https://recipes.vllm.ai/Qwen/Qwen3.8-27B)
- measurements: `llama.cpp/EVALUATIONS.md`, `llama.cpp/EVALUATIONS-macos.md`
