"""Fire every refusal in pair.py against synthetic logs.

An analyser whose refusals have never fired is not evidence that the arms did
the same work - it is only evidence that nothing checked. This builds logs in
the exact shape the server prints, breaks one thing at a time, and asserts the
comparison is refused. Run it in a scratch directory beside a copy of pair.py:

    mkdir -p /tmp/paircheck && cp pair.py pair_selftest.py /tmp/paircheck
    cd /tmp/paircheck && python3 pair_selftest.py
"""
import os, subprocess, sys

W = """ds4: gate over tokens {s}-{e}: {cbs:.2f} command buffers, {ab:.2f} aborts, 240.0 expert ids accounted, {mib:.2f} MiB loaded a token; 0 the gate failed to switch off, 0 it could not gate
ds4:   one token, exclusive, same window: entry 0.00 + encode 2.50 + commit-to-done 38.00 + repair-load 8.00 + accounting 0.28 + tail 1.48 = 50.26 of a {wall:.2f} ms wall, residual 0.04
ds4:   of the commit-to-done: GPU running 35.00 ms, GPU not running 3.00 ms
ds4:   {gated:.1f} gated dispatches a token, {behind:.1f} of them behind an abort; 750.0 sent plain ahead of a buffer's first validate
ds4:   encode-ahead: 0.00 segments used, 0.00 dropped, 0.00 ms a token spent encoding under the GPU
ds4:   concurrent sections: {att:.2f} attempted, {op:.2f} opened a token
ds4:   expert cache over the last 64 tokens: 240.00 hits, 4.77 misses, 4.77 evictions a token; 7930 of 7930 entries live (100.0%)
ds4:   of the address-table holes repaired a token: 0.00 already resident, 4.77 genuinely absent
"""

def run(name, arm, block, wall, *, nwin=20, cbs=17.0, att=None, op=None,
        behind=195.0, sha="abc", gated=1500.0, mib=45.0):
    if att is None: att = 80.0 if arm == "on" else 0.0
    if op is None: op = att
    p = f"ab-{arm}{block}-{name}.log"
    with open(p, "w") as f:
        for i in range(nwin):
            f.write(W.format(s=1 + 64 * i, e=64 + 64 * i, cbs=cbs, ab=5.0, mib=mib,
                             wall=wall, gated=gated, behind=behind, att=att, op=op))
    open(p.replace('.log', '.sha'), 'w').write(f"{sha} 1400\n")
    open(p.replace('.log', '.gap'), 'w').write("60\n")

def check(label, expect_refuse, setup, extra=()):
    for f in os.listdir('.'):
        if f.startswith('ab-'): os.remove(f)
    setup()
    r = subprocess.run(['python3', 'pair.py', 'ab-on*.log', 'ab-off*.log', *extra],
                       capture_output=True, text=True)
    refused = 'REFUSING' in (r.stdout + r.stderr)
    ok = refused == expect_refuse
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")
    if not ok:
        print('        ' + (r.stdout + r.stderr).strip()[-300:])
    return ok

def good():
    for b in (1, 2):
        run(f"a{b}", "on", b, 50.0); run(f"b{b}", "on", b, 50.2)
        run(f"c{b}", "off", b, 51.0); run(f"d{b}", "off", b, 51.2)

def fell_back():
    good()
    for b in (1, 2): run(f"a{b}", "on", b, 50.0, att=80.0, op=0.0)

def off_sections():
    good()
    for b in (1, 2): run(f"c{b}", "off", b, 51.0, att=80.0, op=80.0)

def behind_differs():
    good()
    for b in (1, 2):
        run(f"c{b}", "off", b, 51.0, behind=150.0)
        run(f"d{b}", "off", b, 51.2, behind=150.0)

res = [
    check("a clean pair is compared", False, good),
    check("a different command-buffer count is refused", True,
          lambda: (good(), run("x", "off", 1, 51.0, cbs=18.0))),
    check("a different window set is refused", True,
          lambda: (good(), run("x", "off", 1, 51.0, nwin=18))),
    check("different generated text is refused", True,
          lambda: (good(), run("x", "off", 1, 51.0, sha="def"))),
    check("more bytes loaded in one arm is refused", True,
          lambda: (good(), run("x", "off", 1, 51.0, mib=46.0))),
    check("an on arm that fell back to serial is refused", True, fell_back),
    check("an off arm that opened sections is refused", True, off_sections),
    check("an undeclared behind-abort difference is refused", True, behind_differs),
    check("the same difference, declared, is compared", False, behind_differs,
          extra=('--declare=the shared expert moved behind the validate',)),
]
print(f"\n{sum(res)}/{len(res)} checks of the analyser passed")
sys.exit(0 if all(res) else 1)
