# V4.1 streaming memory budget 80 vs 84 GiB: fixed plan

## Recoverable upper bound

The adopted 80 GiB budget leaves the production decode cache at 7,041
experts. Replay of the held-out production route gives 7.84 aborting layers
per token. A 4 GiB increase is expected to admit about 430 more experts;
capacities 7,425-7,470 replay at about 6.5 aborts/token. At the previously
measured 0.96 ms per avoided abort, the optimistic E2E recovery is about
1.3 ms/token, above the 1 ms implementation threshold.

## Safety gate before timing

The same binary accepts
`DS4_METAL_V41_STREAMING_MEMORY_BUDGET_GIB=84`; it is hard-clamped to 21/32
of host memory (84 GiB on this machine). Default/unset remains 80 GiB.

Before any timed run, run one guarded lifecycle and one guarded seven-input
production pass at 84 GiB. Do not enter ABBA unless all of the following hold:

- pressure stays at level 1 and swap growth is zero;
- peak wired stays below the fixed 88 GiB soft line;
- close releases all ds4-managed cache/residency allocations;
- the seven output hashes match the oracle, Metal 3 work and feedback errors
  are zero, and the larger cache is observed.

## Timed comparison

- Same binary, cache request 10,268 and physical-reserve lending enabled.
- A: default 80 GiB. B: budget override 84 GiB.
- Two `a b b a` blocks, eight 2,048-token production requests.
- 480 seconds idle before every arm; if the load-log quiet gate is unavailable,
  use `NOGATE=1` and retain the fixed idle plus CPU/GPU/thermal records.
- Primary metric: whole request wall / 2,048 generated tokens.

B is adopted only if every valid arm is output-identical, both ABBA blocks
favor B, mean improvement is at least 1.0 ms/token and exceeds
same-configuration variation, and every B arm remains inside the safety gate.
Otherwise revert the override code and close the proposal.

## Invalid second block and replacement rule

The first block completed normally. During the second block the machine slept:
three arms reported 203-483 ms/token outside the graph versus the normal
sub-3 ms, while CPU ticks advanced for only seconds over tens of minutes.
Those arms meet the predeclared unrelated-host-stall exclusion and are invalid.
The unfinished arm was stopped because one endpoint could not reconstruct the
block. Replace the invalid block once, with the identical order, cooling and
binary under `caffeinate -dimsu`; do not rerun or select individual arms.
