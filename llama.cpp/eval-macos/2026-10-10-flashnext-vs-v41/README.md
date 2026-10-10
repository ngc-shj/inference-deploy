# Flash-Next vs DeepSeek V4.1 Flash Q2 — harness and raw results

Results and verdict: [EVALUATIONS-macos.md](../../EVALUATIONS-macos.md), 2026-10-10.

| File | What it is |
| --- | --- |
| `tasks.py` | the 49 prompts and their checkers |
| `hidden.py` | hidden tests for the coding tasks |
| `ref.py` | reference solutions; `hidden.py` must give them full marks |
| `passage.txt` | the passage summarised in F2 |
| `run.py` | sends every task to one engine, appends to `out-<engine>.jsonl` |
| `score.py` | scores the machine-checkable tasks; J1–J3 and F1–F3 are judged by hand |
| `out-flashnext.jsonl`, `out-ds4.jsonl` | raw responses, including `reasoning` when thinking was on |
| `blind.md`, `blind-key.json` | the free-form answers as the judge saw them (shuffled X/Y), and the key |

Run one engine at a time (Flash-Next on port 11234, ds4 on 8019), then:

```bash
python3 run.py flashnext     # or: ds4; already-answered ids are skipped
python3 score.py flashnext ds4
```

To check the tests themselves:

```bash
python3 -c "import ref, hidden; print([getattr(hidden, 't_' + n)(ref) for n in ['merge_intervals', 'LRUCache', 'calculate', 'longest_valid_parentheses', 'is_match', 'min_window', 'course_order', 'sliding_median']])"
```
