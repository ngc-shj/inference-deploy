# Model evaluations (GB10 / DGX Spark)

Measured on the resident llama.cpp router (`localhost:8080`), GB10 / 128 GB
unified memory, ~273 GB/s. Linked from [README.md](README.md).

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

## Sampling parameters (validation)

Sampling is a **client-side, per-request** choice — not a `models.ini` load
flag (the example file notes recommended values per section for reference). The
values used in the evals above were checked against each vendor's recommendation:

| Model | Used in eval | Vendor recommendation | Match |
| --- | --- | --- | --- |
| Qwen3.6-35B-A3B (instruct) | 0.7 / 0.8 / 20 | instruct: 0.7 / 0.8 / 20 · thinking: 0.6 / 0.95 / 20 | ✅ |
| Qwen3-Coder-Next | 1.0 / 0.95 / 40 | 1.0 / 0.95 / 40 | ✅ |
| Qwen3.6-27B | 0.2 (all, prior eval) | coding: 0.6 / 0.95 / 20 · instruct: 0.7 / 0.8 / 20 | ⚠ low, but uniform |
| gpt-oss-20b | n/a | 1.0 / top_p 1.0 (or 0.95) — tune one, not both | — |

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
