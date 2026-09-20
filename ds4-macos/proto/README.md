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
