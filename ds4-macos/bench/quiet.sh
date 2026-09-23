#!/bin/bash
# Is the machine quiet enough to measure on?
#
# Not a CPU question only. A scanner at 90% of a core is also moving unified
# memory bandwidth, power and die temperature, all of which this machine's
# decode is sensitive to - which is why the answer is to wait for it rather
# than to subtract it. Excluding the interference from the accounting would
# leave the interference and remove the guard.
#
#   quiet.sh [cores] [window]   0 when quiet, 1 when not; prints either way
#
# The unit is cores of CPU taken by everything except ds4-server, averaged
# over the window. Two consecutive windows must both pass, because a scanner
# between files reads as idle for a few seconds at a time.
set -u
MAX=${1:-0.35}
WINDOW=${2:-30}

sample() {
    ps -Ao comm=,time= | awk '$1 !~ /ds4-server/ {
        n = split($2, t, ":")
        s = (n == 3 ? t[1]*3600 + t[2]*60 + t[3] : t[1]*60 + t[2])
        total += s
    } END { printf "%.2f\n", total }'
}

busiest() { ps -Ao comm=,%cpu= | sort -k2 -nr | head -1 | awk '{printf "%s %s%%", $1, $2}'; }

ok=1
for pass in 1 2; do
    a=$(sample); sleep "$WINDOW"; b=$(sample)
    cores=$(echo "$b $a $WINDOW" | awk '{printf "%.2f", ($1-$2)/$3}')
    verdict=$(echo "$cores $MAX" | awk '{print ($1 <= $2) ? "quiet" : "busy"}')
    echo "$(date '+%H:%M:%S') pass $pass: $cores cores of other work ($verdict, limit $MAX); busiest $(busiest)"
    [ "$verdict" = quiet ] || ok=0
done
exit $((1 - ok))
