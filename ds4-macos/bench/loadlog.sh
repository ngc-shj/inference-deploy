#!/bin/bash
# Background CPU, integrated over the same window an arm occupies.
#
# Two things had to be right here and only one of them was at first.
#
# The window: a point sample's minimum is an outlier rather than a floor, and
# it is not the quantity that breaks a paired comparison anyway. What breaks
# one is how much the background moves between the arms of a block, and an arm
# is about 130 s of generation. So this integrates over that long and writes
# one number a window, and the threshold is fixed from the distribution
# afterwards - from this log alone, before any performance number is in hand.
# A threshold adjusted after seeing a result is not a threshold.
#
# The source: summing `ps -Ao time=` over live processes and differencing it
# is not a measurement of CPU. A process that starts and ends inside the
# window contributes nothing, a long-lived one exiting takes its whole
# lifetime out of the sum, and any change in which processes exist reads as a
# change in load. A scanner spawning short-lived helpers is exactly the case
# it cannot see, which is exactly the case this exists for. cputicks reads the
# kernel's per-core counters instead: monotone, owned by no process, and a
# difference of two readings is the work done in between whoever did it.
#
#   loadlog.sh [window_s] &      # appends to load.log
#
# Two syscalls a window, so the logger is not part of what it measures.
# Whoever is using the machine is: run it with nothing else going on.
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
W=${1:-150}
[ -x "$S/cputicks" ] || { echo "build it first: cc -O2 -o cputicks cputicks.c" >&2; exit 1; }

# Five numbers or nothing. A reader that quietly returns something else would
# make every window after it wrong, and the log would go on looking healthy.
ticks() {
    local t
    t=$("$S/cputicks")
    echo "$t" | awk 'NF != 5 { exit 1 } { for (i = 1; i <= 5; i++) if ($i !~ /^[0-9]+$/) exit 1 }' \
        || { echo "cputicks returned '$t'" >&2; exit 1; }
    echo "$t"
}

a=$(ticks)
while sleep "$W"; do
    b=$(ticks)
    # No ternary inside printf's argument list: awk reads the `>` as a
    # redirection and the whole expression is a syntax error, which with
    # stderr discarded is a logger that writes nothing and says nothing.
    echo "$(date '+%Y-%m-%d %H:%M:%S') $(echo "$a $b" | awk '{
        du = $6 - $1; ds = $7 - $2; di = $8 - $3; dn = $9 - $4
        tot = du + ds + di + dn
        cores = 0
        if (tot > 0) cores = (du + ds + dn) / tot * $5
        printf "%.3f", cores
    }')" >> "$S/load.log"
    a=$b
done
