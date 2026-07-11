# llama.cpp llama-server — systemd deployment

Builds llama.cpp with CUDA and runs `llama-server` as a hardened systemd
service. Targeted at the GB10 (Grace Blackwell, sm_121) box but parameterized.

## Layout

| Path | Purpose |
| --- | --- |
| `/opt/llama/bin`, `/opt/llama/lib` | binaries + bundled shared libs (rpath `$ORIGIN/../lib`) |
| `/var/lib/llama/models` | manually-placed GGUF files (`-m ...`) |
| `/var/lib/llama/cache` | `LLAMA_CACHE` — `-hf` auto-downloads land here |
| `/etc/llama/llama-server.env` | runtime flags (`$LLAMA_SERVER_ARGS`) |
| `/etc/llama/models.ini` | per-model router presets (`--models-preset`) |
| `/etc/systemd/system/llama-server.service` | the unit |

## Install / upgrade

```bash
./install.sh                 # build (CUDA) -> /opt/llama -> create user -> install unit
sudoedit /etc/llama/llama-server.env
sudo systemctl enable --now llama-server
journalctl -u llama-server -f
```

Re-running `install.sh` rebuilds (ccache-less but incremental), reinstalls, and
`daemon-reload`s. After a unit change, `sudo systemctl restart llama-server`.

The llama.cpp source is cloned from `REPO` (default
`https://github.com/ggml-org/llama.cpp.git`) into `SRC` when the checkout is
absent; an existing `SRC` is reused untouched. Override defaults via env:
`SRC=/path CUDA_ARCH=121 PREFIX=/opt/llama ./install.sh`.

## Design notes (the non-obvious bits)

- **No `/home/linuxbrew` dependency.** A Homebrew `pkg-config`/curl/openssl is on
  PATH; configure uses `PKG_CONFIG_LIBDIR` (replaces, not prepends, the search
  path) plus explicit `OPENSSL_*` so the binary links only system + CUDA libs.
  `install.sh` aborts before installing if `ldd` shows any linuxbrew lib.
- **`CMAKE_INSTALL_RPATH=$ORIGIN/../lib`** so `/opt/llama/bin/llama-server` finds
  its sibling `.so`s without ldconfig pollution. CUDA libs resolve via the
  existing `/etc/ld.so.conf.d/*cuda*` entries.
- **`stdbuf -oL -eL`** in `ExecStart`: llama.cpp block-buffers stdio to a pipe,
  so without this the model-download/load progress never reaches journald until
  the port is already up (looks hung).
- **Hardening**: `ProtectSystem=strict`, `ProtectHome=read-only`. NVIDIA device
  nodes are left visible on purpose — `PrivateDevices=true` and
  `MemoryDenyWriteExecute=true` both break the CUDA runtime.

## Router mode (switch models from the client)

The default config runs `llama-server` in **router mode**: no model on the
command line, so the router forwards each request to the matching model instance
based on the OpenAI `model` field. Clients switch models without restarting the
server.

```jsonc
// POST /v1/chat/completions
{ "model": "Jackrong/Qwopus3.5-9B-v3-GGUF:Q8_0", "messages": [...] }
```

- **`llama-server.env`** holds *global* flags inherited by every instance
  (`-ngl 999 -fa on`), plus `--models-max` (resident model cap) and
  `--models-preset /etc/llama/models.ini`.
- **`models.ini`** holds *per-model* flags. Model-specific options like
  `--spec-type draft-mtp` (needs the MTP head) **must** live here, not in the
  global args, or non-MTP models would break. Section name = the model ID the
  router exposes; confirm it with `curl -s localhost:8080/v1/models | jq -r '.data[].id'`.
- A model must be **in the cache before it can be served**. Download once, then
  restart:
  ```bash
  sudo -u llama LLAMA_CACHE=/var/lib/llama/cache /opt/llama/bin/llama-server \
      -hf Jackrong/Qwopus3.5-9B-v3-GGUF:Q8_0 -ngl 0   # Ctrl-C after "model loaded"
  sudo systemctl restart llama-server
  ```
