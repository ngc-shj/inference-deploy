# Run X's item-13 failure: audit and invariants (2026-10-06)

The failure: in m4inproc's short case the second of two sessions stepped in
lockstep diverged from evaluation 1298 (ids cda274dc0a35a390 against the
oracle's 13607d993a447227). 32 runs since, on 625b3a7 and abe4ceb's engine,
none reproduced it (822eaa1).

## Audit

| Question | Finding | Evidence |
|---|---|---|
| Router publication | kernel_dsv41_route_schedule (ROUTER_FUSE_TRANSFORM=5): cluster 1's row is stored by col 256 and only col 0 arrives; no barrier between them, so the last group could validate a stale odd row (the previous layer's logit) and pick other experts. A real race; it predates the superbatch. Fixed: engine b2bd8d1. | metal/dsv41.metal, the publish block |
| Background loads and epochs | No session or engine epoch. The one asynchronous load (early selected load) is not used on this path (0 begun in every recorded run). | ds4_metal.m begin/finish_selected_load; history counts |
| Publish order | Bytes joined before install; table slot, then entry fields; host writes go to the seed table, copied to the live one at the next commit behind a queue barrier. | install_loaded; ds4_metal_mtl4.h seed/live copy |
| Slot reuse before GPU completion | Gated reads mark nothing in flight; the only guard is that loads, installs and evictions happen with the queue idle. Now checked (ds4_cache_busy_check): 0 violations in 73,875 checks on the short pair, 0 in a full m4inproc. | engine 7066f10 and its follow-up |
| Route prediction | Process-global, off on this env (no DS4_METAL_V41_ROUTE_PREDICT), and unreachable with ABORT_GATE=40. | ds4.c ds41_route_predict_* |
| Encode-ahead / gate state | Global, reset per token and per segment; every token drains before returning. | ds4_metal_gate.h token_begin, region_end |
| Session end | No cancel or drain at free; relies on every step having drained, which the decode loop does. | ds4_session_free |

## Invariants and history now in the engine

- ds4_cache_busy_check: a load, install or eviction while the queue's
  shared event is behind the last commit is counted and reported once.
- Per session, the last 32 gated tokens: eval sequence, gate segment and
  slot, install / early-load / spare / address-mismatch / busy counts, and
  every layer's six experts' state, generation and slab slot. The in-process
  test prints both sessions' last three at the first logits divergence.

After the fix: the whole prompt is the oracle's (tailab-fixchk), and a full
m4inproc passes with every id hash the oracle's (m4in-infix3). The original
failure is not reproduced, so the router race is the most plausible cause,
not a proven one.
