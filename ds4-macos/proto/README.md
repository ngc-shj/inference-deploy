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
This arm removes that oracle, and only that one.

    clang -O2 -fobjc-arc -framework Foundation -framework Metal -o servemoe servemoe.m
    ./servemoe <cached experts> <layers> <% all-hit layers> <rounds>

One command buffer holds the whole token. Per layer:

    router -> validate (writes the lane masks, signals "validated")
           -> expert pass over the hit lanes
           -> wait for "repaired"
           -> expert pass over the repaired lanes

A service thread waits on "validated", installs addresses for whatever missed,
and signals "repaired".

| all-hit layers | host-driven | served | |
|---|---|---|---|
| 100% | 0.725 ms/layer | 0.577 | −20.5% |
| 68% | 0.730 | 0.584 | −19.9% |
| 32% | 0.734 | 0.580 | −21.0% |
| 0% | 0.736 | 0.586 | −20.4% |

Output identical at every row, both arms stable against themselves.

## Read the table with all of this in mind

**The host is on the critical path on every layer, hit or not.** The GPU
signals, the service thread wakes, writes a value back, and the GPU waits for
it - four operations a layer, all forty of them, whatever the masks say. What
is skipped on an all-hit layer is the service thread's *work*, not the round
trip. Only the *encoding* thread is free of it.

**The repair is a stand-in.** Two pointer stores hand a missing expert the
address of `id % cached`, so it reads another expert's bytes. There is no file
read, no no-copy view, no residency update, no eviction, no down projection.
Both arms read the same wrong expert, which is why they agree. The flatness
across hit rates follows from a miss costing two stores and is not evidence
about a real fetch.

**The two arms do not have the same shape.** Host-driven builds two command
buffers a layer and waits on both - eighty buffers and eighty host waits a
token - against one. The −20% contains that, and is not a control-plane
measurement.

**An earlier version of this arm reported −44% and was wrong.** It span on a
word the validate kernel stored, which is what device-side flags do on CUDA;
Metal does not guarantee a host read of memory a running command buffer wrote,
so the thread could see a layer's epoch before its masks and leave lanes
uncomputed. The event fixes it. The difference between the two is not the
price of the round trip - one of them does not compute the right answer.

**Known bug**: `epoch` is used as a flag and zeroed by the service thread after
the last layer, which can land after the main thread has published the next
one. The arms alternate today and the host-driven stretch hides it. It needs a
sequence ring or a completion acknowledgement before this harness is used for
anything else.

## What a next version has to do

1. zero CPU events and zero CPU signals on an all-hit layer, counted;
2. a real fetch on a miss - bytes, view, residency, eviction, invalidation;
3. a control group with the same command buffer structure;
4. one named difference from `DS4_METAL_V41_RESIDENT_LAYER=all`, which is
   already a service thread with a real miss load in the main tree.

## What it did establish

A host read of GPU-written memory needs an `MTLSharedEvent`, shown by an arm
that was wrong without one. And two bugs in the shared expert kernel that only
showed up when each arm was checked against *itself*: the grid tables were
filled four values a thread, which assumes 64 threads and writes 4096 bytes
into a 2176-byte threadgroup allocation at anything wider; and the kernel's row
assignment is a compile-time function of `NSG` and `NR0`, so a host program
that disagrees about either has two simdgroups writing the same output row.

# Can a kernel switch off the dispatches encoded after it?

`gateprobe.m`. The abort gate needs one guarantee: a kernel writes zeros into
the indirect dispatch arguments of dispatches encoded later in the same command
buffer, and those dispatches then launch nothing.

    clang -O2 -fobjc-arc -framework Foundation -framework Metal -o gateprobe gateprobe.m
    ./gateprobe <dispatches> <gate index> <rounds> [1 = one shared encoder]

| | ran past the gate | lost before it |
|---|---|---|
| 64 dispatches, gate 8, 200 rounds, separate encoders | 0 | 0 |
| 64 dispatches, gate 8, 200 rounds, one encoder | 0 | 0 |
| 256 dispatches, gate 40, 100 rounds, one encoder | 0 | 0 |

The single-encoder rows are the ones that matter: ds4 keeps one compute encoder
across a layer's dispatches, so the kernel doing the switching off and the
dispatches it switches off are in the same encoder, with no implicit barrier
between them.

# What does one dispatch cost, and what does sending it indirect add?

    clang -O2 -fobjc-arc -framework Foundation -framework Metal -o dispatchcost dispatchcost.m
    ./dispatchcost 11

Perfectly linear in N from 256 to 4096; the figures below are µs a dispatch of
GPU span, taken as the best of eleven laps, on an idle machine.

| shape | what it is | µs a dispatch |
|---|---|---|
| plain | one pipeline, no rebinding | 0.70 |
| pipe | a `setComputePipelineState` between every dispatch | 0.70 |
| bind | a 16-byte `setBytes` between every dispatch | 0.70 |
| indirect | `dispatchThreadgroupsWithIndirectBuffer`, one slot reused | 2.28 |
| slotted | the same, a distinct slot a dispatch — **what the gate encodes** | 2.25 |
| private | slotted, table in private storage | 2.22 |
| gatedoff | slotted, grid zeroed — what is left behind an abort | 1.85 |

Three things follow.

