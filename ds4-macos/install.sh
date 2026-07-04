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
#     plist's ProgramArguments at install time instead of at launch.
#
# The ds4 source is cloned from REPO into SRC if absent; an existing checkout is
# reused as-is. Override any setting via environment, e.g.
#   SRC=/path/to/ds4 MAKE_TARGET=metal ./install.sh
set -euo pipefail

# --- configuration ------------------------------------------------------------
REPO="${REPO:-https://github.com/antirez/ds4.git}"       # upstream source of truth
SRC="${SRC:-$HOME/ghq/github.com/antirez/ds4}"           # local checkout (cloned if absent)
MAKE_TARGET="${MAKE_TARGET:-metal}"                      # metal | cpu

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
    say "Cloning $REPO -> $SRC"
    git clone "$REPO" "$SRC"
fi
[[ -f "$SRC/Makefile" ]] || die "ds4 source not found at SRC=$SRC (clone of $REPO failed?)"

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

# Load DS4_SERVER_ARGS from the (possibly user-edited) env file.
# shellcheck disable=SC1090
source "$ENVFILE"
[[ -n "${DS4_SERVER_ARGS:-}" ]] || die "DS4_SERVER_ARGS is empty in $ENVFILE"

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
# Expand each whitespace-separated flag into its own <string> element, indented
# to match the template's ProgramArguments block. Written to a file (not an awk
# -v var, whose backslash/newline handling would mangle a multi-line block) and
# streamed in when the placeholder line is reached.
args_file="$(mktemp)"
tmp_plist="$(mktemp)"
# Clean up temp files on any exit path (die, plutil failure, awk/sed error).
trap 'rm -f "${args_file:-}" "${tmp_plist:-}"' EXIT
for tok in $DS4_SERVER_ARGS; do
    esc="${tok//&/&amp;}"; esc="${esc//</&lt;}"; esc="${esc//>/&gt;}"
    printf '        <string>%s</string>\n' "$esc" >> "$args_file"
done

say "Rendering $PLIST"
# tmp_plist gives us a staging file so a failed render never truncates an
# existing $PLIST; mv into place only after plutil validates it.
# __DS4_SERVER_ARGS__ sits alone on a line; swap that whole line for the block.
awk -v argsfile="$args_file" '
    /__DS4_SERVER_ARGS__/ {
        while ((getline line < argsfile) > 0) print line
        close(argsfile)
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
# bootout is asynchronous: it returns before the old service (which has ~93GB of
# model mmapped) finishes tearing down. Bootstrapping while it is still attached
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
# bootstrap loads the plist; RunAtLoad starts it. No `kickstart -k` here — that
# would kill the just-started process and reload the ~93GB model a second time.
launchctl bootstrap "$domain" "$PLIST"

# --- 6. wait for readiness ----------------------------------------------------
# kickstart/bootstrap return once launchd has SPAWNED the process, not when the
# server is serving. Without this gate a crash-on-boot (missing model, port in
# use, Metal init failure) is invisible: KeepAlive + ThrottleInterval respawn it
# every 30s and the installer would still print "Done.". Poll the server's own
# "listening on" ready line in the log, bounded, and die with the log path on
# timeout. Model load can take minutes, so the window is generous.
ready_log="$LOGDIR/ds4-server.err.log"
say "Waiting for ds4-server to report ready (model load can take minutes)"
ready=""
for _ in $(seq 1 300); do
    if grep -q 'listening on' "$ready_log" 2>/dev/null; then ready=1; break; fi
    # If launchd gave up (no pid) the process is crash-looping, not still loading.
    if ! launchctl print "$domain/$LABEL" 2>/dev/null | grep -q 'pid = '; then
        sleep 1; continue   # between respawns; keep waiting within the budget
    fi
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
