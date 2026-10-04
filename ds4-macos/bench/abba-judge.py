#!/usr/bin/env python3
"""Judge an m4abba.sh a-b-b-a run by the rules in abba-plan-final.md.

    abba-judge.py <m4ab-dir> <gpurun-samples> [want_n_b]

Per arm: wall ms a token ("per token: X ms wall"), generated tokens, whether
its text and its token ids (the server's "token ids: N, hash H") equal the
first a arm's, how many prefill-tail steps ran token-major, other processes' CPU ticks, the worst
pressure level and swap growth gpurun sampled while it ran, and b's last
"entries live" N. Then d, d1, d2, s and the decision.
"""
import datetime, glob, json, os, re, statistics, sys

d, samples = sys.argv[1], sys.argv[2]
want_n = int(sys.argv[3]) if len(sys.argv) > 3 else None

def sample_rows():
    rows = []
    for line in open(samples):
        m = re.match(r'(\d\d:\d\d:\d\d) wired [\d.]+ pressure (\d) swap\+ (-?[\d.]+)', line)
        if m:
            rows.append((m.group(1), int(m.group(2)), float(m.group(3))))
    return rows

rows = sample_rows()
arms, ref_text, ref_ids = [], None, None
for out in sorted(glob.glob(os.path.join(d, '[0-9][0-9]-m?.out'))):
    arm = os.path.basename(out)[:-4]
    kind = arm[-1]
    txt = open(out).read()
    m = re.search(r'per token: ([\d.]+) ms wall', txt)
    ms = float(m.group(1)) if m else None
    tokens, text = None, None
    try:
        j = json.load(open(os.path.join(d, arm + '.json')))
        tokens = j['usage']['completion_tokens']
        text = j['choices'][0]['message'].get('content', '') + '\x00' + \
               (j['choices'][0]['message'].get('reasoning_content') or '')
    except Exception:
        pass
    # cputicks: five counters (the first is other processes' user ticks),
    # then the epoch second, at the start and again at the end.
    f = list(map(int, open(os.path.join(d, arm + '.ticks')).read().split()))
    t0, s0, t1, s1 = f[0], f[5], f[6], f[11]
    lo = datetime.datetime.fromtimestamp(s0).strftime('%H:%M:%S')
    hi = datetime.datetime.fromtimestamp(s1).strftime('%H:%M:%S')
    inside = [r for r in rows if lo <= r[0] <= hi]
    pressure = max((r[1] for r in inside), default=None)
    swap = max((r[2] for r in inside), default=0.0) - min((r[2] for r in inside), default=0.0)
    n_live, ids, tails = None, None, 0
    for line in open(os.path.join(d, arm + '.log'), errors='replace'):
        m2 = re.search(r'(\d+) of (\d+) entries live', line)
        if m2:
            n_live = int(m2.group(1))
        m3 = re.search(r'token ids: (\d+), hash ([0-9a-f]+)', line)
        if m3:
            ids = m3.group(1) + ':' + m3.group(2)
        m4 = re.search(r'prefill tail of \d+ rows at position \d+ ran (\d+) token-major steps', line)
        if m4:
            tails += int(m4.group(1))
    if kind == 'a' and ref_text is None:
        ref_text, ref_ids = text, ids
    arms.append(dict(arm=arm, kind=kind, ms=ms, tokens=tokens, text=text, ids=ids, tails=tails,
                     ticks=t1 - t0, pressure=pressure, swap=swap, n=n_live))

med = statistics.median(a['ticks'] for a in arms)
for a in arms:
    why = []
    if a['ms'] is None: why.append('no wall')
    if a['tokens'] != 2048: why.append('tokens %s' % a['tokens'])
    if a['text'] != ref_text: why.append('TEXT DIFFERS from the first a arm')
    if a['ids'] is None or a['ids'] != ref_ids: why.append('TOKEN IDS %s differ from %s' % (a['ids'], ref_ids))
    if a['ticks'] > 1.5 * med: why.append('ticks %d > 1.5 x median %d' % (a['ticks'], med))
    if a['pressure'] is None or a['pressure'] > 1: why.append('pressure %s' % a['pressure'])
    if a['swap'] > 0.5: why.append('swap +%.2f GiB' % a['swap'])
    if a['kind'] == 'b' and want_n is not None and a['n'] != want_n: why.append('N %s' % a['n'])
    a['valid'] = not why
    print('%s %s %6s ms  tokens %s  ids %s  tail steps %d  ticks %d  pressure %s  swap +%.2f  N %s  %s' % (
        a['arm'], a['kind'], a['ms'], a['tokens'], a['ids'], a['tails'], a['ticks'], a['pressure'],
        a['swap'], a['n'], 'valid' if a['valid'] else 'INVALID: ' + '; '.join(why)))

valid = [a for a in arms if a['valid']]
if len(valid) != len(arms):
    print('not every arm valid: the plan reruns the affected block before a decision')
A = [a['ms'] for a in valid if a['kind'] == 'a']
B = [a['ms'] for a in valid if a['kind'] == 'b']
if len(A) < 2 or len(B) < 2:
    sys.exit('too few valid arms to decide')
dd = statistics.mean(B) - statistics.mean(A)
s = max(statistics.stdev(A), statistics.stdev(B))
blocks = []
for k in range(0, len(arms), 4):
    blk = arms[k:k + 4]
    if len(blk) == 4 and all(a['valid'] for a in blk):
        blocks.append(statistics.mean(a['ms'] for a in blk if a['kind'] == 'b') -
                      statistics.mean(a['ms'] for a in blk if a['kind'] == 'a'))
th = max(0.3, 2 * s)
print('a mean %.3f sd %.3f | b mean %.3f sd %.3f' % (
    statistics.mean(A), statistics.stdev(A), statistics.mean(B), statistics.stdev(B)))
print('token-major prefill tail steps in b arms: %d (0: the arithmetic 13c14ca changed is not on this path)' %
      sum(a['tails'] for a in arms if a['kind'] == 'b'))
print('d %.3f ms a token; blocks %s; threshold %.3f' % (dd, ['%.3f' % x for x in blocks], th))
if dd > th:
    print('decision: REGRESSION')
elif dd < -th and len(blocks) == 2 and all(x < 0 for x in blocks):
    print('decision: improvement of %.3f ms a token, same sign in both blocks' % -dd)
else:
    print('decision: no regression')
