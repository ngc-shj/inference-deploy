#!/usr/bin/env python3
"""Replay each abort of a gated decode under an expert-ready scheduler.

    abort-replay.py TRACE --tokens N [--gu MS] [--dn MS] [--sh MS] [--eps MS] [--calibrate]
    abort-replay.py --selftest

TRACE is the host-event file written with DS4_METAL_V41_GATE_TRACE=t:<path>
(schema v1, "# ds4 host trace v1" on its first line, then "# env" lines and a
"V <revision>" event): "H <ns> <kind> ..." lines on the clock of the command
buffers' GPU times. It must come from the current scheduler, which repairs
before it commits the continuation; the expert-ready one reorders R and S.

  S tok start end resume   a segment committed
  C gpu_start gpu_end      a waited command buffer's GPU span
  A tok layer mask n ids.. the validator reported misses (mask = missing slots)
  P layer n t_ra t_rd0 t_rd1   the repair's phases
  X layer expert slot t0 t1    one expert's reads, first byte to last
  R tok layer              the repair returned

For every abort the measured completion of the aborted layer's MoE is

    T_cur = GPU start of the continuation + gate/up + down + shared

and the replayed one lets the GPU run what does not wait on a read the moment
the aborting buffer ends - the shared expert, gate/up of every resident slot,
and the ordered down up to the first missing slot - then takes the remaining
slots in slot order, each no earlier than its read completed (+eps), which is
the only order the per-lane accumulation of the current down kernel allows.

Two schedules are replayed on the same trace:
  overlap:  the reads keep their measured times
  +early:   the reads also start when the aborting buffer ends, not when the
            host got round to them (shifted by the measured delay)
The difference T_cur - T_new is the layer finishing earlier; nothing after it
changes, so the sum over aborts divided by tokens is the per-token gain.
"""
import argparse
import collections
import statistics
import sys


def parse(path):
    ev = []
    lines = open(path)
    first = next(lines, "")
    if not first.startswith("# ds4 host trace v1"):
        raise SystemExit(f"{path}: not a v1 host trace")
    for line in lines:
        f = line.split()
        if len(f) < 3 or f[0] != "H":
            continue
        ev.append((int(f[1]), f[2], f[3:]))
    return ev


