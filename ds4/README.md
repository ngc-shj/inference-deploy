# ds4-server (DwarfStar) — systemd deployment

Builds DwarfStar with `make` and runs `ds4-server` as a hardened systemd
service. Targeted at the GB10 (Grace Blackwell, sm_121) box but parameterized.

## Layout

| Path | Purpose |
| --- | --- |
| `/opt/ds4/ds4-server` | the binary |
| `/var/lib/ds4/models` | relocated GGUFs, readable by the CLI |
| `/var/lib/ds4/models/ds4flash.gguf` | stable alias symlink (the env file's `-m` target) |
| `/var/lib/ds4/kv` | `--kv-disk-dir` on-disk KV cache (0750, service-private) |
| `/etc/ds4/ds4-server.env` | runtime flags (`$DS4_SERVER_ARGS`) |
| `/etc/systemd/system/ds4-server.service` | the unit |

## Install / upgrade

```bash
# download the model first (see "Downloading the model")
MODEL_MOVE=1 MODEL_SRC=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf ./install.sh
sudoedit /etc/ds4/ds4-server.env
sudo systemctl start ds4-server   # ON-DEMAND — do NOT enable (see below)
journalctl -u ds4-server -f
...
sudo systemctl start llama-server # done — restore the llama.cpp router
```

Run as a normal user (NOT root); privileged steps call `sudo` themselves so the
build does not run as root. Re-running rebuilds (incremental), reinstalls, and
`daemon-reload`s. After a unit change, `sudo systemctl restart ds4-server`.

### On-demand only — do NOT `enable` this service

DeepSeek V4.1 Flash streams its weights from SSD but still plans ~81 GiB
resident at the configured 64GB expert-cache budget (104 GiB with the automatic
one); it cannot share the 128GB unified memory with the llama.cpp router (~93GB
resident) or a vLLM instance. The unit declares
`Conflicts=llama-server.service vllm-server.service`, so
`systemctl start ds4-server` evicts the other engines first and gives ds4 the
pool; `systemctl start llama-server` hands it back. The three are mutually
exclusive — run one at a time, and never `enable` ds4-server.

The ds4 source is cloned from `REPO` (default
`https://github.com/antirez/ds4.git`) into `SRC` when the checkout is absent; an
existing `SRC` is reused untouched. Override defaults via env:
`SRC=/path MAKE_TARGET=cuda-generic ./install.sh`
(`cuda-spark`/`cuda-generic`/`cpu`); `NO_BUILD=1` skips the build.

### Downloading the model

The V4.1 Flash Q2 GGUF is 341 GiB and is read continuously while serving, so it
must sit on the local NVMe. Upstream's `./download_model.sh ds41f-q2` works and
verifies the SHA-256, but when `HF_TOKEN` is unset it reads
`~/.cache/huggingface/token` and passes it as `hf download --token <token>`,
readable by every local account through `ps` for the whole ~3 h download.
Call the CLI directly instead — it picks up the stored token itself:

```bash
hf download antirez/deepseek-v4.1-flash-gguf DeepSeek-V4.1-Flash-Q2.gguf \
  --local-dir ~/ghq/github.com/antirez/ds4/gguf
sha256sum ~/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
# compare with the ds41f-q2 expected_sha in download_model.sh
```

`MODEL_MOVE=1` is not optional at this size: the installer copies by default,
and a second 341 GiB does not fit.

## Design notes (the non-obvious bits)

- **Models must leave `$HOME`.** The service runs as the unprivileged `ds4`
  user, which cannot traverse a `0750` home — a GGUF left there fails with
  `cannot open model ...: Permission denied`. `install.sh` relocates GGUFs to
  `/var/lib/ds4/models`. Default copies; `MODEL_MOVE=1` moves instead (instant
  on the same filesystem) and leaves a symlink at the source so the `ds4` CLI
  keeps resolving it.
- **No speculative decoding for V4.1.** DSpark and MTP are not implemented for
  V4.1 on CUDA. Upstream also dropped the standalone V4 MTP download, so the
  installer's MTP auto-detection (keyed on `MTP_FILE` in `download_model.sh`)
  now finds nothing.
- **No `LimitMEMLOCK` needed.** V4.1's encoder-residency `mlock` path is
  Metal-only (`ds41_encoder_acquire` returns immediately off Apple); CUDA stages
  experts into its own bounded device cache.
- **`StateDirectoryMode=0755`** (llama.cpp uses `0750`): the ds4 CLI is also run
  as a normal user and reads the same models, so `/var/lib/ds4` must be
  traversable. The `kv/` subdir stays `0750`, service-private.
- **`Type=simple`, no readiness signal.** ds4-server has no `sd_notify`, and
  model load is slow, so systemd marks it started immediately — load progress
  shows up in journald, not as a `systemctl start` that blocks until ready.
- **Hardening**: `ProtectSystem=strict`, `ProtectHome=read-only`. NVIDIA device
  nodes are left visible on purpose — `PrivateDevices=true` and
  `MemoryDenyWriteExecute=true` both break the CUDA runtime.

## Current model

DeepSeek V4.1 Flash **Q2** (`DeepSeek-V4.1-Flash-Q2.gguf`, 341 GiB, of which
189 GiB is Engram that stays on disk) on engine 6e4c285, served with
`--cuda --ssd-streaming --ctx 32768 --ssd-streaming-cache-experts 64GB`. See
`ds4-server.env.example`.

Expect **7–8 tok/s decode and 12–26 s to the first token even for a short
prompt** — this is the quality option, not the fast one. The explicit 64GB
budget costs 14–29% decode against the automatic one, which on this box pushes
other processes into swap and logs `NVRM ... NV_ERR_NO_MEMORY`; ds4 sets
`oom_score_adj=1000` on itself, so it is the first thing the kernel kills.
Upstream validates `--ctx` up to 65536 under SSD streaming.

The server thinks at high effort by default; send `think:false` (or
`model=deepseek-chat`) for direct answers. Measurements, and what replaced
Flash 0731, are in [EVALUATIONS.md](EVALUATIONS.md). 0731 is no longer on disk;
the previous engine is kept as `/opt/ds4/ds4-server.e34a808`.
