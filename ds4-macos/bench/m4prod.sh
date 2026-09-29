#!/bin/bash
# The production server, the seven inputs, one process, and what ran.
#
#   m4prod.sh <name> <backend 3|4> [VAR=VALUE...]
#   ONLY=a,b     run a subset of the inputs
#   REPEAT=N     run the whole list N times in the same process
#
# The configuration is bench/sustained.sh's - the frozen exact production -
# not correct.sh's, which is ungated. Every run records the revision, whether
# the tree was dirty, and the binary's hash beside its outputs, so a result
# cannot be read against a binary it did not come from.
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; BACKEND=$2; shift 2
case "$BACKEND" in 3) M4=0 ;; 4) M4=1 ;; *) echo "backend must be 3 or 4" >&2; exit 2 ;; esac
for a in "$@"; do
    case "$a" in
        *" "*) echo "environment argument contains a space: $a" >&2; exit 2 ;;
        *=*) ;;
        *) echo "not a VAR=VALUE assignment: $a" >&2; exit 2 ;;
    esac
done
PORT=${PORT:-8019}
LOG=$S/m4-$NAME.log
BIN=${DS4_BIN:-$HOME/ghq/github.com/antirez/ds4-v41-mtl4dag}
cd "$BIN" || exit 1
while pgrep -x ds4-server >/dev/null; do sleep 2; done
{
    echo "rev $(git rev-parse HEAD)"
    echo "dirty $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    git diff --stat | tail -1 | sed 's/^/diffstat /'
    echo "binary $(shasum -a 256 ds4-server | cut -d' ' -f1)"
    echo "binary_mtime $(stat -f %Sm ds4-server)"
    echo "backend $BACKEND"
    echo "extra $*"
    echo "started $(date '+%F %T')"
} > "$S/m4-$NAME.prov"
# Nothing newer than the binary may be in the sources it was built from:
# a header edit that did not rebuild is how an old binary gets measured.
newer=$(find . -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' \) -newer ds4-server | head -5)
newer_metal=$(find metal -name '*.metal' -newer ds4-server | head -5)
if [ -n "$newer$newer_metal" ]; then
    echo "REFUSED: sources newer than ds4-server: $newer $newer_metal" >&2
    exit 1
fi
env DS4_METAL_V41_DECODE_QUEUE=1 DS4_METAL_IQ2_SELECTED_SHARED_EVENT=1 \
    DS4_METAL_STREAM_SPLIT_MIN_MISSING=1 \
    DS4_METAL_STREAMING_EXPERT_AUTO_PRELOAD_CAP=8192 \
    DS4_METAL_V41_DECODE_LEND_HEADROOM=1 \
    DS4_METAL_V41_ABORT_GATE=40 DS4_METAL_V41_ABORT_GATE_SEG=3 \
    DS4_METAL_V41_EXPERT_RESIDENCY_SET=1 DS4_METAL_V41_FFN_OVERLAP=1 \
    DS4_METAL_V41_ROUTER_FUSE_TRANSFORM=5 DS4_METAL_V41_FUSE_BF16=2 \
    DS4_METAL_V41_HC_COMPOUND=1 \
    DS4_METAL_V41_GATE_ENCODE_AHEAD=1 \
    DS4_METAL_V41_MTL4=$M4 \
    "$@" ./ds4-server -m "$MODEL" --ssd-streaming --ctx 8192 \
    ${DS4_EXTRA_ARGS:---ssd-streaming-cache-experts 10268} \
    --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT
n=0
until grep -q 'listening on' "$LOG"; do
    kill -0 "$pid" 2>/dev/null || { echo "server exited"; tail -30 "$LOG"; exit 1; }
    n=$((n+1)); [ "$n" -gt 200 ] && { echo "server never listened"; exit 1; }
    sleep 3
done
NAME="$NAME" S="$S" ONLY="${ONLY:-}" REPEAT="${REPEAT:-1}" python3 - "$PORT" <<'PY'
import hashlib, json, os, sys, time, urllib.request
URL = f"http://127.0.0.1:{sys.argv[1]}/v1/chat/completions"
S, NAME = os.environ["S"], os.environ["NAME"]
PROMPTS = [
    ("breakout", "単一のHTMLファイルで、キーボードで遊べるブロック崩しゲームを作ってください。"
                 "HTML・CSS・JavaScriptをすべて1つのファイルに含め、コードだけを出力してください。", 512),
    ("quicksort", "Write a quicksort in C with an explanation of the partition step.", 512),
    ("haiku",    "俳句を三つ、季語を変えて詠んでください。", 256),
    ("json",     "Design a JSON schema for a library catalogue and explain each field.", 512),
    ("proof",    "Prove that the square root of two is irrational, carefully.", 384),
    ("long",     "Explain how a modern CPU executes an instruction, from fetch to retire, "
                 "in as much detail as you can.", 2048),
    ("long_ie",  "Explain how a modern CPU executes an instruction, from fetch to retire, "
                 "in as much detail as you can.", 2048, True),
]
only = [x for x in os.environ.get("ONLY", "").split(",") if x]
out = {}
for rep in range(int(os.environ["REPEAT"])):
    for name, p, n, *rest in PROMPTS:
        if only and name not in only: continue
        req = {"model":"deepseek-v4-flash","messages":[{"role":"user","content":p}],
               "max_tokens":n,"temperature":0,"think":False}
        if rest and rest[0]: req["ignore_eos"] = True
        t0 = time.time()
        with urllib.request.urlopen(urllib.request.Request(URL, json.dumps(req).encode(),
                                    {"Content-Type":"application/json"}), timeout=3600) as r:
            d = json.load(r)
        txt = d["choices"][0]["message"].get("content") or ""
        ntok = d["usage"]["completion_tokens"]; w = time.time() - t0
        h = hashlib.sha256(txt.encode()).hexdigest()
        key = name if rep == 0 else f"{name}#{rep}"
        out[key] = h
        open(f"{S}/m4-{NAME}-{key}.txt", "w").write(txt)
        print(f"  {key:<12} {ntok:5d} tok  {w:7.1f}s  {1000*w/max(ntok,1):6.1f} ms/tok  {h[:16]}", flush=True)
json.dump(out, open(f"{S}/m4-{NAME}.json", "w"), indent=1)
PY
rc=$?
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
trap - EXIT
echo "finished $(date '+%F %T') rc=$rc" >> "$S/m4-$NAME.prov"
# Token ids, as the server hashed them, one line a request.
grep -o 'token ids: [0-9]*, hash [0-9a-f]*' "$LOG" > "$S/m4-$NAME.ids"
exit $rc
