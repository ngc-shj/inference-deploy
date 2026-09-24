#!/bin/bash
# One in-process ABBA, started only on a quiet machine.
#
#   abba-when-quiet.sh <name> VAR=VALUE...
#
# selftest.sh's BATCH_AB pairs the arms inside one process, which is the only
# comparison on this machine that can see a change smaller than the drift. It
# still has to *start* quiet: an ABBA that begins at load 2 and ends at load 1
# reports the load. One run here drifted from 196 to 311 ms/step across five
# rounds and the two orders disagreed in sign.
#
# The gate is startable.sh against the frozen condition, so this waits rather
# than deciding for itself what quiet means. Exit 2 from the gate means the
# load logger is dead, and waiting on a dead logger is a silent forever - it
# stops instead.
set -u
S=$(cd "$(dirname "$0")" && pwd)
NAME=${1:?usage: abba-when-quiet.sh <name> VAR=VALUE...}; shift
WAIT=${WAIT:-90}
TRIES=${TRIES:-240}
for try in $(seq 1 "$TRIES"); do
    out=$("$S/startable.sh" 2>&1); code=$?
    case "$code" in
        0) echo "$(date '+%m-%d %H:%M:%S') quiet after $try checks: $out"
           exec "$S/selftest.sh" "$NAME" "$@" ;;
        2) echo "$(date '+%m-%d %H:%M:%S') gate cannot answer: $out" >&2; exit 2 ;;
        *) [ $((try % 10)) -eq 1 ] && echo "$(date '+%m-%d %H:%M:%S') waiting: $out" ;;
    esac
    sleep "$WAIT"
done
echo "never quiet in $((TRIES * WAIT))s" >&2
exit 1
