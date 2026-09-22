#!/bin/bash
# One arm of the paired comparison. $1 = name, rest = extra env.
# The window report is the measurement; the stream rate is a sanity check only.
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
PORT=8015
LOG=$S/ab-$NAME.log
cd "$HOME/ghq/github.com/antirez/ds4-v41" || exit 1
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
# How long the machine was idle before this arm. An hour of running costs 6-7
# ms a token and ten minutes idle returns it, so the gap belongs beside the
# result rather than in a file nothing reads.
now=$(date +%s)
if [ -f "$S/.last-arm-end" ]; then
    echo "$((now - $(cat "$S/.last-arm-end")))" > "$S/ab-$NAME.gap"
else
    echo "-1" > "$S/ab-$NAME.gap"
fi
vm_stat | head -4 > "$S/ab-$NAME.vm"
# How much CPU anything other than this arm took while it ran.
#
# The thermal gate watches a fixed GPU kernel, so it says nothing about the
# host - and the host is on the critical path, because every miss is repaired
# by it. A campaign was lost to a security scanner that woke at 23:19 and sat
# at 124% CPU: same bytes a token, same routes, 70 ms a token instead of 55,
# and repair-load 14.1 instead of 10.2. Pairing did not cancel it because the
# contention varied between arms.
#
# Total CPU-seconds of every process except the server, sampled either side.
# pair.py refuses a campaign whose arms did not get the same machine.
host_cpu() {
    ps -Ao comm=,time= | awk '$1 !~ /ds4-server/ {
        n = split($2, t, ":")
        s = (n == 3 ? t[1]*3600 + t[2]*60 + t[3] : t[1]*60 + t[2])
        total += s
    } END { printf "%.0f\n", total }'
}
host_cpu > "$S/ab-$NAME.cpu"
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
NTOK="${NTOK:-1400}" S="$S" NAME="$NAME" python3 - "$PORT" <<'PY'
# The performance run hashes its own output. A separate six-prompt check is
# still the byte-identity proof, but an arm that quietly generated something
# else is not a paired comparison, and only its own bytes can say.
import hashlib, json, os, sys, time, urllib.request
URL = f"http://127.0.0.1:{sys.argv[1]}/v1/chat/completions"
S, NAME = os.environ["S"], os.environ["NAME"]
P = ("Explain how a modern CPU executes an instruction, from fetch to retire, "
     "in as much detail as you can.")
body = json.dumps({"model":"deepseek-v4-flash","messages":[{"role":"user","content":P}],
                   "max_tokens":int(os.environ["NTOK"]),"temperature":0,"think":False,
                   "stream":True}).encode()
req = urllib.request.Request(URL, body, {"Content-Type":"application/json"})
n, t0, text = 0, time.time(), []
with urllib.request.urlopen(req, timeout=3600) as r:
    for line in r:
        if line.startswith(b"data: ") and line[6:].strip() != b"[DONE]":
            d = json.loads(line[6:])
            c = d["choices"][0].get("delta", {}).get("content")
            if c is not None:
                n += 1
                text.append(c)
out = "".join(text)
h = hashlib.sha256(out.encode()).hexdigest()
open(f"{S}/ab-{NAME}.sha", "w").write(f"{h} {n}\n")
print(f"  [{NAME}] {n} chunks in {time.time()-t0:.1f}s  {h[:16]}")
PY
vm_stat | head -4 >> "$S/ab-$NAME.vm"
host_cpu >> "$S/ab-$NAME.cpu"
kill "$pid" 2>/dev/null
wait_for_no_server
date +%s > "$S/.last-arm-end"
sleep 45
