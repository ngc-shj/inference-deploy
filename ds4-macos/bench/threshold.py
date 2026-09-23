"""Fix the campaign's start condition from the load log, and from nothing else.

Read before the campaign is run, never after a result is in hand. The start
condition is a preflight against wasting forty minutes; it is not what makes a
comparison valid. That is pair.py's spread check, which is applied to the runs
that actually happened and refuses the campaign entire.

So the question here is not "is the machine idle" - a steady 0.8 cores of
background does not break a paired comparison - but "is the background steady
enough right now that a campaign started now is likely to survive that check".

    threshold.py load.log            # the distribution, and the condition

floor    the 25th percentile of the windows, not the minimum: a point minimum
         is an outlier, and the quantity that matters is a sustained level.
swing    the median absolute change between consecutive windows, which is the
         scale of the movement a block would have to absorb.
start    every one of the last N windows within floor + 3 x swing, and their
         own range under 2 x swing.
"""
import sys, statistics as st

rows = []
for line in open(sys.argv[1] if len(sys.argv) > 1 else 'load.log'):
    parts = line.split()
    if len(parts) >= 3:
        try: rows.append((parts[0] + ' ' + parts[1], float(parts[2])))
        except ValueError: pass
if len(rows) < 8:
    sys.exit(f"only {len(rows)} windows; let the log fill before fixing anything")

v = sorted(x for _, x in rows)
def q(p): return v[min(len(v) - 1, int(p * len(v)))]
floor = q(0.25)
steps = [abs(rows[i][1] - rows[i - 1][1]) for i in range(1, len(rows))]
swing = st.median(steps)

print(f"windows {len(rows)}, {rows[0][0]} to {rows[-1][0]}")
print(f"  cores of background work: min {v[0]:.2f}  p25 {floor:.2f}  "
      f"median {q(0.5):.2f}  p75 {q(0.75):.2f}  max {v[-1]:.2f}")
print(f"  change between consecutive windows: median {swing:.2f}, "
      f"max {max(steps):.2f}")
print()
print(f"floor  = {floor:.2f} cores (p25)")
print(f"swing  = {swing:.2f} cores (median step)")
print(f"start when the last 4 windows are all <= {floor + 3 * swing:.2f} "
      f"and their range is <= {2 * swing:.2f}")
share = sum(1 for i in range(3, len(rows))
            if max(x for _, x in rows[i-3:i+1]) <= floor + 3 * swing
            and max(x for _, x in rows[i-3:i+1]) - min(x for _, x in rows[i-3:i+1])
                <= 2 * swing) / max(1, len(rows) - 3)
print(f"that condition held in {share*100:.0f}% of this log's windows")
