# Swift-internals plan: implementation ledger

Where each item of [the Swift-internals plan](2026-11-07-swift-internals.md) stands on branch `impl/swift-internals`
(worktree `../SwiftFormal-impl`, from `main` at `916f918`). One commit per ID. Status: **todo**, **done** (commit),
**deferred** (reason), **not doing** (the plan says so).

## Owner decisions (2026-11-07)

| Decision | Choice |
|---|---|
| 1. K2 pin | Gate fails closed; `sfverify` and `swiftformal check` warn and stamp the report; ships with V7 |
| 3. R5 configuration | Default `--config both` |
| L1 tier 1b, L8 (S0 growth) | Yes |
| L3/L4 loops | Yes: partial correctness, "termination not proved" in TRUST.md, default unwind bound 8, `--unwind N` |
| L5 classes | Yes, narrow; a conflict the caller may hold is `undecided` (decision 6, conservative default) |
| H4 summaries | Yes, opt-in `--modular` |
| K5 plugin product | Yes |
| H6 trait | Yes (tools 6.1 for consumers) |
| V4 cross-check | Yes, opt-in `--cross-check llvm` |
| U14 prebuilt binary | Yes |

Plan defaults taken without asking: R4 traps at `count >= 2^48` (decision 2); R8 states the SDK's stdlib (decision 4);
V3 fetches the corpus by SHA in the nightly lane (no vendoring); U4 two-part helper now, `--confirm` opt-in
(decision 12); R10 now (decision 13); H10 deferred (decision 14); no upstream reports filed (decision 15,
outward-facing).

## Items

