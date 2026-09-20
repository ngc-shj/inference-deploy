# A vertical slice of one V4.1 streaming MoE layer

Two control structures over identical arithmetic:

    host-driven   router -> commit -> WAIT -> read ids -> look up -> experts
    resident      router -> GPU validate -> hit experts -> miss record

Both run the same expert kernel over the same bytes with the same ids. The only
difference is whether the selected ids leave the GPU, so the time between them
is the control structure and nothing else. Outputs are compared byte for byte.

    clang -O2 -fobjc-arc -framework Foundation -framework Metal -o moeproto moeproto.m
    ./moeproto <cached experts> <layers> <% all-hit layers> <rounds>

`cached` is how many of the 384 experts have storage and therefore an address;
the rest have none and the GPU cannot reach them. `% all-hit` arranges what
fraction of layers has all six selections inside the cache. A layer that misses
ends the resident arm's segment, because an expert that is not in the cache has
to come back to the host whatever the control structure.

## What it does not model

- Only the gate/up IQ2_XXS pair. No Q2_K down projection, no shared expert, no
  attention, so the per-layer denominator is smaller than a real layer's and
  the percentages here would be diluted in the full model.
- The miss path costs a synchronisation but not the work of actually bringing
  an expert in.
- The resident arm is told where the misses are. A real implementation learns
  that only by reading the miss record, so it cannot choose its segment
  boundaries this way. This is the main thing the prototype is still optimistic
  about, and the next thing to solve.

# Can a committed command buffer reach a resource decided on afterwards?

`residency.m` answers the question the MoE slice leaves open: the slice assumes
the host can service a miss without the per-layer commit/readback/re-encode,
and that assumption rests on Metal letting a residency set change while a
command buffer is already in flight.

    clang -O2 -fobjc-arc -framework Foundation -framework Metal -o residency residency.m
    ./residency <gguf> [steps] [rounds] [bytes] [cache cap]

    GPU:  resident pass ... signal gpu_event ... wait cpu_event ... deref addr_table
    CPU:  wake on gpu_event -> newBufferWithBytesNoCopy over the file ->
          addAllocation -> removeAllocation of what the GPU is past -> commit ->
          write the address table -> signal cpu_event

Against the structure it replaces — commit, wait on the main thread, do the
host work, encode a fresh buffer, commit again — on 40 steps of 3 MiB with
no-copy views spread over the 340 GiB file:

    commit / wait / re-encode   1.966 ms/step
    one buffer, event-gated     0.990 ms/step      -49.7%
    checksums against a direct binding: identical
    command buffer errors: 0
    evictions from the set: 36 at a cap of 4

The resident pass between the signal and the wait is what makes it a result
rather than a stall in a different shape: without GPU work in that window the
same experiment measures -6%, because the CPU's service is not hidden behind
anything.

# Does one big window over the model wire all of itself?

`window.m`. A layer's 384 experts are contiguous in the file, so a single
no-copy buffer over that range would make every one of them addressable and a
miss would stop existing — no repair, no stall. The notes above say a large
window is an eager load; that was measured before a residency set was known to
work here, so it is worth asking of both routes.

    clang -O2 -fobjc-arc -framework Foundation -framework Metal -o window window.m
    ./window <gguf> [window GiB] [regions touched] [1=residency set, 0=useResource]

A 3.56 GiB window — one layer's gate, up and down — with six 3 MiB regions
actually read:

| | first cost |
|---|---|
| `addAllocation` + `requestResidency` | 1021 ms |
| `useResource` on the dispatch | 305 ms |

Both wire the whole window for eighteen megabytes of reads, so the eager-load
note stands. What is new is the 3.3x between the two routes, and that the cost
is paid once per window rather than per use.

It does not rescue the idea. Forty layers of 3.56 GiB is 142 GiB of windows on
a 128 GiB machine, so they cannot all be wired, and wiring one per layer per
token is a second of work for a 50 ms token.

# Do independent dispatches overlap, and is it worth anything?

`concur.m`. Metal serialises dispatches inside a compute encoder unless the
encoder is created with `MTLDispatchTypeConcurrent`, and ds4 creates one only
in two hand-picked places. The expert matvec reaches about 300 GB/s on its own,
which reads like a bandwidth ceiling until independent copies of it are allowed
to overlap:

