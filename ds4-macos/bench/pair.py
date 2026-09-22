"""The analysis, fixed before the runs are read.

Primary result   raw wall ms a token, steady region only (window start >= 449).
Unit of analysis the run. A run's 64-token windows are not independent samples
                 of anything - they are one generation on one machine state -
                 so a run collapses to one number, its median steady window.
Pairing          the campaign is five ABBA blocks of (on, off, off, on). A
                 block's difference is mean(on) - mean(off) within that block,
                 so a monotone drift in machine state cancels inside the block.
                 The five block differences are the sample.
Nothing dropped  every run that produced steady windows is used, including the
                 slow ones. Rule 8 says runs move by 29%; discarding the ones
                 that did is how a result gets manufactured.
Identical work   aborts, command buffers and dispatches-behind-an-abort are
                 asserted equal across arms window by window (rule 12). If they
                 are not, the arms are not doing the same work and the
                 comparison is void.
Components       encode and commit-to-done are printed to explain the result,
                 never to adjust it. Raw wall decides (rules 13 and 14).
"""
import re, sys, glob, statistics as st

W = re.compile(r"gate over tokens (\d+)-(\d+): ([\d.]+) command buffers, ([\d.]+) aborts"
               r".*?(\d+) the gate failed to switch off, (\d+) it could not gate\n"
               r".*?encode ([\d.]+) \+ commit-to-done ([\d.]+) .*?"
               r"= ([\d.]+) of a ([\d.]+) ms wall.*?\n.*?\n"
               r".*?([\d.]+) gated dispatches a token, ([\d.]+) of them behind an abort; "
               r"([\d.]+) sent plain", re.S)
STEADY = 449

def load(pat, arm):
    out = []
    for p in sorted(glob.glob(pat)):
        block = re.search(r"ab-(?:on|off)(\d+)-", p)
        w = {}
        for m in W.finditer(open(p, errors='replace').read()):
            w[int(m.group(1))] = dict(
                cbs=float(m.group(3)), aborts=float(m.group(4)), fail=int(m.group(5)),
                ungate=int(m.group(6)), encode=float(m.group(7)), c2d=float(m.group(8)),
                wall=float(m.group(10)), gated=float(m.group(11)),
                behind=float(m.group(12)), plain=float(m.group(13)))
        steady = {k: v for k, v in w.items() if k >= STEADY}
        if steady:
            out.append(dict(path=p, arm=arm, block=int(block.group(1)) if block else 0,
                            w=w, steady=steady))
    return out

def ci(xs):
    """Student t, 95%, small sample - the five block differences."""
    T = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
         7: 2.365, 8: 2.306, 9: 2.262}
    n = len(xs)
    if n < 2: return None
    m, sd = st.mean(xs), st.stdev(xs)
    h = T.get(n - 1, 1.96) * sd / (n ** 0.5)
    return m - h, m + h

A = load(sys.argv[1], 'on')
B = load(sys.argv[2], 'off')
print(f"runs with steady windows: {len(A)} on, {len(B)} off "
      f"(every run kept, none discarded)")
if not A or not B: sys.exit(1)

fails = sum(v['fail'] + v['ungate'] for r in A + B for v in r['w'].values())
print(f"gate failures + ungatable dispatches, every window of every run: {fails}")

common = sorted(set.intersection(*[set(r['w']) for r in A + B]))
# Command buffers and aborts must match exactly: they are counts, and a
# difference in them is a difference in what the arms did. Dispatches behind
# an abort is an average printed to one decimal, so two runs doing identical
# work can print 200.6 and 200.7; the tolerance is that last digit and no
# more, and the spread is printed so it cannot hide anything larger.
bad, behind_spread = [], 0.0
for k in common:
    if len({(round(r['w'][k]['aborts'], 2), round(r['w'][k]['cbs'], 2))
            for r in A + B}) != 1:
        bad.append(k)
        continue
    bs = [r['w'][k]['behind'] for r in A + B]
    behind_spread = max(behind_spread, max(bs) - min(bs))
    if max(bs) - min(bs) > 0.1:
        bad.append(k)
print(f"{len(common)} windows shared by every run; windows where the arms did not do "
      f"identical work: {len(bad)}" + ("" if bad else "  - the comparison is paired")
      + f"; largest spread in dispatches behind an abort: {behind_spread:.1f}")
if bad:
    print("\nREFUSING to print a wall comparison. The arms are not doing the same work,\n"
          "so a difference between them is not the change - it is the change plus\n"
          "whatever moved the dispatch or abort counts. Find that first.")
    sys.exit(2)
csteady = [k for k in common if k >= STEADY]
print(f"steady windows a run (start >= {STEADY}): {len(csteady)}\n")

def per_run(rs, f): return [st.median(v[f] for v in r['steady'].values()) for r in rs]

pa, pb = per_run(A, 'plain'), per_run(B, 'plain')
ga, gb = per_run(A, 'gated'), per_run(B, 'gated')
print("dispatches a token, steady, of the population the gate would send indirect:")
print(f"  off  eligible {st.mean(gb)+st.mean(pb):7.1f} = indirect {st.mean(gb):7.1f}"
      f" + plain {st.mean(pb):6.1f}")
print(f"  on   eligible {st.mean(ga)+st.mean(pa):7.1f} = indirect {st.mean(ga):7.1f}"
      f" + plain {st.mean(pa):6.1f}")
print(f"  converted to plain {st.mean(pa)-st.mean(pb):.1f}"
      f"  ->  upper bound {(st.mean(pa)-st.mean(pb))*1.55/1000:.2f} ms a token")

for f, label, primary in (('wall', 'raw wall', True),
                          ('c2d', 'commit-to-done', False),
                          ('encode', 'host encode', False)):
    ra, rb = per_run(A, f), per_run(B, f)
    print(f"\n{'=== ' if primary else '--- '}{label}"
          f"{' (PRIMARY)' if primary else ' (explanatory only)'}, ms a token")
    print(f"  on  {' '.join(f'{x:.2f}' for x in ra)}")
    print(f"  off {' '.join(f'{x:.2f}' for x in rb)}")
    print(f"  mean   {st.mean(ra):7.2f} vs {st.mean(rb):7.2f}   diff {st.mean(ra)-st.mean(rb):+.2f}")
    print(f"  median {st.median(ra):7.2f} vs {st.median(rb):7.2f}   diff {st.median(ra)-st.median(rb):+.2f}")
    blocks = sorted({r['block'] for r in A + B})
    diffs = []
    for bl in blocks:
        xa = [st.median(v[f] for v in r['steady'].values()) for r in A if r['block'] == bl]
        xb = [st.median(v[f] for v in r['steady'].values()) for r in B if r['block'] == bl]
        if not xa or not xb: continue
        d = st.mean(xa) - st.mean(xb)
        diffs.append(d)
        print(f"  ABBA block {bl}: on {st.mean(xa):6.2f}  off {st.mean(xb):6.2f}   {d:+.2f}")
    if diffs:
        iv = ci(diffs)
        print(f"  block differences: mean {st.mean(diffs):+.2f}, median {st.median(diffs):+.2f}"
              + (f", 95% CI [{iv[0]:+.2f}, {iv[1]:+.2f}]" if iv else "")
              + f", {sum(d < 0 for d in diffs)}/{len(diffs)} blocks favour the arm under test")
