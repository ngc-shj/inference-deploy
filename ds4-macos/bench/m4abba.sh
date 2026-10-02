#!/bin/bash
# Metal 3 against Metal 4, same binary, one backend a process, in ABBA order,
# each arm the sustained 2048-token generation that the frozen 41.5 ms a token
# was measured with.
#
#   m4abba.sh <name> [blocks]      blocks of 3-4-4-3 (default 2: 8 arms)
#   BIN_A=dir BIN_B=dir            instead: two binaries in blocks of a-b-b-a
#                                  (before/after a change); MTL4_A/MTL4_B set
#                                  DS4_METAL_V41_MTL4 per build (default 1)
#   EXTRA_A / EXTRA_B              the server arguments for each build's arms
#                                  (DS4_EXTRA_ARGS), e.g. its cache size
#
# Waits for bench/startable.sh before the first arm, and before every arm
# waits for bench/thermal to come back to 97% of the settled reference, so no
# arm starts hotter than the one before it. Beside each arm it keeps: the
# binary's provenance, the machine's CPU taken by anything but the server
# (cputicks), the gap since the previous arm, vm_stat and the page-ins, the
# thermal reading, and the server's own per-token split and cache counters.
# The number compared is wall time over the whole generation divided by
# tokens generated - not a best window.
set -u
S=$(cd "$(dirname "$0")" && pwd)
NAME=${1:?usage: m4abba.sh <name> [blocks]}
BLOCKS=${2:-2}
BIN=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-mtl4dag}
OUT=$S/m4ab-$NAME
mkdir -p "$OUT"
say() { echo "$(date '+%m-%d %H:%M:%S') $*" | tee -a "$OUT/run.log"; }

# NOGATE=1 starts at once; the load at the start is still recorded.
code=0
[ "${NOGATE:-0}" = 1 ] && say "no gate: $("$S/startable.sh" 2>&1)"
[ "${NOGATE:-0}" = 1 ] || for try in $(seq 1 240); do
    g=$("$S/startable.sh" 2>&1); code=$?
    [ "$code" = 0 ] && { say "gate: $g"; break; }
    [ "$code" = 2 ] && { say "gate cannot answer: $g"; exit 2; }
    [ $((try % 10)) -eq 1 ] && say "waiting: $g"
    sleep 90
done
[ "$code" = 0 ] || { say "never quiet"; exit 1; }

order=""
if [ -n "${BIN_A:-}" ]; then
    for b in $(seq 1 "$BLOCKS"); do order="$order a b b a"; done
else
    for b in $(seq 1 "$BLOCKS"); do order="$order 3 4 4 3"; done
fi
i=0
for be in $order; do
    i=$((i + 1))
    arm=$(printf '%02d-m%s' "$i" "$be")
    BIN_ARM=$BIN
    case "$be" in a) BIN_ARM=$BIN_A ;; b) BIN_ARM=$BIN_B ;; esac
    # COOL=seconds idles before every arm: on this machine the decode slows
    # continuously as it heats (29 -> 87 ms of GPU a token over three arms)
    # while the one-second compute probe does not move.
    [ -n "${COOL:-}" ] && sleep "$COOL"
    if [ "${NOGATE:-0}" = 1 ]; then "$S/thermal" > "$OUT/$arm.thermal" 2>&1; else "$S/thermal" --until 0.97 > "$OUT/$arm.thermal" 2>&1; fi
    (cd "$BIN_ARM" && echo "rev $(git rev-parse HEAD) dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ') binary $(shasum -a 256 ds4-server | cut -d' ' -f1)") > "$OUT/$arm.prov"
    now=$(date +%s)
    [ -f "$OUT/.last-end" ] && echo "$((now - $(cat "$OUT/.last-end")))" > "$OUT/$arm.gap"
    vm_stat > "$OUT/$arm.vm0"
    t0=$("$S/cputicks"); s0=$(date +%s)
    M4=0; [ "$be" = 3 ] || M4=1
    # MTL4_A / MTL4_B override the backend switch per build: an old build that
    # still has the switch must be told 0 to be the Metal 3 baseline.
    case "$be" in a) M4=${MTL4_A:-$M4} ;; b) M4=${MTL4_B:-$M4} ;; esac
    # Other GPU clients (the window server, a browser) share the GPU and
    # the CPU gate cannot see them: sample the render and device load.
    ( while :; do
        ioreg -r -d 1 -c IOAccelerator | grep -o '"PerformanceStatistics" = {[^}]*}' |
          tr ',' '\n' | grep -E 'Renderer Utilization|Tiler Utilization|Device Utilization' |
          tr -dc '0-9\n' | tr '\n' ' '; echo; sleep 5
      done ) > "$OUT/$arm.gpu" 2>/dev/null &
    sampler=$!
    EXTRA_ARM=${DS4_EXTRA_ARGS:-}
    case "$be" in a) EXTRA_ARM=${EXTRA_A:-$EXTRA_ARM} ;; b) EXTRA_ARM=${EXTRA_B:-$EXTRA_ARM} ;; esac
    echo "server args $EXTRA_ARM" >> "$OUT/$arm.prov"
    env TOKENS=2048 DS4_BIN="$BIN_ARM" DS4_EXTRA_ARGS="$EXTRA_ARM" "$S/sustained.sh" "m4ab-$NAME-$arm" DS4_METAL_V41_MTL4=$M4 \
        > "$OUT/$arm.out" 2>&1
    kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null
    t1=$("$S/cputicks"); s1=$(date +%s)
    vm_stat > "$OUT/$arm.vm1"
    date +%s > "$OUT/.last-end"
    mv "$S/sus-m4ab-$NAME-$arm.log" "$OUT/$arm.log" 2>/dev/null
    mv "$S/sus-m4ab-$NAME-$arm-1.json" "$OUT/$arm.json" 2>/dev/null
    echo "$t0 $s0 $t1 $s1" > "$OUT/$arm.ticks"
    say "$arm: $(grep -E 'aggregate|per token' "$OUT/$arm.out" | tr '\n' ' ') | $(tail -1 "$OUT/$arm.thermal")"
done
say "done"
