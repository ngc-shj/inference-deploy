# The V4.1 decode harness

These lived in a session scratchpad until they nearly did not survive one.
Everything here drives `ds4-server` from `~/ghq/github.com/antirez/ds4-v41`
against `DeepSeek-V4.1-Flash-Q2.gguf` and writes beside itself.

| | |
|---|---|
| `abba.sh NAME [ENV=V ...]` | one arm: start a server with the decode baseline's environment plus whatever is passed, generate `NTOK` (default 1400) tokens from a prompt long enough to reach the steady region, record `vm_stat` either side, stop, wait for the 340 GiB to unmap, cool 45 s |
| `abba-run.sh N` | N blocks of on, off, off, on, so a monotone drift in machine state cancels inside a block. Edit the two arms at the bottom; they are the experiment |
| `pair.py 'ab-on*.log' 'ab-off*.log'` | the analysis, and it is meant to be read before the runs are. Raw wall of the steady windows, one number a run, differenced within each block; refuses to print a comparison at all if the arms did not do identical work |
| `correct.sh NAME [ENV=V ...]` | six prompts through one server, longest 2048 tokens, SHA-256 of each answer to `co-NAME.json`. The only proof a change is allowed to be measured |
| `census.sh NAME [ENV=V ...]` | the same run with `DS4_METAL_V41_GATE_CENSUS=1`, which prints every gated dispatch site with its grid. Symbolise with `atos -o ds4-server -l 0x100000000 <addr>` |
| `cachesim.py` | offline replay of a route log against expert-cache policies |

Rules the analysis encodes, each of which was learned by getting it wrong
once - the full account is in `../V4.1-TUNING.md`:

- **A run is one number.** Its 64-token windows are one generation on one
  machine state, not independent samples.
- **Nothing is dropped.** Runs move by 29%; discarding the ones that did is
  how a result gets manufactured.
- **The steady region starts at token 449.** Before that the expert cache is
  filling and a miss costs a seventh of what it costs after.
- **Identical work or no comparison.** Command buffers and aborts must match
  exactly; dispatches behind an abort within the one decimal it is printed to.
- **The machine gets hot and comes back.** An hour of running costs 6-7 ms a
  token and ten minutes idle returns it, with the memory counters flat
  throughout. This is why the arms alternate.