- **GGUF only.** Safetensors-only HF repos must be converted with
  llama.cpp's `convert_hf_to_gguf.py` first, then placed under
  `/var/lib/llama/models` and referenced from a preset section with
  `model = /var/lib/llama/models/<file>.gguf`.

To pin a single model instead (ignoring the `model` field), use a single-model
`LLAMA_SERVER_ARGS` line — see the commented examples in
`llama-server.env.example`.

## Current models

Model comparisons and throughput numbers measured on this box live in
[EVALUATIONS.md](EVALUATIONS.md). The same models measured on Apple Silicon
(MLX) are in [EVALUATIONS-macos.md](EVALUATIONS-macos.md).

Served side by side via the router (clients pick one per request):

| Model ID | Size | Notes |
| --- | --- | --- |
| `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Q4_K_XL` | ~20GB | Qwen MoE, UD-Q4_K_XL file (router drops the `UD-` prefix), MTP spec-decode, autoloaded on startup |
| `Jackrong/Qwopus3.5-9B-v3-GGUF:Q8_0` | ~9.5GB | Qwen3.5 (`qwen35`) hybrid-SSM **Qwen-VL** finetune, near-lossless quant, no spec-decode; multimodal (mmproj loaded) |
| `unsloth/gpt-oss-20b-GGUF:F16` | ~13.8GB | OpenAI MoE (non-Qwen family), MXFP4-native, adjustable reasoning effort |

Quant policy: big model → efficient quant (`UD-Q4_K_XL`), small Qwen finetune →
high-quality quant (`Q8_0`), gpt-oss → `F16` (its experts are natively MXFP4, so
F16 *is* near-full quality and lower quants gain little). All three fit resident
at once (see KV math below), so `--models-max 3` keeps them loaded with no reload
on switch. `Qwopus...:Q4_K_M` (~5.6GB) is commented out in `models.ini.example` —
enable it only to compare quantization quality.

### Context length and KV cache

Each `c` in `models.ini` stays within the model's trained length, so no rope
scaling (YaRN — required only past a model's trained length, at a quality cost):

| Model | Trained ctx | Configured `c` | KV (f16) | Memory type |
| --- | --- | --- | --- | --- |
| Qwen3.6-35B-A3B | 262144 | 262144 | ~26GB | hybrid linear attn — only some layers cache KV (see EVALUATIONS.md) |
| gpt-oss-20b | 131072 (native) | 131072 | ~4GB | alternating sliding-window attention |
| Qwopus3.5-9B | 262144 | 131072 | light | `qwen35` hybrid SSM: state-space (Mamba-style) layers + a full-attention layer every `full_attention_interval`; only the full-attn layers cache KV |

None of these use plain full attention: Qwen3.6 and Qwopus (`qwen35`) interleave
state-space / linear-attention layers with periodic full-attention layers,
gpt-oss uses sliding-window attention — so only a fraction of layers cache
context-growing KV and it stays far below a dense model's. Qwen runs at full
native 262144 (it routinely sees >131k-token prompts). Resident weights (~45GB) +
KV total well under the 128GB pool. (Architectures confirmed from GGUF
`general.architecture` + per-arch `ssm.*` / `full_attention_interval` keys.)

**Prompt-cache caveat.** Because of SWA / hybrid-recurrent memory, llama.cpp
cannot reuse cross-request prompt KV for these models — the log shows
`forcing full prompt re-processing due to lack of cache data` ([PR 13194](https://github.com/ggml-org/llama.cpp/pull/13194)).
Every turn re-encodes the whole prompt, so multi-turn latency grows with context
length (most visible on Qwen at high `c`). This is a model-architecture
limitation, not a config bug.

To trim KV when tight: lower a model's `c`, or halve KV with `cache-type-k = q8_0`
/ `cache-type-v = q8_0` (`-ctk/-ctv`, requires `-fa on`, negligible quality loss).
Read a model's trained length and live KV size from
`journalctl -u llama-server | grep -iE 'n_ctx_train|KV cache'`.
