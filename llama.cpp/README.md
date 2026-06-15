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

Override defaults via env: `SRC=/path CUDA_ARCH=121 PREFIX=/opt/llama ./install.sh`.

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

## Current model

Qwen3.6-35B-A3B (MoE, ~20GB UD-Q4_K_XL) via `-hf`, with the model's built-in
multi-token-prediction head driving speculative decoding
(`--spec-type draft-mtp --spec-draft-n-max 2`). See `llama-server.env.example`.
