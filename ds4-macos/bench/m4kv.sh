#!/bin/bash
# Disk KV cache across a restart: the first server answers a long prompt and
# saves its prefix, a second server on the same directory is sent the
# conversation continued and has to restore from disk before it prefills the
# new turn. Bytes and token ids of both answers are kept.
#
#   m4kv.sh <name> [VAR=VALUE...]      DS4_BIN picks the build
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; shift
PORT=${PORT:-18423}
BIN=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-mtl4dag}
KV=$S/m4kv-$NAME.kvdir
rm -rf "$KV"; mkdir -p "$KV"
cd "$BIN" || exit 1
while pgrep -x ds4-server >/dev/null; do sleep 2; done
newer=$(find . -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer ds4-server | head -5)
[ -n "$newer" ] && { echo "REFUSED: sources newer than ds4-server: $newer" >&2; exit 1; }
echo "rev $(git rev-parse HEAD) dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ') binary $(shasum -a 256 ds4-server | cut -d' ' -f1) extra $*" > "$S/m4kv-$NAME.prov"
serve() {
    env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
        DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 \
        DS4_METAL_STREAMING_EXPERT_AUTO_PRELOAD_CAP=8192 \
    DS4_METAL_V41_DECODE_LEND_HEADROOM=2 \
        DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
        DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
        DS4_METAL_V41_ROUTER_FUSE_TRANSFORM=5 DS4_METAL_V41_FUSE_BF16=2 \
        DS4_METAL_V41_HC_COMPOUND=1 \
        DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
        "$@" ./ds4-server -m "$MODEL" --ssd-streaming --ctx 8192 \
        --ssd-streaming-cache-experts 10268 --kv-disk-dir "$KV" --kv-disk-space-mb 4096 \
        --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
    pid=$!
    n=0
    until grep -q 'listening on' "$LOG"; do
        kill -0 "$pid" 2>/dev/null || { echo "server exited"; tail -30 "$LOG"; exit 1; }
        n=$((n+1)); [ "$n" -gt 200 ] && { echo "server never listened"; exit 1; }
        sleep 3
    done
}
ask() {
    NAME="$NAME" S="$S" TURN="$1" python3 - "$PORT" <<'PY'
import hashlib, json, os, sys, urllib.request
URL = f"http://127.0.0.1:{sys.argv[1]}/v1/chat/completions"
S, NAME, TURN = os.environ["S"], os.environ["NAME"], os.environ["TURN"]
story = open(os.path.expanduser(
    "~/ghq/github.com/antirez/ds4-v41-mtl4dag/tests/long_context_story_prompt.txt")).read()[:9000]
msgs = [{"role": "user", "content": story + "\n\nSummarize the story so far in five sentences."}]
if TURN == "2":
    msgs += [{"role": "assistant", "content": open(f"{S}/m4kv-{NAME}-1.txt").read().split("|", 1)[1]},
             {"role": "user", "content": "Now list every named character and one fact about each."}]
req = {"model": "deepseek-v4-flash", "messages": msgs, "max_tokens": 192,
       "temperature": 0, "think": False}
with urllib.request.urlopen(urllib.request.Request(URL, json.dumps(req).encode(),
                            {"Content-Type": "application/json"}), timeout=3600) as r:
    d = json.load(r)
m = d["choices"][0]["message"]
txt = (m.get("reasoning_content") or "") + "|" + (m.get("content") or "")
open(f"{S}/m4kv-{NAME}-{TURN}.txt", "w").write(txt)
print(f"  turn {TURN}: {d['usage']['completion_tokens']} tok {hashlib.sha256(txt.encode()).hexdigest()[:16]}")
PY
}
LOG=$S/m4kv-$NAME-a.log; serve "$@"; ask 1; kill "$pid"; wait "$pid" 2>/dev/null
ls "$KV" | head -3 | sed 's/^/  saved: /'
LOG=$S/m4kv-$NAME-b.log; serve "$@"; ask 2; kill "$pid"; wait "$pid" 2>/dev/null
grep -h -i -E 'kv.*(disk|load|restor|hit)|disk.*(hit|load)' "$S/m4kv-$NAME-b.log" | head -5
grep -ho 'token ids: [0-9]*, hash [0-9a-f]*' "$S/m4kv-$NAME-a.log" "$S/m4kv-$NAME-b.log" > "$S/m4kv-$NAME.ids"
