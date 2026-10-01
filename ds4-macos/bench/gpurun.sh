#!/bin/bash
# The one way any ds4 GPU process is started on this machine.
#
#   gpurun.sh <name> <command> [args...]
#
# 1. An exclusive lock, taken atomically (mkdir) and recorded with the owner's
#    pid. A lock whose owner is gone is cleared; one whose owner is alive
#    refuses the run. No other ds4 process may be running either.
# 2. The machine is checked before anything starts: wired memory, the
#    compressor's free percentage, swap in use. A machine already under
#    pressure refuses the run.
# 3. While the command runs, wired memory, swap growth since the start and the
#    command's resident size are sampled every second. Past the soft line it
#    is asked to stop (SIGTERM: a test closes its engine and reports); past
#    the hard line, or still alive a minute after being asked, it is killed,
#    and the run is marked INVALID - a killed process proves nothing about
#    what a close releases. (The 12:30 panic was a watchdog timeout at 109.7
#    GiB wired, 14 MiB free.) Disk is synced every two seconds so a panic
#    still leaves the log.
# 4. Before and after: process count, wired, free, swap, written to
#    gpurun-<name>.prov beside the command's own output (gpurun-<name>.log).
#
# Limits are fixed here, not taken from the environment.
set -u
S=$(cd "$(dirname "$0")" && pwd)
NAME=${1:?usage: gpurun.sh <name> <command> [args...]}; shift
[ $# -gt 0 ] || { echo "no command" >&2; exit 2; }
LOCK=$HOME/.cache/ds4-gpu.lock
PROV=$S/gpurun-$NAME.prov
OUT=$S/gpurun-$NAME.log
PRE_WIRED_MAX_GIB=16
PRE_FREE_PCT_MIN=50
PRE_SWAP_MAX_GIB=2
SOFT_WIRED_GIB=88
SOFT_SWAP_GROWTH_GIB=4
HARD_WIRED_GIB=100
HARD_SWAP_GROWTH_GIB=10
TERM_GRACE_S=60

mkdir -p "$HOME/.cache"
take_lock() {
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
    local owner; owner=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        echo "REFUSED: GPU lock held by pid $owner" >&2; return 1
    fi
    echo "clearing stale GPU lock (owner ${owner:-unknown} gone)" >&2
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null && { echo $$ > "$LOCK/pid"; return 0; }
    echo "REFUSED: GPU lock contended" >&2; return 1
}
take_lock || exit 3
trap 'rm -rf "$LOCK"' EXIT

pagesize=$(sysctl -n hw.pagesize)
wired_gib() { vm_stat | awk -v p="$pagesize" '/Pages wired down/ {gsub("\\.","",$4); printf "%.2f", $4*p/1073741824}'; }
free_pct() { memory_pressure | awk '/free percentage/ {gsub("%","",$5); print $5}'; }
swap_gib() { sysctl -n vm.swapusage | awk '{v=$6; u=substr(v,length(v)); n=substr(v,1,length(v)-1); if (u=="M") n/=1024; printf "%.2f", n}'; }
ds4_procs() { pgrep -x ds4-server | wc -l | tr -d ' '; }
ds4_tests() { pgrep -f 'tests/test_deepseek41_' | grep -v "^$$\$" | wc -l | tr -d ' '; }
snapshot() { echo "$1 $(date '+%F %T') ds4-server $(ds4_procs) tests $(ds4_tests) wired $(wired_gib) GiB free $(free_pct)% swap $(swap_gib) GiB"; }

{
    echo "command $*"
    echo "cwd $(pwd)"
    snapshot before
} > "$PROV"
if [ "$(ds4_procs)" != 0 ] || [ "$(ds4_tests)" != 0 ]; then
    echo "REFUSED: another ds4 process is running" | tee -a "$PROV" >&2; exit 3
fi
w=$(wired_gib); f=$(free_pct); sw=$(swap_gib)
if awk -v w="$w" -v f="$f" -v s="$sw" -v W=$PRE_WIRED_MAX_GIB -v F=$PRE_FREE_PCT_MIN -v SW=$PRE_SWAP_MAX_GIB \
       'BEGIN { exit !(w > W || f < F || s > SW) }'; then
    echo "REFUSED: machine under pressure (wired $w GiB > $PRE_WIRED_MAX_GIB, free $f% < $PRE_FREE_PCT_MIN, or swap $sw GiB > $PRE_SWAP_MAX_GIB)" | tee -a "$PROV" >&2
    exit 3
fi

( while :; do sync; sleep 2; done ) &
syncer=$!
"$@" > "$OUT" 2>&1 &
child=$!
echo "pid $child" >> "$PROV"
swap0=$(swap_gib)
peak=0; peak_rss=0; peak_sg=0; termed=""; termed_at=0; killed=""
while kill -0 "$child" 2>/dev/null; do
    w=$(wired_gib); sg=$(awk -v a="$(swap_gib)" -v b="$swap0" 'BEGIN { printf "%.2f", a - b }')
    rss=$(ps -o rss= -p "$child" 2>/dev/null | awk '{printf "%.2f", $1/1048576}')
    peak=$(awk -v a="$peak" -v b="$w" 'BEGIN { print (b > a ? b : a) }')
    peak_sg=$(awk -v a="$peak_sg" -v b="$sg" 'BEGIN { print (b > a ? b : a) }')
    peak_rss=$(awk -v a="$peak_rss" -v b="${rss:-0}" 'BEGIN { print (b > a ? b : a) }')
    echo "$(date '+%T') wired $w swap+ $sg rss ${rss:-0}" >> "$S/gpurun-$NAME.samples"
    if awk -v w="$w" -v s="$sg" -v K=$HARD_WIRED_GIB -v KS=$HARD_SWAP_GROWTH_GIB 'BEGIN { exit !(w > K || s > KS) }' ||
       { [ -n "$termed" ] && [ $(( $(date +%s) - termed_at )) -gt $TERM_GRACE_S ]; }; then
        killed="wired $w GiB swap+ $sg GiB${termed:+, $TERM_GRACE_S s after SIGTERM}"
        kill -9 "$child" 2>/dev/null
        break
    fi
    if [ -z "$termed" ] && awk -v w="$w" -v s="$sg" -v K=$SOFT_WIRED_GIB -v KS=$SOFT_SWAP_GROWTH_GIB 'BEGIN { exit !(w > K || s > KS) }'; then
        termed="wired $w GiB swap+ $sg GiB"; termed_at=$(date +%s)
        kill -TERM "$child" 2>/dev/null
    fi
    if grep -q '^paused' "$OUT" 2>/dev/null && [ ! -f "$S/gpurun-$NAME.footprint" ]; then
        footprint -p "$child" > "$S/gpurun-$NAME.footprint" 2>&1
    fi
    sleep 1
done
wait "$child"; rc=$?
kill "$syncer" 2>/dev/null; wait "$syncer" 2>/dev/null
{
    [ -n "$termed" ] && echo "ASKED TO STOP (SIGTERM) at $termed"
    [ -n "$killed" ] && echo "KILLED at $killed - INVALID as a release test"
    echo "rc $rc peak wired $peak GiB, peak swap growth $peak_sg GiB, peak rss $peak_rss GiB"
    snapshot after
} >> "$PROV"
sync
cat "$PROV"
exit $rc
