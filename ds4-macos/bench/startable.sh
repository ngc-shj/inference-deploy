#!/bin/bash
# Is a campaign worth starting right now?
#
#   startable.sh          0 start, 1 wait, 2 the log is not being written
#
# Reads the frozen condition in start-condition.txt and the last windows of
# load.log. Nothing here decides whether a measurement is valid; pair.py does
# that afterwards, on the runs that happened.
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
COND=$S/start-condition.txt
LOG=$S/load.log
WINDOW=${LOAD_WINDOW:-150}
[ -r "$COND" ] || { echo "no frozen start condition ($COND)" >&2; exit 2; }
[ -r "$LOG" ] || { echo "no load log ($LOG); is loadlog.sh running?" >&2; exit 2; }

get() { awk -v k="$1" '$1 == k { print $2 }' "$COND"; }
cutoff=$(get cutoff); range=$(get range); n=$(get windows)
[ -n "$cutoff" ] && [ -n "$range" ] && [ -n "$n" ] || {
    echo "start-condition.txt is missing cutoff, range or windows" >&2; exit 2; }

# A log that has stopped being written is not a quiet machine, it is a dead
# logger - the failure this harness has now made three times. Do not wait on it.
last_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(tail -1 "$LOG" | cut -d' ' -f1-2)" +%s 2>/dev/null || echo 0)
age=$(( $(date +%s) - last_epoch ))
if [ "$last_epoch" -eq 0 ] || [ "$age" -gt $((2 * WINDOW)) ]; then
    echo "load.log has not advanced in ${age}s (two windows is $((2 * WINDOW))s); loadlog.sh is not running" >&2
    exit 2
fi

have=$(wc -l < "$LOG")
if [ "$have" -lt "$n" ]; then echo "only $have windows, need $n"; exit 1; fi

# The last n lines are not the last n windows unless the logger ran without a
# break. After a gap they are two sessions stitched together, and the condition
# then describes neither: a quiet machine six hours ago can hold the maximum
# up, and - the way that matters - a quiet machine six hours ago can also let a
# busy one through. Only the final run of contiguous windows counts, where
# contiguous means each within two periods of the one before it.
#
# The thresholds are untouched by this. What changes is which windows they are
# applied to, and after a gap the answer is "not enough of them yet" rather
# than a number made of two different machines.
# BSD awk has no mktime, and a handful of date calls a check is nothing
# beside the forty minutes this is guarding.
contig=0
prev=0
while read -r d t _; do
    now=$(date -j -f '%Y-%m-%d %H:%M:%S' "$d $t" +%s 2>/dev/null || echo 0)
    [ "$now" -eq 0 ] && continue
    if [ "$prev" -ne 0 ] && [ $((now - prev)) -gt $((2 * WINDOW)) ]; then contig=0; fi
    prev=$now
    contig=$((contig + 1))
done < <(tail -"$((n * 4))" "$LOG")
if [ "$contig" -lt "$n" ]; then
    echo "only $contig contiguous windows since the last gap, need $n"
    exit 1
fi
read -r mx mn <<<"$(tail -"$n" "$LOG" | awk '{v=$3; if (NR==1 || v>hi) hi=v; if (NR==1 || v<lo) lo=v} END {print hi, lo}')"
spread=$(echo "$mx $mn" | awk '{printf "%.3f", $1 - $2}')
verdict=$(echo "$mx $spread $cutoff $range" | awk '{print ($1 <= $3 && $2 <= $4) ? "start" : "wait"}')
echo "last $n windows: max $mx, range $spread (need <= $cutoff and <= $range) - $verdict"
[ "$verdict" = start ]
