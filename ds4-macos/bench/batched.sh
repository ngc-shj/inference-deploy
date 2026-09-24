#!/bin/bash
# Two concurrent sessions through one server, hashed against the single-session
# answer. The batched expert path only engages with more than one row, so a
# defect that lives there cannot be reproduced by generating on its own.
#
#   batched.sh <name> [VAR=VALUE...]
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4-v41-mtl4dag/../ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; shift
PORT=8017
LOG=$S/bs-$NAME.log
cd "${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-mtl4dag}" || exit 1
while pgrep -x ds4-server >/dev/null; do sleep 2; done
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 DS4_METAL_ZERO_COPY_EXPERTS=1 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    "$@" ./ds4-server -m "$MODEL" --ssd-streaming --ctx 8192 --batched-session ${DS4_BATCH_ROWS:-2} \
    --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT
n=0
until grep -q 'listening on' "$LOG"; do
    kill -0 "$pid" 2>/dev/null || { echo "server exited"; tail -20 "$LOG"; exit 1; }
    n=$((n+1)); [ "$n" -gt 200 ] && { echo "server never listened"; exit 1; }
    sleep 3
done
NAME="$NAME" S="$S" python3 - "$PORT" <<'PY'
import hashlib, json, os, sys, threading, urllib.request
URL = f"http://127.0.0.1:{sys.argv[1]}/v1/chat/completions"
# The same two requests correct-fast.sh sends, so the hashes are comparable to
# its single-session answer. They were not, once, and the difference was read
# as a defect in the batched path.
PROMPTS = [("quicksort", "Write a quicksort in C with an explanation of the partition step.", 160),
           ("haiku", "\u4ff3\u53e5\u3092\u4e09\u3064\u3001\u5b63\u8a9e\u3092\u5909\u3048\u3066\u8a60\u3093\u3067\u304f\u3060\u3055\u3044\u3002", 96)]
out = {}
def run(name, p, n):
    body = json.dumps({"model": "ds4", "messages": [{"role": "user", "content": p}],
                       "max_tokens": n, "temperature": 0, "think": False}).encode()
    req = urllib.request.Request(URL, data=body, headers={"content-type": "application/json"})
    txt = json.load(urllib.request.urlopen(req, timeout=1800))["choices"][0]["message"]["content"]
    out[name] = hashlib.sha256(txt.encode()).hexdigest()
ts = [threading.Thread(target=run, args=a) for a in PROMPTS]
for t in ts: t.start()
for t in ts: t.join()
json.dump(out, open(f"{os.environ['S']}/bs-{os.environ['NAME']}.json", "w"), indent=1)
print(json.dumps(out, indent=1))
PY
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
