#!/usr/bin/env bash
#
# Install vllm-mlx as a macOS LaunchAgent: an OpenAI-compatible MLX inference
# server on Apple Silicon (Metal).
#
# This mirrors ../ds4-macos/install.sh (also a LaunchAgent + Metal), with two
# differences that follow from vllm-mlx being a Python package, not a C binary:
#   - No `make`: the server is installed into a dedicated venv via pip.
#   - No model relocation or path check: the model is an MLX checkpoint resolved
#     by name from the Hugging Face cache and downloaded on first launch.
#
# Like the ds4 sibling: runs as the logged-in user (NO service account, NO sudo)
# because Metal needs a GUI login session, and launchd does not word-split env
# vars, so VLLM_MLX_ARGS is expanded into the plist at install time.
#
# Override any setting via environment, e.g.
#   VENV=/path/to/venv PYTHON=python3.12 ./install.sh
set -euo pipefail

# --- configuration ------------------------------------------------------------
PYTHON="${PYTHON:-python3.12}"                            # interpreter for the venv

# XDG Base Directory layout, split by file kind (each dir overridable via env):
#   config -> vllm-mlx-server.env  (user configuration)
#   data   -> venv                 (the installed package + interpreter)
#   state  -> logs                 (volatile runtime logs)
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CONFDIR="${CONFDIR:-$XDG_CONFIG_HOME/vllm-mlx}"
VENV="${VENV:-$XDG_DATA_HOME/vllm-mlx/venv}"
LOGDIR="${LOGDIR:-$XDG_STATE_HOME/vllm-mlx/logs}"
LABEL="com.vllm-mlx.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ENVFILE="${ENVFILE:-$CONFDIR/vllm-mlx-server.env}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UID_NUM="$(id -u)"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "this installer is for macOS (MLX/Metal); there is no CUDA equivalent"
[[ $EUID -ne 0 ]] || die "run as your normal user, not root (a LaunchAgent runs per-user)"

# launchd has no systemd `Conflicts=`, so mutual exclusion is not declarative.
# This Mac is expected to run a single inference engine at a time (see README).
# Warn — don't stop it for the user — if a sibling agent (ds4-macos) is loaded,
# since it shares the port (8000) and the unified-memory pool.
if launchctl print "gui/$(id -u)/com.antirez.ds4-server" >/dev/null 2>&1; then
    printf '\033[1;33mWARNING:\033[0m ds4-macos (com.antirez.ds4-server) is loaded — it also uses port 8000 and the memory pool.\n' >&2
    printf '         Stop it first:  launchctl bootout gui/%s/com.antirez.ds4-server\n' "$(id -u)" >&2
fi

# --- 1. venv + package --------------------------------------------------------
# A dedicated venv keeps vllm-mlx's transformers pin from colliding with any
# other Python on this machine (see EVALUATIONS-macos.md — the version matrix is
# finicky). Reused if present; pass NO_BUILD=1 to skip the pip step on re-runs.
if [[ -z "${NO_BUILD:-}" ]]; then
    if [[ ! -d "$VENV" ]]; then
        command -v "$PYTHON" >/dev/null || die "$PYTHON not found; install it (brew install python@3.12) or set PYTHON="
        say "Creating venv at $VENV ($PYTHON)"
        "$PYTHON" -m venv "$VENV"
    fi
    say "Installing/upgrading vllm-mlx into $VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet --upgrade vllm-mlx
fi
VLLM_MLX_BIN="$VENV/bin/vllm-mlx"
[[ -x "$VLLM_MLX_BIN" ]] || die "$VLLM_MLX_BIN not found; run without NO_BUILD to install it"

# --- 2. directories -----------------------------------------------------------
# Own-only (700) on config/logs: the env file may carry a bind address / api-key
# and the logs hold inference-derived data. $HOME/Library/LaunchAgents is a
# macOS-standard dir — leave its mode alone.
say "Preparing config=$CONFDIR venv=$VENV state=$LOGDIR"
mkdir -p "$CONFDIR" "$LOGDIR" "$HOME/Library/LaunchAgents"
chmod 700 "$CONFDIR" "$LOGDIR"

# --- 3. env file --------------------------------------------------------------
# Seed the env file from the template on first run; leave an existing one alone.
if [[ ! -f "$ENVFILE" ]]; then
    cp "$HERE/vllm-mlx-server.env.example" "$ENVFILE"
    say "Wrote $ENVFILE — review model/host/port (see the comments)"
else
    say "$ENVFILE already exists; leaving it untouched"
fi

# Load VLLM_MLX_MODEL and VLLM_MLX_ARGS from the (possibly user-edited) env file.
# shellcheck disable=SC1090
source "$ENVFILE"
[[ -n "${VLLM_MLX_MODEL:-}" ]] || die "VLLM_MLX_MODEL is empty in $ENVFILE"
[[ -n "${VLLM_MLX_ARGS:-}" ]] || die "VLLM_MLX_ARGS is empty in $ENVFILE"

