#!/bin/bash
# ABBA x N over the two arms, so a monotone drift in machine state cancels.
# on = the five projections that read `norm` in one concurrent section; off =
# the five one after another, which is what ships.
# $1 = rounds (each round is on,off,off,on).
set -u
S=$(cd "$(dirname "$0")" && pwd)
R=${1:-5}
for i in $(seq 1 "$R"); do
  for arm in on off off on; do
    case $arm in
      on)  "$S/abba.sh" "on$i-$RANDOM" DS4_METAL_V41_NARROW_SECTION=1 ;;
      off) "$S/abba.sh" "off$i-$RANDOM" ;;
    esac
  done
done
