#!/bin/bash
# Sustained generation through the ordinary server path, and a refusal when the
# thing being measured did not run.
#
#   sustained.sh <name> [VAR=VALUE...]
#   EXPECT_K=8  the candidate width production is supposed to verify at
#
# The selftest measures one k-row verification step in isolation. That is the
# right ruler for a kernel change and the wrong one for the goal: 100 tok/s is a
# wall-clock number over a real generation. But a generation rate is only
# evidence about a block executor if the generation used one, and on this build
# it does not: ds41_graph_step_batch_logits is called by ds41_verify_selftest,
# while the server's decode advances at most two tokens through the MTP path
# (server_slot::decode_accepted[2]).
#
# So this exits non-zero when the run shows no K-row verification steps, or a
# candidate width other than EXPECT_K, or - with DS4_METAL_V41_BATCH_FUSE set -
# no fusion sites taken. A tok/s number from a run that failed those checks is a
# measurement of the single-row path wearing the block path's name, and this
# harness refuses to print it as a result.
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; shift
TOKENS=${TOKENS:-256}
EXPECT_K=${EXPECT_K:-8}
PORT=${PORT:-8017}
LOG=$S/sus-$NAME.log
WANT_FUSE=0
for a in "$@"; do
    case "$a" in DS4_METAL_V41_BATCH_FUSE=0) ;; DS4_METAL_V41_BATCH_FUSE=*) WANT_FUSE=1 ;; esac
done
cd "${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-mtl4dag}" || exit 1
while pgrep -x ds4-server >/dev/null; do sleep 2; done
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 DS4_METAL_ZERO_COPY_EXPERTS=1 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    "$@" ./ds4-server -m "$MODEL" --ssd-streaming --ctx 8192 \
    ${DS4_EXTRA_ARGS:-} \
    --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT
n=0
until grep -q 'listening on' "$LOG"; do
    kill -0 "$pid" 2>/dev/null || { echo "server exited"; tail -30 "$LOG"; exit 1; }
    n=$((n+1)); [ "$n" -gt 200 ] && { echo "server never listened"; exit 1; }
    sleep 3
done
# Greedy, so the rate is the model's and not the sampler's.
curl -s --max-time 3600 "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"ds4\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a detailed explanation of how a B-tree insert works, including node splitting.\"}],\"max_tokens\":$TOKENS,\"temperature\":0}" \
  > "$S/sus-$NAME.json" 2>&1
sleep 2
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

echo "== sustained generation, $TOKENS tokens =="
grep -E 'gen=[0-9]+ .*avg=' "$LOG" | tail -2
grep -E 'finish=' "$LOG" | tail -1
path=$(grep -E 'decode path so far:' "$LOG" | tail -1)
echo "${path:-ds4:   decode path so far: (never printed)}"

rc=0
kblocks=$(printf '%s\n' "$path" | sed -n 's/.*steps, \([0-9]*\) K-row verification.*/\1/p')
kblocks=${kblocks:-0}
fuse=$(printf '%s\n' "$path" | sed -n 's/.*positions, \([0-9]*\) batch-fusion.*/\1/p')
fuse=${fuse:-0}
if [ "$kblocks" = "0" ]; then
    echo "REFUSED: no K-row verification step ran, so this rate is the single-row path" >&2
    rc=1
elif ! printf '%s\n' "$path" | grep -q "candidate K.*\b$EXPECT_K:"; then
    echo "REFUSED: no candidate width $EXPECT_K in the histogram" >&2
    rc=1
fi
if [ "$WANT_FUSE" = "1" ] && [ "$fuse" = "0" ]; then
    echo "REFUSED: DS4_METAL_V41_BATCH_FUSE was set and no fusion site was taken" >&2
    rc=1
fi
[ "$rc" = "0" ] && echo "checks passed: $kblocks K-row steps, $fuse fusion sites"
exit "$rc"
