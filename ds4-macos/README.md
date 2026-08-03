# ds4-server (DwarfStar) — macOS LaunchAgent deployment

Builds DwarfStar with `make` and runs `ds4-server` as a per-user
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
./install.sh                 # build (make) -> render plist -> load agent
$EDITOR "${XDG_CONFIG_HOME:-$HOME/.config}/ds4/ds4-server.env"
NO_BUILD=1 ./install.sh      # re-render plist + reload after editing the env
```

Run as your normal user (NOT root, NO sudo) — a LaunchAgent lives in your login
session. Re-running rebuilds (incremental), re-renders the plist, and reloads the
agent, then waits for the server to log its `listening on` line before reporting
done. `RunAtLoad` starts it now and at every login.

Directory overrides (`KVDIR=`, `CONFDIR=`, `LOGDIR=`) only take effect on the
first install — an existing env file is left untouched, so its `--kv-disk-dir` is
frozen at first seed. To move the KV path later, edit the env file directly.

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

- **There is no `make metal` target.** On Darwin the Metal build is the
  Makefile's default target; `metal` names only the `metal/` shader directory in
  the checkout, so `make metal` matches that directory and exits "Nothing to be
  done" — a silent no-op that leaves a stale binary in place while the installer
  reports success. `MAKE_TARGET` therefore defaults to `all`.
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
- **No mutual-exclusion, and nothing enforces the convention.** The Linux box
  time-shares one 128GB pool between llama.cpp / vLLM / ds4 via systemd
  `Conflicts=`; launchd has no equivalent. [`../vllm-mlx/`](../vllm-mlx/)
  installs its own `RunAtLoad` agent, so both engines start at login and sit on
  the pool together — ~90 GB for ds4 plus ~19 GB for vllm-mlx was the actual
  state during a day of benchmarking here, undetected because free memory looks
  the same either way. Before measuring anything, check:
  `launchctl print gui/$(id -u)/com.vllm-mlx.server`. It costs streamed models
  ~14% and residency nothing (see [EVALUATIONS.md](EVALUATIONS.md)).
- **`--host 0.0.0.0` exposes an unauthenticated API.** The default is
  `127.0.0.1`. If you bind to the LAN, firewall the port — the server has no auth.

## Current model

DeepSeek V4 Flash **0731**, q2 quant
(`IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731`, 86.7 GB), with the
MTP draft head for speculative decoding (`--mtp <file> --mtp-draft 2`). ds4's
guidance is that MTP helps predictable output (code, structured lists) and can
be marginally slower on divergent text, but an A/B over three alternated reps
measured no difference either way on a coding workload — 16.1 against 16.6
tok/s, inside the run-to-run spread. It stays on. See
[EVALUATIONS.md](EVALUATIONS.md) and `ds4-server.env.example`.

`download_model.sh` in the ds4 checkout has no `-0731` target as of `54b36ed`;
its filenames are hardcoded and not env-overridable, so the 0731 GGUFs have to
be pulled directly from
[antirez/deepseek-v4-gguf](https://huggingface.co/antirez/deepseek-v4-gguf) and
the `ds4flash.gguf` symlink repointed by hand. Use `curl -C -` with
`--speed-limit 1024 --speed-time 60`: without the stall timeout a network change
mid-transfer leaves a half-open connection that `--retry` never notices, and the
download hangs silently.

## Measured throughput

Numbers and protocol are in [EVALUATIONS.md](EVALUATIONS.md). The short version:
decode runs at ~30 tok/s with memory to spare and falls to 4–15 tok/s when the
rest of the desktop crowds it out, and a server restart does not clear it —
**quitting Docker took the same prompt from 4.2 back to 30.7 tok/s.**

The model wires ~90 GB, leaving ~35 GB for everything else. Keep heavy
applications closed while serving. When throughput drops, read `vm_stat` free
pages and compressor size — *not* `vm.swapusage`, which reports a file macOS
resizes on its own and stays flat through a collapse. Activity Monitor's
`ds4-server` row is misleading for the same reason: the model is counted under
wired memory, not against the process.
