# ds4-server (DwarfStar) — systemd deployment

Builds DwarfStar with `make` and runs `ds4-server` as a hardened systemd
service. Targeted at the GB10 (Grace Blackwell, sm_121) box but parameterized.

## Layout

| Path | Purpose |
| --- | --- |
| `/opt/ds4/ds4-server` | the binary |
| `/var/lib/ds4/models` | relocated GGUFs (main + optional MTP), readable by the CLI |
| `/var/lib/ds4/models/ds4flash.gguf` | stable alias symlink (the env file's `-m` target) |
| `/var/lib/ds4/kv` | `--kv-disk-dir` on-disk KV cache (0750, service-private) |
| `/etc/ds4/ds4-server.env` | runtime flags (`$DS4_SERVER_ARGS`) |
| `/etc/systemd/system/ds4-server.service` | the unit |

## Install / upgrade

```bash
MODEL_MOVE=1 ./install.sh    # build (make) -> /opt/ds4 -> create user -> relocate GGUFs -> install unit
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

DeepSeek V4 Flash is ~86GB of weights; with KV it cannot share the 128GB unified
memory with the llama.cpp router (~93GB resident) or a vLLM instance. The unit
declares `Conflicts=llama-server.service vllm-server.service`, so
`systemctl start ds4-server` evicts the other engines first and gives ds4 the
pool; `systemctl start llama-server` hands it back. The three are mutually
exclusive — run one at a time, and never `enable` ds4-server.

Override defaults via env: `SRC=/path MAKE_TARGET=cuda-generic ./install.sh`
(`cuda-spark`/`cuda-generic`/`cpu`); `NO_BUILD=1` skips the build.

## Design notes (the non-obvious bits)

- **Models must leave `$HOME`.** The service runs as the unprivileged `ds4`
  user, which cannot traverse a `0750` home — a GGUF left there fails with
  `cannot open model ...: Permission denied`. `install.sh` relocates GGUFs to
  `/var/lib/ds4/models`. Default copies; `MODEL_MOVE=1` moves instead (instant
  on the same filesystem) and leaves a symlink at the source so the `ds4` CLI
  keeps resolving it.
- **MTP is auto-detected from `download_model.sh`.** The draft model name is the
  single source of truth (`MTP_FILE` in `download_model.sh`); the installer
  looks for it in `$GGUF_DIR` (default `<checkout>/gguf`) and relocates it too.
  It stays off until `--mtp <path> --mtp-draft 2` is added to the env file.
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

DeepSeek V4 Flash, IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8 (~86GB), with the optional
MTP draft head (`DeepSeek-V4-Flash-MTP-Q4K-Q8_0-F32`, ~3.8GB) driving
speculative decoding via `--mtp ... --mtp-draft 2`. See `ds4-server.env.example`.
