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

**"Untouched" means re-running `install.sh` rebuilds the same commit.** To move
to a newer upstream, update the checkout first:

```bash
cd "$SRC" && git fetch --tags origin && git checkout b10488
```

Check `/opt/llama/bin/llama-server --version` before assuming a build is recent
— this box sat on b9652 while the tags had reached b10488. For `qwen35` hybrids
(Qwen3.5/3.6/3.8) **b10434 is the floor**: below it, prompts over ~90–100K crash
llama-server silently (fixed by #26623, recurrent state rollback).

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
- **On a multi-GPU box, select by UUID — not by index.** The GB10 has one GPU and
  needs none of this, but elsewhere `CUDA_VISIBLE_DEVICES=1` does *not* mean
  `nvidia-smi`'s GPU 1: CUDA defaults to `CUDA_DEVICE_ORDER=FASTEST_FIRST`, so its
  indices are ranked by speed rather than by PCI bus. With unequal cards that
  quietly loads the model onto the wrong one, and the over-commit does not
  necessarily fail — under WSL2/WDDM it spills into shared host memory and serves
  at a crawl, leaving only `common_fit_params: failed to fit params to free device
  memory` in the log. Put the UUID from
  `nvidia-smi --query-gpu=index,name,uuid,pci.bus_id --format=csv` in
  `llama-server.env` (systemd exports every line of it), then confirm with
  `nvidia-smi` that the memory landed on the card you meant.
- **Splitting layers over two cards trades decode for prefill — it is not a free
  win.** Measured on an RTX 4090 (24GB) + RTX 4090 Laptop (16GB) box with
  Qwen3.8-27B UD-Q4_K_XL, same build and flags, one card vs both:

  | | 24GB card alone | both, layer-split |
  | --- | --- | --- |
  | decode | **79.0 tok/s** | 64.8 tok/s (**-18%**) |
  | prefill (4189 tok) | 2047 tok/s | **2173 tok/s** (**+6%**) |

  MTP draft acceptance was if anything *better* split (0.931 vs 0.912), so the
  decode loss is the split itself, not a speculative-decoding artifact:
  `-sm layer` runs layer ranges serially, so bandwidth-bound decode is gated by
  the slower card, while compute-bound prefill gets the extra SMs. Prefer one
  card when the model fits it. The reason to split anyway is **headroom**, not
  speed — here it frees ~11GB, which is the difference between capping context at
  65536 and fitting the model's native 262144. Going to native context cost no
  further decode (65.1 tok/s at 262144 vs 64.8 at 65536): the 18% is a fixed price
  for splitting, not a price per token of context.
- **If one of the cards drives a display, set `-ts` by hand.** The default split is
  proportional to capacity, which on the box above left the *display* GPU with
  0.5GB free — llama.cpp counts free VRAM, not what the desktop is about to want.
  `-ts 2,1` (weighting the headless card) brought that back to ~1.8GB and also
  silenced `common_fit_params: failed to fit params`. Note `-ts` sets a ratio, not
  a cap: the same 2,1 landed nearer 40:60 than 33:67 in practice, so read
  `nvidia-smi` afterwards rather than trusting the arithmetic.
- **`-ot` offload has to be spread across the layer index, or `-ts` starves a
  card.** `-ts` splits by *layer*, so offloading a contiguous block of layers
  leaves all the remaining weight at one end of the index and the split follows
  it there. Offloading the top 24 layers' experts of a 180B MoE asked for 60:40
  and measured **CUDA0 20705 MiB : CUDA1 1463 MiB — 93:7**, with 40GB of VRAM
  doing the work of 22 and decode at 5.2 tok/s. Offloading the *same volume*
  from every other layer instead gave 13543:8726 and **11.8 tok/s**; thinning it
  to every sixth layer reached **21.5 tok/s**. Same flags, same bytes on the CPU
  — only the stride changed. Print the placement to check it, at `-lv 4`:
  `load_tensors: CUDA0 model buffer size = ...` is not shown at default
  verbosity, which is how three runs got spent on a split nobody could see.

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
- **Removing a model takes both halves, and each half alone fails silently.**
  The router serves the union of `models.ini` sections and whatever it finds in
  the cache directory — `GET /models` labels each entry `source: preset` or
  `source: cache`. So:
  - **Comment out the section, leave the weights** → the model is *still served*,
    now as `source: cache` with no settings, silently inheriting `[*]`'s
    `c = 8192` instead of its own context length.
  - **Move the weights, leave the section** → a request spawns an instance that
    can never load, and the router sits in `ensure_model: waiting until model …
    is fully loaded` **forever**, holding one of the `--models-max` slots. The
    client hangs rather than getting an error; disconnecting it does not clear
    the state. (Same hang as the CUDA-OOM case in
    [EVALUATIONS.md](EVALUATIONS.md) — two triggers, one symptom.)
    `POST /models/unload {"model": "<id>"}` clears it without a restart.

  Do both, and undo both together.
- **`GET /props?model=<id>` loads the model.** It reads like a metadata query and
  is not one: the router routes any request naming a model through `proxy_get`,
  which calls `ensure_model_ready()` whenever `--models-autoload` is on (the
  default). Probing an unloaded model this way blocks for the full load —
  measured **27.5 s** here — and evicts whatever was least recently used. Pass
  **`&autoload=false`** to get a 400 `model is not loaded` in under a
  millisecond instead; that is the safe form for anything on a timer. Confirmed
  in current master (`is_autoload`, `server-models.cpp`), so it is upstream
  behaviour rather than a quirk of the pinned build.

  This also means the router log's `proxy_reques: proxying request to model X`
  does **not** imply inference. `/props` produces it; `/v1/models` does not.
  Counting those lines as usage over-reports any model a dashboard watches.
- A model must be **in the cache before it can be served**. Download once, then
  restart:
  ```bash
  sudo -u llama LLAMA_CACHE=/var/lib/llama/cache /opt/llama/bin/llama-server \
      -hf Jackrong/Qwopus3.5-9B-v3-GGUF:Q8_0 -ngl 0   # Ctrl-C after "model loaded"
  sudo systemctl restart llama-server
  ```
  Prime with **`llama-server`, not `llama download`**. The latter looks like the
  right tool and silently skips the **mmproj**, leaving a vision model text-only:
  `common/arg.cpp` gates mmproj fetching on `mmproj_examples = {MTMD, SERVER, CLI,
  TTS}` and `DOWNLOAD` is absent from that list, so `use_mmproj` is false whatever
  you pass — despite `llama download --help` promising "mmproj is also downloaded
  automatically if available". Sidecars named by `--spec-type` (e.g. an MTP head
  that is *not* embedded in the weights file) come down either way.
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
| `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Q4_K_XL` | ~20GB | Qwen MoE, UD-Q4_K_XL file (router drops the `UD-` prefix), MTP spec-decode (`n_max = 4`), autoloaded on startup |
| `Jackrong/Qwopus3.6-35B-A3B-Coder-MTP-GGUF:Q4_K_M` | ~21.7GB | coding first pick, same base + MTP (`n_max = 3`), **must run thinking-off** |
| `unsloth/Qwen3.8-27B-GGUF:Q4_K_XL` | ~17GB | dense VL, the only vision model needing no extra setup; MTP (`n_max = 6`) |
| `Jackrong/Qwopus3.5-9B-v3-GGUF:Q8_0` | ~9.5GB | Qwen3.5 (`qwen35`) hybrid-SSM **Qwen-VL** finetune, near-lossless quant, no spec-decode; multimodal (mmproj loaded) |