| ID | Tier | Status | Commit / reason |
|---|---|---|---|
| R1 | 0 | done | 46bfefd; on merging main, main's own fix (2d56c71, `SILPrinting.swift`) replaced this branch's version; the R1 cases stay in `ScanKnownTrapTests` |
| R2 | 0 | done | 46bfefd |
| R3 | 0 | done | 46bfefd |
| V1 | 0 | done | 46bfefd (fail closed; modelling the deinit call is later work) |
| V2 | 0 | done | 46bfefd (also the LLVM reader: KNOWN-ISSUES 3 closed) |
| R4 | 0 | done | 46bfefd |
| R7 | 0 | done | 46bfefd |
| K2 | 0 | done | c36ac5f |
| V7 | 0 (with K2) | done | 3aee1d7 (merged in a525ddd); self-test in the safety net since c36ac5f |
| R5 | 0 | done | 7f330f9 |
| K1 | 1 | done | d623818 |
| U2 | 1 | done | d623818 (golden had the accessor functions in it; re-recorded) |
| U3 | 1 | done | 3d24973 (docs branch, merged in d90ac80) |
| L13 | 1 | done | d623818 |
| U6 | 1 | done | 9f2c2fe |
| U10 | 1 | done | 9f2c2fe |
| K4 | 1 | done | 9f2c2fe |
| H8 | 1 | done | 56c3778 (merged in d90ac80) |
| R8 | 1 | done | 252efef (merged in d90ac80) |
| U13 | 1 | done | f371918 (Walk branch, merged in deb57e1) |
| V8 | 1 | done | d623818; the corpus still shows 10 INVALID in 4 files, recorded as knownInvalid in Scripts/baseline/corpus.json |
| V10 | 1 | done | d623818 |
| H0 | 4 guard | done | e4afc1f; extended on impl/unblock: CNFFeatureHashTests (classes, for-in, dictionaries, strings, ranges, floats, throws, generics, unrolling, contract summaries); CNFFixtureHashTests (2,488 formulas: every SIL suite's fixtures, an Objective-C fixture and one for arms no fixture reached; d12d00a) |
| H2 | 4 | done | 4e40570 |
| H3 | 4 | done | ac370ce |
| L1 | 2 | done | b0e04c3 (tier 1a and 1b; trusted model 272 -> 546 lines, plan estimated ~80) |
| L2 | 2 | done | f04f7e0 (`impl/coverage-a`): Dictionary and Set as count-only values, with their three traps |
| L8 | 2 | done | 038eece (128-bit widths not done: SFBV constants are 64-bit) |
| L6 | 2 | done | 79d02fb, 9416e97 (stdlib throwing calls, rethrows closures, inout through try_apply refused) |
| L3, L4 | 2 | done | L3 304bf3e (while/repeat, invariant true, partial correctness); 2-induction for one-loop functions without ensures and bounded unrolling (`--unwind`, default 8 header visits, owner decision) on branch impl/loops-bmc; L4 for-in (6fa9960). The bound counts header visits of all loops together (CBMC counts per loop); unrolling follows runs from the entry only, so it may miss runs, never invent one |
| L7 | 2 | done | a7313a9 (`impl/coverage-b`): the module's own generic functions read at the call's concrete types |
| L5 | 2 | done | branch impl/l5-classes; final classes without superclass/conformance, one reference per object (every other source of a second reference refused); decision 6: a class parameter is never `safe` (`undecided`, "exclusivity"). Deviation: `[dynamic]` conflicts inside a function are refused instead of encoded as traps (advisor; sound, simpler) |
| L9 | 2 | done | f691d93 |
| R10 | 2 | superseded | main's string model (`SILStrings.swift`, strings as identities, 91b0c30) makes `isEmpty`, `==` and literal counts exact; a UTF-8 count leaf would change that layout under active work, and the 2^48 allocation trap would make `name + ".json"` may-trap. WIP kept on `impl/coverage-a-wip` |
| R11 | 2 | done | 46bfefd (needed by R2's `hashRR` case) |
| K3 | 3 | done | 0916222 (toolchain branch, merged in c8d9aa7); gain is correctness (a changed build is never reused), the 15-20 s saving did not appear on plain --build |
| K11 | 3 | done | bf626dc (merged in c8d9aa7) |
| K5 | 3 | done | d918a90, 33e35e1 (merged in c8d9aa7) |
| K6 | 3 | done | 9ca2cdc, 362cd3b (merged in c8d9aa7); Tuist not tried |
| K8 | 3 | done | 942e13a (merged in c8d9aa7) |
| K12 | 3 | done | 2ad3e3d (docs; merged in c8d9aa7) |
| V3 | 5 | done | 2ae5a73 (validation branch, merged in e944e5b); 4,385 functions, 0 crashes |
| V4 | 5 | done | cc04906 |
| V5 | 5 | done | f9c1daf (merged in e944e5b; L8's ops added to it in the merge) |
| V6 | 5 | done | c90797b (merged in e944e5b); 14 of 14 killed |
| V9 | 5 | done | 72cf782 (merged in e944e5b); seeds made from Examples, no compiler test files |
| R6 | 5 | done | dc07a9a (merged in e944e5b); 67 rows pinned after this branch's rows were added |
| R9 | 5 | done | 2b45ec3 (merged in e944e5b) |
| L12 | 5 | done | 225cf09 (merged in e944e5b); +40 to 75 % compile |
| U11 | 6 | done | f78e44f, 251977e (merged in deb57e1) |
| U9 | 6 | done | 2a0c3e7, 3c96e87 (merged in c7b7616) |
| U7 | 6 | done | 84b8208 (reports branch, merged in c7b7616) |
| U4 | 6 | done | b8eda80, c12253f (merged in deb57e1); Swift 6.3+, macOS; Linux not built |
| U5 | 6 | done | 1f21a29 (merged in c7b7616); --confirm only for free functions over scalars |
| U8 | 6 | done | 1410f74 (merged in c7b7616); GitHub upload not run |
| U12 | 6 | done | 4620d82 (`impl/round2-followups`); stream versions 6.3/6.4 carry no attachment bytes, only a saved file's path with `--attachments-path` |
| U15 | 6 | done | f150315 (merged in d90ac80); not tried in a VS Code or Xcode window |
| U14 | 6 | done | aaa0983 (script and tag-only workflow; not wired into Package.swift until a release URL exists; reproducible across folders, not machines) |
| H4 | 4 | done | opt-in `--modular`; retries only `undecided` and "deep call chain" (pass 1 unchanged, verdicts otherwise identical); keeps only proofs instead of marking approximations and replaying; loop-proved callees excluded (partial correctness) |
| H6 | 4 | done | 978f914 (merged in c8d9aa7); consumers need tools 6.1 |
| H1 | 4 | done | reader half on impl/unblock: SILParser split by family (values, type context, instructions, module, function and instruction parsing), one reader per instruction, the ignored instructions a reviewed allow-list; CNF hashes byte-identical (H0 extended to 42 feature formulas first, which found and fixed a nondeterministic cell merge). Encoder half after round 6 merged (d12d00a, 9ce20b7, 744d7b3): H0 extended again to 2,488 fixture formulas, then `SILEncoder.run` became `FunctionRun` (state in an object, one exhaustive `switch` in `execute`, a method per instruction in `SILRunValues`/`Memory`/`Arrays`/`Calls`/`Summaries`); byte-identical, and the guard caught a `continue` turned into a block skip during the move. The plan said `BlockState`: the object holds the whole function run, so it is named `FunctionRun` |
| H9 | 4 | done | branch impl/unblock: SILModule(text:), SILModule.function and every reader function `throws(SILError)`; ParserFuzzTests checks it at compile time |
| H5 | 4 | deferred | measured after S7 (Benchmarks/Scaling, release, call chains): `ProofCache.key` of the deepest function 8 ms at 64 functions, 46 ms at 512, 86 ms at 1,024 (linear in the callees it renders); keys for every function of a 512 chain 12.7 s, 25 ms each, as D4 measured before S7 (26 ms). After round 6 (2026-11-09): the Merkle key is being built on `feat/dx-speed` (`ScanKeyContext`: each function hashed once, callees combined a level at a time) for the Scan proof cache, its first production user; a second key here would compete with it. NL-S3's formula memo keys on the CNF, not on `ProofCache.key`. Dense value IDs and a typed IR: not built without a measurement that shows a gain (the plan's condition) |
| H7 | 4 | done | b840f9c (`impl/round2-followups`); nightly lane, per-file ratchet 39 -> 33 warnings on the whole package |
| K7 | 3 | done | bca7fb3 (`impl/round2-followups`) |
| K9 | 3 | done | 2b3b7a1 (`impl/round2-followups`); the gate falls back to the temporary directory (sandbox) |
| K10 | 3 | done | 166d477 (`impl/round2-followups`); Linux located but not built or run |
| L11 | 5 | done | e972033; OperandTypeOracleTests: 529 values, 0 mismatches |
| L10 | 2 | not doing | plan: "do not start" |
| H10 | 4 | not doing | deferred by decision 14 (trusted-core change without a workload) |
| R12 | 5 | not doing | rejected in the plan |

## Baseline (before any change)

On the untouched branch (`916f918` plus the plan): `Scripts/safety-net.sh` green (339 tests in the inventory), and
`Scripts/test-lane.sh oracle` green (18 tests in 5 suites). The slow lane was not run as a baseline (release build of
the slow targets; disk was nearly full).

## Merges of main

- After Tier 0: main `2d56c71` (existentials as opaque values, and its own fix of R1's printing gap). Conflicts in
  `SILEncoder.swift` (kept main's `describe`), `TRUST.md`, the lint baseline (main's, plus this branch's delta) and
  the semantics version (both 8; now 9).
- After L1: main `13d0c44` (Scan proves correctness contracts). Conflicts in `SILEncoder.swift` (both summary helpers
  kept), `TRUST.md`, the lint baseline, the semantics version (now 12). Merge commit after `b0e04c3`.

- 2026-11-08: main `ccbd1dd` (round 2 merged into main: Spawn S2, SIL from stdout S3, byte scanning S6, check while
  testing S9, proof-cache tables C4, solver spans E0). Merge `2f0acf6`; K2 had to be restored in `emitSIL` in `e944e5b`.

## Helper branches (merged)

`impl/v7-pin-upgrade` (V7), `impl/docs-tier1` (U3, H8, R8, U15), `impl/walk-dx` (U4, U11, U13), `impl/dx-reports`
(U7, U8, U9, U5), `impl/validation` (V3, V5, V6, V9, R6, R9, L12), `impl/toolchain` (K3, K5, K6, K8, K11, K12, U14,
H6). Running at the time of writing: `impl/round2-followups` (K7, K9, K10, H7, U12).

The 2026-11-07 run stopped once on a full disk (ENOSPC); both helpers were stopped and resumed the next day.
