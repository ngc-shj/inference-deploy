#!/bin/bash
# The byte check while still experimenting: two short prompts through one
# server, about a minute a configuration against correct.sh's five or six.
#
# It exercises what an experiment usually breaks - several layers, the gate's
# aborts and continuations, the deferred roundings - but not the long tail.
# Use it to iterate; use correct.sh once, at the end, before claiming anything.
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; shift
PORT=8014
LOG=$S/cf-$NAME.log
cd "$HOME/ghq/github.com/antirez/ds4-v41" || exit 1
wait_for_no_server() {
    local n=0
    while pgrep -f 'ds4-v41/ds4-server' >/dev/null; do
        n=$((n+1)); [ "$n" -gt 180 ] && { echo "a ds4-server is still running"; exit 1; }
        sleep 2
    done
}
wait_for_no_server
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 DS4_METAL_ZERO_COPY_EXPERTS=1 \
    "$@" ./ds4-server -m "$MODEL" --ssd-streaming --ctx 8192 \
    --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT
until grep -q 'listening on' "$LOG"; do
    kill -0 "$pid" 2>/dev/null || { echo "server exited"; tail -20 "$LOG"; exit 1; }
    sleep 3
done
NAME="$NAME" S="$S" python3 - "$PORT" <<'PY'
import hashlib, json, os, sys, time, urllib.request
URL = f"http://127.0.0.1:{sys.argv[1]}/v1/chat/completions"
S, NAME = os.environ["S"], os.environ["NAME"]
PROMPTS = [("quicksort", "Write a quicksort in C with an explanation of the partition step.", 160),
           ("haiku", "俳句を三つ、季語を変えて詠んでください。", 96)]
out = {}
for name, p, n in PROMPTS:
    body = json.dumps({"model":"deepseek-v4-flash","messages":[{"role":"user","content":p}],
                       "max_tokens":n,"temperature":0,"think":False}).encode()
    t0 = time.time()
    with urllib.request.urlopen(urllib.request.Request(
            URL, body, {"Content-Type":"application/json"}), timeout=1800) as r:
        d = json.load(r)
    txt = d["choices"][0]["message"].get("content") or ""
    out[name] = hashlib.sha256(txt.encode()).hexdigest()
    print(f"  {name:<10} {d['usage']['completion_tokens']:4d} tok  "
          f"{time.time()-t0:5.1f}s  {out[name][:16]}")
json.dump(out, open(f"{S}/cf-{NAME}.json", "w"), indent=1)
PY
kill "$pid" 2>/dev/null
wait_for_no_server
