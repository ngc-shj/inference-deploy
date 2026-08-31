# inference-deploy

Systemd deployments for running local LLM inference engines on a single
**NVIDIA DGX Spark / GB10** box (Grace Blackwell, sm_121, 128 GB unified memory).
Three engines are packaged here; they share the one memory pool and are run
**one at a time**.

## Engines

| Dir | Engine | Role | Build |
| --- | --- | --- | --- |
| [`llama.cpp/`](llama.cpp/) | llama.cpp `llama-server` | **Resident** — the default, always-on router serving several GGUF models at once | from source (CUDA) |
| [`ds4/`](ds4/) | DwarfStar `ds4-server` | On-demand — disk-KV-cache experiments | from source (`make`) |
| [`vllm/`](vllm/) | vLLM (OpenAI API) | On-demand — comparison/benchmarking | container (`nvcr.io/nvidia/vllm` or `vllm/vllm-openai`) |

All three target the GB10 but are parameterized (`CUDA_ARCH`, `PREFIX`, env
files). Each subdirectory has its own README with full install/upgrade steps.

### macOS / Apple Silicon (Metal)

Two engines are also packaged as per-user **LaunchAgents** for Apple Silicon
Macs — the Metal counterparts of the GB10 units. launchd has no `Conflicts=`, so
this Mac is expected to run one engine at a time (the installers warn, they do
not auto-evict).

| Dir | Engine | Build |
| --- | --- | --- |
| [`ds4-macos/`](ds4-macos/) | DwarfStar `ds4-server` (`--metal`) | from source (`make`) |
| [`vllm-mlx/`](vllm-mlx/) | vllm-mlx `serve` (OpenAI API, MLX backend) | pip (dedicated venv) |

**The resident engine on that Mac is a third one, `mlx-serve`, which is not
packaged here** — installed from Homebrew and driven by a hand-written
`com.mlx-serve.flashnext` agent. It holds Qwen3.8-Flash-Next (~70 GB) at
101–104 tok/s with vision, which is why both packaged agents are `RunAtLoad=false`
and started on demand. Its thinking control also differs from everything else in
this repo: `chat_template_kwargs={"enable_thinking": …}` is ignored and a
top-level `reasoning_effort` (`low`/`medium`/`xhigh`) is the only switch, with
the default OFF.

Measured numbers for Apple Silicon — MLX 4-bit format ranking, vllm-mlx thinking
control, and vllm-mlx vs a Metal-built llama.cpp — are in
[`llama.cpp/EVALUATIONS-macos.md`](llama.cpp/EVALUATIONS-macos.md). Headline:
on Apple Silicon the bandwidth law flips the GB10 ranking — MLX `mxfp4` beats
both MLX `nvfp4` and a Metal llama.cpp GGUF at equal bit width.

DeepSeek V4 Flash on ds4 is measured separately in
[`ds4-macos/EVALUATIONS.md`](ds4-macos/EVALUATIONS.md): the 0731 weights are not
distinguishable from their predecessor on single-shot coding tasks, and decode
falls from ~30 tok/s to 4–15 once the rest of the desktop competes with the
model's ~90 GB wired working set — quitting Docker alone restored 4.2 → 30.7.

Prep notes for a model not yet measured — which quantization to pick per box and
what to check before running — are in
[`docs/QWEN3.8-27B-PREP.md`](docs/QWEN3.8-27B-PREP.md) (desk research, not
measurements).

## Mutual exclusion — run one engine at a time

The 128 GB pool fits only one engine's working set at a time. The on-demand
units declare `Conflicts=llama-server.service` (ds4 also conflicts with vllm),
so systemd swaps engines for you — no manual stop needed:

```bash
sudo systemctl start vllm-server     # stops llama-server, vLLM gets the pool
# ... run the comparison ...
sudo systemctl start llama-server    # stops vLLM, llama.cpp resident again
```

- **llama.cpp is the resident engine** — the only one you `enable` (starts on
  boot). It runs in router mode and keeps multiple models loaded.
- **ds4 and vLLM are on-demand** — `start` them for an experiment, never
  `enable` them. Starting either evicts llama.cpp; starting llama.cpp evicts
  them back.

## Layout convention

Each engine directory follows the same shape:

| File | Purpose |
| --- | --- |
| `install.sh` | build/pull → install to `/opt` → create service user → install unit |
| `*-server.service` | the systemd unit (hardened: `ProtectSystem`, `NoNewPrivileges`, …) |
| `*-server.env.example` | runtime flags template → copy to `/etc/<engine>/<engine>-server.env` |
| `README.md` | engine-specific install, design notes, and current config |

Local, machine-specific `*.env` files are gitignored; only the `*.env.example`
templates are tracked.

## Hardware

NVIDIA DGX Spark (GB10): 20-core ARM Neoverse-V2 CPU + Blackwell GPU sharing
**128 GB unified LPDDR5x** at ~273 GB/s. The bandwidth — not capacity — is the
binding constraint for decode throughput, so MoE models with few **active**
parameters run far faster than dense models of similar total size. See
[`llama.cpp/EVALUATIONS.md`](llama.cpp/EVALUATIONS.md) for measured numbers.
