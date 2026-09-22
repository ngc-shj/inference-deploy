#!/bin/bash
# One server, several prompts, bytes kept. $1 = name, rest = extra env.
set -u
S=$(cd "$(dirname "$0")" && pwd)
MODEL=$HOME/ghq/github.com/antirez/ds4/gguf/DeepSeek-V4.1-Flash-Q2.gguf
NAME=$1; shift
# An argument with a space in it is one variable whose value swallowed the
# rest: zsh does not word-split an unquoted $VAR, so `run $ENVS` arrives as a
# single VAR=value with the other assignments inside it. The server then runs
# with most of the configuration missing and reports something that looks like
# a regression. Refuse it.
for a in "$@"; do
    case "$a" in
        *[!A-Za-z0-9_]*=*) ;;
    esac
    case "$a" in
        *" "*) echo "environment argument contains a space: $a" >&2
               echo "pass each VAR=VALUE as its own word" >&2; exit 2 ;;
        *=*) ;;
        *) echo "not a VAR=VALUE assignment: $a" >&2; exit 2 ;;
    esac
done
PORT=8014
LOG=$S/co-$NAME.log
cd "$HOME/ghq/github.com/antirez/ds4-v41" || exit 1
# A killed server holds ds4's lock while it unmaps 340 GiB; starting the next
# arm without waiting either fails outright or runs beside it.
wait_for_no_server() {
    local n=0
    # -x matches the process name, not the command line. Both earlier forms
    # were wrong in opposite directions: "ds4-server -m" matched the waiting
    # shell itself, so an arm refused to start because it could see its own
    # watcher; "ds4-v41/ds4-server" matched nothing at all, because the server
    # is started as ./ds4-server and the directory never appears in its
    # command line - the guard was inert, and a run that overran its arm went
    # unnoticed until a port collision surfaced it somewhere else.
    while pgrep -x ds4-server >/dev/null; do
        n=$((n+1))
        [ "$n" -gt 180 ] && { echo "a ds4-server is still running after 6 min"; exit 1; }
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
    sleep 5
done
NAME="$NAME" S="$S" python3 - "$PORT" <<'PY'
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
]
out = {}
for name, p, n in PROMPTS:
    body = json.dumps({"model":"deepseek-v4-flash","messages":[{"role":"user","content":p}],
                       "max_tokens":n,"temperature":0,"think":False}).encode()
    t0=time.time()
    with urllib.request.urlopen(urllib.request.Request(URL, body, {"Content-Type":"application/json"}), timeout=3600) as r:
        d=json.load(r)
    txt=d["choices"][0]["message"].get("content") or ""
    ntok=d["usage"]["completion_tokens"]; w=time.time()-t0
    out[name]=hashlib.sha256(txt.encode()).hexdigest()
    open(f"{S}/co-{NAME}-{name}.txt","w").write(txt)
    print(f"  {name:<10} {ntok:5d} tok  {w:6.1f}s  {ntok/w:5.2f} t/s  {out[name][:16]}")
json.dump(out, open(f"{S}/co-{NAME}.json","w"), indent=1)
PY
kill "$pid" 2>/dev/null
wait_for_no_server
