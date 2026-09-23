#!/bin/bash
# Run one pre-registered campaign, but only on a quiet machine, and keep
# trying until one comes out whole.
#
# The experiment is fixed here rather than passed in, so it cannot drift
# between attempts: the arms, the block count and the analysis are the same
# on the first try and the ninth. Nothing is ever dropped from a campaign -
# a campaign either passes every check or it is discarded entire and run
# again. That is the difference between waiting for a clean measurement and
# manufacturing one.
#
#   campaign-when-quiet.sh            # runs until a campaign passes
#
# Every attempt, clean or not, is kept under attempts/ for the record.
set -u
S=$(cd "$(dirname "$0")" && pwd)
LOG=$S/when-quiet.log
BIN=${DS4_BIN:?set DS4_BIN to the worktree being measured}
ROUTE=${ROUTE:?set ROUTE to the oracle route log}
BLOCKS=${BLOCKS:-3}
MAX_TRIES=${MAX_TRIES:-12}
# The experiment. Both arms are the same binary; they differ in one thing.
ON="DS4_METAL_V41_FFN_OVERLAP=1 DS4_METAL_V41_ORACLE=$ROUTE DS4_METAL_V41_ORACLE_MODE=1"
OFF="DS4_METAL_V41_FFN_OVERLAP=1"
# The analysis, fixed before any of the runs exist.
ANALYSE=(python3 "$S/pair.py" 'ab-on*.log' 'ab-off*.log' --expect-sections=both
         "--declare=the speculative arm issues a gate/up and a match a layer that the baseline does not"
         --declare-fields=gated,plain,behind)

say() { echo "$(date '+%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

say "frozen binary: $BIN at $(cd "$BIN" && git rev-parse --short HEAD)"
say "on:  $ON"
say "off: $OFF"

for try in $(seq 1 "$MAX_TRIES"); do
    # Quiet first, and checked before anything maps 340 GiB: an arm that
    # starts on a busy machine has already cost forty minutes by the time the
    # analyser says so.
    until "$S/quiet.sh" "${QUIET_CORES:-0.35}" "${QUIET_WINDOW:-30}" >> "$LOG" 2>&1; do
        sleep "${QUIET_RETRY:-600}"
    done
    say "attempt $try: machine is quiet, starting a $BLOCKS-block campaign"
    for f in "$S"/ab-o*; do [ -e "$f" ] && rm -f "$f"; done
    DS4_BIN="$BIN" ON_ENV="$ON" OFF_ENV="$OFF" \
        bash "$S/abba-run.sh" "$BLOCKS" >> "$LOG" 2>&1
    out=$(cd "$S" && "${ANALYSE[@]}" 2>&1)
    keep="$S/attempts/try$try-$(date +%m%d-%H%M)"
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
