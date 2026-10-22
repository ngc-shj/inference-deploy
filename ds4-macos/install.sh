#!/usr/bin/env bash
#
# Build ds4-server (DwarfStar) and install it as a macOS LaunchAgent (Metal).
#
# This is the macOS counterpart of ../ds4/install.sh (Linux/systemd). Differences
# that follow from launchd + Metal:
#   - Runs as the logged-in user (NO service account, NO sudo). Metal needs a GUI
#     login session, so this must be a LaunchAgent, not a boot-time LaunchDaemon.
#   - Models stay in the checkout: the agent runs as you and can already read them,
#     so there is no relocation out of $HOME.
#   - launchd does not word-split env vars, so DS4_SERVER_ARGS is expanded into the
#     plist's ProgramArguments, and DS4_SERVER_ENV into its EnvironmentVariables,
#     at install time instead of at launch.
#
# The ds4 source is cloned from REPO into SRC and checked out at REF if absent; an
# existing checkout is reused as-is. Override any setting via environment, e.g.
#   SRC=/path/to/ds4 MAKE_TARGET=all ./install.sh
# NO_START=1 renders and loads the agent without starting it.
set -euo pipefail

# --- configuration ------------------------------------------------------------
# V4.1 production lives on the ngc-shj/ds4 fork, not upstream; REF is its tag.
REPO="${REPO:-https://github.com/ngc-shj/ds4.git}"
REF="${REF:-ds4-v41-metal4-superbatch-exact-production-documented}"
SRC="${SRC:-$HOME/ghq/github.com/ngc-shj/ds4}"           # local checkout (cloned if absent)
# On Darwin the Metal build IS the default target; there is no `metal` target.
# A `metal/` directory exists in the checkout, so `make metal` matches that
# directory and silently succeeds without building anything.
MAKE_TARGET="${MAKE_TARGET:-all}"                        # all (Metal) | cpu

# XDG Base Directory layout, split by file kind (each dir overridable via env):
#   config -> ds4-server.env   (user configuration)
#   cache  -> server-kv        (regenerable KV checkpoints)
#   state  -> logs             (volatile runtime logs)
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CONFDIR="${CONFDIR:-$XDG_CONFIG_HOME/ds4}"
KVDIR="${KVDIR:-$XDG_CACHE_HOME/ds4/server-kv}"
LOGDIR="${LOGDIR:-$XDG_STATE_HOME/ds4/logs}"
LABEL="com.antirez.ds4-server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ENVFILE="${ENVFILE:-$CONFDIR/ds4-server.env}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UID_NUM="$(id -u)"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "this installer is for macOS; use ../ds4 on Linux"
[[ $EUID -ne 0 ]] || die "run as your normal user, not root (a LaunchAgent runs per-user)"

# Clone the upstream source of truth if the checkout is missing. An existing $SRC
# is left untouched (pull/update is the user's call, not the installer's).
if [[ ! -d "$SRC" ]]; then
    say "Cloning $REPO -> $SRC at $REF"
    git clone "$REPO" "$SRC"
    git -C "$SRC" checkout -q --detach "$REF"
fi
[[ -f "$SRC/Makefile" ]] || die "ds4 source not found at SRC=$SRC (clone of $REPO failed?)"
# An existing checkout at another commit would run a different engine under the
# production's settings; say so rather than move it.
if want="$(git -C "$SRC" rev-parse -q --verify "$REF^{commit}" 2>/dev/null)" \
    && [[ "$(git -C "$SRC" rev-parse HEAD)" != "$want" ]]; then
    printf '\033[1;33mWARNING:\033[0m %s is not at %s; the env file was measured on that tag.\n' "$SRC" "$REF" >&2
fi

# --- 1. build -----------------------------------------------------------------
if [[ -z "${NO_BUILD:-}" ]]; then
    say "Building ds4-server ($MAKE_TARGET) in $SRC"
    make -C "$SRC" "$MAKE_TARGET"
fi
[[ -x "$SRC/ds4-server" ]] || die "$SRC/ds4-server not found; build it or unset NO_BUILD"

