"""The analysis, fixed before the runs are read.

Primary result   raw wall ms a token, steady region only (window start >= 449).
Unit of analysis the run. A run's 64-token windows are not independent samples
                 of anything - they are one generation on one machine state -
                 so a run collapses to one number, its median steady window.
Pairing          the campaign is ABBA blocks, alternating orientation. A
                 block's difference is mean(on) - mean(off) within that block,
                 so drift inside a block cancels. The block differences are the
                 sample.
Nothing dropped  every run that produced steady windows is used, including the
                 slow ones. Rule 8 says runs move by 29%; discarding the ones
                 that did is how a result gets manufactured.
Same windows     every run must report the same window set, and the statistic
                 is computed on exactly the windows the identical-work check
                 covered. Taking a run's own steady set instead lets a longer
                 run contribute windows nothing checked.
Identical work   command buffers, aborts, dispatches (gated, plain, behind an
                 abort), misses, evictions and bytes loaded are asserted equal
                 window by window, and the two arms' generated text must hash
                 the same. If any of that differs the arms are not doing the
                 same work and the comparison is void - unless the difference
                 is declared on the command line, which prints it.
Sections opened  asking for a concurrent section and getting one are different
                 things: the arm that is supposed to overlap must show
                 opened == attempted > 0 a token, and the arm that is not must
                 show none. Without this a fallback to serial reads as "the
                 overlap did nothing".
Components       encode, commit-to-done and GPU-running are printed to explain
                 the result, never to adjust it. Raw wall decides.

  pair.py '<on glob>' '<off glob>' [--expect-sections=on|both|none]
                                   [--declare="why a counter differs"]
"""
import re, sys, glob, statistics as st

STEADY = 449
HEAD = re.compile(r"gate over tokens (\d+)-(\d+): ([\d.]+) command buffers, "
                  r"([\d.]+) aborts, ([\d.]+) expert ids accounted, "
                  r"([\d.]+) MiB loaded a token; (\d+) the gate failed to switch off, "
                  r"(\d+) it could not gate")
WALL = re.compile(r"encode ([\d.]+) \+ commit-to-done ([\d.]+) \+ repair-load ([\d.]+) "
                  r"\+ accounting ([\d.]+) \+ tail ([\d.]+) = [\d.]+ of a ([\d.]+) ms wall")
GPU  = re.compile(r"GPU running ([\d.]+) ms, GPU not running ([\d.]+) ms")
DISP = re.compile(r"([\d.]+) gated dispatches a token, ([\d.]+) of them behind an abort; "
                  r"([\d.]+) sent plain")
CACHE= re.compile(r"([\d.]+) hits, ([\d.]+) misses, ([\d.]+) evictions a token")
SECT = re.compile(r"concurrent sections: ([\d.]+) attempted, ([\d.]+) opened a token")

def load(pat, arm):
    out = []
    for p in sorted(glob.glob(pat)):
        lines = open(p, errors='replace').read().split('\n')
        w = {}
        for i, line in enumerate(lines):
            m = HEAD.search(line)
            if not m:
                continue
            tail = '\n'.join(lines[i + 1:i + 8])
            mw, mg, md = WALL.search(tail), GPU.search(tail), DISP.search(tail)
            mc, ms = CACHE.search(tail), SECT.search(tail)
            if not (mw and mg and md and mc):
                continue
            w[int(m.group(1))] = dict(
                cbs=float(m.group(3)), aborts=float(m.group(4)),
                ids=float(m.group(5)), mib=float(m.group(6)),
                fail=int(m.group(7)), ungate=int(m.group(8)),
                encode=float(mw.group(1)), c2d=float(mw.group(2)),
                repair=float(mw.group(3)), wall=float(mw.group(6)),
                gpu=float(mg.group(1)),
                gated=float(md.group(1)), behind=float(md.group(2)),
                plain=float(md.group(3)),
                misses=float(mc.group(2)), evict=float(mc.group(3)),
                sec_att=float(ms.group(1)) if ms else None,
                sec_open=float(ms.group(2)) if ms else None)
        if not w:
            continue
        block = re.search(r"ab-(?:on|off)(\d+)-", p)
        sha = None
        try:
            sha = open(p.replace('.log', '.sha')).read().split()[0]
        except Exception:
            pass
        gap = None
        try:
            gap = int(open(p.replace('.log', '.gap')).read().strip())
        except Exception:
            pass
        out.append(dict(path=p, arm=arm, block=int(block.group(1)) if block else 0,
                        w=w, sha=sha, gap=gap))
    return out

