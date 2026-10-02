#!/bin/bash
# Sustained generation through the ordinary server path, and a refusal when the
# thing being measured did not run.
#
#   sustained.sh <name> [VAR=VALUE...]
#   CONCURRENCY=N  requests in flight (1 = single stream)
#   EXPECT_K=N     the row count production is supposed to batch at
#
# The selftest measures one k-row step in isolation. That is the right ruler for
# a kernel change and the wrong one for the goal: 100 tok/s is a wall-clock
# number over a real generation. But a generation rate is only evidence about the
# block executor if the generation used it, and which generations do is not
# obvious:
#
#   - ds41_graph_step_batch_logits IS a production path, reached through
#     ds4_sessions_eval_batch_* (ds4.c:85136), but its rows are DIFFERENT
#     sessions - the batch entry rejects a repeated session - plus prefill rows.
#     So N concurrent requests batch into it and one request never does.
#   - single-session speculative verification does NOT reach it: this checkpoint
#     has no drafter (zero mtp.*/nextn tensors, no n_nextn_predict on the
#     FLASH41 shape, no ds41 branch in ds4_session_eval_speculative_argmax_impl),
#     so there are no candidate rows to verify.
#
# Two consequences for anything measured here. A one-request run prices the
# single-row path and says nothing about the row tile or the fusion sweep. And a
# concurrent run prices them on independent sessions, where the weights are
# shared but the KV is not - so the shared-prefix attention declines by design
# and the weight-side work still applies.
#
# This exits non-zero when the run shows no K-row step, or a row count other
# than EXPECT_K, or - with DS4_METAL_V41_BATCH_FUSE set - no fusion sites. A
# tok/s number from a run that failed those checks is the single-row path wearing
# the block path's name.
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; shift
TOKENS=${TOKENS:-256}
CONCURRENCY=${CONCURRENCY:-1}
EXPECT_K=${EXPECT_K:-$CONCURRENCY}
PORT=${PORT:-8017}
LOG=$S/sus-$NAME.log
WANT_FUSE=0
for a in "$@"; do
    case "$a" in DS4_METAL_V41_BATCH_FUSE=0) ;; DS4_METAL_V41_BATCH_FUSE=*) WANT_FUSE=1 ;; esac
done
cd "${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-mtl4dag}" || exit 1
while pgrep -x ds4-server >/dev/null; do sleep 2; done
# The adopted production set: slabs rather than zero-copy experts and the
# prewarm cap (loader, ce99d26/f74eed1) and the package (router 5, fused
# transitions, HC compound). The expert-ready continuation (=2, 4889363) is
# not in it: run alone it was 4.5 ms a token slower (see V4.1-TUNING.md).
# The expert cache at the working-set cap with the prefill reserve lent to
# decode (9709 experts in decode, 2026-09-29): -2.06 ms a token.
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 \
    DS4_METAL_STREAMING_EXPERT_AUTO_PRELOAD_CAP=8192 \
    DS4_METAL_V41_DECODE_LEND_HEADROOM=1 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_ROUTER_FUSE_TRANSFORM=5 DS4_METAL_V41_FUSE_BF16=2 \
    DS4_METAL_V41_HC_COMPOUND=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    "$@" ./ds4-server -m "$MODEL" --ssd-streaming --ctx 8192 \
    ${DS4_EXTRA_ARGS:---ssd-streaming-cache-experts 10268} \
    --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
pid=$!
# Every way out stops what this started: the server and any stream still
# running. A TERM or INT becomes an exit so that this runs then too - killed
# with the default action, bash runs no EXIT trap and leaves the server up.
streams=""
trap 'kill $streams "$pid" 2>/dev/null; for j in $streams "$pid"; do wait "$j" 2>/dev/null; done' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
n=0
until grep -q 'listening on' "$LOG"; do
    kill -0 "$pid" 2>/dev/null || { echo "server exited"; tail -30 "$LOG"; exit 1; }
    n=$((n+1)); [ "$n" -gt 200 ] && { echo "server never listened"; exit 1; }
    sleep 3