def analyze(ev, tokens, gu=0.214, dn=0.142, sh=0.222, eps=0.03, calibrate=False):
    """Replay a parsed trace; returns the closure and the gains per token."""
    out = {"lines": []}
    say = out["lines"].append
    gu_s, dn_s = gu / 6.0, dn / 6.0
    moe_full = gu + dn + sh

    aborts = []
    last_c = None
    i = 0
    while i < len(ev):
        t, k, f = ev[i]
        if k == "C":
            last_c = (float(f[0]) / 1e6, float(f[1]) / 1e6)
        elif k == "A" and last_c:
            ab = {"t_a": t / 1e6, "layer": int(f[1]), "mask": int(f[2]),
                  "gpu_end": last_c[1], "reads": {}, "tok": int(f[0])}
            j = i + 1
            while j < len(ev) and ev[j][1] != "R":
                tj, kj, fj = ev[j]
                if kj == "X" and int(fj[0]) == ab["layer"]:
                    ab["reads"][int(fj[2])] = (int(fj[3]) / 1e6, int(fj[4]) / 1e6)
                if kj == "C":
                    last_c = (float(fj[0]) / 1e6, float(fj[1]) / 1e6)
                j += 1
            if j >= len(ev):
                break
            ab["t_r"] = ev[j][0] / 1e6
            # the continuation: first S after R, then the first C after that
            s = j + 1
            while s < len(ev) and ev[s][1] != "S":
                s += 1
            c = s + 1
            while c < len(ev) and ev[c][1] != "C":
                c += 1
            if c >= len(ev):
                break
            ab["cont_start"] = float(ev[c][2][0]) / 1e6
            aborts.append(ab)
            i = j
        i += 1

    # Closure: the current scheduler, from the same trace. A segment is the
    # first C after its S; one that did not abort (no A before the next S)
    # ran all its layers. Whole segments give the cost of a layer; a
    # continuation (resume=1) starts at the MoE of its first layer, so its span
    # less the whole layers after it is what the MoE of the aborted layer and
    # the rest of that layer actually took - the thing the cost model stands in
    # for.
    seg_full, seg_cont = [], []
    for idx, (t, k, f) in enumerate(ev):
        if k != "S":
            continue
        start, end, resume = int(f[1]), int(f[2]), int(f[3])
        c = idx + 1
        while c < len(ev) and ev[c][1] not in ("C", "S"):
            c += 1
        if c >= len(ev) or ev[c][1] != "C":
            continue
        span = (float(ev[c][2][1]) - float(ev[c][2][0])) / 1e6
        n = c + 1
        while n < len(ev) and ev[n][1] not in ("S", "A"):
            n += 1
        aborted = n < len(ev) and ev[n][1] == "A"
        if aborted or end <= start:
            continue
        (seg_cont if resume else seg_full).append((end - start, span))
    per_layer = statistics.mean(sp / nl for nl, sp in seg_full)
    tail = [sp - (nl - 1) * per_layer for nl, sp in seg_cont]
    # Held out: fit the layer cost and the tail on even-numbered segments and
    # predict the spans of the odd ones. The current scheduler's model is
    # "a continuation is the tail plus whole layers"; if that does not predict
    # buffers it was not fitted on, its gains are not worth reading.
    if len(seg_full) >= 4 and len(seg_cont) >= 4:
        fit_pl = statistics.median(sp / nl for nl, sp in seg_full[0::2])
        fit_tail = statistics.median(sp - (nl - 1) * fit_pl for nl, sp in seg_cont[0::2])
        err_full = [sp - nl * fit_pl for nl, sp in seg_full[1::2]]
        err_cont = [sp - (fit_tail + (nl - 1) * fit_pl) for nl, sp in seg_cont[1::2]]
        rel = lambda errs, segs: statistics.median(abs(e) / sp for e, (_, sp) in zip(errs, segs))
        held = seg_full[1::2] + seg_cont[1::2]
        pred_sum = (sum(nl * fit_pl for nl, _ in seg_full[1::2]) +
                    sum(fit_tail + (nl - 1) * fit_pl for nl, _ in seg_cont[1::2]))
        meas_sum = sum(sp for _, sp in held)
        out.update(heldout_sum_rel=(pred_sum - meas_sum) / meas_sum, fit_tail=fit_tail)
        out.update(heldout_full_bias=statistics.median(err_full),
                   heldout_cont_bias=statistics.median(err_cont),
                   heldout_full_rel=rel(err_full, seg_full[1::2]),
                   heldout_cont_rel=rel(err_cont, seg_cont[1::2]))
        say(f"held out: whole segments predicted with median error "
            f"{statistics.median(err_full):+.3f} ms ({100 * out['heldout_full_rel']:.1f}% abs), "
            f"continuations {statistics.median(err_cont):+.3f} ms "
            f"({100 * out['heldout_cont_rel']:.1f}% abs); summed over all of them "
            f"predicted {pred_sum:.0f} ms against {meas_sum:.0f} measured "
            f"({100 * out['heldout_sum_rel']:+.2f}%)")
    out.update(per_layer=per_layer, tail_mean=statistics.mean(tail),
               tail_median=statistics.median(tail), moe_model=moe_full)
    say(f"closure: {len(seg_full)} whole segments, {per_layer:.3f} ms a layer; "
        f"{len(seg_cont)} continuations, aborted layer's MoE and rest measured "
        f"{statistics.mean(tail):.3f} ms (median {statistics.median(tail):.3f}); "
        f"model gate/up+down+shared {moe_full:.3f} ms")
    if calibrate:
        scale = statistics.median(tail) / moe_full
        gu_s, dn_s, sh = gu_s * scale, dn_s * scale, sh * scale
        moe_full *= scale
        say(f"  calibrated: costs scaled by {scale:.2f} to the measured tail")

    gains_ov, gains_early, waits = [], [], collections.Counter()
    comp = collections.defaultdict(list)
    for ab in aborts:
        missing = [k for k in range(6) if ab["mask"] >> k & 1]
        if not missing or any(k not in ab["reads"] for k in missing):
            waits["incomplete"] += 1
            continue
        t_cur = ab["cont_start"] + moe_full
        first = missing[0]
        reads = ab["reads"]
        t0_min = min(reads[k][0] for k in missing)
        comp["detect (gpu end -> A)"].append(ab["t_a"] - ab["gpu_end"])
        comp["A -> first read"].append(t0_min - ab["t_a"])
        comp["reads (first start -> last end)"].append(max(reads[k][1] for k in missing) - t0_min)
        comp["last read -> R"].append(ab["t_r"] - max(reads[k][1] for k in missing))
        comp["R -> continuation GPU start"].append(ab["cont_start"] - ab["t_r"])

        def schedule(shift):
            g = ab["gpu_end"] + sh + (6 - len(missing)) * gu_s + first * dn_s
            for k in range(first, 6):
                if k in missing:
                    g = max(g, reads[k][1] - shift + eps) + gu_s + dn_s
                else:
                    g += dn_s
            return g

        gains_ov.append(t_cur - schedule(0.0))
        shift = max(0.0, t0_min - ab["gpu_end"] - eps)
        gains_early.append(t_cur - schedule(shift))

    n = len(gains_ov)
    if "fit_tail" in out:
        # The same replay with the costs calibrated to the even segments'
        # tail only, summed over the aborts of odd tokens only: a gain that
        # does not lean on the half it was fitted to.
        scale_h = out["fit_tail"] / (gu + dn + sh)
        gu_h, dn_h, sh_h = gu / 6.0 * scale_h, dn / 6.0 * scale_h, sh * scale_h
        full_h = out["fit_tail"]
        g_h, toks = 0.0, set()
        for ab in aborts:
            if ab["tok"] % 2 == 0:
                continue
            missing = [k for k in range(6) if ab["mask"] >> k & 1]
            if not missing or any(k not in ab["reads"] for k in missing):
                continue
            first = missing[0]
            g = ab["gpu_end"] + sh_h + (6 - len(missing)) * gu_h + first * dn_h
            for k in range(first, 6):
                g = (max(g, ab["reads"][k][1] + eps) + gu_h + dn_h) if k in missing else g + dn_h
            g_h += ab["cont_start"] + full_h - g
        odd_tokens = (tokens + 1) // 2
        out["gain_overlap_heldout"] = g_h / odd_tokens
        say(f"held out: overlap gain on odd tokens, costs fitted on even segments: "
            f"{g_h / odd_tokens:6.3f} ms a token")
    out.update(aborts=n, gain_overlap=sum(gains_ov) / tokens,
               gain_early=sum(gains_early) / tokens)
    say(f"aborts replayed {n} ({dict(waits)}), {n / tokens:.2f} a token")
    for name, v in comp.items():
        say(f"  {name:34s} mean {statistics.mean(v):6.3f} ms  median {statistics.median(v):6.3f}"
            f"  per token {sum(v) / tokens:6.3f}")
    say(f"gain, overlap only:    {sum(gains_ov) / tokens:6.3f} ms a token"
        f"  (per abort mean {statistics.mean(gains_ov):.3f})")
    say(f"gain, overlap + early: {sum(gains_early) / tokens:6.3f} ms a token"
        f"  (per abort mean {statistics.mean(gains_early):.3f})")
    return out


