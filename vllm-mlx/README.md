# vllm-mlx — macOS LaunchAgent deployment

Runs [`vllm-mlx`](https://pypi.org/project/vllm-mlx/) — an OpenAI-compatible
inference server with an MLX (Apple Silicon / Metal) backend — as a per-user
**LaunchAgent**. Same launchd + Metal pattern as [`../ds4-macos/`](../ds4-macos/),
but the engine is a Python package serving MLX checkpoints instead of a C binary
serving GGUFs.

Why vllm-mlx over bare `mlx-lm`: it gives an OpenAI API that matches this repo's
vLLM / llama.cpp deployments **and** real per-request thinking control — clients
pass `chat_template_kwargs={"enable_thinking": false}` to skip the reasoning
preamble, which bare `mlx-lm` cannot do. Measurements and the format/version
matrix are in [`../llama.cpp/EVALUATIONS-macos.md`](../llama.cpp/EVALUATIONS-macos.md).

## Layout

| Path | Purpose |
| --- | --- |
| `$XDG_DATA_HOME/vllm-mlx/venv` | dedicated venv with `vllm-mlx` installed |
| `$XDG_CONFIG_HOME/vllm-mlx/vllm-mlx-server.env` | runtime config (`$VLLM_MLX_MODEL`, `$VLLM_MLX_ARGS`) |
| `$XDG_STATE_HOME/vllm-mlx/logs/` | stdout / stderr of the agent |
| `~/Library/LaunchAgents/com.vllm-mlx.server.plist` | the agent |
| Hugging Face cache (`~/.cache/huggingface`) | the model, downloaded on first launch |

Paths follow the XDG Base Directory spec, split by file kind. macOS has no XDG
defaults of its own, so unless you export the variables these resolve to
`~/.local/share/vllm-mlx/`, `~/.config/vllm-mlx/`, and `~/.local/state/vllm-mlx/`.
Override any single directory with `VENV=`, `CONFDIR=`, or `LOGDIR=`.

## Install / upgrade

```bash
./install.sh                 # create venv + pip install -> render plist -> load agent
$EDITOR "${XDG_CONFIG_HOME:-$HOME/.config}/vllm-mlx/vllm-mlx-server.env"
NO_BUILD=1 ./install.sh      # re-render plist + reload after editing the env
```

Run as your normal user (NOT root, NO sudo) — a LaunchAgent lives in your login
session. Re-running upgrades the package (unless `NO_BUILD=1`), re-renders the
plist, and reloads the agent, then waits for the server to log its `Uvicorn
running` line before reporting done. `RunAtLoad` starts it now and at every login.

The venv uses `python3.12` by default (`PYTHON=python3.13 ./install.sh` to
override). `NO_BUILD=1` skips the pip step and just re-renders/reloads.

## Managing the agent

```bash
launchctl print gui/$(id -u)/com.vllm-mlx.server          # status, last exit
launchctl kickstart -k gui/$(id -u)/com.vllm-mlx.server   # restart
launchctl bootout   gui/$(id -u)/com.vllm-mlx.server      # stop + unload
tail -f "${XDG_STATE_HOME:-$HOME/.local/state}"/vllm-mlx/logs/vllm-mlx-server.err.log  # model-load progress
```

Quick check once it's up (default port 8000):

```bash
curl -s http://127.0.0.1:8000/v1/models | jq -r '.data[].id'
```

## Why a LaunchAgent, not a LaunchDaemon

MLX uses **Metal**, which requires a logged-in GUI session — a boot-time
`LaunchDaemon` runs before login and cannot reach the GPU. So this is a per-user
**LaunchAgent**: it starts when you log in and stops when you log out. If you
need it up without an interactive login, enable auto-login for the account or
keep the session alive with `caffeinate`; a true headless daemon is not an
option for the Metal backend.

## Design notes (the non-obvious bits)

- **Flags are baked into the plist, not read at launch.** launchd does not
  word-split env vars into `ProgramArguments` the way systemd's `ExecStart`
  does, so `install.sh` expands each token of `VLLM_MLX_ARGS` into its own
  `<string>` when it renders the plist. Editing the env file therefore requires
  re-running `install.sh` (use `NO_BUILD=1`).
- **Dedicated venv.** vllm-mlx pins a specific `transformers` (5.12.x) that
  drives `mlx-lm` cleanly; a shared Python can drift and break the tokenizer or
  the loader. Isolating it in `$XDG_DATA_HOME/vllm-mlx/venv` keeps that pin from
  colliding with anything else. See EVALUATIONS-macos.md for the version matrix.
- **Model by name, not by path.** Unlike ds4 (local GGUF), the model is an MLX
  checkpoint resolved from the Hugging Face cache and downloaded on first
  launch. The readiness poll's 600s budget covers that first download.
- **`KeepAlive` only on failure.** `SuccessfulExit=false` relaunches a crash
  (after `ThrottleInterval` seconds) but a clean stop or a `launchctl bootout`
  stays down. `ExitTimeOut=120` gives the model unload a graceful window.
- **No declarative mutual exclusion.** The Linux units time-share one pool via
  systemd `Conflicts=`; launchd has no equivalent. This Mac is expected to run a
  single engine at a time, so `install.sh` only *warns* if the ds4-macos agent
  is loaded. Both default to port **8000**, but they can still co-exist if they
  bind different addresses (e.g. ds4 on the Tailscale/LAN IP, vllm-mlx on
  `127.0.0.1`) — the real constraint is the shared unified-memory pool, not the
  port. To truly free the memory, stop the other:
  `launchctl bootout gui/$(id -u)/com.antirez.ds4-server`.
- **No auth by default.** `--host 127.0.0.1` keeps the API local. Binding to
  `0.0.0.0` exposes an unauthenticated API unless you add `--api-key`; firewall
  the port either way.

## Current model

`mlx-community/Qwen3.6-35B-A3B-mxfp4` — the throughput pick on Apple Silicon
(fastest + smallest of the MLX 4-bit formats). Swap to `-nvfp4` for
cross-hardware parity with the GB10 NVFP4 default, or `-4bit` as an
effectively-equal fallback. See `vllm-mlx-server.env.example` and
[`../llama.cpp/EVALUATIONS-macos.md`](../llama.cpp/EVALUATIONS-macos.md).
