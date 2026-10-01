#!/bin/bash
# The one way any ds4 GPU process is started on this machine.
#
#   gpurun.sh <name> <command> [args...]
#   gpurun.sh --selftest-soft|--selftest-hard <name> <command> [args...]
#       the guard itself, on processes that touch no GPU: the soft or hard
#       line is put at zero so it fires at once, and the pressure check is
#       skipped; the lock is taken and released as for a real run
#
# 1. An exclusive lock, taken atomically (mkdir) and recorded with the owner's
#    pid. A lock whose owner is gone is cleared; one whose owner is alive
#    refuses the run. No other ds4 process may be running either.
# 2. The machine is checked before anything starts: the kernel's memory
#    pressure level must be normal, wired memory low, the free percentage
#    enough for the run. Swap in use is recorded, not judged: macOS keeps it
#    long after the load that made it is gone; what is watched is its growth
#    during the run.
# 3. The command runs as the leader of a process group of its own, and the
#    group, not the command, is what is watched and stopped: a script that
#    starts ds4-server and is itself stopped must not leave the server running
#    unwatched (14:55, p8179). Every second: wired memory, the kernel's
#    pressure level, swap growth since the start, and the group's summed
#    physical footprint (memwatch; GPU allocations are in it, a resident size
#    misses them); every other second the Metal allocations of its largest
#    process ("IOAccelerator (graphics)" in footprint(1), which matched the
#    engine's own device count to 0.3 GiB). Past the soft line the group is
#    asked to stop (SIGTERM: a test closes its engine and reports, the server
#    drains) and has a minute to do it. Past the hard line the group gets
#    SIGTERM and five seconds, then SIGKILL; so does a group still alive a
#    minute after the soft request. A killed run is marked INVALID - a killed
#    process proves nothing about what a close releases. (The 12:30 panic was
#    a watchdog timeout at 109.7 GiB wired, 14 MiB free.) The watch goes on
#    until the group is empty: if the command exits and leaves members behind,
#    they are asked to stop as at the soft line. Disk is synced every two
#    seconds so a panic still leaves the log.
# 4. Before and after: process count, wired, free, swap, written to
#    gpurun-<name>.prov beside the command's own output (gpurun-<name>.log).
#    The lock is released only once the group is empty.
#
# Limits are fixed here, not taken from the environment. They are the last
# guard, not the budget: a normal run is expected to stay below the soft line.
set -u
S=$(cd "$(dirname "$0")" && pwd)
SELFTEST=""
case "${1:-}" in --selftest-soft|--selftest-hard) SELFTEST=${1#--selftest-}; shift ;; esac
NAME=${1:?usage: gpurun.sh <name> <command> [args...]}; shift
[ $# -gt 0 ] || { echo "no command" >&2; exit 2; }
LOCK=$HOME/.cache/ds4-gpu.lock
PROV=$S/gpurun-$NAME.prov
OUT=$S/gpurun-$NAME.log
PRE_WIRED_MAX_GIB=16
PRE_FREE_PCT_MIN=35
SOFT_WIRED_GIB=88
SOFT_SWAP_GROWTH_GIB=4
SOFT_PRESSURE_LEVEL=2
HARD_PRESSURE_LEVEL=4
HARD_WIRED_GIB=100
HARD_FOOTPRINT_GIB=90
HARD_SWAP_GROWTH_GIB=10
TERM_GRACE_S=60
HARD_GRACE_S=5
case "$SELFTEST" in
    soft) SOFT_WIRED_GIB=0 ;;
    hard) HARD_WIRED_GIB=0 ;;
esac

mkdir -p "$HOME/.cache"
MW=$S/memwatch
if [ ! -x "$MW" ] || [ "$S/memwatch.c" -nt "$MW" ]; then
    cc -O2 -o "$MW" "$S/memwatch.c" || { echo "REFUSED: memwatch does not build" >&2; exit 3; }
