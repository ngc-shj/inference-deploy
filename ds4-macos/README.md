# ds4-server (DwarfStar) — macOS LaunchAgent deployment

Builds DwarfStar with `make` and runs `ds4-server` as a per-user
**LaunchAgent** on Apple Silicon (Metal). This is the macOS counterpart of
[`../ds4/`](../ds4/), which targets a Linux/CUDA box with systemd.

## Layout

| Path | Purpose |
| --- | --- |
| `<checkout>/ds4-server` | the binary (built in place, run from the checkout) |
| `<checkout>/*.gguf`, `<checkout>/gguf/` | models, read directly from the checkout |
| `$XDG_CONFIG_HOME/ds4/ds4-server.env` | runtime flags (`$DS4_SERVER_ARGS`) and engine switches (`$DS4_SERVER_ENV`) |
| `$XDG_CACHE_HOME/ds4/server-kv` | `--kv-disk-dir` on-disk KV cache (optional; not in the default flags) |
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
NO_START=1 ./install.sh      # render + load, but leave it stopped
```

Run as your normal user (NOT root, NO sudo) — a LaunchAgent lives in your login
session. Re-running rebuilds (incremental), re-renders the plist, and reloads the
agent, then waits for the server to log its `listening on` line before reporting
done. The installer starts it explicitly; `RunAtLoad` is **false**, so it does
NOT come back at the next login — start it when you want it (see below). It
refuses to start while `com.mlx-serve.flashnext` or `com.vllm-mlx.server` is
running: V4.1's 80 GiB budget assumes it has the machine to itself. Stop the
other engine first; the installer does not evict it for you.

Directory overrides (`KVDIR=`, `CONFDIR=`, `LOGDIR=`) only take effect on the
first install — an existing env file is left untouched, so its `--kv-disk-dir` is
frozen at first seed. To move the KV path later, edit the env file directly.

The ds4 source is cloned from `REPO` (default
`https://github.com/ngc-shj/ds4.git`, the fork that carries the V4.1 Metal 4
production) into `SRC` and checked out at `REF` (default
`ds4-v41-metal4-superbatch-exact-production-documented`) when the checkout is
absent; an existing `SRC` is reused untouched, with a warning if it is not at
`REF`. Override defaults via env: `SRC=/path MAKE_TARGET=cpu ./install.sh`;
`NO_BUILD=1` skips the build.

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
  `ds4-server.env` into its own `<string>` when it renders the plist, and each
  `KEY=VALUE` of `$DS4_SERVER_ENV` into the plist's `EnvironmentVariables`. V4.1
  production is defined by fifteen of those switches as much as by its flags, so
  an env file without them runs a different engine. Editing the env file
  therefore requires re-running `install.sh` (use `NO_BUILD=1`).
- **No service account, no model relocation.** The agent runs as you, so it can
  already read GGUFs inside your `$HOME` checkout. The Linux unit needs a
  dedicated `ds4` user and moves models out of a `0750` home; none of that
  applies here.
- **No `KeepAlive`, so no restart on crash.** launchd.plist(5): any
  `KeepAlive` "implicitly implies RunAtLoad". The agent used to carry
  `KeepAlive{SuccessfulExit=false}` beside `RunAtLoad=false`, and launchd started
  it at every login and every `bootstrap` regardless. With V4.1 prewarming ~58
  GiB of experts at startup that is no longer a ~5 MB idle process, so the key is
  gone: a crash leaves it down until you start it. `ExitTimeOut=120` gives the
  model unload a graceful window before SIGKILL.
- **No mutual-exclusion, and nothing enforces the convention.** The Linux box
  time-shares one 128GB pool between llama.cpp / vLLM / ds4 via systemd
  `Conflicts=`; launchd has no equivalent. Both agents tracked here are
  `RunAtLoad=false` with no `KeepAlive` (see above), so neither starts on its
  own and co-tenancy is a decision — but that is a convention, not a guarantee, and the failure is silent: ~90 GB
  for ds4 plus ~19 GB for vllm-mlx was the actual state through a day of
  benchmarking, undetected because free memory looks the same whether the pool
  is committed or not. It costs streamed models ~14% and residency nothing (see
  [EVALUATIONS.md](EVALUATIONS.md)).
  The live risk is no longer vllm-mlx: this Mac's resident engine is **mlx-serve**
  (`com.mlx-serve.flashnext`, ~70 GB for Qwen3.8-Flash-Next, not packaged in this
  repo), and an idle `ds4-server` holds only ~5 MB, so a stopped-looking ds4 that
  is merely *loaded* wires tens of GB the moment one request arrives. The
  installer now refuses to *start* ds4 beside a running mlx-serve or vllm-mlx,
  but a manual `kickstart` is not checked. Before measuring anything, check all
  three:

  ```bash
  launchctl print gui/$(id -u)/com.antirez.ds4-server
  launchctl print gui/$(id -u)/com.vllm-mlx.server
  launchctl print gui/$(id -u)/com.mlx-serve.flashnext
  ```

- **`--host 0.0.0.0` exposes an unauthenticated API.** The default is
  `127.0.0.1`. If you bind to the LAN, firewall the port — the server has no auth.

## Current model

DeepSeek V4.1 Flash, calibrated **Q2** (`DeepSeek-V4.1-Flash-Q2.gguf`, 341 GiB
on disk: 152 GiB of main weights plus 189 GiB of Engram tables), run with
`--ssd-streaming` — on 128 GB it cannot be resident. The engine is the Metal 4
build fixed as the exact production on the `ngc-shj/ds4` fork, tag
[`ds4-v41-metal4-superbatch-exact-production-documented`](https://github.com/ngc-shj/ds4/tree/ds4-v41-metal4-superbatch-exact-production-documented):
its outputs are bit-identical to a frozen reference build. The tag's README has
the download, the launch command and what each switch does;
`ds4-server.env.example` is that command split into `DS4_SERVER_ENV` and
`DS4_SERVER_ARGS`, with the port moved to 8000.

The startup log should say the cache was fitted from 10268 to 7034 experts, the
backend is Metal 4, and 77.99 GiB is planned.

## Measured throughput

From the tag's README, on this machine: a 4795-token prompt's first prefill
takes about 35 s on a cool machine and slows under back-to-back long prompts as
the GPU heats (about 35, 38 and 55 s for three in a row); decode is about 45 ms
a token once the expert cache is warm. Earlier measurements of upstream builds
are in [EVALUATIONS.md](EVALUATIONS.md).

It is not the resident engine. On the same 49 prompts it was somewhat more
accurate than Qwen3.8-Flash-Next and took 69.7 minutes against 15.4 (see
[../llama.cpp/EVALUATIONS-macos.md](../llama.cpp/EVALUATIONS-macos.md),
2026-10-10), so it is started on demand for work where accuracy matters more
than latency.
