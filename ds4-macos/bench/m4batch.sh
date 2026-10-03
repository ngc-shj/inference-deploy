#!/bin/bash
# The production server with batched sessions and requests in flight
# together: each stream's bytes and token ids kept, so a Metal 4 build can be
# compared with the Metal 3 oracle build stream by stream.
#
#   m4batch.sh <name> [VAR=VALUE...]      DS4_BIN picks the build
#   SESSIONS=N  resident sessions and concurrent requests (default 3)
#
# SSD-streaming V4.1 serves batched sessions in order unless
# DS4_METAL_ENABLE_V41_STREAMING_SESSION_BATCH=1 is passed, which takes the
# native K-row path instead.
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; shift
N=${SESSIONS:-3}
PORT=${PORT:-18422}
LOG=$S/m4b-$NAME.log
BIN=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-mtl4dag}
cd "$BIN" || exit 1
while pgrep -x ds4-server >/dev/null; do sleep 2; done
newer=$(find . -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer ds4-server | head -5)
[ -n "$newer" ] && { echo "REFUSED: sources newer than ds4-server: $newer" >&2; exit 1; }
{
    echo "rev $(git rev-parse HEAD) dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    echo "binary $(shasum -a 256 ds4-server | cut -d' ' -f1)"
    echo "sessions $N extra $*"
} > "$S/m4b-$NAME.prov"
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 \
    DS4_METAL_STREAMING_EXPERT_AUTO_PRELOAD_CAP=8192 \
    DS4_METAL_V41_DECODE_LEND_HEADROOM=2 \
    DS4_METAL_V41_STREAMING_MEMORY_BUDGET_GIB=84 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_ROUTER_FUSE_TRANSFORM=5 DS4_METAL_V41_FUSE_BF16=2 \
    DS4_METAL_V41_HC_COMPOUND=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    "$@" ./ds4-server -m "$MODEL" --ssd-streaming --ctx 4096 --batched-session "$N" \
    --ssd-streaming-cache-experts 10268 \
    --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT
n=0
until grep -q 'listening on' "$LOG"; do
    kill -0 "$pid" 2>/dev/null || { echo "server exited"; tail -30 "$LOG"; exit 1; }
    n=$((n+1)); [ "$n" -gt 200 ] && { echo "server never listened"; exit 1; }
    sleep 3
done
NAME="$NAME" S="$S" N="$N" python3 - "$PORT" <<'PY'
import hashlib, json, os, sys, time, threading, urllib.request
URL = f"http://127.0.0.1:{sys.argv[1]}/v1/chat/completions"
S, NAME, N = os.environ["S"], os.environ["NAME"], int(os.environ["N"])
PROMPTS = [
    ("quicksort", "Write a quicksort in C with an explanation of the partition step.", 384),
    ("proof", "Prove that the square root of two is irrational, carefully.", 384),
    ("json", "Design a JSON schema for a library catalogue and explain each field.", 384),
    ("haiku", "俳句を三つ、季語を変えて詠んでください。", 256),
    ("cpu", "Explain how a modern CPU executes an instruction, from fetch to retire.", 384),
    ("btree", "Explain how a B-tree insert works, including node splitting.", 384),
    ("tcp", "Explain the TCP three-way handshake and why it needs three steps.", 384),
    ("rust", "Explain Rust ownership and borrowing with a short example.", 384),
][:N]
out = {}
def run(name, p, n):
    req = {"model": "deepseek-v4-flash", "messages": [{"role": "user", "content": p}],
           "max_tokens": n, "temperature": 0, "think": False}
    t0 = time.time()
    with urllib.request.urlopen(urllib.request.Request(URL, json.dumps(req).encode(),
                                {"Content-Type": "application/json"}), timeout=3600) as r:
        d = json.load(r)
    m = d["choices"][0]["message"]
    txt = (m.get("reasoning_content") or "") + "|" + (m.get("content") or "")
    out[name] = hashlib.sha256(txt.encode()).hexdigest()
    open(f"{S}/m4b-{NAME}-{name}.txt", "w").write(txt)
    print(f"  {name:<10} {d['usage']['completion_tokens']:4d} tok {time.time()-t0:6.1f}s  "
          f"{out[name][:16]}", flush=True)
threads = [threading.Thread(target=run, args=a) for a in PROMPTS]
for t in threads: t.start()
for t in threads: t.join()
json.dump(dict(sorted(out.items())), open(f"{S}/m4b-{NAME}.json", "w"), indent=1)
PY
rc=$?
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
trap - EXIT
# Request order varies between runs, so the ids are kept sorted.
grep -o 'token ids: [0-9]*, hash [0-9a-f]*' "$LOG" | sort > "$S/m4b-$NAME.ids"
grep -E 'decode path so far' "$LOG" | tail -1 > "$S/m4b-$NAME.path"
exit $rc
