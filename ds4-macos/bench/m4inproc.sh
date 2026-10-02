#!/bin/bash
# tests/test_deepseek41_backend under the production environment: Metal 3 and
# Metal 4 sessions stepped together in one process with every logit compared,
# then an injected command-buffer failure in decode and in prefill, then a
# fresh session against the reference.
#
#   m4inproc.sh <name> [VAR=VALUE...]      STEPS=N sets the decode length
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; shift
BIN=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-mtl4dag}
cd "$BIN" || exit 1
while pgrep -x ds4-server >/dev/null; do sleep 2; done
T=tests/test_deepseek41_backend
newer=$(find . -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer "$T" | head -5)
[ -n "$newer" ] && { echo "REFUSED: sources newer than $T: $newer" >&2; exit 1; }
{
    echo "rev $(git rev-parse HEAD) dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    echo "binary $(shasum -a 256 "$T" | cut -d' ' -f1)"
    echo "extra $*"
} > "$S/m4in-$NAME.prov"
# EXPECT=1: the token-id hashes must equal the ones the Metal 3 oracle
# produced before it was removed (m4in-final-full2048.log, both backends).
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 \
    DS4_METAL_STREAMING_EXPERT_AUTO_PRELOAD_CAP=8192 \
    DS4_METAL_V41_DECODE_LEND_HEADROOM=2 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_ROUTER_FUSE_TRANSFORM=5 DS4_METAL_V41_FUSE_BF16=2 \
    DS4_METAL_V41_HC_COMPOUND=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    "$@" "./$T" "$MODEL" tests/long_context_story_prompt.txt > "$S/m4in-$NAME.log" 2>&1
rc=$?
grep -E '^(short|haiku|long|injected|after|fallback|health|reopen|closed|warmup|refusal|fulltable|m3api|PASS|FAIL)' "$S/m4in-$NAME.log"
grep -E '^FAIL' "$S/m4in-$NAME.log" | head -20
if [ "${EXPECT:-0}" = 1 ]; then
    for c in short haiku long; do
        want=$(awk -v c="$c" '$1 == c {print $NF}' "$S/m4in-final-full2048.log")
        got=$(awk -v c="$c" '$1 == c {print $NF}' "$S/m4in-$NAME.log")
        [ -n "$want" ] && [ "$want" = "$got" ] && echo "oracle   $c ids $got as before" ||
            { echo "ORACLE MISMATCH $c: want $want got $got"; rc=1; }
    done
fi
exit $rc
