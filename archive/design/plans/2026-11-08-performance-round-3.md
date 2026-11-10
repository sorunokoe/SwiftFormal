# Performance, round 3

Branch `perf/round-3` (worktree `../SwiftFormal-round3`), from main at 21cb1a8. Rule as before: every change keeps
verdicts identical. Evidence: the JSON reports of main's and the branch's `sfverify` (timings removed) on the same
inputs, golden verdicts, solver metrics, the test lanes.

## Where main stands (measured 2026-11-08, M4 Pro, release builds, best of 3)

Round-2 tip (ccbd1dd) against main (21cb1a8), same inputs:

| Run | Round 2 | Main |
|---|---:|---:|
| `sfverify` on one file (quiet machine) | 0.17 s | 0.52 s |
| `sfverify --budget 1000 Examples/Metrics/*.swift` (quiet) | 0.22 s | 0.99 s |
| `sfverify --package Examples/GatedPackage --target Kernels --build` | 3.0 s | 3.0 s |
| `sfverify --package . --target SFSIL --build` | 10.1 s | 217 s |
| `sfverify` on a generated module of 8,192 functions | 8.3 s | 148 s |
| `swiftformal check` on `Examples/Walk` | 2.8 s | 7.9 s |

The 8,192-function module gives the same verdicts in both. Its time is in `verifySeconds` (1.4 -> 142.7 s), not in
compiling or parsing.

## Findings (reviews of ccbd1dd..21cb1a8 plus profiles)

| Id | What | Where | Evidence | Fix (same results) |
|---|---|---|---|---|
| R1 | R5's `recheck` renders the whole callee closure (every witness first, each function through `Mirror`) of every open function, in both modules, serially | `SFVerify.recheck`, `ProofCache.closureText` | Sample of k8192: Mirror, dynamic casts, string building | Render each function's part once per module, in parallel; diff the modules once; a function changed iff its closure in the first module reaches a changed part (a changed witness changes all). `closureText` (the cache key) unchanged |
| R2 | R5 compiles the second configuration after the first is compiled and verified; it links the imports and runs both type-name probes again | `SFVerify.run`, `TypeNameCheck` | Code; small runs 3-4.5x slower | Compile the second configuration on its own thread while the first compiles and verifies; memoize `dependency` (serialized: it may run `swift build`); cache type-name probes per process |
| R3 | `swiftformal check`: the scan's `swift build` waits for the test build's SwiftPM lock, so round 2's overlap is gone; cold, the target is rebuilt with `-j 1` | `SwiftFormalCLI/main.swift` | Review; trace to confirm | Start the test build after the scan's plan returns |
| R4 | Whole-module text scans with character search in `init` and in every `link` (deinit callbacks, issue reporters), and `willThrow` per instruction line | `SILClosures.swift`, `SILPackageTypes.swift`, `SILParser.swift` | Micro-benchmark: 0.7 + 0.4 s per 22 MB, 30-60x by bytes | Byte search as a prefilter, the existing character check confirms each hit (identical both ways) |
| R5 | Saved compile commands miss after a build of another target (description changes), causing extra `swift build`s and `-j 1` rebuilds | `SwiftPMSavedCommand.swift`, `SwiftPM.swift` | Review | MEASURE-FIRST: count builds on a warm run with two local dependencies |
| R6 | Full-name demangle still spawns `swift-demangle` | `Demangle.swift` | Review | MEASURE-FIRST: `swift_demangle_getDemangledName` in process, byte-identical on a corpus |
| R7 | L7 specialization text rebuilt on every `function(key)`; `resolve` uncached; dictionary literal keys re-parse the enclosing function | `SILGenerics.swift`, `SILParser.swift`, `SILLiteralKeys.swift` | Review | MEASURE-FIRST: memo per encoder |
| R8 | `Table`/`Property.table` looks rows up linearly per input (slope 2.0) | `Properties.swift`, `PropertyTypes.swift` | Scaling baseline | `Hashable` overloads building a dictionary once, first row wins |
| R9 | `@Verify mutating` copies `self` on every call even when no closure reads `old`; `Contract.ensures` formats the result on every failing call | `VerifyMacro.swift`, `Contract.swift` | Review | Skip the copy when `old` is unreachable; format only when it is read |
| R10 | Smaller: toolchain probes in sequence, `dump-package` per run, `--confirm` cold per run, cross-check IR emitted late, build-log parsing per module | various | Review | After the above, if measured |