# --- 2. directories -----------------------------------------------------------
# Own-only (700) on config/cache/logs: the env file may carry a bind address and
# the cache/logs hold inference-derived data. Matches the Linux sibling's 0750
# intent. Cheap defense-in-depth on a shared-account Mac; a no-op on a single-user
# one. $HOME/Library/LaunchAgents is a macOS-standard dir — leave its mode alone.
say "Preparing config=$CONFDIR cache=$KVDIR state=$LOGDIR"
mkdir -p "$CONFDIR" "$KVDIR" "$LOGDIR" "$HOME/Library/LaunchAgents"
chmod 700 "$CONFDIR" "$KVDIR" "$LOGDIR"

# --- 3. env file --------------------------------------------------------------
# Seed the env file from the template on first run; leave an existing one alone.
if [[ ! -f "$ENVFILE" ]]; then
    sed "s#__KVDIR__#$KVDIR#g" "$HERE/ds4-server.env.example" > "$ENVFILE"
    say "Wrote $ENVFILE — review host/port/ctx/model (add --mtp to enable MTP)"
else
    say "$ENVFILE already exists; leaving it untouched"
fi

# Load DS4_SERVER_ARGS and DS4_SERVER_ENV from the (possibly user-edited) env file.
# shellcheck disable=SC1090
source "$ENVFILE"
[[ -n "${DS4_SERVER_ARGS:-}" ]] || die "DS4_SERVER_ARGS is empty in $ENVFILE"
DS4_SERVER_ENV="${DS4_SERVER_ENV:-}"
for kv in $DS4_SERVER_ENV; do
    [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || die "'$kv' in DS4_SERVER_ENV is not KEY=VALUE; fix $ENVFILE"
done

# Validate model paths before rendering. ds4-server resolves -m/--mtp relative to
# WORKDIR (the checkout), so a wrong path (a bare MTP filename that actually lives
# under gguf/, say) otherwise fails only at launch — after install.sh reports
# success. Catch it here. Absolute paths are checked as-is.
check_model_path() {
    local p="$1" resolved
    [[ "$p" == /* ]] && resolved="$p" || resolved="$SRC/$p"
    [[ -e "$resolved" ]] || die "model path '$p' not found (resolved to $resolved); fix $ENVFILE"
}
set -- $DS4_SERVER_ARGS
while [[ $# -gt 0 ]]; do
    case "$1" in
        # A value-less trailing flag would make `shift 2` overrun the args and,
        # under `set -e`, abort with no context. die() with the real cause instead.
        -m|--model|--mtp)
            [[ -n "${2:-}" ]] || die "$1 has no value in $ENVFILE"
            check_model_path "$2"
            shift 2 ;;
        *) shift ;;
    esac
done

# --- 4. render plist ----------------------------------------------------------
# Expand each whitespace-separated flag into its own <string> element, and each
# KEY=VALUE of DS4_SERVER_ENV into a <key>/<string> pair, indented to match the
# template's ProgramArguments and EnvironmentVariables blocks. Written to files (not an awk
# -v var, whose backslash/newline handling would mangle a multi-line block) and
# streamed in when the placeholder line is reached.
args_file="$(mktemp)"
env_file="$(mktemp)"
tmp_plist="$(mktemp)"
# Clean up temp files on any exit path (die, plutil failure, awk/sed error).
trap 'rm -f "${args_file:-}" "${env_file:-}" "${tmp_plist:-}"' EXIT
xml_escape() { local v="${1//&/&amp;}"; v="${v//</&lt;}"; printf '%s' "${v//>/&gt;}"; }
for tok in $DS4_SERVER_ARGS; do
    printf '        <string>%s</string>\n' "$(xml_escape "$tok")" >> "$args_file"
done
for kv in $DS4_SERVER_ENV; do
    printf '        <key>%s</key>\n        <string>%s</string>\n' \
        "${kv%%=*}" "$(xml_escape "${kv#*=}")" >> "$env_file"
done

say "Rendering $PLIST"
# tmp_plist gives us a staging file so a failed render never truncates an
# existing $PLIST; mv into place only after plutil validates it.
# Each placeholder sits alone on a line; swap that whole line for its block.
awk -v argsfile="$args_file" -v envfile="$env_file" '
    /__DS4_SERVER_ARGS__/ {
        while ((getline line < argsfile) > 0) print line
        close(argsfile)
        next
    }
    /__DS4_SERVER_ENV__/ {
        while ((getline line < envfile) > 0) print line
        close(envfile)
        next
    }
    { print }
' "$HERE/com.antirez.ds4-server.plist.example" \
    | sed \
        -e "s#__PREFIX__#$SRC#g" \
        -e "s#__WORKDIR__#$SRC#g" \
        -e "s#__LOGDIR__#$LOGDIR#g" \
    > "$tmp_plist"

plutil -lint "$tmp_plist" >/dev/null || die "generated plist failed validation"
mv "$tmp_plist" "$PLIST"

# --- 5. (re)load the agent ----------------------------------------------------
# bootout is idempotent-ish: ignore "not loaded", then bootstrap.
domain="gui/$UID_NUM"
say "Reloading LaunchAgent in $domain"
# bootout is asynchronous: it returns before the old service (which has tens of
# GB of model and expert cache mapped) finishes tearing down. Bootstrapping while it is still attached
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
# "listening on" line, not a stale one from a previous run.
: > "$LOGDIR/ds4-server.err.log" 2>/dev/null || true
# bootstrap loads the plist. The agent has RunAtLoad=false and no KeepAlive (any
# KeepAlive implies RunAtLoad; see the plist), so nothing is running yet and
# kickstart has to start it explicitly. Plain `kickstart`, not `-k`: the
# latter would kill and respawn, reloading the model a second time.
launchctl bootstrap "$domain" "$PLIST"
if [[ -n "${NO_START:-}" ]]; then
    say "Loaded, not started (NO_START). Start it with: launchctl kickstart $domain/$LABEL"
    exit 0
fi
# V4.1 plans ~78 GiB of a 128 GB pool, so a second resident engine leaves macOS
# too little; the 80 GiB budget assumes it is alone. Refuse to start rather than
# evict — stopping the resident engine is the user's call.
for other in com.mlx-serve.flashnext com.vllm-mlx.server; do
    if launchctl print "$domain/$other" 2>/dev/null | grep -q 'pid = '; then
        die "$other is running; stop it first (launchctl bootout $domain/$other), then: launchctl kickstart $domain/$LABEL"
    fi
done
launchctl kickstart "$domain/$LABEL"

# --- 6. wait for readiness ----------------------------------------------------
# kickstart/bootstrap return once launchd has SPAWNED the process, not when the
# server is serving. Without this gate a crash-on-boot (missing model, port in
# use, Metal init failure) is invisible: the process exits and the installer
# would still print "Done.". Poll the server's own
# "listening on" ready line in the log, bounded, and die with the log path on
# timeout. Model load can take minutes, so the window is generous.
ready_log="$LOGDIR/ds4-server.err.log"
say "Waiting for ds4-server to report ready (model load can take minutes)"
ready=""
for _ in $(seq 1 300); do
    if grep -q 'listening on' "$ready_log" 2>/dev/null; then ready=1; break; fi
    # No KeepAlive, so no respawn: a process that is gone has died during startup.
    launchctl print "$domain/$LABEL" 2>/dev/null | grep -q 'pid = ' \
        || die "ds4-server exited during startup; check $ready_log and: launchctl print $domain/$LABEL"
    sleep 1
done
[[ -n "$ready" ]] || die "ds4-server did not report ready within 300s; check $ready_log and: launchctl print $domain/$LABEL"

cat <<EOF

$(say "Done — ds4-server is listening.")
Binary : $SRC/ds4-server
Model  : resolved against $SRC (see -m in $ENVFILE)
Config : $ENVFILE
Cache  : $KVDIR (kv-disk)
Logs   : $LOGDIR
Agent  : $PLIST  (label $LABEL)

Manage:
  launchctl print $domain/$LABEL          # status
  launchctl kickstart -k $domain/$LABEL   # restart
  launchctl bootout $domain/$LABEL        # stop + unload
  tail -f $LOGDIR/ds4-server.err.log      # startup / model-load progress

Change flags: edit $ENVFILE then re-run ./install.sh (NO_BUILD=1 to skip rebuild).
EOF
