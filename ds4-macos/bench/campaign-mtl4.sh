#!/bin/bash
# Is the Metal 4 backend faster than the Metal 3 path it replaces?
#
# Pre-registered, and fixed here so it cannot drift between attempts. Both arms
# are the same binary and differ in one variable, which is what makes this a
# paired run: the OFF arm is the Metal 3 path of that same commit, which is the
# encode-ahead pipeline of 91b18e5 - the best Metal 3 there is - reached without
# changing binaries between arms.
#
# What decides: raw wall ms a token over the steady windows, as pair.py
# computes it. Not prompt wall, which carries prefill; not the submission
# counts, which say the mechanism engaged and nothing about time.
#
#   DS4_BIN=<worktree> ./campaign-mtl4.sh
#
# Every attempt, clean or not, is kept under attempts/ for the record.
set -u
S=$(cd "$(dirname "$0")" && pwd)
LOG=$S/when-quiet-mtl4.log
BIN=${DS4_BIN:?set DS4_BIN to the worktree being measured}
BLOCKS=${BLOCKS:-3}
MAX_TRIES=${MAX_TRIES:-12}
COMMON="DS4_METAL_V41_FFN_OVERLAP=1 DS4_METAL_V41_GATE_ENCODE_AHEAD=1"
ON="$COMMON DS4_METAL_V41_MTL4=1"
OFF="$COMMON"
# The analysis, fixed before any of the runs exist. Both arms run the FFN
# overlap, so both must show sections opened; an arm that fell back to serial
# would otherwise read as "Metal 4 did nothing".
ANALYSE=(python3 "$S/pair.py" 'ab-on*.log' 'ab-off*.log' --expect-sections=both)

say() { echo "$(date '+%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

say "frozen binary: $BIN at $(cd "$BIN" && git rev-parse --short HEAD)"
say "start condition: $(awk '$1=="cutoff"||$1=="range"||$1=="windows"{printf "%s %s  ", $1, $2}' "$S/start-condition.txt")"
say "on:  $ON"
say "off: $OFF"

for try in $(seq 1 "$MAX_TRIES"); do
    while true; do
        rc=0; "$S/startable.sh" >> "$LOG" 2>&1 || rc=$?
        [ "$rc" -eq 0 ] && break
        if [ "$rc" -ge 2 ]; then
            say "the load log is not usable; stopping rather than waiting on it"
            tail -1 "$LOG"
            exit 2
        fi
        sleep "${QUIET_RETRY:-300}"
    done
    say "attempt $try: machine is quiet, starting a $BLOCKS-block campaign"
    for f in "$S"/ab-o*; do [ -e "$f" ] && rm -f "$f"; done
    DS4_BIN="$BIN" ON_ENV="$ON" OFF_ENV="$OFF" \
        bash "$S/abba-run.sh" "$BLOCKS" >> "$LOG" 2>&1
    out=$(cd "$S" && "${ANALYSE[@]}" 2>&1) || true
    keep="$S/attempts/mtl4-try$try-$(date +%m%d-%H%M)"
    mkdir -p "$keep"
    for f in "$S"/ab-o*; do [ -e "$f" ] && mv "$f" "$keep/"; done
    printf '%s\n' "$out" > "$keep/pair.txt"
    if printf '%s' "$out" | grep -q REFUSING; then
        say "attempt $try refused, kept in $keep:"
        printf '%s\n' "$out" | grep REFUSING | tee -a "$LOG"
        continue
    fi
    say "attempt $try passed every check; the result is in $keep/pair.txt"
    printf '%s\n' "$out" | tee -a "$LOG"
    exit 0
done
say "gave up after $MAX_TRIES attempts"
exit 1
