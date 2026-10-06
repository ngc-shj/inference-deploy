# Prefill paths that re-read weights per row, after abe4ceb

Every place in the V4.1 prefill (ds41_graph_prefill_sweep and the interleaved
tail) where a weight matrix is read more than once per dispatch of rows,
priced from measurements already on file. The bar for implementing is 1 ms an
input token: 4.8 s on the 4795-token prompt.

| Path | Rows a weight read serves | Cost now | Best exact gain on file | Over the bar? |
|---|---|---|---|---|
| Prefix Q8_0 projections (q_a, q_b, kv, o_a, o_b, shared): t48 | 4 (BR) | 13.7 s (172.5 ms a 2048-row chunk-layer) | weight reads are at most 31% of the kernel (q8dg, no-read arm); every exact reshaping tried was slower or equal (q8-variants.diff, q8-prepack-flat-wide.diff: wider tiles, shared staging, row-block loops, one-barrier reduction, prepacked layouts) | no: the whole read share is under 4.3 s and no exact form has recovered any of it |
| Tail routed experts (699 rows, decode arithmetic, address pair kernels) | 1 | ~5 s (116-132 ms a layer, split timer) | row-tiled IQ2 keeps the per-row order and saves 20-33% (a29b132); expert-major em/em2 never faster (31dbf89); 11 rows an expert on this tail | no: at most ~1.6 s |
| Tail Q8_0 projections: t48 | 4 | ~2.4 s (59 ms a layer) | as the prefix's | no |
| Layer 20's compressor publication, a row at a time (kv source at ratio 1; the batched form is ratio 2 only on Metal) | 1 | ~0.24 s (layer 20 drains 170-230 ms over layer 24 a prefix; tail pro rata) | all of it | no |
| Index-source layers' indexer projections (F16 projection rows) | batched | ~0.7 s including scoring (24/28/32/36 over their neighbours) | - | no |
| Tail HC mixes in the exact-rows scope (F16, single-row arithmetic) | 1 | under 0.1 s (786 KB a row) | - | no |
| Layer-0 embedding (a row at a time) | gather, not a reuse | layer 0 drains as any layer | - | no |

Source of the prices: tailab-gap1.log (per-layer drains, GPU-bound prefix),
the moe split timer runs (mpprof), 68b4936 (q8dg), a29b132, 31dbf89.

No path clears 4.8 s under the frozen arithmetic, so none is implemented. The
two over 1 s (prefix Q8_0, tail routed) are bounded by their measured read
share and by exact kernels already built and closed.