def ci(xs):
    """Student t, 95%, small sample - the block differences."""
    T = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
         7: 2.365, 8: 2.306, 9: 2.262}
    n = len(xs)
    if n < 2:
        return None
    m, sd = st.mean(xs), st.stdev(xs)
    h = T.get(n - 1, 1.96) * sd / (n ** 0.5)
    return m - h, m + h

args = [a for a in sys.argv[1:] if not a.startswith('--')]
opts = {a.split('=', 1)[0]: a.split('=', 1)[1] if '=' in a else ''
        for a in sys.argv[1:] if a.startswith('--')}
expect = opts.get('--expect-sections', 'on')
declared = opts.get('--declare')

A, B = load(args[0], 'on'), load(args[1], 'off')
print(f"runs with windows: {len(A)} on, {len(B)} off (every run kept, none discarded)")
if not A or not B:
    sys.exit(1)
gaps = [r['gap'] for r in A + B if r['gap'] is not None and r['gap'] >= 0]
if gaps:
    print(f"idle before an arm: {min(gaps)}-{max(gaps)} s (median {st.median(gaps):.0f})")

fails = sum(v['fail'] + v['ungate'] for r in A + B for v in r['w'].values())
print(f"gate failures + ungatable dispatches, every window of every run: {fails}")
if fails:
    sys.exit("REFUSING: the gate did not switch off everything it was asked to.")

shas = {r['sha'] for r in A + B}
missing = sum(1 for r in A + B if r['sha'] is None)
one = next(iter(shas - {None}), None)
print(f"hashes of the generated text: {len(shas - {None})} distinct"
      + (f" ({one[:16]})" if one and len(shas - {None}) == 1 else "")
      + (f", {missing} run(s) recorded none" if missing else ""))
if missing or len(shas) > 1:
    sys.exit("REFUSING: the arms did not generate the same text, or a run did not "
             "record its hash. A paired comparison needs both arms to have done "
             "the same generation - these logs predate that being recorded.")

# Same windows everywhere, or the statistic covers what the check did not.
sets = {frozenset(r['w']) for r in A + B}
if len(sets) != 1:
    sizes = sorted({len(s) for s in sets})
    sys.exit(f"REFUSING: the runs do not report the same windows ({sizes} of them). "
             f"A run that generated a different number of tokens cannot be paired "
             f"window by window.")
common = sorted(next(iter(sets)))

# Counts that reproduce exactly run to run, and must: a difference in any of
# them is a difference in the work.
EXACT = ('cbs', 'aborts', 'ids', 'misses', 'evict', 'mib')
# Per-token averages printed to one decimal. Two runs of the SAME arm differ by
# one unit in the last digit here - measured, not assumed: over seven runs the
# within-arm spread reaches 0.100 while the arm means agree to 0.002. So the
# per-window tolerance is that digit, and a systematic shift is caught by the
# arm means instead, at a bound twenty times tighter than any real change has
# ever been (the lane pair moved this by 45 a token).
NEAR = ('gated', 'plain', 'behind')
# The epsilon is not slack: 1559.2 - 1559.1 is 0.10000000000002 in binary, and
# a bare > comparison rejects exactly the one-digit jitter the tolerance exists
# to allow.
WINDOW_TOL, MEAN_TOL, EPS = 0.1, 0.05, 1e-6
bad, spread = [], {f: 0.0 for f in NEAR}
for k in common:
    if any(len({round(r['w'][k][f], 3) for r in A + B}) != 1 for f in EXACT):
        bad.append(k)
        continue
    for f in NEAR:
        xs = [r['w'][k][f] for r in A + B]
        spread[f] = max(spread[f], max(xs) - min(xs))
        if max(xs) - min(xs) > WINDOW_TOL + EPS and not declared:
            bad.append(k)
            break
for f in NEAR:
    ma = st.mean(st.mean(r['w'][k][f] for k in common) for r in A)
    mb = st.mean(st.mean(r['w'][k][f] for k in common) for r in B)
    if abs(ma - mb) > MEAN_TOL + EPS and not declared:
        sys.exit(f"REFUSING: {f} differs systematically between the arms - "
                 f"on {ma:.3f}, off {mb:.3f}, {ma-mb:+.3f} a token. Within-run "
                 f"jitter is one unit in the last printed digit; this is not that.")
print(f"{len(common)} windows in every run; windows where the arms did not do "
      f"identical work: {len(bad)}" + ("" if bad else "  - the comparison is paired")
      + "; largest within-window spread " + ", ".join(f"{f} {spread[f]:.2f}" for f in NEAR))
