# Performance and developer-experience plan (2026-11-06)

What to change, how, why, what it is expected to buy, and which check proves it did not regress anything.
Built from five parallel investigations (engine profiling, Scan pipeline, front-end API and CLIs, Apple/swiftlang library survey, build/test/CI).
All measurements: Apple M4 Pro, macOS 27, Apple Swift 6.4, release unless stated. The machine was loaded (load average 7 to 22) while
other investigations built in parallel, so wall times are the minimum of 3 to 5 runs and are noisy; conflict and clause counts are exact.
**MEASURED** means a prototype was built and timed (on a scratch copy, never in this tree). **PROJECTED** means derived from a measured
profile share (Amdahl) without a prototype.

Raw reports, prototypes and profiles: a temporary scratchpad of the session
(`report-*.md`, `engbench/`, `frontbench/`, `inst/`, `*.sample.txt`, `ab-final.txt`, `bench-release.txt`). Scratch storage is temporary; copy what you want to keep.

Line numbers refer to the working tree as of 21:00 on 2026-11-06. `SFSIL` and `SFVerifyKit` changed after that (new `SILSummaries.swift`, `SILStringTests.swift`), so re-locate before editing.

## Status on branch `perf/dx-plan` (2026-11-06)

Done, each with the guard named in its row below, and checked first against `10b9287`, then again after merging main at `a169c55` (fast, slow and oracle
lanes, golden, metrics, CLI contract, portability, API, ratchets):

| Item | Result |
|---|---|
| G1 to G5 | `SampleSequenceTests` (seeded draws and enumeration order pinned), `Scripts/check-cli.py`, `Scripts/check-portability.py`, `Benchmarks/` |
| F1 to F7, F9 (sfverify only), F10 | Measured, release, before -> after: `verify` 1M inputs 157 -> 19 ms, with two properties 221 -> 54 ms, 3-field product 195 -> 28 ms; `verifyContracts` 100k 30 -> 8 ms; `Contract.requires` 1M 10.6 -> 1.8 ms; `partition` 100k/20k 41.2 s -> 15 ms (`docs/PERFORMANCE.md`) |
| X1, X2, X3, X7, X8 | Fixed. X1 and X2 each have a test that fails on the old code; X3 is guarded by building the tests with warnings as errors (CI); X7 by `Scripts/check-cli.py`; X8 is a README sentence (measured 0.08 s in release) |
| E3, E4 | Solver about 5 % faster; LRAT logs identical step by step to the old solver on 45 formulas |
| B1 to B4, B6 | `slow-dev` lane: 144 slow tests in about 40 s of test time; consistent release flags; API check gated in the safety net; CI hygiene; nightly warnings |

Deferred because `main` has uncommitted work in the same files (do them after it merges, re-measured first):
S1 to S3, S6, S7 (`SFVerifyKit/Verify.swift`, `Compile.swift`, `SILParser.swift`, `SILEncoder.swift`), F8 and X5
(`Pairwise.swift`), moving the oracle tests out of `SILAggregateTests.swift` (B5), and a stricter `sfgen` parser
(main adds `sfgen` flags that it would reject without a textual conflict).

Not done, for a reason:

- **E1, E2** (raw solver buffers, about -6 % and -5 to -14 % more): they need dozens of `Unsafe` uses, and the
  `unsafe_mentions_in_sources` ratchet (7) may only stay or fall. Raising it is the owner's decision.
- **E5** (checker by dense ID, check -32 to -43 %, about 3 to 5 % of a whole proof): it changes `SFCheck`, the trusted
  checker, and needs a second code path for sparse IDs from parsed text proofs. The owner's decision.
- **E6** (`Int32` hints): the proof is converted to the checker's `Int` format anyway, so both copies coexist at the
  peak; the projected saving does not hold.
- **B5 timing tests**: `timingTable` and `speedTable` also assert that the checkers accept every proof; gating them
  would drop that coverage.
