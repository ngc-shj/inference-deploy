# Prefix superbatch: every step of a prefix layer, classified

A 4096-row prefix (ctx 8192-16383) runs as two 2048-row chunks a layer. The
superbatch runs each row-independent step once over both chunks' 4096 rows
and keeps only the steps whose rows read other rows' keys a chunk at a time,
in order. Source: `ds41_graph_prefill_sweep` and what it calls.

| Step (per layer) | Rows depend on other rows? | Superbatch |
|---|---|---|
| carry load / store (residual, pre, ffn_split, selection, mask) | no | 4096 rows |
| token ids, layer-0 embedding (per-row loop, batch split per chunk for scratch) | no | 4096 rows |
| Engram rows read and copy, `engram_kv` projection, Engram add (layers 1, 14) | no | 4096 rows |
| HC pre: RMS + `hc_attn_fn` projection, Sinkhorn split, weighted sum, BF16, `attn_norm` | no | 4096 rows |
| `attn_q_a` + norm + BF16, `attn_q_b`, `attn_kv` + norm + BF16 (Q8_0) | no | 4096 rows |
| RoPE of q and kv, kv FP8 rounding | no (position only) | 4096 rows |
| compressor publication of a kv-source layer: pool/score projections, pool2 pairs, latent norm, `indexer_attn_k`, RoPE, FP4, cache writes | no: pairs from an even start; a chunk reads only the n_comp keys it can see | 4096 rows |
| indexer `index_q` projection + RoPE + FP4, `index_weights` projection | no | 4096 rows |
| raw window: previous 127 keys and the chunk's own into `raw_prefill` | yes | per chunk |
| indexer scores, top-k / every-block selection, visible masks | yes (causal width) | per chunk |
| attention core (raw, mixed, indexed) | yes | per chunk |
| heads BF16 rounding and inverse RoPE | no | 4096 rows |
| window commit (last 128 raw keys) | yes | per chunk |
| `attn_output_a` / `attn_output_b` (Q8_0) + BF16 | no | 4096 rows |
| HC after attention: expand, BF16, `hc_ffn_fn` mix, split, weighted sum, `ffn_norm` | no | 4096 rows |
| router (+ hash-routed layers' token ids), shared expert (Q8_0) | no | 4096 rows |
| routed experts (packed MPP mm_id) | no | 4096 rows |
| HC expansion: routed + shared, BF16, expand, BF16 | no | 4096 rows |
| decode-cache seed from the last chunk's selection (host) | - | last chunk's rows, as before |

Kernels that choose by row count (the HC mix projection, the Q8_0 tiles, the
packed routed path) choose the same at 2048 and 4096 rows; every output is
checked by the whole prompt's logits and saved state, not assumed.

Memory: the arena grows by the interleaved tail's 800 rows (0.47 GiB of
buffers, 102 fewer cached experts at the 80 GiB budget) so the prefix's 4096
rows and the tail's never share rows; the packed routed scratch grows to 4096
rows.