fi
take_lock() {
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
    local owner group; owner=$(cat "$LOCK/pid" 2>/dev/null); group=$(cat "$LOCK/pgid" 2>/dev/null)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        echo "REFUSED: GPU lock held by pid $owner" >&2; return 1
    fi
    if [ -n "$group" ] && [ "$("$MW" "$group" | cut -d' ' -f1)" != 0 ]; then
        echo "REFUSED: GPU lock's process group $group is still alive" >&2; return 1
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
pressure_level() { sysctl -n kern.memorystatus_vm_pressure_level; }
ds4_procs() { pgrep -x ds4-server | wc -l | tr -d ' '; }
ds4_tests() { pgrep -f 'tests/test_deepseek41_' | grep -v "^$$\$" | wc -l | tr -d ' '; }
snapshot() { echo "$1 $(date '+%F %T') ds4-server $(ds4_procs) tests $(ds4_tests) pressure level $(pressure_level) wired $(wired_gib) GiB free $(free_pct)% swap $(swap_gib) GiB"; }

{
    echo "command $*"
    echo "cwd $(pwd)"
    snapshot before
} > "$PROV"
if [ "$(ds4_procs)" != 0 ] || [ "$(ds4_tests)" != 0 ]; then
    echo "REFUSED: another ds4 process is running" | tee -a "$PROV" >&2; exit 3
fi
w=$(wired_gib); f=$(free_pct); sw=$(swap_gib); pl=$(pressure_level)
[ -n "$SELFTEST" ] && echo "selftest $SELFTEST: pressure check skipped (wired $w free $f% swap $sw)" >> "$PROV"
if [ -z "$SELFTEST" ] && { [ "$pl" != 1 ] || awk -v w="$w" -v f="$f" -v W=$PRE_WIRED_MAX_GIB -v F=$PRE_FREE_PCT_MIN \
       'BEGIN { exit !(w > W || f < F) }'; }; then
    echo "REFUSED: machine under pressure (pressure level $pl != 1, wired $w GiB > $PRE_WIRED_MAX_GIB, or free $f% < $PRE_FREE_PCT_MIN)" | tee -a "$PROV" >&2
    exit 3
fi

( while :; do sync; sleep 2; done ) &
syncer=$!
# Job control gives the command a process group of its own, led by it.
set -m
"$@" < /dev/null > "$OUT" 2>&1 &
child=$!
set +m
pgid=$child
echo "$pgid" > "$LOCK/pgid"
echo "pid $child process group $pgid" >> "$PROV"
swap0=$(swap_gib)
peak=0; peak_fp=0; peak_metal=0; peak_sg=0; peak_pl=1
termed=""; termed_at=0; killed=""; rc=""; orphans=""; tick=0; metal=0
# Bytes from footprint(1)'s "IOAccelerator (graphics)" row (dirty column).
metal_gib() {
    footprint -p "$1" 2>/dev/null | awk '/IOAccelerator \(graphics\)/ {
        v=$1; u=$2; m=(u=="KB")?1024:(u=="MB")?1048576:(u=="GB")?1073741824:1;
        printf "%.2f", v*m/1073741824; exit }'
}
group_term() { kill -TERM -- "-$pgid" 2>/dev/null; }
# A second before the first sample: a process is given the chance to install
# its SIGTERM handler before anything could send it one.
sleep 1
while :; do
    # The leader is reaped as soon as it exits, so that what is left in the
    # group is what it left behind.
    if [ -z "$rc" ] && { ! kill -0 "$child" 2>/dev/null ||
                         [ "$(ps -o stat= -p "$child" 2>/dev/null | cut -c1)" = Z ]; }; then
        wait "$child"; rc=$?
    fi
    read -r n fp_b top top_b <<< "$("$MW" "$pgid")"
    [ "${n:-0}" = 0 ] && break
    if [ -n "$rc" ] && [ -z "$orphans" ]; then
        orphans="$n process(es) left in the group after the command exited (rc $rc)"
        [ -z "$termed" ] && { termed="$orphans"; termed_at=$(date +%s); group_term; }
    fi
    w=$(wired_gib); pl=$(pressure_level)
    sg=$(awk -v a="$(swap_gib)" -v b="$swap0" 'BEGIN { printf "%.2f", a - b }')
    fp=$(awk -v b="${fp_b:-0}" 'BEGIN { printf "%.2f", b/1073741824 }')
    tick=$((tick + 1))
    [ $((tick % 2)) = 1 ] && [ "${top:-0}" != 0 ] && metal=$(metal_gib "$top") && metal=${metal:-0}
    peak=$(awk -v a="$peak" -v b="$w" 'BEGIN { print (b > a ? b : a) }')
    peak_sg=$(awk -v a="$peak_sg" -v b="$sg" 'BEGIN { print (b > a ? b : a) }')
    peak_fp=$(awk -v a="$peak_fp" -v b="$fp" 'BEGIN { print (b > a ? b : a) }')
    peak_metal=$(awk -v a="$peak_metal" -v b="$metal" 'BEGIN { print (b > a ? b : a) }')
    [ "$pl" -gt "$peak_pl" ] && peak_pl=$pl
    echo "$(date '+%T') wired $w pressure $pl swap+ $sg group $n footprint $fp metal $metal (pid $top)" >> "$S/gpurun-$NAME.samples"
    hard=""
    awk -v w="$w" -v s="$sg" -v r="$fp" -v p="$pl" -v K=$HARD_WIRED_GIB -v KS=$HARD_SWAP_GROWTH_GIB \
        -v KR=$HARD_FOOTPRINT_GIB -v KP=$HARD_PRESSURE_LEVEL 'BEGIN { exit !(w > K || s > KS || r > KR || p >= KP) }' &&
        hard="hard line: wired $w GiB pressure $pl swap+ $sg GiB group footprint $fp GiB"
    [ -z "$hard" ] && [ -n "$termed" ] && [ $(( $(date +%s) - termed_at )) -gt $TERM_GRACE_S ] &&
        hard="$TERM_GRACE_S s after the soft request"
    if [ -n "$hard" ]; then
        group_term
        for i in $(seq 1 $HARD_GRACE_S); do
            [ "$("$MW" "$pgid" | cut -d' ' -f1)" = 0 ] && break; sleep 1
        done
        if [ "$("$MW" "$pgid" | cut -d' ' -f1)" != 0 ]; then
            killed="$hard"
            kill -KILL -- "-$pgid" 2>/dev/null
        else
            killed="$hard (exited within the $HARD_GRACE_S s before SIGKILL)"
        fi
        for i in $(seq 1 10); do [ "$("$MW" "$pgid" | cut -d' ' -f1)" = 0 ] && break; sleep 1; done
        break
    fi
    if [ -z "$termed" ] && awk -v w="$w" -v s="$sg" -v p="$pl" -v K=$SOFT_WIRED_GIB -v KS=$SOFT_SWAP_GROWTH_GIB \
            -v KP=$SOFT_PRESSURE_LEVEL 'BEGIN { exit !(w > K || s > KS || p >= KP) }'; then
        termed="wired $w GiB pressure $pl swap+ $sg GiB"; termed_at=$(date +%s)
        group_term
    fi
    if grep -q '^paused' "$OUT" 2>/dev/null && [ ! -f "$S/gpurun-$NAME.footprint" ]; then
        footprint -p "$child" > "$S/gpurun-$NAME.footprint" 2>&1
    fi
    sleep 1
done
[ -z "$rc" ] && { wait "$child"; rc=$?; }
left=$("$MW" "$pgid" | cut -d' ' -f1)
kill "$syncer" 2>/dev/null; wait "$syncer" 2>/dev/null
{
    [ -n "$orphans" ] && echo "ORPHANS: $orphans"
    [ -n "$termed" ] && echo "ASKED TO STOP (SIGTERM to the group) at $termed"
    [ -n "$killed" ] && echo "KILLED at $killed - INVALID as a release test"
    [ "$left" != 0 ] && echo "GROUP NOT EMPTY: $left process(es) still in group $pgid"
    echo "rc $rc peak wired $peak GiB, peak pressure level $peak_pl, peak swap growth $peak_sg GiB, peak group footprint $peak_fp GiB, peak Metal $peak_metal GiB"
    snapshot after
} >> "$PROV"
sync
cat "$PROV"
# The lock stays held while anything of the group is alive.
[ "$left" != 0 ] && trap - EXIT
exit $rc