done
# Greedy, so the rate is the model's and not the sampler's. The prompts differ
# per stream: identical prompts would share a prefix cache and the streams would
# not stay at the same frontier, which is not what a batch of clients looks like.
wall0=$(python3 -c 'import time; print(time.time())')
# Wait on the streams by pid. A bare `wait` also waits on the server job started
# above, which does not exit until it is killed - so the harness hung after every
# generation and never printed its own lines, while the numbers still reached the
# log and could be read from there.
for c in $(seq 1 "$CONCURRENCY"); do
    curl -s --max-time 3600 "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'content-type: application/json' \
      -d "{\"model\":\"ds4\",\"messages\":[{\"role\":\"user\",\"content\":\"Stream $c: write a detailed explanation of how a B-tree insert works, including node splitting.\"}],\"max_tokens\":$TOKENS,\"temperature\":0}" \
      > "$S/sus-$NAME-$c.json" 2>&1 &
    streams="$streams $!"
done
for j in $streams; do wait "$j"; done
wall1=$(python3 -c 'import time; print(time.time())')
sleep 2
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

echo "== sustained generation, $CONCURRENCY x $TOKENS tokens =="
python3 -c "print('aggregate %.2f tok/s over %.1f s wall' % ($CONCURRENCY*$TOKENS/($wall1-$wall0), $wall1-$wall0))"
grep -E 'gen=[0-9]+ .*avg=' "$LOG" | tail -2
grep -E 'finish=' "$LOG" | tail -1
path=$(grep -E 'decode path so far:' "$LOG" | tail -1)
echo "${path:-ds4:   decode path so far: (never printed)}"

# Only meaningful for one stream: with N in flight each stream's wall per token
# is N steps of GPU, so wall minus graph is queueing, not host work.
if [ "$CONCURRENCY" != "1" ]; then graph_ms=""; fi
# The split, from this one run on one ruler. Subtracting the selftest's median
# single from a generation's tok/s would be two rulers and has been the mistake
# here twice; the graph's per-step wall is now counted inside the same process
# that produced the rate.
graph_ms=$(printf '%s\n' "$path" | sed -n 's/.*single-row steps (\([0-9.]*\) ms each.*/\1/p')
avg_tps=$(grep -Eo 'avg=[0-9.]+ t/s' "$LOG" | tail -1 | sed 's/avg=//;s/ t\/s//')
if [ -n "${graph_ms:-}" ] && [ -n "${avg_tps:-}" ]; then
    python3 -c "
g=$graph_ms; t=$avg_tps
w=1000.0/t
print('per token: %.1f ms wall at %.2f tok/s, %.1f ms inside the graph, %.1f ms (%.0f%%) outside'
      % (w, t, g, w-g, 100.0*(w-g)/w))"
fi

rc=0
kblocks=$(printf '%s\n' "$path" | sed -n 's/.*[,)] \([0-9]*\) K-row verification.*/\1/p')
kblocks=${kblocks:-0}
fuse=$(printf '%s\n' "$path" | sed -n 's/.*positions, \([0-9]*\) batch-fusion.*/\1/p')
fuse=${fuse:-0}
if [ "$kblocks" = "0" ]; then
    echo "REFUSED: no K-row verification step ran, so this rate is the single-row path" >&2
    rc=1
elif ! printf '%s\n' "$path" | grep -q "candidate K.*[ ]$EXPECT_K:"; then
    echo "REFUSED: no row count $EXPECT_K in the histogram" >&2
    rc=1
fi
if [ "$WANT_FUSE" = "1" ] && [ "$fuse" = "0" ]; then
    echo "REFUSED: DS4_METAL_V41_BATCH_FUSE was set and no fusion site was taken" >&2
    rc=1
fi
[ "$rc" = "0" ] && echo "checks passed: $kblocks K-row steps, $fuse fusion sites"
exit "$rc"
