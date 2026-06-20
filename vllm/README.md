# vLLM vllm-server — systemd deployment (NGC container)

Runs vLLM's OpenAI-compatible API as a hardened systemd service, backed by the
NVIDIA NGC container `nvcr.io/nvidia/vllm`. Targeted at the GB10 (Grace
Blackwell, sm_121) box but parameterized.

Unlike the `llama.cpp` and `ds4` deployments here (bare-metal binaries built from
source), vLLM runs from a **pre-built container**: NVIDIA ships and QA's the NGC
image for DGX Spark / GB10 (aarch64, sm_121), so there is no source build to fight
with CUDA 13 / aarch64 wheels. The systemd unit just runs `docker run`.

## Layout

| Path | Purpose |
| --- | --- |
| `nvcr.io/nvidia/vllm:<tag>` | the container image (pulled on first start) |
| `/var/lib/vllm/cache` | `HF_HOME` bind mount — model weights download here |
| `/etc/vllm/vllm-server.env` | runtime config (image tag, model, host/port, flags) |
| `/etc/systemd/system/vllm-server.service` | the unit (runs `docker run`) |

## Install

```bash
./install.sh                 # install unit + env template, prepare HF cache
sudoedit /etc/vllm/vllm-server.env   # pin VLLM_IMAGE tag, set VLLM_MODEL
sudo systemctl start vllm-server     # do NOT enable — this is on-demand (see below)
journalctl -u vllm-server -f         # watch image pull + model load
...
sudo systemctl start llama-server    # done comparing — hand memory back to llama.cpp
```

`install.sh` does no build — it installs the unit, writes the env template
(0640, it may hold `HF_TOKEN`), and pre-creates `/var/lib/vllm/cache`. It warns
if the NVIDIA container runtime is missing from `docker info`. Re-running is
idempotent and leaves an existing env file untouched.

Override paths via env: `CONF=/etc/vllm STATE=/srv/vllm ./install.sh`.

## ⚠️ On-demand only — do NOT `enable` this service

The GB10 has **128GB of unified memory shared by GPU and CPU**, and the
`llama.cpp` router already holds its 3-model resident set at up to **~93GB** (see
[`../llama.cpp/README.md`](../llama.cpp/README.md)) — in practice the box sits at
**~17GB free**. There is no room for vLLM to live alongside it. So vLLM here is
**an on-demand engine for comparison/experiments, not a resident service**:

- **Never `systemctl enable vllm-server`.** Start it by hand when you want it,
  stop it when done.
- The unit declares **`Conflicts=llama-server.service`**, so
  `systemctl start vllm-server` makes systemd **stop llama-server first**,
  freeing the whole pool for vLLM. When finished, `systemctl start llama-server`
  hands the memory back. The two never run resident together.

```bash
sudo systemctl start vllm-server     # stops llama-server, vLLM gets the pool
# ... compare ...
sudo systemctl start llama-server    # stops vLLM, llama.cpp resident again
nvidia-smi ; free -g                 # check the unified pool either way
```

`--gpu-memory-utilization` is a **fraction of *total* device memory, reserved up
front** (not of free space). Because `Conflicts=` clears llama.cpp out of the
way, this deployment can run it high — it ships at **`0.60`** (≈73GB). If you
ever deliberately run both at once, drop it hard (`0.20`) or the box OOMs.

> Note: `Conflicts=` is declared on the vLLM unit, so starting vLLM reliably
> stops llama-server. The reverse (starting llama-server stops vLLM) also holds
> because systemd treats Conflicts as mutual — but vLLM is the transient one, so
> the normal flow is: start vLLM → experiment → start llama-server to restore.

## Design notes (the non-obvious bits)

- **Container unit, foreground.** `ExecStart` runs `docker run --rm` *without*
  `-d`, so systemd supervises the container as its own process and journald
  captures vLLM's logs directly. `ExecStartPre` removes any stale
  `vllm-server` container left by an unclean shutdown (else `--name` collides).
- **`--shm-size=8g`.** vLLM's worker processes pass tensors over `/dev/shm`; the
  Docker default (64MB) deadlocks engine startup. This is the single most common
  cause of a "hangs at load" container.
- **`--host 0.0.0.0` *inside* the container, bind address *outside*.** The
  process listens on `0.0.0.0:8000` within the container; host exposure is
  controlled by the `-p ${VLLM_HOST}:${VLLM_PORT}:8000` mapping. Binding to
  `127.0.0.1` inside the container would make it unreachable. Default
  `VLLM_HOST=127.0.0.1` keeps the API local-only; set `0.0.0.0` to expose on the
  LAN (then firewall it — vLLM has no auth unless you add `--api-key`).
- **Pin the image tag.** Tags are monthly (`YY.MM-py3`). Use an explicit tag,
  not `:latest`, so restarts are reproducible. DGX Spark / GB10 support landed in
  `26.01-py3`; use that or newer.
- **No GGUF.** vLLM serves Hugging Face `safetensors` repos directly (and many
  pre-quantized formats: FP8, AWQ, GPTQ). Point `VLLM_MODEL` at the HF handle;
  the GGUF files under `/var/lib/llama/models` are for llama.cpp only.

## Current model

| Model | Format | Notes |
| --- | --- | --- |
| `openai/gpt-oss-20b` | MXFP4 (HF) | OpenAI MoE; ~14GB weights, NVIDIA's Spark vLLM example. Deliberately the **same** 20B that llama.cpp serves (as GGUF) and Ollama serves (as a blob) — so this instance is a like-for-like cross-engine comparison. Served at `--gpu-memory-utilization 0.60`, `--max-model-len 32768`. |

The 20B weights exist in three formats on this box on purpose (Ollama blob,
llama.cpp GGUF, vLLM safetensors) — they are not shareable across engines, and
keeping all three is what lets you compare them. If you only want vLLM to cover
ground llama.cpp can't, point `VLLM_MODEL` at something else (e.g. a Qwen FP8
checkpoint) instead.

vLLM serves **one model per process** — there is no llama.cpp-style router. To
run a second model, copy the env file, change `VLLM_MODEL` and `VLLM_PORT`, and
start a second instance.

## Smoke test

```bash
curl -s http://127.0.0.1:8000/v1/models | jq -r '.data[].id'
curl -s http://127.0.0.1:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"openai/gpt-oss-20b","messages":[{"role":"user","content":"2+2?"}]}'
```
