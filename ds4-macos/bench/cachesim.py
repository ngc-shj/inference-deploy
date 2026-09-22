"""Replay the recorded route log against cache policies.

The number that matters is not expert misses but *aborting layers*: the gate
stops a segment at the first layer whose selection is not all reachable, and
repairs every missing expert of that layer in one call. Two misses in one
layer are one abort and one repair, so misses/token overstates what a policy
buys. Both are reported; the abort column is the one that maps to wall time.
"""
import sys, array
from collections import OrderedDict, deque

DECAY_TOKENS = 16      # ds4_metal.m: DS4_METAL_STREAM_EXPERT_HOTNESS_DECAY_TOKENS
N_LAYER, N_SEL = 40, 6

def load(path):
    a = array.array('i'); a.frombytes(open(path,'rb').read())
    recs = len(a)//8
    toks = []
    cur = []
    for r in range(recs):
        b = r*8
        layer, n = a[b], a[b+1]
        cur.append((layer, tuple(a[b+2+k] for k in range(n))))
        if len(cur) == N_LAYER:
            toks.append(cur); cur = []
    if cur: toks.append(cur)
    return toks

class Stats:
    def __init__(s): s.miss = s.abort = s.tok = 0
    def token(s, misses_by_layer):
        s.tok += 1
        s.miss += sum(misses_by_layer)
        s.abort += sum(1 for m in misses_by_layer if m)
    def row(s, name, cap):
        if s.tok == 0: return f"{name:<16} {cap:>6}   no measured tokens"
        return (f"{name:<16} {cap:>6}  {s.miss/s.tok:7.2f} {s.abort/s.tok:8.2f}"
                f"  {s.miss/s.tok*9.49:8.1f}")

def run(toks, cap, policy, warm_frac=0.5):
    warm = int(len(toks)*warm_frac)
    st = Stats()
    if policy == "infinite":
        seen = set()
        for i,tok in enumerate(toks):
            mb=[]
            for layer, ids in tok:
                m=0
                for e in ids:
                    k=(layer,e)
                    if k not in seen: seen.add(k); m+=1
                mb.append(m)
            if i>=warm: st.token(mb)
        return st
    if policy == "belady":
        # next-use table over the flat access stream
        flat=[]; 
        for tok in toks:
            for layer, ids in tok:
                for e in ids: flat.append((layer,e))
        nxt=[0]*len(flat); last={}
        for i in range(len(flat)-1,-1,-1):
            nxt[i]=last.get(flat[i], 1<<60); last[flat[i]]=i
        cache=set(); pos=0
        nextuse={}
        for i,tok in enumerate(toks):
            mb=[]
            for layer, ids in tok:
                m=0
                for e in ids:
                    k=(layer,e)
                    if k in cache:
                        nextuse[k]=nxt[pos]
                    else:
                        m+=1
                        if len(cache)>=cap:
                            victim=max(cache, key=lambda c: nextuse.get(c,1<<60))
                            cache.discard(victim); nextuse.pop(victim,None)
                        cache.add(k); nextuse[k]=nxt[pos]
                    pos+=1
                mb.append(m)
            if i>=warm: st.token(mb)
        return st

    lru = OrderedDict()                 # key -> last_used clock (value unused for LRU)
    hot = {}                            # (layer,expert) -> decayed frequency
    a1in, a1out = deque(), deque()
    a1set, a1outset = set(), set()
    per = [OrderedDict() for _ in range(N_LAYER)]
    if policy.startswith("layer"):
        if policy == "layer-lru":
            caps=[cap//N_LAYER]*N_LAYER
        else:                            # share by each layer's distinct working set
            dis=[set() for _ in range(N_LAYER)]
            for tok in toks:
                for layer, ids in tok:
                    dis[layer].update(ids)
            tot=sum(len(d) for d in dis)
            caps=[max(N_SEL, int(cap*len(d)/tot)) for d in dis]
    clock=0
    for i,tok in enumerate(toks):
        if policy in ("current","tinylfu") and i and i % DECAY_TOKENS == 0:
            for k in list(hot): 
                hot[k] >>= 1
                if hot[k]==0: del hot[k]
        mb=[]
        for layer, ids in tok:
            if policy in ("current","tinylfu"):
                for e in ids: hot[(layer,e)] = hot.get((layer,e),0)+1
            m=0
            for e in ids:
                clock+=1
                k=(layer,e)
                if policy.startswith("layer"):
                    c=per[layer]
                    if k in c: c.move_to_end(k)
                    else:
                        m+=1; c[k]=clock
                        if len(c)>caps[layer]: c.popitem(last=False)
                    continue
                if policy == "2q":
                    if k in lru: lru.move_to_end(k); continue
                    if k in a1set:
                        a1in.remove(k); a1set.discard(k)
                        lru[k]=clock
                        if len(lru)+len(a1set) > cap: lru.popitem(last=False)
                        continue
                    m+=1
                    if k in a1outset:
                        a1outset.discard(k); a1out.remove(k)
                        lru[k]=clock
                        while len(lru)+len(a1set) > cap and lru: lru.popitem(last=False)
                    else:
                        a1in.append(k); a1set.add(k)
                        while len(a1in) > max(1,cap//4):
                            ev=a1in.popleft(); a1set.discard(ev)
                            a1out.append(ev); a1outset.add(ev)
                            while len(a1out) > max(1,cap//2):
                                o=a1out.popleft(); a1outset.discard(o)
                        while len(lru)+len(a1set) > cap and lru: lru.popitem(last=False)
                    continue
                # global single-list policies
                if k in lru:
                    lru.move_to_end(k); lru[k]=clock; continue
                m+=1
                if len(lru) >= cap:
                    if policy == "lru":
                        lru.popitem(last=False)
                    elif policy == "current":
                        protect=set((layer,x) for x in ids)
                        victim=min((c for c in lru if c not in protect),
                                   key=lambda c: (hot.get(c,0), lru[c]))
                        del lru[victim]
                    elif policy == "tinylfu":
                        protect=set((layer,x) for x in ids)
                        cand=[c for c in lru if c not in protect]
                        victim=min(cand, key=lambda c: lru[c])      # LRU victim
                        if hot.get(k,0) <= hot.get(victim,0):
                            continue                                 # not admitted
                        del lru[victim]
                lru[k]=clock
            mb.append(m)
        if i>=warm: st.token(mb)
    return st

if __name__ == "__main__":
    toks = load(sys.argv[1] if len(sys.argv)>1 else "cap1.route")
    print(f"{len(toks)} tokens, {len(toks)*N_LAYER*N_SEL} accesses")
    print(f"\n{'policy':<16} {'cap':>6}  {'miss/tok':>7} {'abort/tok':>8}  {'MiB/tok':>8}")
    for cap in (7930, 8698):
        for pol in ("current","lru","layer-lru","layer-prop","2q","tinylfu","belady"):
            print(run(toks, cap, pol).row(pol, cap), flush=True)
        print()
    print(run(toks, 1<<30, "infinite").row("infinite", 0))