**Neither the pipeline switch nor the binding costs anything.** A dispatch is
0.70 µs whatever the encoder does between them, so "fewer dispatches" is worth
exactly 0.70 µs each with the gate off, and the encode-side saving is separate.

**The indirect form costs 1.55 µs more, and nothing moves it.** A distinct slot
a dispatch reads the same as one slot reused, so the table is not a cache
effect; private storage is 0.03 µs cheaper, which is noise. The cost is the
command processor reading the arguments, and the only way to stop paying it is
to stop sending the dispatch indirect.

**A switched-off dispatch still costs 1.85 µs.** `launched` is checked as 0 for
that shape, so the gate's guarantee holds — and the header's claim that the
dispatches after an abort "still cost their issue" is now a number: at ~290
such dispatches a token they are 0.54 ms.

Against a token's measured 2,666.6 gated dispatches (zero-abort window) this
prices the gate itself:

    as encoded      2,666.6 x 2.25 us = 6.00 ms of a 39.3 ms GPU term
    were they plain 2,666.6 x 0.70 us = 1.87 ms
    the gate's tax                      4.13 ms a token

## What it does not settle

The probe's kernel does nothing. A real dispatch's issue may overlap the
previous kernel's execution, so 2.25 µs is what an empty chain costs, not
necessarily what each one adds to a chain that is also computing. It is an
upper bound on the saving, which is the direction that matters for deciding
whether to build something.

# Which step of the router's weight tail changes the bits

`routerbits.m`. Replacing the generic five-kernel tail with
`kernel_dsv4_router_weights_one` changed the model's output, and three things
change at once: the sum over six entries goes from a tree reduction to index
order, the divide and the 1.5 scale stop being separate kernels with an f32
round-trip between them, and `clamp(sum, eps, inf)` becomes `max(sum, eps)`.
Attributing it to the first without measuring was a guess; this measures it.
Twenty thousand rounds of six weights, probabilities drawn over the range
`sqrt(softplus(logit))` actually produces:

| | differ |
|---|---|
| divide and scale in one expression against two | **0 (0.00%)** |
| index-order sum against a tree sum | **18,928 (94.64%)** |
| both at once | 18,928 (94.64%) |

**The expression fusion is innocent and the sum order is the whole of it.** The
worry that `-ffast-math` would reassociate `a / sum * 1.5f` or swap in a
reciprocal does not show up at this width and range: not one round in twenty
thousand.

And the sum order is not a rare last-bit event. Six addends are few, but
`sqrt(softplus(x))` spreads them over about one and a half decades, so the
exponents do not line up and the association shows through on **19 rounds in
20**. A six-element sum being "small enough not to matter" is the intuition
this kills.

So the fused tail is usable if its sum is written to match the reduction the
generic path performs - a strided per-thread partial followed by a simdgroup
reduction, not the shared-memory halving this probe uses for its tree arm. That
is a kernel change with a byte comparison behind it, not a flag.

# What a narrow projection reaches, and what merging them recovers

`narrowmv.m`. DeepSeek V4.1's layer is low-rank and compressed throughout, so
its projections are narrow: the indexer projection is 7168x32, `attn_kv` and
the KV compressor 7168x512, `attn_output_a` 7168x1024, `attn_q_a` 7168x1280. A
narrow output is few rows, few rows are few threadgroups, and the call-site
census finds 59.1 dispatches a token at **24 threadgroups** on a forty-core GPU.

Same geometry as the real kernel - 256 threads, eight simdgroups, a row to a
simdgroup - and a cold slab every lap so a weight is gone before it comes round
again:

| projection | threadgroups | GB/s |
|---|---|---|
| `indexer_proj` 7168x32 | 1 | **1.2** |
| `attn_kv` 7168x512 | 10 | **19.0** |
| KV compressor 7168x512 | 10 | 19.1 |
| `attn_output_a` 7168x1024 | 19 | 37.1 |
| `attn_q_a` 7168x1280 | 24 | **45.9** |
| the five, one dispatch each | | **24.9** |
| the five as five lanes of one dispatch | 120 | **203.8** |

**8.2 times, and the rate tracks the threadgroup count almost exactly** - 1
group 1.2, 10 groups 19.0, 24 groups 45.9, 120 groups 203.8. Nothing here is
bandwidth-limited. It is limited by how much of the machine one dispatch asks
for, and a narrow projection asks for almost none of it. Against the 560 GB/s
the dense projections reach in situ, `attn_q_a` alone gets a twelfth.

`concur.m` had already found that 288 threadgroups does not saturate. These are
at 1 to 24, far below where that curve was even sampled.

## What it does not settle

**The absolute times do not transfer.** Five projections a layer is 45.6 MiB,
1.82 GiB a token, which at 24.9 GB/s would be 73 ms - larger than the whole
token. So in the engine they are not running at the cold-slab rate: they
overlap other work in the layer, and their weights are resident rather than
freshly streamed. **Read the 8.2x ratio, not the 73 ms.** Sizing the change
needs an A/B in the engine, not this file.

What it does establish is the direction and the mechanism: the five all read
`norm`, none depends on another, and they go out one at a time at a fraction of
the machine. Merging them needs a matvec that can carry lanes of different
weight type and output width in one grid - the shared expert already has a
two-lane form, but it requires both lanes to share a type and a width, which
these do not.