- **S5**: done on `feat/dx-speed` (dx-and-speed plan, Phase 2): `SemanticsDigest.current` is computed once per process
  and is part of every Scan proof cache key.
- **X4**: already documented: `docs/guides/platforms.md` lists Scan (`SFSIL`, `SFVerifyKit`, `sfverify`) as macOS
  only, says the iOS build fails and why (`Process`), and CI does not build them for iOS. Nothing to fix.
- **E7, F11, F12, B7**: decisions (Phase 3).

## The short answer about Apple's libraries

Almost none of them should be adopted now. The wins are in this package's own code and configuration. Reasons, each verified:

| Library | Verdict | Deciding fact |
|---|---|---|
| swift-collections 1.7.x (`Heap`, `Deque`, `BitCollections`, `Ordered*`) | **Not now** | Every module links `@rpath/libswiftCompatibilitySpan.dylib` (via `InternalCollectionsUtilities`). A standalone CLI (`sfverify`, `swiftformal`, `sfgen`, or any downstream tool) then fails to launch on macOS 13 to 15 unless the dylib ships beside it ([swift-collections#732](https://github.com/apple/swift-collections/issues/732)). Our CLIs link it 0 times today. Also: `Heap` has no decrease-key/handle, so it cannot replace the VSIDS heap; `BitSet` cannot hold the solver's tri-state `values`; the trail already is a deque. Revisit at a macOS 26 floor. |
| swift-algorithms | No | Nothing hot uses its shapes (no index-to-value mapping or seeded draw); pulls swift-numerics. Copy a function if ever needed. |
| swift-argument-parser | No (in-house parser instead, item F9) | Every consumer clones and pins it even if only the library is used (verified with a git-URL consumer); `SwiftFormalGate` builds `sfverify` inside users' builds; its usage-error exit code is 64 where our contract says 2. A default-off package trait avoids the fetch, but needs tools 6.1 and two parsers. |
| swift-subprocess 1.0.x | No | Declares iOS `"99.0"`; the measured win (item S2) is available with Foundation. |
| swift-system | No | No path hot spot; the OS `System` module's `FilePath` already works at macOS 13. |
| swift-crypto | No | Re-exports CryptoKit on Darwin and adds swift-asn1; CryptoKit is already used and fast (3.8 ms per 10 MB). |
| swift-async-algorithms, swift-atomics, swift-numerics, swift-log | No | No need; async-algorithms also needs macOS 15 and pulls swift-collections. |
| swift-collections-benchmark | No | Needs macOS 15, 0.0.x, built for collection size curves. Use ordo-one/package-benchmark in a nested package instead (item B10). |
| swift-format (package) | No | Requires swift-syntax at least 604, which narrows our 600..<700. Keep the toolchain's `swift format`. |

Stdlib features at the macOS 13 / iOS 16 floor (from `utils/availability-macros.def` at `swift-6.4.2-RELEASE`, plus probes):

| Feature | Usable at macOS 13? |
|---|---|
| `~Copyable` types, `@inline(always)`, strict memory safety, `OSAllocatedUnfairLock` | Yes |
| `Span`/`MutableSpan` on `ContiguousArray`, `ArraySlice`, `UnsafeBufferPointer` | Yes, but may link the compatibility dylib: guard with item G3 |
| `Array.span`/`mutableSpan`, `InlineArray`, `UTF8Span` | No, macOS 26 |
| `Mutex`, `Atomic`, typed-throws function values used generically | No, macOS 15 |

## Ground rules every item follows

1. **The trusted core stays trusted.** `SFCheck` imports only Foundation, Swift and SFCNF (`check-layering.py`); SFCNF is frozen. No dependency enters either. The one SFCheck change (E5) is stdlib-only and pays its lines against the `check-ratchet.py` budget. `SFSemantics/S0.swift` (ratcheted semantics) is not touched.
2. **Determinism.** Each item is labelled:
   - **(a) order-preserving**: identical verdicts, conflicts, clauses, LRAT proofs and models; only time or memory changes. `metrics.py` must pass unchanged.
   - **(b) shape-changing**: the CNF or search changes. Needs `metrics.py --record` in the same commit with a reason, `check-golden.sh`, the slow and oracle lanes, and a decision about `ProofCacheVersions`.
   - **(c) behaviour-changing for users**: output or sampled sequence changes; CHANGELOG entry.
3. **No new dependency, no `unsafeFlags` on a product target, no platform floor raise.**
4. **Guards come first.** Phase 0 lands before anything it protects.

## Expected effect, by workflow

| Workflow | Today | After phases 0 to 2 (a only) | After phase 3 | Basis |
|---|---|---|---|---|
| `sfverify` on a small target (gate example) | 0.60 to 0.94 s | about 0.25 s | same | PROJECTED from measured per-spawn and temp-file costs |
| `Examples/Metrics` scan | 2.35 to 2.55 s | about 1.6 s | about 1.25 s | PROJECTED: overhead 0.6 s to 0.15 s; solver long pole 1.86 s to 1.45 s (a) or 1.02 s (a+b, MEASURED in harness) |
| Scan of a 3,840-function module | 14.3 s | about 4 s | same | PROJECTED from a 62 % measured share (contract matching) |
| Hard UNSAT proof (Prove API, live9) | solve 2.36 s, check 0.25 s | solve -11 %, check -32 % | | MEASURED in harness |
| Peak memory of a large proof (live10) | 834 MB | about -35 % | | PROJECTED |
| `verify` over 1M inputs, fast function | 162 ms release, 406 ms debug | 7.3 ms release, 81 ms debug | 2.3 ms release (`@inlinable`) | MEASURED |
| `partition` 100k inputs / 20k outputs | 43.4 s | 4.6 ms | | MEASURED |
| Engine tests in debug (SFSAT+SFProve) | 170 s | 2.6 s in the dev-optimize lane | | MEASURED |
| `Scripts/safety-net.sh` | includes 46 s `check-api` and about 54 s rebuild thrash | minus up to 100 s | | MEASURED |
| CI macOS minutes on PR pushes | | about -50 % | | PROJECTED |

## Phase 0: guards (do first, about one day)

| # | What | How | Why |
|---|---|---|---|
| G1 | Pin the seeded sample sequences | A test that records the first 64 draws of every `Domain` combinator and `Pairwise.rows` and compares them literally. Today only `run() == run()` is checked. | F1, F3, F7 must prove they keep users' sampled results identical; F11 must show exactly what it changes. |
| G2 | Golden table of CLI argv | For each of `sfverify`, `swiftformal`, `sfgen`: argv to (exit code, stdout, stderr). Nothing tests argv or exit codes now. | Guards F9 and the flag contract (ADR 0003). |
| G3 | No compatibility-Span dylib in shipped binaries | CI step: `otool -L` on each release CLI must not mention `CompatibilitySpan`. | Catches a dependency or `Span` use that would break macOS 13 to 15. |
| G4 | No `unsafeFlags` in the consumer manifest | CI step: `swift package dump-package` with `SWIFTFORMAL_DEV_OPTIMIZE` unset must contain 0 `unsafeFlags` (measured: 0 unset, 8 set). | Guards B1. |
| G5 | Wall-time harness, reported only | Nested `Benchmarks/Package.swift` (path dependency on the root, so users never fetch it) with ordo-one/package-benchmark: solver on mulCommutes32/live9, checker, a 1M-input `verify`, a synthetic 960-function scan. Nightly, uploaded, not gating. `metrics.py` stays the deterministic gate. | Every estimate below gets checked against a recorded number instead of a claim. |

## Phase 1: low-risk, order-preserving wins (about 3 to 5 days)

### Build, test and CI (no source behaviour change)

| # | What | How | Gain | Guard |
|---|---|---|---|---|
| B1 | **Dev-optimize lane** for engine tests in debug | In `Package.swift`: `let devOptimize = ProcessInfo.processInfo.environment["SWIFTFORMAL_DEV_OPTIMIZE"] != nil`, and for SFCNF, SFSAT, SFCheck, SFBV, SFProve, SFSemantics, SFSIL, SFLLVM add `.unsafeFlags(["-O"], .when(configuration: .debug))` only when set. `test-lane.sh engine` sets it and uses `--scratch-path .build/devopt`. The variable is the same pattern as `SWIFTFORMAL_DOCS`. | 170 s to 2.6 s; 107 s to 0.54 s; the README's discount example 23.6 s to 0.072 s (MEASURED). Debug penalty today is 10 to 40x for SAT-only tests and 140 to 340x for encoding tests (`CNFBuilder`'s `[[Int32]]` and `Dictionary<GateKey, Int32>` run unspecialized at `-Onone`). Engine tests could then join the fast lane (PROJECTED at most 25 s), but that needs an amendment to ADR 0004, whose fast lane is plain debug. Cost: +1.2 s per engine edit, +36 s CPU cold. | G4; release slow lane stays nightly. `-O` keeps `precondition`, overflow and bounds checks; there is no `assert`/`#if DEBUG` in the engine sources. |
| B2 | Same flags for every release build | Add `-Xswiftc -enable-testing` to the release `sfverify` builds in `check-golden.sh` and `metrics.py`; build once in `metrics.py` (it builds twice). | About 54 s per switch between safety net and slow/oracle lanes (MEASURED) | Verdicts and conflicts are deterministic. |
| B3 | Run `check-api.sh` in the safety net only when public sources change | Run if `git diff --name-only origin/main` touches `Sources/{SwiftFormal,SwiftFormalContracts,SwiftFormalTesting,SFProve}` or `SAFETY_NET_FULL=1`. CI keeps running it always. | 46 s warm, 79 s cold per run (MEASURED) | CI `api` job. |
| B4 | CI hygiene | `push` on `main` only (PRs run from `pull_request`); `concurrency` with `cancel-in-progress`; `timeout-minutes` (20, nightly 60); merge the small ratchet/links/hygiene jobs; `actions/cache` for `.build` keyed on OS, Xcode version, `Package.resolved`, `Package.swift`; one shared `-derivedDataPath` for the four iOS schemes; one `-warnings-as-errors` build instead of toggling. | About -50 % PR minutes, 30 to 60 s per job (PROJECTED) | Nightly stays uncached. |
| B5 | Lane hygiene | Move the 3 `encodingsAgreeWithNativeExecution` tests and `enumEncodingsAgreeWithNativeExecution` from `SFSILTests` to `SFOracleTests` with `.requiresPinnedCompiler`; gate `timingTable`/`speedTable` (7.4 s, prints only) behind `SF_BENCH`; tag `clampStaysInRangeAt64Bits` (9.8 s debug) `.slow`; `SILEnumTests.swift:204` writes `.sf-enum-<UUID>` into the working directory (the untracked folder at the repo root is one): use `NSTemporaryDirectory()`; `swift test list --skip-build` in the inventory check. | Slow lane about -27 s (MEASURED); about 3 s on inventory | `check-test-inventory.sh` |
| B6 | Pin the toolchain in nightly | `xcode-select` the pinned Xcode and fail if `swift --version` is not `swiftlang-6.4.0`. | Golden and oracle are green but empty on an unpinned compiler today. | The check itself. |

### Scan pipeline (all (a); none changes the CNF)

| # | What | How | Gain | Guard |
|---|---|---|---|---|
| S1 | Contract matching in linear time | `Verify.swift:385-386` scans all functions for each function with `functions.first {}` and recomputes `baseName` (`Compile.swift:30`, allocates) per comparison. Store `baseName` once; build `[baseName: [FunctionInfo]]` in array order; keep first-match semantics. | 3,840 functions: 14.3 s to about 5.4 s (PROJECTED) | `check-golden.sh`, `metrics.py`, a new overload-pairing test |
| S2 | One shared process runner | `Process.waitUntilExit()` costs about 66 ms per spawn on this OS (76 ms vs 8 to 10 ms with `terminationHandler` + semaphore; MEASURED). 13 call sites (`Compile.swift`, `Demangle.swift`, `SwiftPM.swift`, `Check.swift`, `SILVerify.swift`, `ProofDigest.swift`, CLI, SFLLVM). One `package` `ToolRunner` that drains stdout and stderr concurrently and waits by handler; also check `terminationStatus` in `xcrun(_:)`/`sdkPath()` (ignored today). | About 0.2 s per scan; gate -25 to 30 % (PROJECTED) | SFVerifyKitTests, golden |
| S3 | SIL through a pipe, not a temp file | `swiftc ... -o -` (SIL byte-identical at `-Onone` and `-O`, checked with `cmp`); drain stderr concurrently (otherwise more than 64 KB deadlocks). Also removes the temp dir that the gate's timeout `exit(1)` leaks (up to 30 MB). | Compile step about 0.4 s to 0.1 s on Metrics (MEASURED with S2) | golden with `--build`, a test with large stderr, one `cmp` in the oracle lane |
| S4 | Per-function `seconds` is always 0 | `Verify.swift:98`: the `defer` runs after `return` copied the struct. Set it before returning; update `docs/guides/scan.md:62`. Output value changes, schema does not: (c), CHANGELOG. | Correctness | Schema validation; golden already strips `seconds` |
| S5 | Memoize `SemanticsDigest.compute` before the cache is wired into Scan | 0.52 s per process (`ProofDigest.swift:148`). | 0.5 s per run once used | ProofCacheTests. Done (dx-and-speed Phase 2): computed once per process, in the Scan key |

### Front end (all behaviour-preserving)

| # | What | How | Gain | Guard |
|---|---|---|---|---|
| F1 | Tighten the `verify` loop | `Verify.swift` calls `slots.allSatisfy` and `slots.indices.dropFirst()` on every input. Hoist `domain.element`, map observers once, keep an `open` counter that drops when a slot first fails, break when 0. Same verdicts, same order. | 22x release (162 to 7.3 ms per 1M), 5x debug (MEASURED) | G1, existing tests |
| F2 | `Contract.requires` checks the condition first | `Contract.swift:23` reads a TaskLocal on every call although the doc says it costs nothing in release. Evaluate `condition()` first, read the recorder only on failure. | 11.0 to 2.4 ms per 1M calls (MEASURED) | release bench |
| F3 | One `Recorder` per walk | `Contract.swift:72-73` allocates a Recorder and binds a TaskLocal per input; reuse and reset. Also fixes the debug crash in F-bug 2. | About 130 ns per input (PROJECTED) | new crash test |
| F4 | Hashed `partition` | Additive overload `where Output: Hashable` (dictionary of group index); `Partition.swift:18` is O(inputs x groups). Same groups, same order. | 43.4 s to 4.6 ms (MEASURED) | partition tests, `check-api.sh` (additive) |
| F5 | Lock masking pre-check | `Lock.swift:144` runs a regex and a scalar walk on every output; check UTF-8 for `0x` / four `-` first. | 217 to 5.2 ms per 100k (MEASURED) | LockTests plus a UUID case |
| F6 | `evenlySpaced` overflow | Full-width multiply at `Domain.swift:60`. | Correctness | unit test |

### Bugs found along the way (fix with a failing test first, per ADR 0006)

| # | Bug | Where |
|---|---|---|
| X1 | `@Verify` + `#ensures` on a `throws(E)` function does not compile ("'any Error' cannot be converted") | `VerifyMacro.swift:77-82` |
| X2 | `verifyContracts` with `.deterministic()` crashes in debug when an `ensures` fails: the re-evaluation runs outside the recorder | `Contract.swift:86` (fixed by F3) |
| X3 | `@Verify` produces "immutable value was never used" warnings in user code (4 in `SwiftFormalContractsTests`); blocks `-warnings-as-errors` | VerifyMacro expansion |
| X4 | `SFSIL` and `SFVerifyKit` use `Process`, which does not exist on iOS, so they cannot build for the declared iOS 16 platform | `SILVerify.swift:23/42`, `ProofDigest.swift:75`; add `#if os(macOS)` or document macOS-only |
| X5 | `Pairwise.rows(levels:)` passes `Int.max`, bypassing the `pairTableLimit` memory guard | `Pairwise.swift:9` |
| X6 | Proof-cache digests differ between CryptoKit and the `fnv1a128-weak` fallback, and `String(reflecting:)` in the key depends on the runtime's format (misses, never stale hits). Scan's cache (dx-and-speed Phase 2) avoids both: it is used only with SHA-256 and hashes SIL text, not `String(reflecting:)` | `ProofCache.swift:171` |
| X7 | `sfgen` has no `--help` and accepts unknown flags (typo gives an empty run that exits 0); `sfverify` accepts `--budget 0` or negative; several flag combinations are silently ignored | CLIs (fixed by F9) |
| X8 | README says the 16-bit `proveSigned` discount example takes about 25 s in debug. That is correct: the same claim (`discountNeedsARangeAndThenIsProved`) took 23.6 s in debug and 0.072 s in release (`proveSigned` itself: 0.071 s release). Add the release figure and point readers to `-c release`; a 330x debug penalty surprises users. | `README.md:49` |

## Phase 2: engine internals, order-preserving (about 1 to 2 weeks)

Every item here was prototyped on a copy of the engine and A/B-checked on every case: identical `SolveStats`, identical `LRATLog` (each id, clause and hint), identical models, `LRATChecker` accepts. Zero mismatches.

Profile (mulCommutes32 / live9): `propagate` 56 / 62 %, `isRedundant` 10 / 9 %, hint sort 7 / 8 %, VSIDS bump 7 / 6 %, heap pop + backtrack 10 / 3 %; uniqueness checks of copy-on-write arrays are 10.5 % of all solver samples. Encoding is under 0.3 %, LRAT checking 9 to 17 % of a proof.

| # | What | How | Gain | Risk / guard |
|---|---|---|---|---|
| E1 | Solver arrays as owned buffers | `values, level, reason, trail, trailPos, activity, heap, heapPos, phase, seen, levelStamp, nodeStamp, unitID` become fixed-size buffers allocated in `init`, owned by a `~Copyable` solver with `deinit`; reuse the `isRedundant` stack. Removes 5 levels of `withUnsafe`/take in `propagate` and the COW checks. | -6 % (MEASURED) | Unsafe code in the untrusted solver: a bug crashes rather than forging a proof (the checker is independent). Keep debug bounds asserts; ASan run of SFSATTests. |
| E2 | Per-literal watch buffers | Pointer + count + capacity per literal, doubling growth, in-place compaction. Exact same visit and append order as `[[Watch]]` (required: watch order is not canonical). | further -5 to -14 % (MEASURED) | metrics.py exact |
| E3 | Sort only half the hints | The UIP part of the hint chain is already ordered; sort the minimization part and merge (`Solver.swift:549`). | 2 to 4 % (MEASURED) | identical LRAT |
| E4 | Reuse per-conflict scratch | `learnt`, `toClear`, `logAdd` copies. | at most 3 % (PROJECTED) | |
| E1 to E4 together | | | mulCommutes32 1.764 to 1.379 s (-22 %), discount proxies -15 %, live9 -11 % (MEASURED) | `metrics.py` unchanged, SFSATTests, SelfVerificationTests, SoundnessZooTests, slow lane |
| E5 | Checker indexed by clause ID | In `SFCheck/LRATChecker.swift`, replace `[Int: [Int32]]` + `Set<Int>` with arrays indexed by ID, sized by a pre-pass. Stdlib only. Must keep a bounded path for sparse IDs from parsed text proofs (binary search over sorted IDs; never reject a valid proof, never allocate by attacker-chosen ID). | check -32 % (live9), -43 % on small proofs (MEASURED); error values identical on injected corruptions | Trusted code: about +8 to 12 lines against the 282-line ratchet; `check-ratchet.py`, `check-layering.py`, `measure-trust.py`, checker fuzzing in SoundnessZooTests, LRATTests rejection cases. Review as a soundness change. |
| E6 | LRAT hints as `Int32` in `LRATLog` | Convert in `LRATBridge`; `LRATStep` in SFCheck unchanged. | peak RSS about -35 % (PROJECTED) | identical proofs |
| S6 | Byte-level SIL text preparation | `SILText.prepare` uses Foundation `range(of:)` per line (`Compile.swift:244`, `:301`) and joins lines that `SILParser.swift:328` splits again. Scan `utf8`; pass lines directly. | `prepare` 3 to 8x (MEASURED 619 to 60 ms on one step); -8 to -20 % wall on large inputs (PROJECTED) | Byte reading is the correct SIL lexing; differs only for a quote or slash followed by a combining mark. Fixture with a non-ASCII literal; metrics, golden, oracle lane |
| S7 | Parse each SIL body once | Bodies are parsed about 4 times (15,398 parses for 3,852 functions); cache parsed bodies (and errors) behind `OSAllocatedUnfairLock` (macOS 13), fresh cache when `replacingBody` copies the module; UTF-8 `stripComment`/`splitTopLevel` (266 to 20 ms). | parse CPU /4 or more; small on 14 cores, more on 3-core CI (PROJECTED) | SFSILTests (release), oracle lane |
| F7 | `@Finite` emits flat products for 2 to 4 fields | `FiniteMacro.swift:100` always nests. Index order and seeded draws checked identical. | 2.7x on top of F1 (MEASURED) | G1, macro expansion snapshots |
| F8 | Flat pairwise coverage table | `[[[Bool]]]` to one flat `[Bool]` (`Pairwise.swift:52`). Identical rows. | 1.4 to 1.8x (MEASURED) | G1 |
| F9 | Shared in-house CLI parser | A `package` module used by the three CLIs: `--flag=value`, `--version`, `sfgen --help`, strict integers, "did you mean", warnings for ignored combinations, static completion scripts, exit code 2. No dependency. Rejecting bad input that is accepted today is (c): CHANGELOG. | DX | G2 |
| F10 | Macro diagnostics | Anchor diagnostics to the offending node (today: column 1 of the attribute, no fix-its); reject `inout`, variadic, generic, `some` and isolated functions with a clear message (today they fail inside the expansion); fix-it `: <#Type#>`. | DX | `DiagnosticSpec` column tests |

## Phase 3: changes that need a decision

| # | What | Class | Gain | Why it needs a decision |
|---|---|---|---|---|
| E7 | **Build the overflow flag of `*_with_overflow` only when it is read** | (b) | mulCommutes32 1.76 to 1.19 s (-32 %), proxies -14 to -19 % with identical conflicts at widths 8, 9, 10 (MEASURED); with E1 to E4: 1.76 to 1.02 s (-42 %), still undecided at 20,001 conflicts | `S0.swift:244` always builds the 64-bit exact product for the flag, which `&*` discards: about 52k of mulCommutes32's 70,566 clauses. Construct the flag lazily, on the first `tuple_extract`/`destructure_tuple` of element 1, so any use forces it: sound by construction. **Never** use a use-analysis that defaults a missing flag to false: that hides a trap and is a false `proved` (P0). Keep the semantics in one checked place. Preferred: add a split or lazy form inside `S0` (value circuit now, flag circuit on demand) and pay its ratchet lines, so the exhaustive 8-bit `S0SlowTests` still cover it. If `S0` must stay untouched and `SILEncoder` builds the value with `c.mul` itself, add a new exhaustive 8-bit test of that encoder path with the flag unused and with it used-and-trapping. Either way add a ScanZoo case where the flag is used and must trap. Emission order changes, so `discount`/`cellIndex` conflicts may move: `metrics.py --record` with the diff reviewed. Bump `ProofCacheVersions` even though the cache stores only `proved` and replayed counterexamples: it costs one round of misses, and it lets a later rollback of E7 invalidate `proved` results produced by the lazy encoder. |
| F11 | `@inlinable verify` | API/ABI | another about 3x in release on top of F1 (PROJECTED) | Freezes internals; the SPI `Property.Observer` blocks it, so it needs a `@usableFromInline` wrapper. `check-api.sh` behaviour with it needs verification. |
| F12 | Opt-in unbiased sampling / without replacement (in-house Lemire + Feistel; not `Int.random(in:using:)`, whose algorithm may change) | (c) only when opted in | coverage: 1M draws over a 1.2M domain cover only 56 % today | New option, default unchanged; also document that `union` picks a part and `arrays` a length uniformly. |
| B7 | Move `SFGenKit`/`sfgen` to a nested package | breaking | cold CPU up to -47 %, -11 s wall (MEASURED upper bound): swift-syntax prebuilts are disabled because a non-macro product uses swift-syntax | Changes the documented install path (`--product sfgen`) and the SFGenKit product. Defer to a minor release. |
| X4 | iOS story for SFSIL/SFVerifyKit | decision | | `#if os(macOS)` versus declaring them macOS-only. |

## Phase 4: deferred until the platform floor is macOS 26 / iOS 26

swift-collections (`HeapModule`/`DequeModule` only, behind G3), `InlineArray` for small fixed tuples, `Array.span`, `UTF8Span` for the SIL reader, `Mutex` instead of `NSLock`. None has a measured hot spot that today's alternatives cannot reach.

## Rejected, with reason

- `unsafeFlags` on product targets, even gated by trait or configuration: SwiftPM rejects the package for remote consumers (measured).
- `-O` on test-only targets: allowed, but the slow code is in the engine modules.
- SwiftPM traits for optimization: 6.4's `SwiftSetting` has no optimization setting.
- `@inlinable`/`@_specialize` to speed up debug: nothing is specialized at `-Onone`.
- `-Ounchecked`, `-enforce-exclusivity=unchecked`: unsafe flags, and they remove safety checks.
- Smaller problem sizes in debug tests: weakens soundness coverage.
- Search-heuristic tuning: speculative (b); deciding `mulCommutes32` fails `metrics.py` on purpose.
- Cone-of-influence pruning of the whole CNF: sound for `proved`, but counterexample validation would then depend on the pruner. E7 gets the measured gain without that.
- Swift `Regex`/`firstRange(of:)` in the SIL reader: measured slower than the Foundation code it would replace.
- Type-check tuning: one function over 100 ms (195 ms).

## Suggested order

Other sessions are changing `Verify.swift`, `Compile.swift`, `SILParser.swift` (+421 lines) and `SILEncoder.swift` (+306) right now. Land S1 to S3, S6, S7 and E7 after that work merges, and re-measure the Scan numbers on the new tree first: the "each body parsed about 4 times" finding and the `prepare` share may change with a parser that large. The engine items (E1 to E6), the front-end items and the build/CI items are largely independent of it.

1. Phase 0 (G1 to G5).
2. B1 to B6 and X1 to X8 (each bug with its failing test first).
3. S1 to S5, F1 to F6.
4. E1 to E6 one per commit, each with `metrics.py` unchanged and the slow lane run; E5 reviewed as trusted code.
5. S6, S7, F7 to F10.
6. Decide E7, F11, F12, B7, X4.
