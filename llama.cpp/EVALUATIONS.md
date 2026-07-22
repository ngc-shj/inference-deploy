# Model evaluations (GB10 / DGX Spark)

Measured on the resident llama.cpp router (`localhost:8080`), GB10 / 128 GB
unified memory, ~273 GB/s. Linked from [README.md](README.md). For the same
models on Apple Silicon (MLX), see [EVALUATIONS-macos.md](EVALUATIONS-macos.md)
— where the 4-bit format ranking inverts because there is no NVFP4 hardware path.

## Why throughput is what it is on this box

Decode speed is bound by **memory bandwidth ÷ active-parameter bytes**, not by
total parameters. On GB10's ~273 GB/s pool an MoE model with a small *active*
set is far faster than a dense model of similar total size. Every result below
is consistent with this: pick models by **active** params for throughput, by
benchmark scores for quality, and only then check the memory budget.

KV cache is rarely the constraint for the recent Qwen models here — they use
hybrid linear attention (Gated DeltaNet + a few full-attention layers), so only
a fraction of layers cache KV. The flip side: SWA / hybrid-recurrent memory means
llama.cpp cannot reuse cross-request prompt KV (log: `forcing full prompt
re-processing`), so multi-turn latency grows with context length even though
single-shot tok/s stays flat. Throughput numbers below are single-shot.

---

## 2026-06-21 — Qwen3.6-27B (MTP) vs resident 35B-A3B

Two 27B variants evaluated against the resident `Qwen3.6-35B-A3B-MTP:Q4_K_XL`.
Same coding prompt (`merge_intervals` with doctests), temp 0.2, on-demand load.

| Model | Quant | thinking OFF | thinking ON | Code (doctest) | Notes |
| --- | --- | --- | --- | --- | --- |
| `unsloth/Qwen3.6-27B-MTP` | Q4_K_XL (17.9 GB) | 24.4 tok/s | runs away — 8292-char reasoning, hit length cap | 3/3 ✓ | dense+hybrid; verbose docstrings |
| `bytkim/...-pi-tune` | Q4_K_M (16.8 GB) | 25.7 tok/s | concise (1720-char reasoning, completes) | 3/3 ✓ | no-thinking agentic focus; most instruction-faithful |
| `unsloth/Qwen3.6-35B-A3B-MTP` *(ref)* | Q4_K_XL (20 GB) | **90.5 tok/s** | 27.9 s, completes | 3/3 ✓ | MoE, active ~3B |

**Findings**

- **Speed inversion**: the 35B-A3B (MoE, active ~3B) runs ~3.5× faster than
  either 27B (dense + hybrid attention), repeated across two runs — structural,
  not warm-up. Fewer total params ≠ faster.
- **Quality on par**: all three produce correct implementations (doctests pass).
  pi-tune's output is the most concise and obeys "output only the code block".
- **unsloth-27B's thinking mode over-thinks** (2560 tokens used without reaching
  a conclusion). pi-tune thinks briefly and finishes.