Not this round: D4 (the proof cache is still not used outside tests; since done in the dx-and-speed plan, Phase 2), S7 (parse each body once; R7 covers the hot
part), Tier 3 search changes.

S7 was done since, on the Swift-internals branch `impl/unblock` (it unblocks H1, H5 and H9 there): `SILModule.function`
caches parses, reset on any change to the module; 2,014 generated functions: verify 0.83 to 0.62 s, CPU 11.6 to 8.7 s.

## Order

R1, R2, R3, R4 (the regressions), then R5-R9 measured first, then R10. One commit per fix; main merged into the branch
after each large fix.

## Status (2026-11-08)

| Id | Result |
|---|---|
| R1 | Done on main by the other session the same way (`ClosureComparison`, 1eaa769); this branch's version dropped in the merge |
| R2 | Done: second configuration compiled on its own thread; imports asked once; type-name probes concurrent and kept per process (keyed by compiler too). A race in it (the thread held the lent `linking` closure past `value()`, so a compile error could trap) was caught by the CLI contract check and fixed (25004f0) |
| R3 | Measured, not changed: moving the test build after the scan's plan saved nothing (three SwiftPM runs, ~2.3 s each, stay serial). One `swift build --build-tests -v` read by the scan would save ~1.7 s warm; it changes how saved commands are keyed, left to the owner |
| R4 | Done: byte search confirmed by `contains` (deinit callbacks, issue reporters, `willThrow`); `SILModule(text:)` 0.47 -> 0.10 s |
| prepare | Found while measuring R4: `ContractFailureCall.kind` and `location(in:)` per line; 0.97 -> 0.38 s |
| R5 | Not reproduced for `sfverify --build` (Walk; SFSIL with six linked targets): warm runs reuse the saved command. `swiftformal verify` over several targets in a row, the reviewer's first case, was not measured |
| R6 | Measured: no `swift-demangle` spawn on these runs; nothing to do |
| R7 | Not done: the remaining verify time is encoder and solver work (two configurations); left with Tier 3 |
| R8 | Done: `Hashable` table overloads; 8,192 rows about 9 s -> 3 ms |
| R9 | `Contract.ensures` formats only where it is used: done. `@Verify mutating` copy elision: not done (only when every closure writes `_` for `old`; changes code Scan reads) |
| R10 | Concurrent SDK probes measured at ~10 ms, reverted. A disk cache of `-print-target-info` (~0.1 s per run) is a possible next step |

Also: the scaling harness did not compile on main (`SILText.Prepared`); fixed.

## Follow-ups (2026-11-08, branch `perf/round-3-followups`)

| Item | Result |
|---|---|
| Parallel rendering in the recheck | Done: `ClosureComparison.prepare`; k8192 13.2 -> 10.6 s, SFSIL `--build` 10.3 -> 8.6 s |
| `check` with one SwiftPM run | Done: `swift build --build-tests -v` once, the scan planned from its log (`plan(fromTestsBuild:)`); warm 7.2 -> 4.6 s, cold unchanged |
| `verify` over several targets | Measured: the first run after another kind of build rebuilt each target with `-j 1` (17 s for two). Done: one `swift build -v` for two or more targets in a built package; 4.6 -> 3.5 s after a `swift build` |
| R7 encoder caches | Not done: no workload or profile shows generics, dictionary literals or `resolve` in the time; left with the solver work |
| Compiler answers on disk | Done: `ToolchainInfoCache`, keyed by the compiler file's identity and the toolchain environment; one file 0.28 -> 0.17 s |
| `@Verify mutating` copy | Done: no copy when every `#ensures` names `old` `_` |
