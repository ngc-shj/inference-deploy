#!/bin/bash
# One verify-selftest run: start a server, send one short request so the first
# decode fires ds41_verify_selftest, keep the stderr log.
#
#   selftest.sh <name> VAR=VALUE...
#
# The selftest runs once per process, on the first decode of the first session,
# so the request only has to exist - its content and length do not matter.
#
# What it is for is the k-row step, and the only comparison on this machine that
# can see a change smaller than the drift is the one inside a single process:
#
#   selftest.sh ab DS4_V41_VERIFY_SELFTEST=8 DS4_V41_VERIFY_SELFTEST_ROUNDS=5 \
#       DS4_V41_VERIFY_SELFTEST_BATCH_AB=DS4_METAL_V41_BATCH_ATTN_OUT
#
# Starting one server per arm cannot: the same K=8 step measured 255 ms and
# 427 ms three hours apart. Check that the variable being alternated is read on
# every call and not cached in a static, or both arms are the same arm.
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; shift
for a in "$@"; do
    case "$a" in
        *" "*) echo "environment argument contains a space: $a" >&2
               echo "pass each VAR=VALUE as its own word" >&2; exit 2 ;;
        *=*) ;;
        *) echo "not a VAR=VALUE assignment: $a" >&2; exit 2 ;;
    esac
done
PORT=${PORT:-8016}
LOG=$S/st-$NAME.log
cd "${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-mtl4dag}" || exit 1
while pgrep -x ds4-server >/dev/null; do sleep 2; done
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 DS4_METAL_ZERO_COPY_EXPERTS=1 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    "$@" ./ds4-server -m "$MODEL" --ssd-streaming --ctx 8192 \
    --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT
n=0
until grep -q 'listening on' "$LOG"; do
    kill -0 "$pid" 2>/dev/null || { echo "server exited"; tail -30 "$LOG"; exit 1; }
    n=$((n+1)); [ "$n" -gt 200 ] && { echo "server never listened"; exit 1; }
    sleep 3
done
curl -s --max-time 900 "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"ds4","messages":[{"role":"user","content":"hi"}],"max_tokens":4,"temperature":0}' \
  > "$S/st-$NAME.json" 2>&1
sleep 2
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
grep -E 'verify selftest|round |median|ceiling|batch vs single|hoisted' "$LOG"