- **Memory is not the bottleneck**: 27B hybrid KV is light — ~128 KB/token (16
  full-attn layers, 4 KV heads, head_dim 256) → native 262144 ctx ≈ 34 GB total
  (lighter than the 35B's 46 GB).
- **MTP head is embedded in the GGUF** (no sidecar), same as the 35B —
  `spec-type = draft-mtp` alone works.

**Verdict**: no reason to replace the 3-model set with these. The 27B is slower
than the resident 35B at equal quality. Keep `pi-tune-27B` only as a
no-thinking agent/tool-calling option where instruction-following beats tok/s;
`unsloth-27B` is a strict downgrade from the 35B.

---

## 2026-07-20 — Ternary-Bonsai-27B (1.6-bit) — does extreme quant beat bandwidth?

`prism-ml/Ternary-Bonsai-27B` is a Qwen3.6-27B VLM quantized end-to-end to
**ternary (~1.6 bit/weight)** — the same 27B dense+hybrid backbone as the
2026-06-21 row above, but with the weights shrunk ~9× (Q4_K_XL 17.9 GB →
Q2_0 6.7 GB). The GB10 is bandwidth-bound, so the hypothesis worth testing was:
if decode is `bandwidth ÷ active-parameter *bytes*`, a 9× lighter weight set
should decode several times faster. It does **not**.

Requires the **PrismML fork** of llama.cpp (`PrismML-Eng/llama.cpp`, branch
`prism`) — its custom `Q1_0`/`Q2_0` low-bit kernels are not in mainline. Built
here for GB10 with `-DCMAKE_CUDA_ARCHITECTURES=121` (CMake auto-promotes to
`121a`; server logs `BLACKWELL_NATIVE_FP4=1`, `ARCHS=1210`). The Hopper-only
`Q1_0` wgmma path (`mmq-hopper-q1.cu`) is opt-in (`env GGML_HOPPER_Q1`) and
explicitly excludes Blackwell, so GB10 falls back to the normal mmvq/mmq path.
Run on a **separate instance (`:8090`)**, not the resident router — the fork is
a different binary. Same `merge_intervals` prompt, temp 0.2, warm single-shot.

| Model | Quant | thinking OFF | thinking ON | + dspark draft | Code (doctest) | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `prism-ml/Ternary-Bonsai-27B` | Q2_0 (6.7 GB, ~1.6-bit) | 25.7 tok/s | 27.5 tok/s | 28.6 tok/s | 3/3 ✓ | ternary; same 27B backbone |
| `unsloth/Qwen3.6-27B-MTP` *(ref, 06-21)* | Q4_K_XL (17.9 GB) | 24.4 tok/s | — | — | 3/3 ✓ | mainline; Q4 of the same base |

**Findings**

- **Extreme quant does not buy speed here.** 9× lighter weights → **~1.05×**
  faster (24.4 → 25.7 tok/s). If decode were weight-bandwidth-bound the ternary
  build would be multiples faster; it is flat. On GB10 the 27B dense+hybrid is
  bound by **per-token compute / attention seriality and low-bit dequant
  overhead**, not weight traffic — the opposite regime from the MoE models,
  whose small *active* set genuinely is bandwidth-limited (35B-A3B → 90 tok/s).
- **The dspark speculative drafter gives nothing measurable** (+1 tok/s). The
  fork logs `no implementations specified for speculative decoding` — the
  advertised 1.34× is a CUDA-serving/batch result, not single-stream on GB10.
  (Note the flag rename in this fork: `--draft-max` → `--spec-draft-n-max`.)
- **Quality holds at ternary**: doctests 3/3, concise think-off output — on par
  with the Q4 27B. The claimed ~95% of FP16 is plausible for this task.
- **Memory win is real but irrelevant here**: 6.7 GB resident is tiny, but the
  27B was never memory-constrained on this box (its hybrid KV is light too).

**Verdict**: no reason to adopt. It is the same speed class as every other 27B
dense on GB10 (~25 tok/s), i.e. ~3.5× slower than the resident 35B-A3B at
comparable quality, and it needs a non-mainline fork + separate binary to run.
The value was the *measurement*: it confirms GB10's 27B-dense ceiling is
compute/attention-bound, so no quant — however aggressive — moves it. Extreme
low-bit quant pays off for *footprint* (edge/phone, the model's actual target),
not for throughput on this bandwidth-rich, compute-modest box.

---

## 2026-06-21 — Survey: coding-specialized models for DGX Spark

Goal: agentic-coding models that actually run on GB10. Filtered by **active**
params (throughput) and the 128 GB budget.

| Model | Type | Active | Q4 size | SWE-bench | GB10 fit |
| --- | --- | --- | --- | --- | --- |
| **Qwen3-Coder-Next 80B-A3B** | MoE | 3B | ~46 GB | Aider 60.9% | ◎ fast + capable — top pick |
| Qwen3-Coder 30B-A3B | MoE | 3.3B | ~18 GB | 50.3% | ◎ lightest, best balance |
| GLM-4.5/4.6 Air 106B-A12B | MoE | 12B | ~70 GB | upper tier | ○ runs, mid speed, ~70 GB |
| Devstral Small 2 24B | dense | 24B | ~14 GB | **68%** | △ best SWE but dense → slow (~24 tok/s class) |
| Devstral 2 123B (Medium) | dense | 125B | ~75 GB | upper tier | △ fits at Q4, but dense 125B → ~5 tok/s est., unusable for agents |
| Qwen3-Coder 480B-A35B | MoE | 35B | **~276 GB** | Aider 60.9% | ✗ does not fit (2× the pool); active 35B = slow even offloaded |
| Kimi K2.7 Code 1T-A32B | MoE | 32B | **~585 GB** | 60.4% | ✗ does not fit; ~4 tok/s even if it did |
| MiniMax M3 ~428B | MoE | large | n/a | Pro 59.0% | ✗ too big; sparse-attn unsupported in llama.cpp |

**Takeaways**

- **Qwen3-Coder-Next 80B-A3B** is the sweet spot: active 3B → 35B-A3B-class
  throughput expected, coding-specialized, 256K context, same MoE lineage as the
  resident model. (Note: **no MTP head** — hybrid linear attn, 12 of 48 layers
  cache KV. Recommended sampling: temp 1.0 / top_p 0.95 / top_k 40.)
- **Kimi K2.7 Code** is top-quality (SWE 60.4%) but a multi-GPU-server model:
  ~585 GB even at Q4, and active 32B caps it near ~4 tok/s on this bandwidth.
  Use it via API, not locally on GB10.
- **The large coding models all fail one of two ways on this box**: either they
  don't fit (Qwen3-Coder 480B ~276 GB, Kimi 1T ~585 GB, MiniMax) or they fit but
  are dense and bandwidth-starved (Devstral 2 123B ~75 GB → ~5 tok/s est.). The
  usable local tier is small-to-mid MoE with active ~3B; everything above that
  belongs behind an API.
- For local coding here, the realistic plan is **Qwen3-Coder-Next resident**,
  escalate to a hosted Kimi/GLM-5.x-class model by API only when needed.

Sources: kilo.ai / MindStudio open-source coding roundups, Unsloth model docs,
explainx.ai DGX Spark guide, Atlas Cloud Kimi-vs-GLM-vs-Qwen comparison.

---

## 2026-06-22 — Qwen3-Coder-Next 80B-A3B vs resident 35B-A3B (measured)

Same 3 coding tasks (`merge_intervals`, refactor-with-type-hints, fix
`second_largest`), no-think. Coder-Next at its recommended sampling
(temp 1.0 / top_p 0.95 / top_k 40), 35B at 0.7 / 0.8 / 20. One model at a time
(see memory caveat below). **First call per model is load+warmup-dominated —
discard it; the 2nd/3rd calls are the real throughput.**

| Model | Quant (size) | refactor | bugfix | (merge, cold) | Quality |
| --- | --- | --- | --- | --- | --- |
| `unsloth/Qwen3-Coder-Next` | UD-Q4_K_XL (49.6 GB) | 43.7 tok/s | 37.5 tok/s | 3.5 (cold) | merge 3/3 ✓, bugfix ✓ |
| `unsloth/Qwen3.6-35B-A3B-MTP` *(ref)* | Q4_K_XL (20 GB) | **77.8 tok/s** | **63.3 tok/s** | 11.1 (cold) | merge 3/3 ✓, bugfix ✓ |

**Findings**

- **35B-A3B is ~1.7× faster** than Coder-Next on warm decode, even though both
  are MoE with active ~3B. The difference is **total resident weight**:
  Coder-Next streams from 49.6 GB vs the 35B's 20 GB. On a bandwidth-bound box,
  active-param count alone does not predict throughput — resident GB matters too.
- **Quality is on par** for these short tasks: both pass the merge doctests 3/3
  and correctly fix the `second_largest` `s[-2]`-on-short-list bug across edge
  cases. Coder-Next's coding specialization showed no measurable edge here.
- **Memory contention is real**: Coder-Next (49.6 GB) + 35B (46 GB) do **not**
  co-reside in 128 GB. With `--models-max 3` the router tried to load both and
  OOM-crashed the second instance in a retry loop (`ensure_model: waiting…`).
  Evaluate large models with **`--models-max 1`** so loading one evicts the
  other; restore to 3 afterward.

**Verdict**: not worth adopting for local use here. Coder-Next costs 49.6 GB
resident (can't co-reside with the 35B), runs slower, and matches — not beats —
the 35B on quality for everyday coding. The 35B-A3B remains the best
local coding model on this box; escalate to a hosted Kimi/GLM-class model by API
when a task genuinely needs frontier coding quality.

---

## 2026-06-25 — vLLM NVFP4 vs llama.cpp GGUF (same 35B-A3B, cross-engine)

Compared the resident llama.cpp `Qwen3.6-35B-A3B-MTP:Q4_K_XL` (GGUF) against
`nvidia/Qwen3.6-35B-A3B-NVFP4` (safetensors, ModelOpt NVFP4, ~19GB) served by
vLLM on the on-demand vllm deployment. Same model, two engines / quant formats.
GB10 has native FP4 (`BLACKWELL_NATIVE_FP4=1`), so NVFP4 is the format the
hardware can compute on directly. Same no-think coding tasks; warm tok/s.

| Engine / quant | merge | refactor | bugfix | Quality | MTP |
| --- | --- | --- | --- | --- | --- |
| llama.cpp Q4_K_XL (GGUF) | — | 77.8 | 63.3 | 3/3 ✓ | draft-mtp |
| vLLM NVFP4, minimal flags | 75.9 | 73.1 | 69.7 | 3/3 ✓ | off |
| **vLLM NVFP4, full DGX-Spark flags** | **112.3** | **77.5** | **93.8** | 3/3 ✓ | mtp spec-decode |

**Findings**

- **NVFP4 matches GGUF even without MTP**, and with the full official flags
  (MTP spec-decode + marlin MoE + flashinfer + fp8 KV + prefix-cache) it pulls
  clearly ahead on templated outputs (merge 112, bugfix 94 tok/s). Quality is
  identical (doctests 3/3, bugfix all edge cases). Blackwell-native FP4 + MTP is
  a real win on this box.
- **TTFT is better than llama.cpp** — vLLM pre-captures cudagraphs, so there's no
  cold first-call penalty (llama.cpp's first call warmed up at ~11 tok/s).

**Operational gotchas (cost most of the session — see also the unit comments):**

- **Image matters.** NGC `nvcr.io/nvidia/vllm:26.05-py3` (vLLM 0.20.1) **cannot
  load** this checkpoint: `KeyError: layers.0.mlp.experts.w2_input_scale` — its
  loader doesn't map the MoE per-expert FP4 scales (same class as vllm#38980).
  Use `vllm/vllm-openai:nightly` (0.23.1rc1+), as the HF card says.
- **Entrypoint differs by image.** The Docker-Hub `vllm/vllm-openai` ENTRYPOINT
  already includes `vllm serve`, so passing `serve <model>` doubles it
  (`unrecognized arguments: <model>`). Run it with `--entrypoint vllm` then
  `serve <model> …`. NGC's entrypoint does not — there you write `vllm serve …`.
- **systemd `$VAR` vs `${VAR}`.** The vllm unit used `${VLLM_SERVE_ARGS}`, which
  systemd passes as ONE argv (no word-split) → vLLM argparse `IndexError`. Fixed
  to bare `$VLLM_SERVE_ARGS` (matches the llama.cpp/ds4 units). Single-value vars
  keep `${...}`.

**Verdict**: NVFP4 on vLLM is the faster way to serve this exact model on GB10,
once you pin the nightly image and the right entrypoint. The llama.cpp GGUF stays
the *resident* daily driver (vLLM is on-demand, `Conflicts=` with llama-server);
NVFP4 is the option to spin up when you want max throughput for this model.

---

## 2026-06-30 — Ornith-1.0-35B (DeepReinforce agentic-coding MoE) vs resident 35B-A3B

[deepreinforce-ai/Ornith-1.0-35B](https://huggingface.co/deepreinforce-ai/Ornith-1.0-35B)
is an MIT-licensed, **reasoning** coding MoE (post-trained on Qwen3.5/Gemma4,
active ~3B) trained with a self-scaffolding RL method — it learns its own agent
harness, not just solutions. Vendor benchmarks claim SWE-bench Verified 75.6 (vs
Qwen3.5-35B 70.0) and Terminal-Bench 2.1 64.2 (vs 41.4), even beating
Qwen3.5-397B on Terminal-Bench. Evaluated the GGUF
`deepreinforce-ai/Ornith-1.0-35B-GGUF:Q4_K_M` (21.2 GB) on the router at
`c = 65536`, NOT MTP. Same 3 coding tasks as prior evals, vendor sampling
(temp 0.6 / top_p 0.95 / top_k 20). First call was load+warmup; numbers below are
warm.

| Model | Quant (size) | refactor | bugfix | merge | Quality |
| --- | --- | --- | --- | --- | --- |
| `deepreinforce-ai/Ornith-1.0-35B` *(think)* | Q4_K_M (21.2 GB) | 63.5 tok/s | 63.7 tok/s | 63.4 tok/s | merge 5/5 ✓, bugfix ✓, refactor ✓ |
| `deepreinforce-ai/Ornith-1.0-35B` *(no-think)* | Q4_K_M (21.2 GB) | — | 64.2 tok/s | — | bugfix ✓ |
| `unsloth/Qwen3.6-35B-A3B-MTP` *(ref, no-think)* | Q4_K_XL (20 GB) | **77.8** | **63.3** | — | merge 3/3 ✓, bugfix ✓ |

**Findings**

- **Throughput ~63 tok/s, rock-steady** across all tasks and both think/no-think
  (variance < 1 tok/s) — confirms the active-~3B MoE profile. Comparable to the
  resident 35B-A3B on raw decode, but the 35B keeps an edge on templated output
  (refactor 77.8 vs 63.5) because it runs **MTP spec-decode**; Ornith's GGUF has
  no MTP head, so no draft acceleration here.
- **Quality is on par** for these short tasks: merge doctests 5/5 (empty, single,
  full-overlap, touching endpoints, disjoint), bugfix returns None for `[5]` /
  `[3,3]` / `[]` and 2 for `[1,2,3]`, refactor adds type hints + docstring with
  behavior unchanged. No measurable coding edge over the 35B-A3B on this tiny set
  — the vendor SWE-bench/Terminal-Bench gap doesn't show on toy tasks.
- **It is a reasoning model, thinking-on by default.** llama.cpp splits the
  chain-of-thought into `reasoning_content`; even trivial tasks spent 2.3k–7k
  chars of thinking before the code (merge nearly hit an 8k-token budget). That's
  many extra decoded tokens per answer vs the resident 35B (measured no-think).
  **`chat_template_kwargs: {enable_thinking: false}`** cleanly disables it
  (reasoning 0 chars, still correct) — use it for latency-sensitive agent loops.
- **Memory co-resides fine.** Ornith (21 GB) + 35B-A3B (20 GB) + gpt-oss both
  `loaded` at once: used 81 GB / available 39 GB. No `--models-max` change needed.

**Verdict**: a credible local coding model — same speed class and on-par quality
vs the resident 35B-A3B, MIT-licensed, fits alongside it. Two caveats before
adopting: (1) no MTP, so it's a touch slower than the 35B on this box despite
equal active params; (2) reasoning-on by default burns tokens — pin
`enable_thinking=false` for agent use. Its claimed advantage is **agentic**
(self-scaffolding, SWE-bench/Terminal-Bench), which toy tasks can't surface;
worth a real agent-loop trial (e.g. via an OpenAI-compatible coding CLI) before
deciding whether it beats the 35B-A3B where it counts. For now: keep as an
on-demand option, not a resident-set change.

### Agent-loop trial (read → edit → run → verify)

Pointed an OpenAI-compatible coding CLI at the router endpoint (`localhost:8080/v1`,
provider = `@ai-sdk/openai-compatible`) and gave it a real tool-using task: a
buggy RPN calculator (`calc.py`) whose `*` operator was unimplemented, with a
runner (`test_calc.py`) that failed (4 cases, mul + chain error out with
`IndexError`). Instruction: run the tests, fix `calc.py`, re-run to confirm, don't
touch the tests.

- **opencode** (1.17.10) connected and drove Ornith through the loop;
  **codex** (0.130.0) could NOT be used — it now requires `wire_api = "responses"`
  (OpenAI Responses API), which llama.cpp doesn't speak (`wire_api = "chat"` is
  rejected). For llama.cpp-served models, use a CLI that speaks plain chat
  completions (opencode, aider, …), not current codex.
- **Result: pass.** Ornith ran the tests, saw the failures, patched `calc.py` with
  the correct `else: stack.append(a * b)` branch, re-ran, and left
  `test_calc.py` untouched. All 4 tests pass. It completed the multi-step
  read→edit→run→verify loop autonomously.
- This is where Ornith earns its pitch: on toy *generation* it tied the 35B-A3B,
  but it **does carry a real agent loop to completion** end-to-end. (Latency note:
  reasoning-on, so a single agent turn took minutes of wall-clock — the long CoT
  that helps the agent also makes each step slow on this box. A `> 10 min` task
  needs to run detached, not in a 10-min-capped foreground shell.)

**Net**: credible local agentic-coding model, MIT, fits alongside the 35B-A3B.
Adopt it as the **on-demand agent endpoint** (point opencode/aider at it) rather
than a resident-set swap; the resident 35B-A3B stays the fast interactive driver.

### Quant choice: Q4_K_M vs Q5_K_M on GB10 — Q4 wins here

Prompted by [note.com/zephel01](https://note.com/zephel01/n/nb64f1495778b), who ran
40 pytest coding tasks on **EVO-X2 + RTX 5090** and found Q5_K_M best: **97.5%
(39/40) vs Q4_K_M 92.5% (37/40)**, at near-identical speed (259 vs 265 tok/s). We
re-checked on GB10 — and the speed story does NOT carry over.

| Quant | Size | GB10 warm tok/s | RTX 5090 (article) |
| --- | --- | --- | --- |
| Q4_K_M | 21.2 GB | **63–78** | 265 |
| Q5_K_M | 24.7 GB | **32–38** | 259 |

**Findings**

- **On GB10, Q5_K_M runs ~half the tok/s of Q4_K_M** (33 vs 63, re-confirmed
  across repeats), where on the RTX 5090 the two were within 2%. The article's
  premise — Q5 is "free quality" because speed is unchanged — is a
  **wide-bandwidth-GPU result** and does not hold on this box. The RTX 5090 has
  ~1.8 TB/s VRAM; GB10 is ~273 GB/s **bandwidth-bound**, so the heavier Q5_K
  weights (and its costlier dequant vs the well-optimized Q4_K path) show up
  directly as decode latency. This is the same active-bytes ÷ bandwidth law as the
  27B/Coder-Next evals above — quant format, not just param count, moves it.
- **Q4 + Q5 do NOT co-reside** — with both Ornith quants in `models.ini`, loading
  the second on top of Q5 + 35B-A3B + gpt-oss **CUDA-OOMs** and hangs in
  `ensure_model: waiting…` (same failure class as Coder-Next + 35B at
  `--models-max 3`). Keep exactly ONE Ornith quant registered.
- **Fewer residents → faster.** After dropping Q5 and gpt-oss, Q4 alongside just
  the 35B-A3B measured **78 tok/s** (up from 63 with the full 3-model set) —
  resident GB, not active params, sets the ceiling on this box.

**Verdict**: **stay on Q4_K_M** on GB10. The +5 pt quality (2 of 40 tasks, on
different hardware/tasks, unverified here) doesn't justify halving throughput for
an agent model that makes dozens of calls per task and already escalates hard
cases to a hosted API. Q5 is the right pick only on a wide-bandwidth GPU where it
costs nothing; here it costs 2×. Kept Q4_K_M registered; removed the Q5_K_M
preset and deleted its 24.7 GB cache blob.

---

## 2026-07-05 — Qwopus3.6-35B-A3B-Coder-MTP vs resident 35B-A3B and Ornith

[Jackrong/Qwopus3.6-35B-A3B-Coder-MTP](https://huggingface.co/Jackrong/Qwopus3.6-35B-A3B-Coder-MTP-GGUF)
is an Apache-2.0 **coding finetune of the same Qwen3.6-35B-A3B base as our
resident model**, by the same author as the resident Qwopus3.5-9B. Crucially it
ships an **embedded MTP head** (unlike Ornith) and is a **thinking-off,
token-efficient** agentic-coding finetune. Vendor: SWE-bench 62.4% (300-case,
thinking-off, Q5). Evaluated `…:Q4_K_M` (21.7 GB) on the router at `c = 65536`
with `spec-type = draft-mtp` (works with the flag alone, same as the resident —
MTP is in the GGUF). Sampling: Qwen3-family instruct 0.7 / 0.8 / 20.

| Model (Q4, warm) | think | no-think | MTP | Quality |
| --- | --- | --- | --- | --- |
| **Qwopus3.6-Coder-MTP** | 84–92 (but overthinks → length cap) | **95–100 tok/s** | ✓ accept 0.76–1.0 | merge 5/5 ✓, bugfix ✓, refactor ✓ (best docstrings) |
| `Ornith-1.0-35B` | 63 | 64 | ✗ | on par |
| `Qwen3.6-35B-A3B` *(resident ref)* | — | 63–78 | ✓ | on par |

**Findings**

- **Fastest local coding model measured on this box: 95–100 tok/s no-think**,
  beating even the resident 35B-A3B — because it's the *same* base + MTP + a
  finetune tuned for short outputs. The llama.cpp log confirms MTP is live:
  **draft acceptance 0.76–1.00** (1.00 on templated code), the exact win Ornith
  lacks (Ornith has no MTP → capped at 63).
- **Must run it no-think.** Despite the "thinking-off" branding, at default
  (thinking-on) it *over-thinks* — refactor/merge blew 25k–32k reasoning chars and
  hit the token cap with **empty code** (same failure as Ornith). With
  `chat_template_kwargs:{enable_thinking:false}` it emits code immediately,
  correctly, and fastest. Pin thinking-off for this model.
- **Quality on par or better.** merge doctests 5/5, bugfix all edge cases, and the
  most thorough refactor (typed `list[int]` + full Args/Returns/Raises docstring).
- **Agent loop: pass.** opencode (local provider → router) drove it through the
  same RPN-calc fix task — ran tests, added the correct `elif tok == "*"` branch,
  re-verified, left tests untouched, 4/4 pass. Finished faster than Ornith (no
  multi-minute CoT per turn).

**Verdict**: this is the first genuine **resident-set upgrade candidate** for local
coding. Same base as the resident 35B-A3B, so it drops into the identical
`spec-type=draft-mtp` slot; it's *faster* (95–100 vs 63–78) and coding-specialized,
where Ornith was slower (no MTP) and reasoning-heavy. Next step before promoting:
run it head-to-head with the resident 35B-A3B on a harder multi-file agent task
(SWE-bench-style), and decide whether it *replaces* the resident 35B-A3B for
coding or rides alongside as the on-demand coding endpoint. Registered on-demand
for now (thinking-off, Qwen3-family sampling). Note: repo also ships an mmproj
(vision) — text-only unless `mmproj=` is added.

---

## 2026-07-11 — Unsloth "Dynamic NVFP4" vs nvidia NVFP4 (same 35B-A3B, vLLM)

Unsloth published [NVFP4 quants](https://huggingface.co/collections/unsloth/nvfp4)
of Qwen3.6-35B-A3B claiming **1.56× (std) / 1.79× (Fast) throughput vs other
NVFP4 quants** plus better accuracy (calibrated on Unsloth + UltraChat data).
Verified against `nvidia/Qwen3.6-35B-A3B-NVFP4` on the on-demand vLLM
deployment — all three on the same `vllm/vllm-openai:nightly` image, same flags
as the 2026-06-25 eval (MTP spec-decode `num_speculative_tokens=3`, fp8 KV,
flashinfer, marlin MoE, ctx 262144, `--gpu-memory-utilization 0.4`).
Single-stream streaming decode, no-think, 2 runs each: a code prompt (LRU cache
+ tests, 1500 tok) and a prose prompt (~700 tok). nvidia re-benched the same day
as a fresh baseline.

| Checkpoint | Size | code tok/s | prose tok/s | MTP accept |
| --- | --- | --- | --- | --- |
| `nvidia/Qwen3.6-35B-A3B-NVFP4` | 22 GB | **116–122** | **82–84** | 0.69 |
| `unsloth/Qwen3.6-35B-A3B-NVFP4-Fast` | 23 GB | 104–107 | 72–74 | 0.70 |
| `unsloth/Qwen3.6-35B-A3B-NVFP4` | 25 GB | 99–104 | 71–75 | 0.72 |

**Findings**

- **The 1.56×/1.79× claim does not transfer to GB10 — it inverts.** Unsloth's
  numbers are **1×B200 at 128-request concurrency** (batch throughput); on GB10
  single-stream the Unsloth quants are **~15% slower** than nvidia's.
- **The size column explains it** — same active-bytes ÷ bandwidth law as every
  eval above. Checkpoint anatomy (from `quantization_config`): nvidia
  (ModelOpt) keeps only `linear_attn` in FP8; Unsloth (compressed-tensors)
  keeps **all attention + `lm_head`** in FP8, and the std variant additionally
  the **last-8-layers' MoE experts** → 25/23 GB resident vs 22 GB, and the extra
  bytes show up directly as decode latency on the ~273 GB/s pool.
- **MTP is intact in all three** (19 `mtp.*` tensors; Unsloth excludes them from
  quantization too). Acceptance is marginally *higher* on Unsloth (0.72 vs
  0.69) — the calibration does help the draft head — but not enough to offset
  the bandwidth cost.
- **Compatibility is clean**: both Unsloth checkpoints load on the nightly with
  the exact `vllm-server.env` flags (quant_method `compressed-tensors` vs
  nvidia's `modelopt` — no flag changes). Output sanity-checked (fizzbuzz, LRU
  cache): correct code, no-think honored.
- **nvidia baseline moved up since 2026-06-25** (112 → 122 tok/s peak) — newer
  nightly, same flags. Worth re-benching baselines when the image tag is a
  moving nightly.

**Verdict**: **stay on `nvidia/Qwen3.6-35B-A3B-NVFP4`** for single-user GB10
serving. Unsloth's pitch is batch-concurrency throughput on datacenter parts
plus accuracy (MMLU-Pro 85.85 etc., unverified here); revisit the Unsloth
quants only if quality issues surface on the nvidia quant — they are a drop-in
swap when that day comes.

---

## Sampling parameters (validation)

Sampling is a **client-side, per-request** choice — not a `models.ini` load
flag (the example file notes recommended values per section for reference). The
values used in the evals above were checked against each vendor's recommendation:

| Model | Used in eval | Vendor recommendation | Match |
| --- | --- | --- | --- |
| Qwen3.6-35B-A3B (instruct) | 0.7 / 0.8 / 20 | instruct: 0.7 / 0.8 / 20 · thinking: 0.6 / 0.95 / 20 | ✅ |
| Qwen3-Coder-Next | 1.0 / 0.95 / 40 | 1.0 / 0.95 / 40 | ✅ |
| Ornith-1.0-35B | 0.6 / 0.95 / 20 | 0.6 / 0.95 / 20 (reasoning) | ✅ |
| Qwen3.6-27B | 0.2 (all, prior eval) | coding: 0.6 / 0.95 / 20 · instruct: 0.7 / 0.8 / 20 | ⚠ low, but uniform |
| gpt-oss-20b | n/a | 1.0 / top_p 1.0 (or 0.95) — tune one, not both | — |

Recommended values for the **resident router models** (send these client-side;
`min_p=0` for all; `presence_penalty=1.5` for long sessions):

| Resident model | instruct / non-thinking | thinking |
| --- | --- | --- |
| Qwen3.6-35B-A3B | 0.7 / 0.8 / 20 | 0.6 / 0.95 / 20 |
| Qwopus3.5-9B (qwen35) | 0.7 / 0.8 / 20 | 0.6 / 0.95 / 20 |
| gpt-oss-20b | temp 1.0 / top_p 1.0 — tune one; control depth via reasoning-effort | — |

(format: temperature / top_p / top_k)

**Notes**

- **Throughput is independent of sampling** — temp/top_p/top_k don't change the
  per-token compute, so the speed conclusions above hold regardless. Sampling
  only affects output text/quality.
- **35B vs Coder-Next is a fair quality comparison**: each ran at its own vendor
  recommendation. The different `top_k` (20 vs 40) is correct — matching them
  would override a vendor default, not improve fairness.
- **The 27B eval used temp=0.2**, below Qwen's coding recommendation (0.6–0.7).
  Applied uniformly to all models, so the *relative* comparison stays valid, and
  low temp favors correctness on deterministic coding tasks. Re-measuring at the
  per-model recommended temps would be stricter but is unlikely to change the
  throughput-driven verdicts.
- **`presence_penalty` / `min_p` were left at defaults.** Qwen recommends
  `presence_penalty=1.5` for the 35B instruct mode to curb repetition; negligible
  on these short tasks but worth setting for long agent sessions.

Sources: HF model cards (Qwen3.6-35B-A3B, Qwen3.6-27B, Qwen3-Coder-Next,
gpt-oss-20b), Muxup vendor-parameter quick reference.
