#!/bin/bash
# The Metal 4 full expert address table's staged bring-up
# (tests/test_deepseek41_fulltable) under the production environment.
#
#   m4fulltable.sh <name> <layers> plan|run [experts] [cache_experts] [steps] [VAR=VALUE...]
#   PARTS=N   encode every Metal 4 context in N command buffers
#   ROUNDS=N  open, run and close the engine N times in the process
#
# Started detached so a session ending does not take it down; the log, the
# test's own lines and the provenance are kept beside each other.
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; LAYERS=$2; MODE=$3; shift 3
EXPERTS=${1:-0}; CACHE=${2:-4096}; STEPS=${3:-16}; shift $(( $# < 3 ? $# : 3 ))
BIN=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-m4native}
cd "$BIN" || exit 1
while pgrep -x ds4-server >/dev/null || pgrep -x test_deepseek41_fulltable >/dev/null; do sleep 2; done
T=tests/test_deepseek41_fulltable
newer=$(find . -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer "$T" | head -5)
[ -n "$newer" ] && { echo "REFUSED: sources newer than $T: $newer" >&2; exit 1; }
{
    echo "rev $(git rev-parse HEAD) dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    echo "binary $(shasum -a 256 "$T" | cut -d' ' -f1)"
    echo "layers $LAYERS mode $MODE experts $EXPERTS cache $CACHE steps $STEPS parts ${PARTS:-default} rounds ${ROUNDS:-1} extra $*"
    echo "started $(date '+%F %T')"
} > "$S/m4ft-$NAME.prov"
# A kernel panic loses what was not yet on disk: keep flushing while it runs.
( while :; do sync; sleep 2; done ) &
syncer=$!
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 \
    DS4_METAL_STREAMING_EXPERT_AUTO_PRELOAD_CAP=8192 \
    DS4_METAL_V41_DECODE_LEND_HEADROOM=2 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_ROUTER_FUSE_TRANSFORM=5 DS4_METAL_V41_FUSE_BF16=2 \
    DS4_METAL_V41_HC_COMPOUND=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    DS4_METAL_ENABLE_V41_STREAMING_SESSION_BATCH=1 \
    DS4_METAL_ENABLE_STREAMING_FULL_EXPERT_ADDR_TABLE=1 \
    DS4_METAL_FULL_ADDR_LAYERS=$LAYERS \
    "$@" "./$T" "$MODEL" "$MODE" "$EXPERTS" "$CACHE" "$STEPS" "${PARTS:-0}" "${ROUNDS:-1}" > "$S/m4ft-$NAME.log" 2>&1
rc=$?
kill "$syncer" 2>/dev/null
echo "finished $(date '+%F %T') rc=$rc" >> "$S/m4ft-$NAME.prov"
grep -E '^(opened|plan|prefill|decoded|ids|closed|failed)' "$S/m4ft-$NAME.log" > "$S/m4ft-$NAME.summary"
grep -E 'not admitted|addresses every expert|wired .* expert|failed|Insufficient' "$S/m4ft-$NAME.log" | head -20 >> "$S/m4ft-$NAME.summary"
sync
exit $rc
