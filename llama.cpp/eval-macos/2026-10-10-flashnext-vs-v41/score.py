"""Score out-<engine>.jsonl files. Manual and free-form items are listed, not scored.

usage: python3 score.py flashnext ds4
"""
import json, os, re, subprocess, sys, tempfile
from tasks import TASKS

HERE = os.path.dirname(os.path.abspath(__file__))
BY_ID = {t["id"]: t for t in TASKS}


def code_block(text, name):
    blocks = re.findall(r"```(?:python|py)?\s*\n(.*?)```", text, re.S)
    defs = [b for b in blocks if re.search(rf"^(def|class) {name}\b", b, re.M)]
    return (defs or blocks or [""])[-1]


def run_code(src, name, timeout=120):
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "cand.py"), "w").write(src)
        prog = f"import sys; sys.path[:0]=[{d!r},{HERE!r}]; import cand, hidden; print(hidden.t_{name}(cand))"
        try:
            r = subprocess.run([sys.executable, "-c", prog], capture_output=True, text=True, timeout=timeout, cwd=d)
        except subprocess.TimeoutExpired:
            return (0, None), "timeout"
        m = re.search(r"\((\d+), (\d+)\)\s*$", r.stdout)
        if not m:
            return (0, None), (r.stderr.strip().splitlines() or ["no result"])[-1]
        return (int(m[1]), int(m[2])), ""


def score(rec):
    t = BY_ID[rec["id"]]
    chk = t["check"]
    if chk is None:
        return None, ""
    if isinstance(chk, tuple):
        (ok, tot), err = run_code(code_block(rec["content"], chk[1]), chk[1])
        return (ok, tot) if tot else (0, 1), err
    return chk(rec["content"]), ""


def main():
    for eng in sys.argv[1:]:
        recs = [json.loads(l) for l in open(f"out-{eng}.jsonl")]
        groups = {}
        print(f"== {eng}")
        for r in recs:
            s, err = score(r)
            u = r.get("usage") or {}
            tag = "manual" if s is None else f"{s[0]}/{s[1]}"
            print(f"{r['id']:5} {tag:8} {r['wall']:7.1f}s out={u.get('completion_tokens')} "
                  f"finish={r['finish']} {err}")
            if s and s[1]:
                key = BY_ID[r["id"]]["group"] + ("+think" if BY_ID[r["id"]]["think"] else "")
                g = groups.setdefault(key, [0, 0, 0])
                g[0] += s[0] / s[1]; g[1] += 1; g[2] += 1 if s[0] == s[1] else 0
        for k, (frac, n, full) in groups.items():
            print(f"  {k:14} full {full}/{n}  (partial-credit sum {frac:.2f})")


if __name__ == "__main__":
    main()
