#!/bin/bash
# The memory budget paying for sessions the engine did not plan for
# (tests/test_deepseek41_budget), native batch on, production environment,
# through gpurun.sh.
#
#   m4budget.sh <name> [sessions] [ctx] [steps] [cache_experts]
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=${1:?usage: m4budget.sh <name> [sessions] [ctx] [steps] [cache_experts]}; shift
BIN=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-m4native}
cd "$BIN" || exit 1
T=tests/test_deepseek41_budget
newer=$(find . -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer "$T" | head -5)
[ -n "$newer" ] && { echo "REFUSED: sources newer than $T: $newer" >&2; exit 1; }
{
    echo "rev $(git rev-parse HEAD) dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    echo "binary $(shasum -a 256 "$T" | cut -d' ' -f1)"
    echo "args $*"
} > "$S/gpurun-$NAME.rev"
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
    "./$T" "$MODEL" "$@"
