#!/bin/bash
# One engine at a given expert-cache size under the production environment,
# opened, decoded and closed once in one process (tests/test_deepseek41_lifecycle),
# through gpurun.sh: what the cache size costs in wired memory.
#
#   m4cap.sh <name> <cache_experts> [steps]
#
# The prewarm is the production 8192, so the cache is as full at open as the
# engine lets it be; the engine's memory budget decides what of it is admitted.
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=${1:?usage: m4cap.sh <name> <cache_experts> [steps]}; CACHE=${2:?cache_experts}; STEPS=${3:-64}
BIN=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-m4native}
cd "$BIN" || exit 1
T=tests/test_deepseek41_lifecycle
newer=$(find . -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer "$T" | head -5)
[ -n "$newer" ] && { echo "REFUSED: sources newer than $T: $newer" >&2; exit 1; }
{
    echo "rev $(git rev-parse HEAD) dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    echo "binary $(shasum -a 256 "$T" | cut -d' ' -f1)"
    echo "cache $CACHE steps $STEPS prewarm 8192"
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
    "./$T" "$MODEL" "$CACHE" "$STEPS" 0 0 1