| dispatches in a group | serial | concurrent | |
|---|---|---|---|
| 2 | 303.2 GB/s | 353.6 | −14.3% |
| 6 | 303.3 GB/s | **429.6** | **−29.4%** |

So one dispatch of 288 threadgroups does not saturate the machine. The reading
that suggested itself — that a concurrent encoder is the way to fix it, and
that a V4.1 layer's shared and routed experts should be overlapped because they
hang off the same `ffn_norm` — is wrong, and a third arm says why:

| | |
|---|---|
| six dispatches, serial encoder | 303.4 GB/s |
| six dispatches, concurrent encoder | 429.5 GB/s |
| **one dispatch with z = 6** | **437.9 GB/s** |

**The gain is threadgroups in flight, not the encoder.** One dispatch whose z
extent carries all six lanes beats the concurrent encoder, and that is exactly
what the real kernel already does: `MTLSizeMake(row_groups, 1, pairs)`, 1728
threadgroups at once. There is nothing here to collect.

It also casts doubt on the 244 GB/s this file quotes for the same kernel
in situ. That came from `DS4_METAL_MOE_STAGE_PROFILE`, which ends and begins a
command buffer around each stage it times.

# Serving the misses instead of being told where they are

`servemoe.m`. The resident arm above reads a host-side array to decide where to
break the command buffer. A decoder has no such array: the router runs on the
GPU, so whether a layer's six experts are reachable is known first on the GPU.
This arm removes the oracle.

    clang -O2 -fobjc-arc -framework Foundation -framework Metal -o servemoe servemoe.m
    ./servemoe <cached experts> <layers> <% all-hit layers> <rounds>

One command buffer holds the whole token. Per layer:

    router -> validate (writes the lane masks, signals "validated")
           -> expert pass over the hit lanes
           -> wait for "repaired"
           -> expert pass over the repaired lanes, empty and free when nothing missed

A service thread - never the encoding thread - waits on "validated", installs
addresses for whatever missed, and signals "repaired". On an all-hit layer it
reads two words and signals.

| all-hit layers | host-driven | served | host work | |
|---|---|---|---|---|
| 100% | 0.725 ms/layer | 0.577 | 0 of 320 layers | **−20.5%** |
| 68% | 0.730 | 0.584 | 104 of 320 | −19.9% |
| 32% | 0.734 | 0.580 | 216 of 320 | −21.0% |
| 0% | 0.736 | 0.586 | 320 of 320 | **−20.4%** |

Output identical to the host-driven arm at every row, both arms stable against
themselves over rounds, and the encoding thread blocks zero times a token
against the host-driven arm's forty.

**It is flat in the hit rate**, where the oracle arm falls from −47.8% to
−23.4%: the oracle commits and waits at every miss, and this one never breaks
the buffer at all. At 0% hit the two are within three points, which is the
oracle's synchronisation being all that is left of it.

## What it cost to get an answer that means anything

**Metal gives no ordering for memory a running command buffer wrote.** The
first version had the service thread spin on a word the validate kernel stored,
which is what the CUDA implementation does with device-side flags. It reports
−44% and is wrong: the thread can see the new epoch before the masks that go
with it, call a layer clean, and leave lanes uncomputed. With the spin replaced
by an event the GPU signals after the validate - the documented ordering point -
the same arm measures −20%. **The 24 points between them is the price of the
per-layer GPU-to-host round trip, and it is the next thing to attack**, not a
result to quote.

**`iq2_pair` overran its threadgroup allocation.** The grid tables were filled
with a fixed four values a thread, which assumes 64 threads; at the 32*NSG the
expert pass dispatches it wrote 4096 bytes into 2176. It is now strided by the
real threadgroup width. `moeproto` dispatches 64 threads and never saw it.

**The kernel's row assignment is coupled to the launch geometry.** `NSG` and
`NR0` are compile-time in the kernel and repeated in the host program; setting
them differently makes two simdgroups write the same output row, and the arm
disagrees with itself by a few hundred floats in 368,640. Both arms have to be
checked against themselves before either is compared with the other.
