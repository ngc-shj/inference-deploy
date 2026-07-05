# Local coding-model study on GB10 (DGX Spark) — 2026-06 / 07

A focused evaluation of agentic-coding LLMs on the resident llama.cpp router
(`localhost:8080`, GB10 / 128 GB unified memory, ~273 GB/s). This is the
narrative summary; per-run tables and raw numbers live in
[EVALUATIONS.md](EVALUATIONS.md).

## TL;DR

- **Winner for local coding: `Jackrong/Qwopus3.6-35B-A3B-Coder-MTP` (Q4_K_M).**
  95–100 tok/s no-think — faster than the resident 35B-A3B (63–78) — with equal
  task ability. Same Qwen3.6-35B-A3B base + embedded MTP, so it drops into the
  identical `spec-type=draft-mtp` slot. Apache-2.0.
- **MTP is the deciding factor** on this bandwidth-bound box. Models with an MTP
  head hit high draft-acceptance (0.76–1.00) and pull ahead; `Ornith-1.0-35B`
  has none and is capped at ~63 tok/s despite the same active-param count.
- **Run coding finetunes no-think.** Both Coder-MTP and Ornith over-think by
  default and blow the token budget with empty code; `enable_thinking=false`
  fixes it.
- **Quant advice doesn't transfer from wide-bandwidth GPUs.** Q5_K_M, "free
  quality" on an RTX 5090, runs ~half speed on GB10.

## Models evaluated

| Model | Base | Active | MTP | Q4 tok/s (no-think) | Verdict |
| --- | --- | --- | --- | --- | --- |
| **Qwopus3.6-35B-A3B-Coder-MTP** | Qwen3.6-35B-A3B | ~3B | ✓ | **95–100** | **adopted — coding first pick** |
| Qwen3.6-35B-A3B (resident) | Qwen3.6-35B-A3B | ~3B | ✓ | 63–78 | kept — general resident |
| Ornith-1.0-35B | Qwen3.5/Gemma4 | ~3B | ✗ | 63 | dropped — superseded, cache deleted |
| Qwen3-Coder-Next 80B-A3B | Qwen3 | 3B | ✗ | 37–44 | dropped — 49.6 GB, slower, cache deleted |
| Qwen3.6-27B (unsloth) | Qwen3.6 | dense+hybrid | ✓ | 24 | dropped — downgrade to 35B, cache deleted |
| Qwen3.6-27B pi-tune (bytkim) | Qwen3.6 | dense+hybrid | ✓ | 26 | kept on-demand — no-think agent niche |

(All Q4-class quants, warm decode, single-shot. Full conditions in EVALUATIONS.md.)

## Why throughput is what it is here

Decode on GB10 is **memory-bandwidth ÷ active-parameter-bytes**, not total
params. Two consequences drove every result:

1. **MTP wins.** Multi-token prediction lets the model verify several drafted
   tokens per forward pass. On templated code the draft-acceptance rate is very
   high (measured 0.76–1.00), so effective tok/s climbs well past a non-MTP model
   of the same active size. This is the single biggest lever — it's why Coder-MTP
   (95–100) beats the same-base resident (63–78) beats Ornith (63, no MTP).
2. **Resident GB matters too.** More streamed weight per token = slower even at
   equal active params. Qwen3-Coder-Next (49.6 GB) runs slower than the 20 GB
   35B-A3B despite both being active-3B MoE, and the two can't co-reside in
   128 GB.

## The quantization trap (Q4 vs Q5)

An external article (RTX 5090) found Q5_K_M best for Ornith: same speed as Q4,
+5 pt coding accuracy. **On GB10 that reverses** — Q5_K_M ran ~half the tok/s of
Q4_K_M (33 vs 63), re-confirmed across repeats. GB10's ~273 GB/s makes the
heavier Q5_K weights and their costlier dequant show up directly as latency; the
RTX 5090's ~1.8 TB/s hides it. Also: two Ornith quants co-resident CUDA-OOM.
**Takeaway: pick quants on your own hardware; wide-bandwidth-GPU quant advice
does not carry to a bandwidth-bound box.** We stay on Q4_K_M.

## The thinking trap

Both Ornith and Coder-MTP are reasoning finetunes that default to thinking-on.
Even on trivial tasks they emit thousands of chars of chain-of-thought
(2.3k–32k observed) and can hit the token cap before producing code. llama.cpp
exposes this as `reasoning_content`. Fix:

```jsonc
{ "chat_template_kwargs": { "enable_thinking": false } }
```

No-think gives immediate, correct, fastest output. Pin it for agent loops.

## Agent-loop validation

Beyond single-shot generation, models were driven through a real
**read → edit → run → verify** loop with `opencode` pointed at the router
(provider = `@ai-sdk/openai-compatible`, `baseURL=http://localhost:8080/v1`):

- **Single-file task** (fix an unimplemented `*` operator in an RPN calculator):
  Coder-MTP and Ornith both passed — ran tests, patched the right branch,
  re-verified, left tests untouched.
- **Multi-file task** (implement two order-dependent discount rules in
  `pricing.py` across a 3-file project, keep existing tests green): Coder-MTP and
  the resident 35B-A3B both passed 5/5 with correct rule ordering and the `>=50`
  threshold; comparable tool round-trips and token counts. Ability is a tie;
  Coder-MTP wins on speed.

Tooling note: **`codex` 0.130.0 does not work with llama.cpp** — it now requires
`wire_api = "responses"` (OpenAI Responses API), which llama.cpp doesn't speak.
Use a chat-completions CLI (opencode, aider).

## Recommended local setup

- **Resident (general, always loaded):** `Qwen3.6-35B-A3B-MTP` (vision-capable),
  `Qwopus3.5-9B-v3` (small, vision), `gpt-oss-20b` (non-Qwen, adjustable
  reasoning).
- **Coding first pick:** `Qwopus3.6-35B-A3B-Coder-MTP:Q4_K_M` — point
  opencode/aider here. Same MTP slot as the resident 35B-A3B, faster, Apache-2.0.
  Run no-think, Qwen3-family sampling (temp 0.7 / top_p 0.8 / top_k 20).
- **Escalation:** for frontier-quality tasks, a hosted Kimi/GLM-class model by
  API — the local tier is small-to-mid MoE with active ~3B; larger coders either
  don't fit or are bandwidth-starved on this box.

## Cache state (2026-07-05)

Retired GGUF caches were deleted to reclaim disk (~85 GB): `Ornith-1.0-35B`
(superseded by Coder-MTP), `Qwen3-Coder-Next` (49.6 GB, slower, can't
co-reside), `Qwen3.6-27B-MTP` unsloth (downgrade to the 35B). Remaining cache:
the three residents + `Qwopus3.6-Coder-MTP` + `Qwen3.6-27B-pi-tune` (kept as a
no-think agent option).
