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
| [`ds4-macos/`](ds4-macos/) | DwarfStar `ds4-server` (`--metal`) | from source (`make metal`) |
| [`vllm-mlx/`](vllm-mlx/) | vllm-mlx `serve` (OpenAI API, MLX backend) | pip (dedicated venv) |

Measured numbers for Apple Silicon — MLX 4-bit format ranking, vllm-mlx thinking
control, and vllm-mlx vs a Metal-built llama.cpp — are in
[`llama.cpp/EVALUATIONS-macos.md`](llama.cpp/EVALUATIONS-macos.md). Headline:
on Apple Silicon the bandwidth law flips the GB10 ranking — MLX `mxfp4` beats
both MLX `nvfp4` and a Metal llama.cpp GGUF at equal bit width.

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
