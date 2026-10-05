#!/usr/bin/env python3
"""Refuse a tailab full-prompt A/B log before its wall is read.

    tailab-valid.py <tailab log> <counter tag> <expected A count>

Every arm must have run its tail as the same batched, interleaved step, with
no token-major tail; the arm's change counter (the line "<tag> arm X: N ...")
must read the expected count in every A arm and 0 in every B arm; and every
arm must have the reference logits and state. Prints the arms and VALID, or
the first reason it is not, and exits 1 then.
"""
import re
import sys

log, tag, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
lines = open(log).read().splitlines()

arms = []          # (label, token-major tails, batch-step lines, interleaved lines, counter)
cur = {"tm": 0, "batch": 0, "il": 0, "count": None}
order = []
for ln in lines:
    if "token-major steps" in ln:
        cur["tm"] += 1
    if re.search(r"prefill tail at position \d+ ran \d+ rows as 1 batch steps", ln):
        cur["batch"] += 1
    if "interleaved layer by layer" in ln:
        cur["il"] += 1
    m = re.match(rf"{re.escape(tag)}\s+arm ([AB]): (\d+)", ln)
    if m:
        cur["count"] = (m.group(1), int(m.group(2)))
        arms.append(dict(cur))
        cur = {"tm": 0, "batch": 0, "il": 0, "count": None}
    m = re.match(r"(warm-up|round \d+ [AB])", ln)
    if m:
        order.append(ln)

def fail(why):
    print("INVALID:", why)
    sys.exit(1)

if not arms:
    fail(f"no '{tag} arm' lines")
for i, a in enumerate(arms):
    side, n = a["count"]
    print(f"arm {i} {side}: token-major {a['tm']}, batch steps {a['batch']}, "
          f"interleaved {a['il']}, {tag} {n}")
for i, a in enumerate(arms):
    side, n = a["count"]
    if a["tm"]:
        fail(f"arm {i} ({side}) ran {a['tm']} token-major tail(s)")
    if a["batch"] != arms[0]["batch"] or a["il"] != arms[0]["il"]:
        fail(f"arm {i} ({side}) ran {a['batch']} batch / {a['il']} interleaved, "
             f"arm 0 {arms[0]['batch']} / {arms[0]['il']}")
    if a["batch"] != 1 or a["il"] != 1:
        fail(f"arm {i} ({side}) is not one interleaved batch step")
    if side == "A" and n != want:
        fail(f"arm {i} A counted {n}, expected {want}")
    if side == "B" and n != 0:
        fail(f"arm {i} B counted {n}, expected 0")
rounds = [l for l in lines if re.match(r"round \d+ [AB]", l)]
if any(" same " not in l for l in rounds):
    fail("an arm differs from the reference")
tail = [l for l in lines if l.startswith("tail ")]
if not tail or "-> PASS" not in tail[-1]:
    fail("the reference check did not pass")
print("VALID")
