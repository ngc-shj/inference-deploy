#!/bin/bash
# One arm of the expert-cache capacity comparison: tests/test_deepseek41_capacity
# on one tree at one cache size, in its own process, every logit to a file.
#
#   m4capab.sh <name> <tree> <cache_experts> <steps> [story_bytes]
#   tree: a ds4 checkout; one other than DS4_BIN gets the test source from
#         DS4_BIN compiled against its built objects (the test uses the public
#         API only), so the frozen baseline runs the very same test
#   ARM_ENV="VAR=VALUE ..."   after the production environment
#   ARM_PROMPT="text:..."     the user message itself instead of the story
#   ARM_MODE=token-major      run a streaming append's tail token-major, as
#                             before it was batched (the test's 7th argument)
#
# Run each arm through gpurun.sh, one at a time, then cmp the .f32 files: the
# cache is a performance state and must not change a byte. Writes
# capab-<name>.{f32,log,prov}; the .f32 is vocab floats per evaluation.
set -u
S=$(cd "$(dirname "$0")" && pwd)
NAME=${1:?usage: m4capab.sh <name> <tree> <cache_experts> <steps> [story_bytes]}
TREE=$(cd "${2:?tree}" && pwd) || exit 1
CACHE=${3:?cache}; STEPS=${4:?steps}; BYTES=${5:-22000}
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
C=$(cd "${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-m4native}" && pwd)
SRC=$C/tests/test_deepseek41_capacity.c
if [ "$TREE" = "$C" ]; then
    T=$C/tests/test_deepseek41_capacity
    newer=$(find "$C" -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer "$T" | head -5)
    [ -n "$newer" ] && { echo "REFUSED: sources newer than $T: $newer" >&2; exit 1; }
else
    newer=$(find "$TREE" -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer "$TREE/ds4_metal.o" | head -5)
    [ -n "$newer" ] && { echo "REFUSED: $TREE objects older than: $newer" >&2; exit 1; }
    B=$S/capbin/$(git -C "$TREE" rev-parse --short HEAD)
    mkdir -p "$B/tests"
    ln -sf "$TREE/ds4.h" "$B/ds4.h"
    cp "$SRC" "$B/tests/"
    T=$B/test_deepseek41_capacity
    (cd "$TREE" && cc -O3 -ffast-math -mcpu=native -Wall -Wextra -std=c99 -D_GNU_SOURCE \
        -fno-finite-math-only -I"$TREE" -c -o "$B/cap.o" "$B/tests/test_deepseek41_capacity.c" &&
     cc -O3 -o "$T" "$B/cap.o" ds4.o ds4_image.o ds4_distributed.o ds4_tp.o ds4_ssd.o \
        ds4_metal.o ds4_layer_pack.o ds4_engram.o -lm -pthread -framework Foundation -framework Metal) || exit 1
fi
cd "$TREE" || exit 1
{
    echo "rev $(git rev-parse HEAD) dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    echo "binary $(shasum -a 256 "$T" | cut -d' ' -f1)"
    echo "cache $CACHE steps $STEPS bytes $BYTES env ${ARM_ENV:-} prompt ${ARM_PROMPT:-story} mode ${ARM_MODE:-production}"
} > "$S/capab-$NAME.prov"
# shellcheck disable=SC2086 - ARM_ENV is a list of VAR=VALUE words
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 \
    DS4_METAL_STREAMING_EXPERT_AUTO_PRELOAD_CAP=8192 \
    DS4_METAL_V41_DECODE_LEND_HEADROOM=2 \
    DS4_METAL_V41_STREAMING_MEMORY_BUDGET_GIB=80 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_ROUTER_FUSE_TRANSFORM=5 DS4_METAL_V41_FUSE_BF16=2 \
    DS4_METAL_V41_HC_COMPOUND=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    ${ARM_ENV:-} "$T" "$MODEL" "${ARM_PROMPT:-tests/long_context_story_prompt.txt}" \
    "$CACHE" "$STEPS" "$S/capab-$NAME.f32" "$BYTES" ${ARM_MODE:-} > "$S/capab-$NAME.log" 2>&1
rc=$?
grep -E '^(prefill|capacity)' "$S/capab-$NAME.log"
exit $rc