Quant policy: big model → efficient quant (`UD-Q4_K_XL`), small Qwen finetune →
high-quality quant (`Q8_0`). `Qwopus...:Q4_K_M` (~5.6GB) is commented out in
`models.ini.example` — enable it only to compare quantization quality.

**`unsloth/gpt-oss-20b-GGUF:F16` (~13.8GB) was withdrawn on 2026-09-01**, as a
reversible trial rather than a verdict. It had never been evaluated in
[EVALUATIONS.md](EVALUATIONS.md), and the request counts that appeared to
justify its slot were a 30-second dashboard reading `/v1/models` and then
`/props?model=` for each entry — **not inference at all**, and each of those
probes both refreshes LRU and, on an unloaded model, forces a load (see the
`/props` note under Router mode). Weights are parked at
`/var/lib/llama/gpt-oss-20b-GGUF.disabled` and the section is commented out;
restore **both together** (see the removal note under Router mode). With four
models against `--models-max 3` the eviction churn was 46 evictions and 45
load-waits in 14 days — some of which the dashboard caused rather than observed.
The point of the trial is to find out whether anyone misses it, and the
dashboard's traffic cannot answer that: point it at `/v1/models`, or at
`/props?model=…&autoload=false`, before reading the log as usage.

### Context length and KV cache

Each `c` in `models.ini` stays within the model's trained length, so no rope
scaling (YaRN — required only past a model's trained length, at a quality cost):

| Model | Trained ctx | Configured `c` | KV (f16) | Memory type |
| --- | --- | --- | --- | --- |
| Qwen3.6-35B-A3B | 262144 | 262144 | ~26GB | hybrid linear attn — only some layers cache KV (see EVALUATIONS.md) |
| Qwopus3.6-Coder-MTP | 262144 | 262144 | ~26GB | same base as the 35B-A3B |
| Qwen3.8-27B | 262144 | 131072 | ~8GB | dense + hybrid; 16 of 64 layers cache KV (64 KiB/token) |
| Qwopus3.5-9B | 262144 | 131072 | light | `qwen35` hybrid SSM: state-space (Mamba-style) layers + a full-attention layer every `full_attention_interval`; only the full-attn layers cache KV |

None of these use plain full attention: Qwen3.6 and Qwopus (`qwen35`) interleave
state-space / linear-attention layers with periodic full-attention layers — so
only a fraction of layers cache context-growing KV and it stays far below a
dense model's. Qwen runs at full native 262144 (it routinely sees >131k-token
prompts). (Architectures confirmed from GGUF `general.architecture` + per-arch
`ssm.*` / `full_attention_interval` keys.)

**Prompt-cache caveat.** Because of SWA / hybrid-recurrent memory, llama.cpp
cannot reuse cross-request prompt KV for these models — the log shows
`forcing full prompt re-processing due to lack of cache data` ([PR 13194](https://github.com/ggml-org/llama.cpp/pull/13194)).
Every turn re-encodes the whole prompt, so multi-turn latency grows with context
length (most visible on Qwen at high `c`). This is a model-architecture
limitation, not a config bug.

To trim KV when tight: lower a model's `c`, or halve KV with `cache-type-k = q8_0`
/ `cache-type-v = q8_0` (`-ctk/-ctv`, requires `-fa on`). Quality survives it —
measured 2026-09-01, retrieval 5/5 at 181k tokens — but **do not put q8_0 on a
model running `spec-type`**: the cost is a flat ~3% without speculative decoding
and −4/−12/**−25%** at 14k/54k/181k with it, because a verify pass reads KV for
every drafted position. All three MTP residents here therefore stay at f16. See
[EVALUATIONS.md](EVALUATIONS.md).
Read a model's trained length and live KV size from
`journalctl -u llama-server | grep -iE 'n_ctx_train|KV cache'`.
