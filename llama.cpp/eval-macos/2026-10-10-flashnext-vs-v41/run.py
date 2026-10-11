"""Send every task to one engine and save the raw responses.

usage: python3 run.py flashnext|ds4 [task-id ...]
"""
import json, sys, time, urllib.request
from tasks import TASKS

ENGINES = {
    "flashnext": dict(url="http://127.0.0.1:11234", think=lambda on: {"reasoning_effort": "medium"} if on else {}),
    "ds4": dict(url="http://127.0.0.1:8019", think=lambda on: {"think": on}),
}


def post(url, body, timeout=3600):
    req = urllib.request.Request(url, json.dumps(body).encode(), {"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def main():
    name = sys.argv[1]
    only = set(sys.argv[2:])
    eng = ENGINES[name]
    with urllib.request.urlopen(eng["url"] + "/v1/models") as r:
        model = json.load(r)["data"][0]["id"]
    out_path = f"out-{name}.jsonl"
    done = set()
    try:
        with open(out_path) as f:
            done = {json.loads(l)["id"] for l in f}
    except FileNotFoundError:
        pass
    for t in TASKS:
        if (only and t["id"] not in only) or (not only and t["id"] in done):
            continue
        body = dict(model=model, messages=[{"role": "user", "content": t["prompt"]}],
                    temperature=0, max_tokens=6144 if t["think"] else 2048, **eng["think"](t["think"]))
        t0 = time.time()
        resp = post(eng["url"] + "/v1/chat/completions", body)
        wall = time.time() - t0
        msg = resp["choices"][0]["message"]
        rec = dict(id=t["id"], model=model, wall=round(wall, 2),
                   finish=resp["choices"][0].get("finish_reason"), usage=resp.get("usage"),
                   content=msg.get("content") or "", reasoning=msg.get("reasoning_content") or msg.get("reasoning") or "")
        with open(out_path, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        u = rec["usage"] or {}
        print(f"{t['id']:5} {wall:7.1f}s  out={u.get('completion_tokens')}  finish={rec['finish']}", flush=True)


if __name__ == "__main__":
    main()
