#!/bin/bash
# One arm of the paired comparison. $1 = name, rest = extra env.
# The window report is the measurement; the stream rate is a sanity check only.
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; shift
PORT=8015
LOG=$S/ab-$NAME.log
cd "$HOME/ghq/github.com/antirez/ds4-v41" || exit 1
wait_for_no_server() {
    local n=0
    while pgrep -f "ds4-server -m" >/dev/null; do
        n=$((n+1))
        [ "$n" -gt 180 ] && { echo "a ds4-server is still running after 6 min"; exit 1; }
        sleep 2
    done
}
wait_for_no_server
# Rule 11: a window of identical work moves by a factor of two with machine
# state, so record what the machine was doing around each arm.
vm_stat | head -4 > "$S/ab-$NAME.vm"
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 DS4_METAL_ZERO_COPY_EXPERTS=1 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 \
    "$@" ./ds4-server -m "$MODEL" --ssd-streaming --ctx 8192 \
    --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT
until grep -q 'listening on' "$LOG"; do
    kill -0 "$pid" 2>/dev/null || { echo "server exited"; tail -20 "$LOG"; exit 1; }
    sleep 5
done
NTOK="${NTOK:-1400}" python3 - "$PORT" "$NAME" <<'PY'
import json, os, sys, time, urllib.request
URL = f"http://127.0.0.1:{sys.argv[1]}/v1/chat/completions"
P = ("Explain how a modern CPU executes an instruction, from fetch to retire, "
     "in as much detail as you can.")
body = json.dumps({"model":"deepseek-v4-flash","messages":[{"role":"user","content":P}],
                   "max_tokens":int(os.environ["NTOK"]),"temperature":0,"think":False,
                   "stream":True}).encode()
req = urllib.request.Request(URL, body, {"Content-Type":"application/json"})
n, t0 = 0, time.time()
with urllib.request.urlopen(req, timeout=3600) as r:
    for line in r:
        if line.startswith(b"data: ") and line[6:].strip() != b"[DONE]":
            d = json.loads(line[6:])
            if d["choices"][0].get("delta", {}).get("content") is not None: n += 1
print(f"  [{sys.argv[2]}] {n} chunks in {time.time()-t0:.1f}s")
PY
vm_stat | head -4 >> "$S/ab-$NAME.vm"
kill "$pid" 2>/dev/null
wait_for_no_server
sleep 45
