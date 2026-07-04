# ds4-server (DwarfStar) — macOS LaunchAgent deployment

Builds DwarfStar with `make metal` and runs `ds4-server` as a per-user
**LaunchAgent** on Apple Silicon (Metal). This is the macOS counterpart of
[`../ds4/`](../ds4/), which targets a Linux/CUDA box with systemd.

## Layout

| Path | Purpose |
| --- | --- |
| `<checkout>/ds4-server` | the binary (built in place, run from the checkout) |
| `<checkout>/*.gguf`, `<checkout>/gguf/` | models, read directly from the checkout |
| `$XDG_CONFIG_HOME/ds4/ds4-server.env` | runtime flags (`$DS4_SERVER_ARGS`) |
| `$XDG_CACHE_HOME/ds4/server-kv` | `--kv-disk-dir` on-disk KV cache |
| `$XDG_STATE_HOME/ds4/logs/` | stdout / stderr of the agent |
| `~/Library/LaunchAgents/com.antirez.ds4-server.plist` | the agent |

Paths follow the XDG Base Directory spec, split by file kind. macOS has no XDG
defaults of its own, so unless you export the variables these resolve to
`~/.config/ds4/`, `~/.cache/ds4/`, and `~/.local/state/ds4/`. Override any single
directory with `CONFDIR=`, `KVDIR=`, or `LOGDIR=`.

## Install / upgrade

```bash
./install.sh                 # build (make metal) -> render plist -> load agent
$EDITOR "${XDG_CONFIG_HOME:-$HOME/.config}/ds4/ds4-server.env"
NO_BUILD=1 ./install.sh      # re-render plist + reload after editing the env
```

Run as your normal user (NOT root, NO sudo) — a LaunchAgent lives in your login
session. Re-running rebuilds (incremental), re-renders the plist, and reloads the
agent. `RunAtLoad` starts it now and at every login.

The ds4 source is cloned from `REPO` (default
`https://github.com/antirez/ds4.git`) into `SRC` when the checkout is absent; an
existing `SRC` is reused untouched. Override defaults via env:
`SRC=/path MAKE_TARGET=cpu ./install.sh`; `NO_BUILD=1` skips the build.

## Managing the agent

```bash
launchctl print gui/$(id -u)/com.antirez.ds4-server          # status, last exit
launchctl kickstart -k gui/$(id -u)/com.antirez.ds4-server   # restart
launchctl bootout   gui/$(id -u)/com.antirez.ds4-server      # stop + unload
tail -f "${XDG_STATE_HOME:-$HOME/.local/state}"/ds4/logs/ds4-server.err.log  # model-load progress
```

## Why a LaunchAgent, not a LaunchDaemon

`ds4-server` uses **Metal**, which requires a logged-in GUI session — a
boot-time `LaunchDaemon` runs before login and cannot reach the GPU. So this is a
per-user **LaunchAgent**: it starts when you log in and stops when you log out.
If you need it up without an interactive login, enable auto-login for the account
or keep the session alive with `caffeinate`; a true headless daemon is not an
option for the Metal backend.

## Design notes (the non-obvious bits)

- **Flags are baked into the plist, not read at launch.** systemd word-splits
  `$DS4_SERVER_ARGS` in `ExecStart`; launchd does not split env vars into
  `ProgramArguments`. So `install.sh` expands each flag from
  `ds4-server.env` into its own `<string>` when it renders the plist. Editing the
  env file therefore requires re-running `install.sh` (use `NO_BUILD=1`).
- **No service account, no model relocation.** The agent runs as you, so it can
  already read GGUFs inside your `$HOME` checkout. The Linux unit needs a
  dedicated `ds4` user and moves models out of a `0750` home; none of that
  applies here.
- **`KeepAlive` only on failure.** `SuccessfulExit=false` means a crash is
  relaunched (after `ThrottleInterval` seconds) but a clean stop or a
  `launchctl bootout` stays down. `ExitTimeOut=120` gives the slow model unload a
  graceful window before SIGKILL.
- **No mutual-exclusion.** The Linux box time-shares one 128GB pool between
  llama.cpp / vLLM / ds4 via systemd `Conflicts=`. This Mac runs ds4 as the sole
  engine, so there is nothing to evict.
- **`--host 0.0.0.0` exposes an unauthenticated API.** The default is
  `127.0.0.1`. If you bind to the LAN, firewall the port — the server has no auth.

## Current model

DeepSeek V4 Flash (see [`../ds4/`](../ds4/) and the repo's `download_model.sh`),
optionally with the MTP draft head for speculative decoding
(`--mtp <file> --mtp-draft 2`). MTP helps predictable output (code, structured
lists); on divergent free-form text its draft-acceptance rate is low and it can
be marginally slower. See `ds4-server.env.example`.
