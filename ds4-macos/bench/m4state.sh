#!/bin/bash
# tests/test_deepseek41_state under the production environment: token ids,
# every logit of every evaluation, and the saved session state (KV and
# carried state), as hashes, for single prompts to 2048 tokens, two
# alternating sessions and a three-request conversation. The same source is
# built in each tree; two runs are compared line by line.
#
#   m4state.sh <name> [VAR=VALUE...]      DS4_BIN picks the tree
#   PARTS=N   encode every Metal 4 context in N command buffers (the test's
#             third argument), to check the split changes nothing
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; shift
BIN=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-m4native}
cd "$BIN" || exit 1
while pgrep -x ds4-server >/dev/null; do sleep 2; done
T=tests/test_deepseek41_state
newer=$(find . -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer "$T" | head -5)
[ -n "$newer" ] && { echo "REFUSED: sources newer than $T: $newer" >&2; exit 1; }
{
    echo "rev $(git rev-parse HEAD) dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    echo "binary $(shasum -a 256 "$T" | cut -d' ' -f1)"
    echo "extra $* parts ${PARTS:-default}"
} > "$S/m4st-$NAME.prov"
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 \
    DS4_METAL_STREAMING_EXPERT_AUTO_PRELOAD_CAP=8192 \
    DS4_METAL_V41_DECODE_LEND_HEADROOM=1 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_ROUTER_FUSE_TRANSFORM=5 DS4_METAL_V41_FUSE_BF16=2 \
    DS4_METAL_V41_HC_COMPOUND=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    "$@" "./$T" "$MODEL" tests/long_context_story_prompt.txt ${PARTS:-} > "$S/m4st-$NAME.log" 2>&1
rc=$?
grep -E '^(short|haiku|long|pair-|turn-|DONE|FAILED|conversation|pair )' "$S/m4st-$NAME.log" > "$S/m4st-$NAME.hashes"
cat "$S/m4st-$NAME.hashes"
exit $rc
