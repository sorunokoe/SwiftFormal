# Swift-internals plan: soundness, coverage, toolchain, architecture, DX (2026-11-07)

What to change in SwiftFormal next, read against the Swift compiler and standard library themselves
(swiftlang/swift at tag `swift-6.4.0-RELEASE`, commit `b8189d7`, the open-source tag of the pinned
`swiftlang-6.4.0.34.1`). Six investigations ran in parallel on scratch copies of `main` at `d759be7`: Scan's coverage
of SIL, the toolchain and build systems, the standard-library summaries, validation against the compiler and pin
upgrades, the pipeline architecture, and the user's experience. Their full reports, with every command and number, are
in [`archive/research/2026-11-07-swift-internals/`](../../../archive/research/2026-11-07-swift-internals/README.md).

This is the third plan in the series. Round 1 is [2026-11-06-performance-and-dx.md](2026-11-06-performance-and-dx.md);
round 2 is `2026-11-07-performance-round-2.md` (untracked in the main checkout when this was written). Their items
(G, B, S, F, X, E, C, W, P, D, T, N, A) are **not repeated**. Rows below that build on one name it in "Builds on".
Rounds 1 and 2 were about speed. This round found that speed is not the limit: on this repository's own engine
targets 64 to 88 % of functions are `unsupported`, and every decided function needed at most 1 conflict (MEASURED).
The limits are **what Scan can read**, **whether what it claims is true**, and **how the tools meet the toolchain**.

Labels, as before: **MEASURED** (run, numbers given), **VERIFIED** (read in source, cited), **PROJECTED** (estimate).
Classes: **(a)** same output, time or memory only; **(b)** changes the CNF or the search; **(c)** changes what users
see. Effort: S under a day, M 1 to 5 days, L over a week. Swift sources are cited as `path:line@6.4.0`.

## Headline findings

1. **Four false `safe` results** (R1, R2, R3, V1). Scan proves a function `safe` and the same code built natively
   traps. Three come from standard-library summaries; the fourth from ignoring the `deinit` of a `~Copyable` type, found
   by feeding the compiler's own test corpus to Scan. Each was reproduced twice: by the investigation, and again by the
   plan's author with a release `sfverify` built from `d759be7` (exit 133 natively in every case). Per
   [ADR 0006](../../decisions/0006-soundness-policy.md) these come first.
2. **The compiler pin is never checked on the Scan path** (K2/U1, VERIFIED by grep: nothing outside
   `Sources/SFSIL/CompilerPin.swift` calls `PinnedCompiler.check`). [TRUST.md](../../TRUST.md) says other compilers
   "fail closed"; they do not.
3. **A Scan `safe` at `-Onone` does not carry to the release build** (R5, reproduced): an `assert` with a side effect
   gives `safe` at `-Onone`, and the `-O` binary traps.
4. **Coverage, not opcodes, is the bottleneck.** The parser accepts 62 of the 232 instruction kinds of `SILNodes.def`,
   but only 35 % of refused functions contain an unknown opcode. The rest are refused by a type (`Double`, a class,
   `Dictionary`), a restricted shape, or a missing summary. Treating floats as opaque values alone moved 133 functions
   from `unsupported` to a verdict, 0 lost (MEASURED).
5. **Swift Testing 6.4 removes Walk's oldest limit on macOS and Linux**: exit tests turn a trap into a
   `counterexample` with the real input (U4, prototype at the macOS 13 floor, about 0.1 s per walk).
6. **Several documented limits are stale or wrong**: KNOWN-ISSUES #2 (macro targets) mostly works now; TRUST.md says a
   second encoder "is not built" but SFLLVM is one, as an oracle-lane test; the README install line builds one product
   of three.

## Tier 0: soundness and the trust ledger (do first)

Every fix starts with a failing SoundnessZoo case and a native replay that traps (ADR 0006). The fixtures are in the
archive folder (`fixtures/`).