def selftest():
    """A trace small enough to replay by hand: two whole three-layer segments
    of 2.319 ms (0.773 a layer), a segment that aborts at layer 7 with slot 2
    missing and read from 8.6 to 9.2 ms, and its two-layer continuation of
    1.546 ms starting at 9.6 - so the tail is 0.773. With gate/up 0.6, down
    0.3 and shared 0.3 the current scheduler finishes the layer at 10.8; the
    ready one starts the resident work at 8.0 (shared 0.3, five gate/ups 0.5,
    two down slots 0.1 -> 8.9), takes slot 2 once its read is in at 9.23
    (+0.15 -> 9.38) and the three slots after it (+0.15 -> 9.53): a gain of
    1.27. Starting the read when the GPU stopped moves it 0.57 earlier, under
    the resident work, and the layer ends at 9.2: a gain of 1.6."""
    ms = lambda x: int(round(x * 1e6))
    ev = [
        (0, "V", ["test"]),
        (ms(0.0), "S", ["0", "0", "3", "0"]), (ms(3.4), "C", [str(ms(1.0)), str(ms(3.319))]),
        (ms(3.5), "S", ["0", "3", "6", "0"]), (ms(6.4), "C", [str(ms(4.0)), str(ms(6.319))]),
        (ms(6.5), "S", ["0", "6", "9", "0"]), (ms(8.05), "C", [str(ms(7.0)), str(ms(8.0))]),
        (ms(8.1), "A", ["0", "7", "4", "6", "1", "2", "3", "4", "5", "6"]),
        (ms(9.25), "X", ["7", "3", "2", str(ms(8.6)), str(ms(9.2))]),
        (ms(9.3), "R", ["0", "7"]),
        (ms(9.4), "S", ["0", "7", "9", "1"]), (ms(11.2), "C", [str(ms(9.6)), str(ms(11.146))]),
    ]
    r = analyze(ev, 1, gu=0.6, dn=0.3, sh=0.3, eps=0.03)
    want = {"per_layer": 0.773, "tail_median": 0.773, "aborts": 1,
            "gain_overlap": 1.27, "gain_early": 1.6}
    bad = [f"{k}: {r[k]:.4f} != {v}" for k, v in want.items() if abs(r[k] - v) > 1e-3]
    print("\n".join(r["lines"]))
    print("selftest " + ("FAILED: " + "; ".join(bad) if bad else "passed"))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace", nargs="?")
    ap.add_argument("--tokens", type=int)
    ap.add_argument("--gu", type=float, default=0.214, help="routed gate/up, all six slots, ms")
    ap.add_argument("--dn", type=float, default=0.142, help="routed down, all six slots, ms")
    ap.add_argument("--sh", type=float, default=0.222, help="shared expert, ms")
    ap.add_argument("--eps", type=float, default=0.03, help="read-complete to GPU, ms")
    ap.add_argument("--calibrate", action="store_true",
                    help="scale the kernel costs so the model matches the measured continuation tail")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.trace or not a.tokens:
        ap.error("TRACE and --tokens are required")
    r = analyze(parse(a.trace), a.tokens, a.gu, a.dn, a.sh, a.eps, a.calibrate)
    print("\n".join(r["lines"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
