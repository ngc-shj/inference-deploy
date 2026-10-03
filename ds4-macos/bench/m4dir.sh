#!/bin/bash
# Pinned expert windows in the expert directory (tests/test_deepseek41_fulltable),
# native batch on, production environment, through gpurun.sh.
#
#   m4dir.sh <name> <window> <layers> [steps] [cache_experts] [forced]
#   layers 0: no pinned windows - the oracle the pinned runs must match
#   EXTRA_ENV="VAR=VALUE ..." appended after the production environment, so it
#   overrides it (DS4_METAL_V41_ABORT_GATE=0 for the single-row routed path)
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=${1:?usage: m4dir.sh <name> <window> <layers> [steps] [cache_experts] [forced]}
WINDOW=${2:?window}; LAYERS=${3:?layers}; shift 3
BIN=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-m4native}
cd "$BIN" || exit 1
T=tests/test_deepseek41_fulltable
newer=$(find . -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer "$T" | head -5)
[ -n "$newer" ] && { echo "REFUSED: sources newer than $T: $newer" >&2; exit 1; }
{
    echo "rev $(git rev-parse HEAD) dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    echo "binary $(shasum -a 256 "$T" | cut -d' ' -f1)"
    echo "window $WINDOW layers $LAYERS args $* extra env ${EXTRA_ENV:-}"
} > "$S/gpurun-$NAME.rev"
PIN=""
[ "$LAYERS" != 0 ] && PIN="DS4_METAL_ENABLE_STREAMING_FULL_EXPERT_ADDR_TABLE=1 DS4_METAL_FULL_ADDR_LAYERS=$LAYERS"
exec "$S/gpurun.sh" "$NAME" env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 \
    DS4_METAL_STREAMING_EXPERT_AUTO_PRELOAD_CAP=8192 \
    DS4_METAL_V41_DECODE_LEND_HEADROOM=2 \
    DS4_METAL_V41_STREAMING_MEMORY_BUDGET_GIB=84 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_ROUTER_FUSE_TRANSFORM=5 DS4_METAL_V41_FUSE_BF16=2 \
    DS4_METAL_V41_HC_COMPOUND=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    DS4_METAL_ENABLE_V41_STREAMING_SESSION_BATCH=1 \
    $PIN ${EXTRA_ENV:-} "./$T" "$MODEL" "$WINDOW" "$@"