| ID | Finding | Where | Fix | Evidence | Class | Guard | Effort |
|---|---|---|---|---|---|---|---|
| R1 | `describe()` (`String(describing:)`, interpolation) ignores the stdlib's `Mirror` fallback, so a trapping `description` of a struct field, enum payload or `customMirror` is missed | `SILEncoder.swift:780-803`; `OutputStream.swift:302-483@6.4.0`, `Mirror.swift:584-587@6.4.0` | Follow the stdlib's order: for a module type without a printing witness, describe every stored field, payload and tuple element; refuse `CustomReflectable` types and classes | MEASURED, reproduced: `describeWrap` is `safe`, native exit 133 | (b)(c) | Zoo cases `describeWrap`, `describeEnum`, `interpWrap`, `describeReflect` with native replay | S |
| R2 | `hashRawValue` runs the `rawValue` getter and never hashes the result; the stdlib does `hasher.combine(rawValue)` | `SILEncoder.swift:750-756`; `CompilerProtocols.swift:196-199@6.4.0` | Call `hash(rawType, result)` on the getter's result | MEASURED, reproduced: `Outer.hash(into:)` is `safe` while `Key.hash(into:)` is `may trap`; native exit 133 | (b) | Zoo case `Outer`/`RR`/`Key` with replay | S |
| R3 | `DefaultStringInterpolation.init(literalCapacity:interpolationCount:)` is summarized as never trapping; its body has overflow-checked `+` and `*` | `SILSummaries.swift:86`; `StringInterpolation.swift:74-79@6.4.0` | Encode both checked operations as traps (compiler-emitted calls pass literals, so nothing changes there) | MEASURED, reproduced: direct call with `Int.max` is `safe`, native exit 133 | (b) | Zoo case with replay | S |
| V1 | A `~Copyable` struct with a `deinit` is read as a plain struct; `destroy_addr`/`release_value` of it is ignored, so a function that consumes one is `safe` even when the `deinit` traps. Also through containment (`struct Wrap: ~Copyable { var g: Guard }`, an enum payload) | `SILParser.swift:730-773` (`scanDeclaration` never looks at `deinit`), `:1218-1225` (destroys are `.ignored`), `:351` | Fail closed: a struct or enum whose SIL declaration has a `deinit` member goes to `types.rejected`; containing types follow because field resolution fails. Later: encode the destroy as a call to its `…fD` deinit | MEASURED, reproduced: `consume(_ g: consuming Guard) -> Int32 { 1 }` with `deinit { precondition(x > 0) }` is `safe`; native `consume(Guard(x: 0))` exit 133. Found through `test/SILOptimizer/devirt_deinits.swift@6.4.0` | (c) | Zoo case + SFSILTests fixture (expect `unsupported`); bump `semantics` | S |
| V2 | Reader crash on a repeated block label: `Dictionary(uniqueKeysWithValues:)` traps before the guard meant to throw (same bug class as KNOWN-ISSUES 3 in SFLLVM) | `SILEncoder.swift:58-59` | `uniquingKeysWith:` and keep the guard, or reject duplicates in `parseFunction`; add the mutation to ParserFuzzTests. Needed before the next pin, whose `debug_value … transform { bbN: … }` nests block labels | MEASURED: 12-line SIL with `bb1:` twice, exit 133 | (a) | Fuzz case + unit test | S |
| R4 | The "no array holds 2^48 elements" assumption is applied to unknown inputs only; counts computed by `repeating:`, `+`, `append`, `insert` are never capped | `SILEncoder.swift:589-635`; `GenClass.cpp:836@6.4.0`, `Heap.cpp:85-102@6.4.0` | Trap on `count >= 2^48` at every count-producing operation (every element takes at least a byte; no process allocates 2^48 bytes) | MEASURED: `Array(repeating:count:)` with `requires n >= 0` is `contractHolds`; natively it aborts from 2^44 ("failed to allocate", exit 134); `appendWrap(Int.max)` gives a counterexample that does not replay | (b)(c) | Zoo `makeCount`, `appendWrap` | S |
| R5 | `-Onone` is not a superset of release traps: a removed `assert` can change state | `Assert.swift:44-56, 318-387@6.4.0`; `SILOptions.h:209-221@6.4.0` | `sfverify --config debug\|release\|both`: compile again with `-assert-config Release` (still `-Onone`, same readable SIL) and re-verify only functions whose SIL differs; `safe` only if safe in each requested configuration; refuse `-Ounchecked` | MEASURED, reproduced: `g` (`assert(a.popLast() != nil)` then `10 / (a.count - 1)`) is `safe`; the `-O` binary traps. 28 of 119 SFCNF functions differ between configurations | (c) | `as.swift` as a zoo case; `check-cli.py` rows | M |
| K2 | The pin is not enforced, and `--build` re-resolves `swiftc` through `xcrun` instead of using the one SwiftPM ran | No caller of `PinnedCompiler.check` in `SFVerifyKit` or the CLIs; `SwiftPM.swift:159-160`, `Compile.swift:153` | Resolve the toolchain once per process (the log's `swiftc` path wins), check it against the pin, use it for every spawn; `--allow-unpinned` stamps the report; the gate has no override. Print the compiler in text and JSON (additive key) | VERIFIED; MEASURED that `DEVELOPER_DIR` and an unknown `TOOLCHAINS` switch or fall back silently | (c) | Injected `CompilerToolchain` tests (pinned, unpinned, allowed); `check-cli.py`; schema | S |
| R7 | The summary table is not part of `SemanticsDigest`, so fixing R1 to R4 invalidates no cached proof unless someone bumps `SILFrontendVersion.semantics` by hand | `ProofDigest.swift:147-152` | Hash a canonical dump of `StdlibSummary.table` into the digest | VERIFIED | (a) | ProofCache test: a table edit changes the digest | S |

**Owner decision needed with K2** (the pin has one entry): fail closed everywhere, or fail closed in the gate and warn
and stamp in `sfverify`/`check`. Either way a pin-update process (V7, R6) has to ship at the same time, or every
gate breaks on the next Xcode point release.

## Tier 1: things users are told that are not true (S each)

| ID | What | Evidence | Fix | Guard |
|---|---|---|---|---|
| K1 | `sfverify --build` and `swiftformal check` fail on a cold build when a linked target has its package's name: `removeProducts` deletes Swift Build's whole `Intermediates.noindex/<Package>.build` | MEASURED: 2 of 2 cold runs exit 2 before, 2 of 2 pass after a 6-line patch (`SwiftPM.swift:101-123, 204-207`); this repo's `SwiftFormalContractsTests` fails the same way | Match only `<t>-t.build`, `<t>-p.build`, `<triple>/<config>/<t>.build`; drop `-const-gather-protocols-list` and other build-file-only flags | Unit test on a fake scratch tree; oracle-lane cold run on a two-target fixture |
| U2 | The gate's stamp file becomes a resource: users' gated targets gain a `*.bundle` and a `Bundle.module` accessor, which Scan then counts as two unsupported functions (GatedPackage coverage 50 % instead of 100 %) | MEASURED, fix measured: write the stamp as a comment-only `<Module>.sfgate.swift` | as left | `check-examples.sh` asserts no bundle and no accessor |
| U3 | README install line passes three `--product` flags; SwiftPM builds only the last | MEASURED: only `sfgen` built, exit 0 | One `--product` per line | `check-examples.sh` runs the README's install lines verbatim |
| L13 | The coverage classifier calls 236 of its 264 "array" refusals arrays when they are dictionaries (`hasPrefix("[")` is tested before `[K : V]`); 42 array refusals are filed as existentials | MEASURED, `Verify.swift:199-232` | Reorder; one test per category | Golden re-recorded with reason |
| U6 | Generated code counts as hand-written (resource accessors, `@Observable` expansions, derived conformances): a 2-function `@Observable` target reports 15 hand-written functions, coverage 20 % | MEASURED | Optional `origin` key decided from structure (path under `.build`/`DerivedSources`, `@__swiftmacro_` file, implicit flags), never from names alone; keep entries for `check` and the gate | Golden; a test per origin |
| U10 | A mistyped `--target` reports `COMPILER FAILED`/`INVALID SIL`; a multi-module target without `--build` gives "no such module" with no hint | MEASURED | Name the targets; suggest `--build` | `check-cli.py` rows |
| K4 | KNOWN-ISSUES #2 is mostly stale: toolchain and SDK macros (`@TaskLocal`, `@Observable`, `#Predicate`) compile without `--build`, package and Testing macros with it. Still open: `import Testing` in loose-file mode (3 flags fix it) and package macros in loose-file or gate mode | MEASURED | Add `-plugin-path <toolchain>/lib/swift/host/plugins/testing`, `-F`/`-I` for the platform's Developer dirs; rewrite #2 | Fixture: loose `@Test` file compiles to SIL |
| H8 | TRUST.md says a second encoder "is not built"; SFLLVM is one, written independently (`LLVMEncoder.swift:19-21`), checked by `proveEquivalentToSIL` in the oracle lane on scalar kernels | VERIFIED | Correct TRUST.md; settle [ADR 0008](../../decisions/0008-sfllvm-status.md) on option 2 (frozen, test-only oracle); do not share an encoder with SIL, which would remove the independence | `check-links` |
| R8 | At `-Onone`, every summarized call runs the OS's `libswiftCore`: Release-built, and Swift 5.7 at the macOS 13 floor, not the 6.4 source the summaries were audited against | VERIFIED (49 of 51 summary symbols exported in `libswiftCore.tbd`) | Say so in TRUST.md; R6's optional `--source-tag swift-5.7-RELEASE` review | `check-links` |
| U13 | A failed `#ensures` in Walk does not show the returned value | VERIFIED, `Contract.swift:36-38` | Append `(result: …)` | Contracts snapshot test |

## Tier 2: what Scan can read next (ranked by measured frequency)

Measured on 1,988 functions with a body in 11 of this repository's targets, `-Onone`, 1,281 refused. Counts are upper
bounds from a per-function scan of every blocker (not the first-reason histogram, which shows loops in 2 functions
while 173 contain one); only floats were calibrated against a real run (133 measured against 144 predicted). The corpus
is engine code, so classes, `Double` and `Dictionary` are over-weighted against app code.

| ID | Gap | Only blocker | Also needed by | Model (sound by construction) | New trusted-core lines | Effort |
|---|---|---|---:|---|---|---|
| L1 | Floating point | 144 | 289 | Tier 1a: carry IEEE bits as leaves; arithmetic gives fresh values recorded as approximations (FP builtins never trap). Tier 1b: exact `float_literal`, bitcasts, `fneg`, the 16 `fcmp_*`; `fptosi` adds `undefined` for NaN or out of range. SymFPU-style circuits only if users need FP-dependent traps decided | 1a: 0; 1b: about 80 in S0 | S, then M |
| L2 | `Dictionary`/`Set` | 179 | 502 | Count-only opaque values like arrays; each hashing call runs the module's own `hash(into:)`/`==` on unknown keys. **Must keep three traps** or it gives a false `safe`: duplicate literal keys (`Dictionary.swift:880@6.4.0`), duplicates in `init(uniqueKeysWithValues:)` (`NativeDictionary.swift:823-825@6.4.0`), and `hash`/`==` disagreeing (`:458,487,557`) | 0 | M |
| L5 | Classes (narrow) | 107 | 406 | `self` the only reference; fields as state; `alloc_ref` fresh; releases through the deinit audit; nested `begin_access [dynamic]` conflicts encoded as traps. Never treat `[dynamic]` as `[static]` | 0 | L |
| L10 | Indirect enums | 44 | 221 | Refuse, with a better reason | 0 | do not start |
| L7 | Calls to user generics at `-Onone` | 42 | 96 | Monomorphise at the call site from the substitution map; resolve `witness_method` through the module's tables; fail closed on conditional or inherited conformances and existential substitutions. Never "for all T" | 0 | M |
| L6 | Throws | 13 | 376 | `try_apply` as a second exit; typed errors exact; `any Error` an opaque box through the deinit audit; `willThrow` a no-op | 0 | M |
| L3, L4 | Loops and `for-in` | 5 | 173 | (1) header invariant `true`; (2) 2-induction, because `-O` LoopRotate moves the exit test to the latch; (3) bounded unrolling with an unwinding check for real counterexamples; a failed step is `undecided`. `for-in` at `-Onone` calls generic `makeIterator`/`next` (desugared in Sema, `SILGenStmt.cpp:1555@6.4.0`): exact summaries for `Range`/`ClosedRange`/`stride`/`enumerated`/`indices` iterators. `SILVerifier.proveLoopFunction` (`SILVerify.swift:470`) already cuts at headers | 0 | M each |
| L8 | Small S0 set: plain `trunc`/`zext`/`sext`, 128-bit width, `int_ctlz/cttz/ctpop/bswap`, `assumeNonNegative` (identity, `undefined` if negative), generic builtin syntax (`getEnumTag<T>`, 94 sites) | | | One `S0Op` per family, interpreter and circuit side by side | about 60 in S0, plus 128-bit SFBV support | S |
| L9 | `hashValue` getters (`_hashValue(for:)`), mostly synthesized `CodingKeys` | 40 first-reason | | Run `T.hash(into:)` with an opaque `Hasher`, fresh `Int` | 0 | S |
| R10 | Strings: only Unicode-version-independent facts | | | Ghost `utf8Count`: exact for literals and `+`; `isEmpty` iff `utf8Count == 0`; `0 < count <= utf8Count` when non-empty. MEASURED false and therefore never to be added: grapheme-count additivity (regional indicators give 1 + 2 = 2), `==` implying equal UTF-8 counts (`é` composed vs decomposed), case mapping keeping counts | 0 | M |
| R11 | `Hasher()` and `finalize()` as non-trapping rows (after R2) | | | No `_precondition` or `fatalError` in `Hasher.swift@6.4.0` | 0 | S |

Floats as opaque values were prototyped (one line): SFSAT 85 of 156 and SFVerifyKit 48 of 516 functions got a verdict,
130 `safe` and 3 `mayTrap`, nothing previously decided changed. The loop prototype (invariant `true`) proved 3 of 4
safe `-Onone` while-loops, never the overflowing one, and none of the `-O` loops (2-induction needed).

Compiler facts that shape this roadmap (each tried on the installed compiler):

| Fact | Evidence | Consequence |
|---|---|---|
| `-emit-sil` output is canonical, **not OSSA**, at `-Onone` and `-O` (OwnershipModelEliminator runs in both pipelines) | `PassPipeline.cpp:1031, 1100@6.4.0`; 0 `[ossa]` functions measured | Drop every OSSA instruction from the roadmap |
| Static exclusivity conflicts are compile errors; what remains is `[static]` or `[dynamic]` | `AccessEnforcementSelection.cpp:52,59@6.4.0`; `docs/SIL/Instructions.md:1521-1575@6.4.0` | `[static]` as an alias is justified; `[dynamic]` is a runtime trap point (L5) |
| DefiniteInitialization leaves no reads of uninitialized memory | `docs/SIL/SIL.md:95-98@6.4.0` | The encoder's uninitialized-slot refusal stays as a fail-closed backstop |
| No option prints module-qualified type names in SIL bodies; `FullyQualifiedTypesIfAmbiguous` covers only witness tables, vtables and `witness_method` | `SILPrinter.cpp:5121-5135, 2756, 4483-4772@6.4.0`; MEASURED with `-sil-print-types` and `-sil-full-demangle` | `TypeNameCheck` stays (0.06 to 0.23 s) |
| `-sil-link-all` does not exist in 6.4; only the performance pipeline links everything | `SILModule.h:174-180`, `Linker.h:157@6.4.0` | Stdlib bodies only through `-O -Xllvm -sil-print-after=performance-linker` (R6, R12) |
| `@_semantics` and `@_effects` are promises to the optimizer, not about traps | `docs/ReferenceGuides/UnderscoredAttributes.md`@6.4.0 ("violating … is undefined behavior"); its own `readnone` example traps on a bad index; `array.mutate_unknown` is shared by 16 functions | Never a summary source; only a fail-closed cross-check (R9) |
| `-enforce-exclusivity=unchecked` and any `-assert-config` other than the user's change the program | MEASURED | Never use them to make reading easier |
| `-sil-verify-all` works on the release compiler (+40 % compile) | MEASURED | Optional `--paranoid` (L12); it checks the compiler, not our reader |
| `-Xllvm -sil-print-types` prints each operand's type | `SILPrinter.cpp:90@6.4.0` | L11: cross-check the parser's inferred types; adopt together with round 2's S6 |

## Tier 3: toolchain and build systems

| ID | What | Evidence | Gain | Class | Effort | Builds on |
|---|---|---|---|---|---|---|
| K3 | Key the compile-arguments cache on Swift Build's build-description id (last line of `XCBuildData/prior-build-descriptions.txt`), instead of deleting products and rebuilding | MEASURED: stable over null builds and `touch`; changes on a new define, an added file, a different target. SwiftPM 6.4 builds with Swift Build by default; the native system's `debug.yaml` has full `args` | 15 to 20 s cold, 1 to 3 s warm per scan; no stale hit possible | (a) | S-M | P1, K1 |
| K9 | One implicit module cache per toolchain for every Scan compile | MEASURED: `-emit-sil` of a target importing Foundation with a fresh cache 21 to 30 s, warm 0.11 s | First scan in a fresh CI job or plugin work dir about -20 s | (a) | S | S3 |
| K5 | `swift package scan` command plugin on the user's own `.build` (`packageManager.build(..., logging: .verbose)`, hand `logText` to `sfverify --build-log`) | MEASURED prototype; the plugin sandbox blocks `sfverify`'s own nested build, hence the log hand-off | One cold build instead of two (56 s today for `SwiftFormalContractsTests`); discoverable | (c) | M | P1, K3 |
| K6 | Xcode and Tuist: read the compile command from `xcodebuild` output or `.xcactivitylog` (same `builtin-SwiftDriver` lines the SwiftPM parser already reads) | MEASURED for xcodebuild and activity logs; Tuist PROJECTED | Scan app targets with exact flags | (c) | M | |
| K10 | Toolchain locator: one `swiftc -print-target-info` (0.1 s) gives version (K2), triple and resource dir; Linux without `xcrun`; honour `DEVELOPER_DIR`/`TOOLCHAINS` explicitly | MEASURED; loose-file mode passes no `-target`, so it checks the host, not the package's deployment target (VERIFIED) | Correct target; Linux possible | (a)(c) | M | S2, X4 |
| K11 | Gate diagnostics: `note:` lines with inputs, the `_ensures` line, the declaration of a trapping callee; a marker not followed by a function reported at plugin planning time | VERIFIED: PackagePlugin 6.4 `Diagnostics` has file and line only, no column, no note; build commands cannot attach `.dia` files. So plain `file:line:col: note:` lines are the route | Faster fixing in the editor | (c) | S | |
| K12 | Gate and package macros: no PackagePlugin API gives a build-tool plugin the path of a built macro | VERIFIED | Document the limit (option A), or rely on an undocumented layout (B) | (c) | S/M | |
| K8 | The dependency scanner (`swiftc -scan-dependencies`) as an oracle-lane test for import discovery (catches the C1 class) | MEASURED: graph and module origin in one call, 0.40 s warm; not worth it per run | Guards linking and the ambiguity check | (a) test | S | C1 |
| K7 | Demangle in-process with the toolchain's `libswiftDemangle` (`swift_demangle_getSimplifiedDemangledName`), spawn as fallback | MEASURED: 690 symbols, 0 mismatches, 0.8 ms against 75 ms. The runtime's `swift_demangle` only fully demangles (684 of 690 differ) | About 10 ms per scan after S2 | (a) | S | S2 (low rank) |

Rejected here: libSwiftScan in-process (`lib_InternalSwiftScan.dylib`, no stable ABI); symbol graphs or
`.swiftinterface` files instead of `TypeNameCheck` (24 s for Foundation; interfaces miss clang modules, which is
unsound); skipping the null `swift build` when sources look unchanged (a stale `@inlinable` body would be proved);
parsing Swift Build's private `task-store.msgpack`; `xcodebuild -showBuildSettings -json` (settings, not commands).

## Tier 4: architecture of the pipeline

The verify phase already runs about 7x parallel under `concurrentPerform` (5.2 s CPU in 2.2 s wall on 600 synthetic
functions, MEASURED), and solves take 0 to 4 conflicts on real targets. So the architecture work is about making it
cheap and safe to read more Swift, not about speed.

| ID | What | Where | Evidence | Class | Guard | Effort | Builds on |
|---|---|---|---|---|---|---|---|
| H0 | **New guard first: a CNF hash per fixture function** (SHA-256 of the DIMACS text for every function in the SIL fixtures and `Examples/Metrics`). Counts alone miss renumbering | `Tests/SFSILTests` | needed by H1, H5 | test | | S | metrics.py |
| H1 | Split `SILParser`/`SILEncoder` by `SILNodes.def` family (literals, conversions, memory, functions, aggregates, enums, terminators, runtime failure); one closed `Instruction` enum and one exhaustive switch; the 747-line `run` becomes methods on a `BlockState`; the ignored-instruction list in one reviewed file (a wrongly ignored instruction is a false proof) | `SILParser.swift:1217-1494`, `SILEncoder.swift:353-1099`; `SILNodes.def:312-915@6.4.0` | VERIFIED sizes; tests already split by family | (a) | H0 byte-identical; metrics, golden, ParserFuzzTests | M | S7 |
| H5 | Harden the IR that exists instead of adding one: dense `ValueID: Int32`, a type per value, an explicit closure (globals, witness entries, callees), canonical bytes. Proof-cache key = Merkle digest over that | `SILEncoder.swift:357,453,479,873`; `ProofCache.swift:164-182` | VERIFIED: values are strings today; the key hashes `String(reflecting:)` and misses globals and witnesses | (a) | H0; C4 repro gives different keys | M-L | C4, D4, S5, S7 |
| H2 | Typed trap sites (`condFail`, `call(inner:)`, `stdlib`, `unreachable`) instead of strings the reporter parses back; a trap inside a callee keeps its own location | `SILEncoder.swift:26-31, 1184`; `VerifyCounterexample.swift:64-83` | VERIFIED | (a), (c) if nested location shown | describeTrap tests | S | |
| H3 | A verdict per trap site: after a counterexample, re-encode with `¬trap_k` per remaining site. Sound (each proof still LRAT-checked), no checker change | `Verify.swift:171-194` | VERIFIED design; extra solves only for failing functions | (c) additive JSON | zoo; golden; schema | M | H2 |
| H4 | Contract summaries at call sites (assume-guarantee, as Kani `stub_verified` and Verus do): for a callee whose contract was proved in this run, assert `g_requires`, assume `g_ensures`, mark as approximation; counterexamples replay fully inlined. No recursion, no write-back parameters, never from `undecided` | `SILEncoder.swift:272-274, 488-496, 836-863` | MEASURED: inlining makes a fan-out-2 chain grow 11,281 to 1,538,442 clauses over 7 levels; PROJECTED for real code ("deep call chain" not seen on real targets) | (b)(c) | zoo: weak callee contract never gives `safe`; golden; metrics | L | H5 |
| H9 | `throws(SILError)` on the reader's internal leaf functions only | `SILParser.swift:199, 1045, 1189, 1217` | VERIFIED; turns ParserFuzzTests' "parsed or typed error" into a type | (a) | build; fuzz | S | ADR 0007 |
| H6 | SwiftPM trait `Generator` gating swift-syntax for `SFGenKit`/`sfgen` (default on, so installers are unaffected; lanes pass `--disable-default-traits`) | `Package.swift` | MEASURED: cold dev build 92.8 to 31.0 s CPU; needs tools 6.1 (consumer floor 6.0 to 6.1) | (a) installers | dump-package with and without; portability, sandboxes, layering | S | alternative to B7 |
| H7 | Strict-memory-safety lane | `Package.swift` | MEASURED: 41 warnings, 36 in `Solver.swift` (gone with E0), 5 mechanical sites left; `.strictMemorySafety()` needs tools 6.2 | (a) | the lane; ratchet | S | E0 |
| H10 | Incremental SAT with activation literals and LRAT goal clauses (LIDRUP, LPAR 2024) | `Solver.swift:119-134`, `LRATChecker.swift:101-121` | PROJECTED; solves are near free today | (b), changes SFCheck | exhaustive checker tests | L, deferred | |

Rejected: a new verification IR (goto-program, Boogie, Crucible style): one frontend matters, a lowering pass would be
new trusted code, and speed is not the limit. An abstract-interpretation pass that discharges traps (ESBMC/SeaHorn
style): it would be trusted code removing obligations the solver closes at 0 conflicts. One encoder shared with SFLLVM
(destroys the independence). Swift concurrency (TaskGroup, `sending`) for per-function Scan: `concurrentPerform`
already reaches about 7x, and `async` would colour the synchronous engine. `~Copyable` `CNFBuilder` (public API,
negligible gain). Typed throws on the public API (ADR 0007).

## Tier 5: validation against the compiler and pin upgrades

TRUST.md lists the SIL reader, `S0` and the encoder as "tested, not proved". These items make that testing stronger and
use the compiler itself as the second opinion. The 884 hand-written `.sil` files of `test/SIL` and `test/SILOptimizer`
are a poor oracle (another dialect: operand types inline, OSSA, classes; 13 of 7,726 functions readable) but good fuzz
seeds (0 crashes, 0 hangs in 19 s). The 730 `.swift` tests next to them are the valuable part: 370 compile with Scan's
flags and give 4,264 functions of real printer output, 1,199 of which Scan encodes. That corpus found V1 and V2 on its
first run.

| ID | What | Evidence | Class | Effort | Builds on |
|---|---|---|---|---|---|
| V3 | **Compiler-corpus lane** (nightly, oracle lane): compile the `.swift` tests of `test/SIL` and `test/SILOptimizer` at the pinned tag with Scan's exact flags; parse, encode, prove, and compare SIL with IR. Fails on a crash, a hang (over 120 s), an `INVALID` on compiler output, a verdict flip against a checked-in baseline, or a SIL/IR verdict disagreement; counts ratchet | MEASURED: compile 10.5 s (8 jobs), prove 17 s release for 1,199 functions (1,122 proved, 76 counterexamples, 1 unknown) | (a) | M | oracle lane |
| V4 | **SIL≡IR cross-check as an opt-in second encoder** (`sfverify --cross-check llvm`): a `safe` is "cross-checked" only when `LLVMVerifier.proveEquivalentToSIL` proves the two encodings equal; `strict` turns disagreement into `undecided`. Then the SIL reader, `S0` and `SILEncoder` leave the trusted list for those functions (both encoders would have to be wrong the same way) | MEASURED: IR reads 285 of the 1,199 (24 %; `Examples/Metrics` 14 of 14); verdicts agree 285/285; equivalence proved for 245 (39 differ in enum/Optional leaf layout, 1 unknown); about 8 ms per function plus one `-emit-ir` compile (+50 to 60 % compile time). It would not have caught V1 (the IR reader rejects aggregate `alloca`) | (c) opt-in | M, then L to widen the IR reader | ADR 0008, H8 |
| V5 | **The compiler's constant folder as an oracle for `S0`**: raw SIL with literal operands through `swift-frontend -emit-sil -Onone`; read the folded literals and the `division by zero`/`overflow`/`shifting all significant bits` diagnostics; compare both ways with `S0` (diagnosed iff `.undefined`) | MEASURED: 30 non-cast ops, 421 pairs each, at 8, 16, 32 and 64 bits: 45,829 folded values, 4,691 diagnosed pairs, 0 mismatches. First check ever of `S0`'s undefined-behaviour predicate (the native oracle skips UB cases) and of builtins at 16 and 32 bits. Casts still to add | (a) | S | |
| V6 | **Mutation lane** for `S0`, the encoder's trap and UB plumbing and the parser's literals: apply each curated mutant, run the semantics, SIL, zoo and oracle tests, require "killed"; ratchet the kill rate; survivors become test tasks | MEASURED: 14 mutants (S0 opcodes and UB flags, the reference interpreter, array bounds, call-site trap propagation, literal masking, the unconditional-failure detector, `cond_fail` stopping execution); all 14 killed in a first run that shared the machine with other jobs. A clean sequential rerun of 11 of them was stopped at wrap-up after 6, all 6 killed again. Most S0 mutants are first caught by `encoderMatchesInterpreterExhaustivelyAt8Bits`, which fails within 5 to 37 s; a full suite run takes 3 to 8 min. Harness and results: archive `tools/mutation/` | (a) | S | round 2 N1 |
| V7 | **Scripted pin upgrade** (`Scripts/pin-upgrade.sh OLD_TAG NEW_TAG`): (1) static diff of `SILNodes.def`, `Builtins.def`, `SILPrinter.cpp`, the SIL parser and builtin-name code: vocabulary, printer tokens, and a fingerprint of each `visit<Inst>` the reader depends on; (2) dynamic lanes on the candidate toolchain with the version added to the pin (golden, oracle, V3 verdict diff, V5); (3) a decision table: clean and no verdict delta, add the version line only; reader changed, bump `semantics`; any verdict delta, bump and CHANGELOG; a `safe` that became `mayTrap`, stop. Several pins at once through the existing list in `CompilerPin`, one CI lane per pinned Xcode | VERIFIED churn: per release +3 to 8 instructions, +1 to 21 builtins, 120 to 290 changed printer lines. 6.2 changed how every operand is printed. `main` drops `cond_br` branch arguments and gives `debug_value` nested `transform { bbN: … }` blocks; only the visitor fingerprints caught those. The script must flag 6.3 to 6.4.0 (`unchecked_inplace_enum_data_addr` is new) as its self-test | (a) | M | K2 |
| V8 | Real compiler output rejected as `INVALID SIL` (reads as a tool bug) must be `unsupported`: generic builtins (`builtin "sizeof"<T>()`), several `@out` results | MEASURED: 12 functions in V3 | (c) | S | |
| V9 | About 40 curated corpus `.sil` files as parser fuzz seeds (today 2) | MEASURED as above | (a) | S | |
| V10 | Remove the dead `@in_constant` match (`SILParser.swift:1150`); the compiler never prints it | VERIFIED | (a) | S | |

Rejected here: normalising hand-written test SIL into Scan's dialect (a second parser needing its own validation);
`sil-opt` oracles (Xcode does not ship `sil-opt`; `swift-frontend` on raw SIL runs the same folding); exhaustive
folder runs per op in one file (superlinear compile time); switching production to `-sil-print-types` alone (see L11);
making SIL≡IR mandatory now (it would turn about 76 % of `safe` on the corpus into `undecided`).

Also in this tier, from the other investigations:

| ID | What | Evidence | Class | Effort |
|---|---|---|---|---|
| R6 | **Summary pin**: hash each summarized function's linked SIL closure (from `-O -Xllvm -sil-print-after=performance-linker`, normalized for line numbers and file names) into `Scripts/baseline/stdlib-summaries.json`, keyed to compiler and SDK; source-text hashes for the 6 entries with no serialized body; `--update` prints the diff for review, like `check-ratchet.py --update` | MEASURED: 181 bodies cover 44 of 51 entries; one extra 1 to 2 s compile in CI | (a) CI | M |
| R9 | `[_semantics "…"]` on printed callee declarations as a fail-closed cross-check of the mangled-name table (more `unsupported` only, never a behaviour source) | MEASURED: tags appear in `-Onone` SIL | (b) | S |
| L11 | `-Xllvm -sil-print-types`: check every inferred operand type against the compiler's | MEASURED: flag works; 24 % smaller SIL with `-sil-print-no-uses` | (a)(b) | M, with S6 |
| L12 | `--paranoid`: `-sil-verify-all` on the emit | MEASURED +40 % compile | (a) | S |
| R12 | Reading stdlib bodies instead of summaries | Rejected for now: the bodies need a heap, `witness_method` and ObjC-bridge model and about 12 builtins S0 lacks; at `-Onone` they are not the code that runs (R8). Revisit with classes | | L |

## Tier 6: developer experience

| ID | What | Evidence | Class | Effort | Builds on |
|---|---|---|---|---|---|
| U4 | **Walk survives a trap** (macOS, Linux): the walk runs in an exit-test child; a signal handler writes the step number with `write(2)` only; the parent maps the step to the input (enumerated: `domain[n]`; sampled: replay `SplitMix64` n draws) and confirms by running that input alone. Outcomes: walked, trapped (input), trapped while checking (a property), input unknown, unexpected exit; none is ever `proved` or `bounded` | MEASURED prototype at the macOS 13 target: 65,536 inputs, trap reported with its input in 0.10 to 0.12 s; exit tests are `unavailable` on iOS (VERIFIED) | (c) additive | M | G1 |
| U5 | **Concrete playback for Scan** (after Kani): `--emit-tests` writes a Swift Testing test per counterexample (`#expect(processExitsWith: .success) { _ = f(args) }`, or the `_ensures` check); `--confirm` runs them and marks `confirmed`. A counterexample that does not reproduce natively is a model/compiler disagreement: report it as an internal error | MEASURED: replay is scalar-only today (`VerifyCounterexample.swift:152`) | (c) | M | SFOracleTests |
| U7 | **Explain** `unsupported` and `undecided`: `SILError.unsupported` carries the instruction's `loc` and a category enum; print location and a fix hint; "called from here" notes up the call chain, as the compiler's `PerformanceDiagnostics` does for `@_noLocks` (`PerformanceDiagnostics.cpp:136-141@6.4.0`) | MEASURED: `manhattan` is "unsupported — generics" because it calls `abs`, with no location; a non-budget reason is filed under "Undecided (budget)" | (c) | M | F10, H2 |
| U11 | Swift Testing at the floor: warning-severity issue for `bounded` (silent today), attachments with the report, a `TestScoping` trait for a default budget | MEASURED: all compile at `-target arm64-apple-macos13.0`; no `@available` on them in the 6.4 interface except image attachments | (c) | S | |
| U8 | SARIF 2.1.0 and GitHub annotation output | PROJECTED; the JSON has every field | (c) | S | schema v1 |
| U9 | `swiftformal doctor`: pin, debug-build warning, gate wiring, stamp problem, exit-test availability | MEASURED: debug `sfverify` on Examples/Metrics killed after 6.5 CPU-minutes vs 2.4 s release | (c) | S | F9, K2 |
| U14 | The gate plugin runs a debug `sfverify` (2.98 s vs 0.5 s per gate; hard proofs infeasible): ship a release binary `artifactbundle` for tagged releases, or document the release build for CI | MEASURED | (c) | M | B7, G3 |
| U12 | `swiftformal check` reads the test event stream (`--event-stream-version 6.4`, which carries severity and attachments) instead of console text and the `SWIFTFORMAL_WALK_LOG` side file | MEASURED: versions 0 and 1 drop warnings; the flag is in `--help-hidden` only | (a) | M | S9 |
| U15 | Editor integration without an LSP: VS Code task with the `$swiftc` problem matcher on `sfverify --xcode`, SARIF viewer | VERIFIED line format | (c) docs | S | U8 |

Rejected: preamble and code-item macros (`EXPERIMENTAL_FEATURE(…, false)` in `Features.def@6.4.0`); a sub-expression
capturing `#verify` macro (`#expect` already prints the Report); `@Verify` generating `@Test` peers (puts `import
Testing` into production modules); `Domain` as `@Test(arguments:)` (one test case per input, loses "proved over the
domain"); a signal handler in core `verify` (process-wide state in apps); `@_semantics("sf.verify")` as a marker
(changes the inliner, so the verified code); a built-in `--watch`; a custom LSP.

## How this maps to rounds 1 and 2

| This plan | Builds on | Relationship |
|---|---|---|
| K1, K3, K5 | P1 | P1 removes the dependency rebuilds; K1 is still needed for the main target; K3 replaces "delete and rebuild" on null builds; K5 needs K3 |
| K2, K10 | S2, X4, B6 | the spawn helper is where the toolchain is resolved once |
| K9 | S3 | same compile path |
| K7 | S2 | S2 removes most of the spawn cost, so K7 ranks low |
| H1, H5 | S7, C4, D4, S5 | S7's parse cache lives in H5's IR; H5 fixes C4 by construction |
| H6 | B7 | alternative with the same CPU saving and no install-path change |
| H7 | E0 | E0 removes 36 of 41 strict-memory-safety warnings |
| H3 | round 1 rejected COI slicing | H3 uses the full CNF per site, so it is not slicing |
| L11 | S6 | change the SIL text format only together with the byte scanner |
| U4 | G1 | pinned sample sequences make replay of a sampled step exact |
| U12 | S9 | same `swift test` invocation |
| U14 | B7, G3 | a bundled binary must pass the compatibility-dylib check |
| R5 | | changes which SIL is verified; coordinate with any round 2 item touching emit flags |
| V6 | N1 | the mutation lane is how N1's new overflow-flag circuit gets a measured kill rate |
| V3, V5 | round 1 oracle lane (ADR 0004) | both run in the oracle lane with the pinned compiler |

## Decisions for the owner

1. **K2/U1, the pin.** Fail closed everywhere (as TRUST.md says), or fail closed in the gate and warn and stamp in
   `sfverify`/`check`? Either way, ship a pin-update process with it.
2. **R4, huge arrays.** Report `count >= 2^48` as a trap (recommended, sound), assume allocation always succeeds, or
   document memory exhaustion as excluded.
3. **R5, configuration.** Default `--config both` (honest, about 1.2x cost) or `debug` with TRUST.md corrected.
4. **R8, which stdlib.** Does the trust statement cover the floor's stdlib (Swift 5.7 on macOS 13) or only the SDK's?
5. **L3, loops.** With invariant `true`, a function that never terminates comes out `safe` (partial correctness). Allow
   it, say "termination not proved", and add it to TRUST.md? Default unwinding bound for BMC (8 recommended, plus
   `--unwind N`)?
6. **L5, class exclusivity.** May `safe` assume no conflicting access is held by the caller (stated per function, like
   `requires`), or must it be `undecided`?
7. **H4, summaries.** Default, or opt-in (`--modular`)? It changes what a caller's verdict means.
8. **H6 or B7**: tools 6.1 for consumers, or a changed `sfgen` install path.
9. **H8 against V4, the future of SFLLVM.** Both agree on one point: never share an encoder between the SIL and LLVM
   readers, because the cross-check's value is their independence. They differ on use. H8: keep SFLLVM a frozen,
   test-only oracle (ADR 0008 option 2) and correct TRUST.md. V4: give it a consumer, an opt-in
   `sfverify --cross-check llvm` (today it covers 24 % of encodable corpus functions and all of `Examples/Metrics`), and
   widen its reader over time. A middle path: SIL≡IR only inside the V3 corpus lane now, decide V4 after V3 has run
   for a while. Also decide **V3's corpus source**: vendor the 370 files (about 2 MB, Apache-2.0 attribution) or fetch
   them by SHA in the nightly lane.
10. **U14**: a prebuilt release `sfverify` for the plugin is a trust decision (reproducible build, checksum).
11. **K5**: a second public plugin product, `SwiftFormalScan`.
12. **U4/U5 API shape**: two-part exit-test helper now, a macro later? Is `--confirm` (builds and runs user code)
    acceptable as opt-in?
13. **R10**: String ghost facts now, or wait for a full string model.
14. **H10**: a trusted-core change (LRAT goal clauses); defer until a measured workload needs it.
15. **Upstream reports** (optional): `Array(repeating: 0, count: 1 << 61)` dies with SIGBUS instead of a clean trap
    (unchecked multiply at `GenClass.cpp:836@6.4.0`, inferred, not debugged).

## Order

Other sessions are changing `SILParser.swift`, `SILEncoder.swift`, `SILSummaries.swift` and `SILEnums.swift`, and
round 2's branch touches `SFVerifyKit`. The soundness fixes are small and in those files: write the zoo cases first
(they can land anywhere), then the fixes in coordination with whoever owns the SIL work.

1. **Tier 0**: R1, R2, R3, V1, R4 (each with its zoo case and native replay), V2, R7, then K2 with the pin-update
   process (V7), then R5. Then V3 (the corpus lane), V5 and V6, so the next soundness bug is found by a lane rather
   than by a research pass.
2. **Tier 1** (S each, independent): K1, U2, U3, L13, U6, U10, K4, H8 (TRUST.md correction), R8, U13, V8, V10, and
   update KNOWN-ISSUES #2.
3. **Guards before structure**: H0 (CNF hash), then H1 and H9 after round 2's S6/S7 land, then H5 with C4.
4. **Coverage in measured order**: L1 tier 1a, L2, L8, L6, L4 with L3, L7; L1 tier 1b and L5 after a decision; R10,
   R11, L9 as small additions. Each one with its zoo cases and native comparison rows, and a
   `SILFrontendVersion.semantics` bump (or R7).
5. **Toolchain**: K3, K9, K11, then K5, K6, K10, K8; K7 last.
6. **DX**: U11, U9, U7, then U4 and U5; U8, U12, U15; U14 with the release process.
7. **After decisions**: H4, H6 or B7, H7, H10, R6 with the pin process.

Expected effect, from the measurements: the false `safe` results found here closed; the trust ledger true again (pin
checked, configuration stated, stdlib version stated); a cold `--build` that works on the most common package layout;
about 133 more functions decided from floats alone on this repository (more with L2 and L6); a walk that reports the
trapping input instead of killing the test run.

## Sources

- swiftlang/swift `swift-6.4.0-RELEASE` (`b8189d7`), sparse checkout: `include/swift/SIL/SILNodes.def`,
  `include/swift/AST/{Builtins.def,SemanticAttrs.def,SILOptions.h,PrintOptions.h}`, `include/swift/Option/*.td`,
  `lib/SIL/IR/{SILPrinter.cpp,Linker.cpp}`, `lib/SILGen/SILGenStmt.cpp`,
  `lib/SILOptimizer/{PassManager/PassPipeline.cpp,Mandatory/AccessEnforcementSelection.cpp,Mandatory/PerformanceDiagnostics.cpp}`,
  `stdlib/public/core/{Array,ArrayBody,Assert,CompilerProtocols,Hasher,Mirror,NativeDictionary,Dictionary,OutputStream,StringInterpolation,Collection,Range,Stride}.swift`,
  `docs/SIL/{SIL,Instructions}.md`, `docs/ReferenceGuides/UnderscoredAttributes.md`; fetched: `lib/IRGen/GenClass.cpp`,
  `stdlib/public/runtime/{Heap,Demangle}.cpp`.
- Toolchain interfaces: `PackageDescription` and `PackagePlugin` 6.4, `Testing.framework` 6.4 (macOS and iPhoneOS).
- swift-testing proposals ST-0007, ST-0008, ST-0009, ST-0012, ST-0013; SE-0415 (body macros), SE-0450 (package traits).
- Kani (concrete playback, `stub_verified`, function contracts RFC 0009), Verus, Prusti, SMACK, SeaHorn, Crux, ESBMC
  interval analysis; Brain, Schanda, Sun, TACAS 2019 (SymFPU); Sheeran, Singh, Stålmarck, FMCAD 2000 and Donaldson et
  al., SAS 2011 (k-induction); Clarke, Kroening, Lerdahl, TACAS 2004 (unwinding assertions); Fazekas, Pollitt,
  Fleury, Biere, LPAR 2024 (incremental LRAT).
- Full reports, commands and fixtures: [`archive/research/2026-11-07-swift-internals/`](../../../archive/research/2026-11-07-swift-internals/README.md).
