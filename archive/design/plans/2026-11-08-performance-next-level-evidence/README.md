# Evidence for the next-level performance plan

Prototypes behind the numbers marked **measured** in
[2026-11-08-performance-next-level.md](../2026-11-08-performance-next-level.md), kept as starting points. None of them
is shipped code; they were written against main 2cda3ca.

| File | What it is | Used for |
|---|---|---|
| `cone-of-influence-trace.patch` | `CNFBuilder` records each clause's owning gate; `proveExactly` times encode / cone / solve / check, hashes each CNF (FNV-64, experiment only) and hands the solver only the goal's cone | S1, S3 and the encode/solve/check split in section 3 |
| `compare-configuration-sil.py` | Compares function bodies of `<prefix>-Debug.sil`, `<prefix>-Release.sil` and `<prefix>-DisableReplacement.sil` (locations, scopes and comments removed) | C1: which functions differ between configurations, and that the builtin marks them |
| `WorkerWalk.swift.txt` | Data-parallel walk prototype: workers build inputs from index ranges and report the lowest failing index | W2 (13× over serial on cheap functions) |

The patch hashes with FNV-64 for the experiment; production keys need SHA-256 or exact equality.