# --- 4. render plist ----------------------------------------------------------
# Expand each whitespace-separated flag into its own <string> element, indented
# to match the template's ProgramArguments block. Written to a file (not an awk
# -v var, whose backslash/newline handling would mangle a multi-line block) and
# streamed in when the placeholder line is reached.
args_file="$(mktemp)"
tmp_plist="$(mktemp)"
# Clean up temp files on any exit path (die, plutil failure, awk/sed error).
trap 'rm -f "${args_file:-}" "${tmp_plist:-}"' EXIT
for tok in $VLLM_MLX_ARGS; do
    esc="${tok//&/&amp;}"; esc="${esc//</&lt;}"; esc="${esc//>/&gt;}"
    printf '        <string>%s</string>\n' "$esc" >> "$args_file"
done

say "Rendering $PLIST"
# tmp_plist gives us a staging file so a failed render never truncates an
# existing $PLIST; mv into place only after plutil validates it.
# __VLLM_MLX_ARGS__ sits alone on a line; swap that whole line for the block.
awk -v argsfile="$args_file" '
    /__VLLM_MLX_ARGS__/ {
        while ((getline line < argsfile) > 0) print line
        close(argsfile)
        next
    }
    { print }
' "$HERE/com.vllm-mlx.server.plist.example" \
    | sed \
        -e "s#__VLLM_MLX_BIN__#$VLLM_MLX_BIN#g" \
        -e "s#__VLLM_MLX_MODEL__#$VLLM_MLX_MODEL#g" \
        -e "s#__LOGDIR__#$LOGDIR#g" \
    > "$tmp_plist"

plutil -lint "$tmp_plist" >/dev/null || die "generated plist failed validation"
mv "$tmp_plist" "$PLIST"

# --- 5. (re)load the agent ----------------------------------------------------
domain="gui/$UID_NUM"
say "Reloading LaunchAgent in $domain"
# bootout is asynchronous: it returns before the old service (which has ~20GB of
# model resident) finishes tearing down. Bootstrapping while it is still attached
# to the domain fails with "Bootstrap failed: 5: Input/output error". Wait for the
# label to actually disappear before re-bootstrapping.
if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$domain/$LABEL" 2>/dev/null || true
    for _ in $(seq 1 60); do
        launchctl print "$domain/$LABEL" >/dev/null 2>&1 || break
        sleep 1
    done
    launchctl print "$domain/$LABEL" >/dev/null 2>&1 \
        && die "old service still attached after 60s; run: launchctl bootout $domain/$LABEL"
fi
# Truncate the log first so the readiness poll below matches THIS boot's
# "Uvicorn running" line, not a stale one from a previous run.
: > "$LOGDIR/vllm-mlx-server.err.log" 2>/dev/null || true
# bootstrap loads the plist; RunAtLoad starts it. No `kickstart -k` here — that
# would kill the just-started process and reload the model a second time.
launchctl bootstrap "$domain" "$PLIST"

# --- 6. wait for readiness ----------------------------------------------------
# bootstrap returns once launchd has SPAWNED the process, not when the server is
# serving. Without this gate a crash-on-boot (bad model name, port in use, Metal
# init failure) is invisible: KeepAlive + ThrottleInterval respawn it every 30s
# and the installer would still print "Done.". Poll uvicorn's own ready line,
# bounded, and die with the log path on timeout. First launch also downloads the
# model, so the window is generous.
ready_log="$LOGDIR/vllm-mlx-server.err.log"
say "Waiting for vllm-mlx to report ready (first-run model download can take a while)"
ready=""
for _ in $(seq 1 600); do
    if grep -q 'Uvicorn running' "$ready_log" 2>/dev/null; then ready=1; break; fi
    # If launchd gave up (no pid) the process is crash-looping, not still loading.
    if ! launchctl print "$domain/$LABEL" 2>/dev/null | grep -q 'pid = '; then
        sleep 1; continue   # between respawns; keep waiting within the budget
    fi
    sleep 1
done
[[ -n "$ready" ]] || die "vllm-mlx did not report ready within 600s; check $ready_log and: launchctl print $domain/$LABEL"

cat <<EOF

$(say "Done — vllm-mlx is listening.")
Server : $VLLM_MLX_BIN serve $VLLM_MLX_MODEL
Model  : $VLLM_MLX_MODEL (Hugging Face cache)
Config : $ENVFILE
Venv   : $VENV
Logs   : $LOGDIR
Agent  : $PLIST  (label $LABEL)

Manage:
  launchctl print $domain/$LABEL          # status
  launchctl kickstart -k $domain/$LABEL   # restart
  launchctl bootout $domain/$LABEL        # stop + unload
  tail -f $LOGDIR/vllm-mlx-server.err.log # startup / model-load progress

Change model or flags: edit $ENVFILE then re-run ./install.sh (NO_BUILD=1 to skip the pip step).
EOF