if bad and not declared:
    sys.exit("\nREFUSING to print a wall comparison. The arms are not doing the same "
             "work, so a difference between them is not the change - it is the change "
             "plus whatever moved those counts. Find that first, or declare it.")
if declared:
    for f in NEAR:
        a = st.mean(st.mean(r['w'][k][f] for k in common) for r in A)
        b = st.mean(st.mean(r['w'][k][f] for k in common) for r in B)
        if abs(a - b) > 0.1:
            print(f"declared: {declared}\n  {f}: on {a:.2f}, off {b:.2f}, {a-b:+.2f}")

sa = [r['w'][k]['sec_att'] for r in A for k in common]
oa = [r['w'][k]['sec_open'] for r in A for k in common]
sb = [r['w'][k]['sec_att'] for r in B for k in common]
ob = [r['w'][k]['sec_open'] for r in B for k in common]
if None in sa + sb:
    sys.exit("REFUSING: the runs do not report concurrent-section counts, so there "
             "is no evidence the arm that is meant to overlap actually did.")
print(f"concurrent sections a token: on {st.mean(sa):.2f} attempted / "
      f"{st.mean(oa):.2f} opened, off {st.mean(sb):.2f} / {st.mean(ob):.2f}")
want = {'on': (True, False), 'both': (True, True), 'none': (False, False)}[expect]
for arm, att, op, w in (('on', sa, oa, want[0]), ('off', sb, ob, want[1])):
    if w and not (min(att) > 0 and att == op):
        sys.exit(f"REFUSING: the {arm} arm was supposed to open a section every time "
                 f"and did not ({st.mean(op):.2f} opened of {st.mean(att):.2f} "
                 f"attempted). It fell back to serial, so this is not a test of the "
                 f"overlap.")
    if not w and max(att) > 0:
        sys.exit(f"REFUSING: the {arm} arm opened sections it was not supposed to.")

csteady = [k for k in common if k >= STEADY]
print(f"steady windows a run (start >= {STEADY}): {len(csteady)}\n")

def per_run(rs, f):
    return [st.median(r['w'][k][f] for k in csteady) for r in rs]

for f, label, primary in (('wall', 'raw wall', True),
                          ('c2d', 'commit-to-done', False),
                          # ds4_gpu_take_span_ms is the command buffer's
                          # GPUStartTime to GPUEndTime, which contains the gaps
                          # between its encoders. It is not time the GPU spent
                          # running, and calling it that invites reading a
                          # shorter envelope as more work done.
                          ('gpu', 'GPU command-buffer envelope', False),
                          ('encode', 'host encode', False),
                          ('repair', 'repair-load', False)):
    ra, rb = per_run(A, f), per_run(B, f)
    print(f"{'=== ' if primary else '--- '}{label}"
          f"{' (PRIMARY)' if primary else ' (explanatory only)'}, ms a token")
    print(f"  on  {' '.join(f'{x:.2f}' for x in ra)}")
    print(f"  off {' '.join(f'{x:.2f}' for x in rb)}")
    print(f"  mean   {st.mean(ra):7.2f} vs {st.mean(rb):7.2f}   diff {st.mean(ra)-st.mean(rb):+.2f}")
    print(f"  median {st.median(ra):7.2f} vs {st.median(rb):7.2f}   diff {st.median(ra)-st.median(rb):+.2f}")
    diffs = []
    for bl in sorted({r['block'] for r in A + B}):
        xa = [st.median(r['w'][k][f] for k in csteady) for r in A if r['block'] == bl]
        xb = [st.median(r['w'][k][f] for k in csteady) for r in B if r['block'] == bl]
        # A block is two of each arm. One of either side is not a block - its
        # difference carries whatever position that single run happened to sit
        # in, which is exactly what the alternation is there to cancel.
        if len(xa) != 2 or len(xb) != 2:
            print(f"  block {bl}: {len(xa)} on and {len(xb)} off - not a block, skipped")
            continue
        d = st.mean(xa) - st.mean(xb)
        diffs.append(d)
        print(f"  block {bl}: on {st.mean(xa):6.2f}  off {st.mean(xb):6.2f}   {d:+.2f}")
    if diffs:
        iv = ci(diffs)
        print(f"  block differences: mean {st.mean(diffs):+.2f}, median {st.median(diffs):+.2f}"
              + (f", 95% CI [{iv[0]:+.2f}, {iv[1]:+.2f}]" if iv else "")
              + f", {sum(d < 0 for d in diffs)}/{len(diffs)} favour the on arm")
    print()
