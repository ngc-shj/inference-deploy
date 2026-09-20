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
