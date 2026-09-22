#!/bin/bash
# ABBA x N over the two arms. The orientation alternates between blocks -
# on,off,off,on then off,on,on,off - because a fixed one leaves the arm
# confounded with any U-shaped drift inside a block, which a machine that
# warms up and settles has.
# $1 = rounds, $2... = the on arm's environment. The off arm is ON_ENV
# replaced by OFF_ENV below; edit those two, they are the experiment.
set -u
S=$(cd "$(dirname "$0")" && pwd)
R=${1:-5}
ON_ENV=${ON_ENV:-DS4_METAL_V41_FFN_OVERLAP=1}
OFF_ENV=${OFF_ENV:-DS4_METAL_V41_FFN_OVERLAP=2}
echo "on:  $ON_ENV"
echo "off: $OFF_ENV"
# Start when the machine has settled, not when a clock says it should have.
# thermal.m runs a fixed compute-bound kernel; its rate is what the heat moves.
if [ -x "$S/thermal" ] && [ "${SKIP_THERMAL:-0}" = 0 ]; then
    echo "waiting for the machine to settle:"
    "$S/thermal" --until "${SETTLE:-0.97}" | sed 's/^/  /'
fi
# One arm before the first block, thrown away. Every arm waits 20 s for the one
# before it; the first waits however long the machine has been idle, and that
# run is faster than any other - 52.48 ms a token against 59.9-67.3 for the
# other nineteen, in the campaign where it happened - so whichever arm goes
# first collects a bias the alternation cannot cancel.
if [ "${SKIP_WARMUP:-0}" = 0 ]; then
    echo "warm-up arm (discarded):"
    WARM="warmup-$$"
    "$S/abba.sh" "$WARM" $OFF_ENV | sed 's/^/  /'
    rm -f "$S/ab-$WARM.log" "$S/ab-$WARM.vm" "$S/ab-$WARM.sha" "$S/ab-$WARM.gap"
fi
for i in $(seq 1 "$R"); do
  if [ $((i % 2)) -eq 1 ]; then order="on off off on"; else order="off on on off"; fi
  for arm in $order; do
    case $arm in
      on)  "$S/abba.sh" "on$i-$RANDOM"  $ON_ENV  ;;
      off) "$S/abba.sh" "off$i-$RANDOM" $OFF_ENV ;;
    esac
  done
done
