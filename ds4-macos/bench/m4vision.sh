#!/bin/bash
# The production server with the V4.1 vision encoder: image requests, a
# two-image request and a text request after them, bytes and token ids kept.
#
#   m4vision.sh <name> [VAR=VALUE...]      DS4_BIN picks the build
#
# Run once on the Metal 3 oracle build and once on the Metal 4 one, and
# compare m4v-<name>.json and m4v-<name>.ids.
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
VISION=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Vision.gguf
NAME=$1; shift
PORT=${PORT:-18421}
LOG=$S/m4v-$NAME.log
BIN=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-mtl4dag}
cd "$BIN" || exit 1
while pgrep -x ds4-server >/dev/null; do sleep 2; done
newer=$(find . -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer ds4-server | head -5)
[ -n "$newer" ] && { echo "REFUSED: sources newer than ds4-server: $newer" >&2; exit 1; }
{
    echo "rev $(git rev-parse HEAD) dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    echo "binary $(shasum -a 256 ds4-server | cut -d' ' -f1)"
    echo "extra $*"
} > "$S/m4v-$NAME.prov"
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 \
    DS4_METAL_STREAMING_EXPERT_AUTO_PRELOAD_CAP=8192 \
    DS4_METAL_V41_DECODE_LEND_HEADROOM=1 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_ROUTER_FUSE_TRANSFORM=5 DS4_METAL_V41_FUSE_BF16=2 \
    DS4_METAL_V41_HC_COMPOUND=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    "$@" ./ds4-server -m "$MODEL" --vision "$VISION" --ssd-streaming --ctx 8192 \
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
NAME="$NAME" S="$S" python3 - "$PORT" <<'PY'
import base64, hashlib, json, os, sys, time, urllib.request
URL = f"http://127.0.0.1:{sys.argv[1]}/v1/chat/completions"
S, NAME = os.environ["S"], os.environ["NAME"]
def img(path, mime):
    return {"type": "image_url", "image_url": {"url": f"data:{mime};base64," +
            base64.b64encode(open(f"{S}/{path}", "rb").read()).decode()}}
chart = img("vis-chart.png", "image/png")
imac = img("vis-imac.jpg", "image/jpeg")
CASES = [
    ("chart", [chart, {"type": "text", "text": "Read every piece of text in this image and "
                       "describe each shape with its colour."}], 384),
    ("photo", [imac, {"type": "text", "text": "Describe this image in detail."}], 256),
    ("two",   [chart, imac, {"type": "text", "text": "Compare the two images."}], 256),
    ("text",  "Write a quicksort in C with an explanation of the partition step.", 256),
]
out = {}
for name, content, n in CASES:
    req = {"model": "deepseek-v4-flash", "messages": [{"role": "user", "content": content}],
           "max_tokens": n, "temperature": 0, "think": False}
    t0 = time.time()
    with urllib.request.urlopen(urllib.request.Request(URL, json.dumps(req).encode(),
                                {"Content-Type": "application/json"}), timeout=3600) as r:
        d = json.load(r)
    m = d["choices"][0]["message"]
    txt = (m.get("reasoning_content") or "") + "|" + (m.get("content") or "")
    h = hashlib.sha256(txt.encode()).hexdigest()
    out[name] = h
    open(f"{S}/m4v-{NAME}-{name}.txt", "w").write(txt)
    print(f"  {name:<6} {d['usage']['completion_tokens']:4d} tok {time.time()-t0:6.1f}s  {h[:16]}",
          flush=True)
json.dump(out, open(f"{S}/m4v-{NAME}.json", "w"), indent=1)
PY
rc=$?
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
trap - EXIT
grep -o 'token ids: [0-9]*, hash [0-9a-f]*' "$LOG" > "$S/m4v-$NAME.ids"
exit $rc
