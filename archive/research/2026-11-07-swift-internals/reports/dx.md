# Developer experience for SwiftFormal users (item prefix U)

Repo state: `d759be7` (copied to `SCRATCH/dx/repo`; prototypes in `SCRATCH/dx/exitproto`, `SCRATCH/dx/twomod`, `SCRATCH/dx/newuser.swift`).
Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode Testing library 2084, SwiftPM default build system `swiftbuild`.
The machine was shared and loaded (load average 7 to 9), so wall times are the best of 2 to 3 runs. swift-syntax came from the local SwiftPM cache, so a fresh machine would also have to clone it.

## 1. Summary

I followed the README as a new user would, on every Example. The tools work, but the first hour has sharp edges, and two of them matter beyond convenience.

**Two findings that matter beyond convenience**

- **Scan never checks the compiler pin** (U1, VERIFIED). `PinnedCompiler`/`CompilerPin` are used only inside `SFSIL` and its tests. Nothing in `SFVerifyKit`, `sfverify`, `swiftformal` or the gate calls them, and no report prints the compiler version. TRUST.md:31 says "other compilers fail closed", and they do not.
- **The build gate's stamp file is turned into a resource bundle** (U2, MEASURED). The `.sfgate` stamp is copied into `GatedPackage_Kernels.bundle`, a `Bundle.module` accessor is added to the user's target, and Scan then counts that accessor as two hand-written, unsupported functions. GatedPackage reports 50 % coverage instead of 100 %.

**Friction**

- The README install line builds only the last `--product` (U3, MEASURED).
- Generated code is reported as hand-written: SwiftPM's resource accessor, `@Observable` expansions, derived conformances (U6).
- `unsupported` says what but not where or how to fix it (U7).
- The gate's plugin runs a debug `sfverify` (U14).

**Swift Testing in 6.4 now covers the long-standing "a trap kills the walk" limit on macOS.**

- I prototyped library helpers in `SwiftFormalTesting`, compiled at the macOS 13 target. The user writes two exit tests: one for the walk, one to confirm the trap (a macro could write both later).
- A trap becomes a counterexample naming the real input, confirmed by re-running that input alone. Cost: 100 to 118 ms in total, 70 to 82 ms when nothing traps (MEASURED, U4). A child that exits on its own is classified as an unexpected exit, never as a clean walk.
- The same mechanism gives Scan a Kani-style "concrete playback": each Scan counterexample becomes a Swift Testing test that runs the compiled function (U5).
- Warning-severity issues, attachments, scoping traits and the event stream are all usable at the macOS 13 floor (U11, U12).

**Macros:** no new macro role is worth adopting. Body macros are already used. Preamble and code-item macros are experimental and not available in production compilers. `#expect` already prints the whole Report.

## 2. Ranked items

| ID | What | Where | How | Evidence | Gain | Class | Guard | Effort | Builds on |
|---|---|---|---|---|---|---|---|---|---|
| U1 | **Check the compiler pin on every Scan path, and print the compiler** | `SFVerifyKit/SFVerify.swift` (run, gate), `sfverify/main.swift:125`, `SwiftFormalCLI/main.swift:104`; pin in `SFSIL/CompilerPin.swift:41`, `ProofCacheVersions.swift:19` | Call `PinnedCompiler.check()` once per run. On an unpinned compiler: `--gate` fails closed with one `error:` naming the found and pinned versions; `sfverify`/`check` exit 2 unless `--allow-unpinned` is given. With that flag, every report gets an "UNPINNED" banner and the JSON gets `"compilerPinned": false`. Add an optional `compiler` key (the version line) to the JSON and text header (schema: additive key) | VERIFIED: `grep -rn 'PinnedCompiler\|CompilerPin\.' Sources` finds no use outside SFSIL. TRUST.md:31 claims the opposite. MENTAL-MODEL's evidence line "read from compiler SIL (swiftc 6.4)" is not printed | Closes a gap in the trust ledger. Answers Q4 "unpinned compiler message": today there is none | c | SFVerifyKitTests with an injected `CompilerToolchain` (pinned, unpinned, unpinned + allow); `check-cli.py` row for `--allow-unpinned`; schema validation in `metrics.py` | S | B6 (nightly pin), docs/guides/compilers.md |
| U2 | **The gate's stamp must not become a resource** | `Plugins/SwiftFormalGate/SwiftFormalGate.swift:12,19,34,41` | SwiftPM treats a build-command output that is not a source file as a resource. Write the stamp as `<Module>.sfgate.swift`, containing only a comment (no symbols), so it compiles to nothing (`sfverify/main.swift:163` writes `// N of M …`). Same for the Xcode variant (not run in Xcode) | MEASURED: after `swift build` of Examples/GatedPackage: `.build/out/Products/Debug/GatedPackage_Kernels.bundle/Contents/Resources/Kernels.sfgate` and `DerivedSources/resource_bundle_accessor.swift`. Without `--build` Scan sees 2 functions; with it, 4 (`BundleFinder.__allocating_init`, `NSBundle.module.getter`, both unsupported). An app that gates a target ships an extra bundle. **Fix MEASURED** on the scratch copy (stamp `Kernels.sfgate.swift`, content `// 2 of 2 gated functions proved`): clean build has no bundle and no accessor; unchanged rebuild 0.33 s without re-running the gate; a broken function still fails the build; Scan `--build` sees 2 functions | No stray bundle in users' apps; correct counts | c | `check-examples.sh`: after building GatedPackage, assert no `*_Kernels.bundle` and no `resource_bundle_accessor.swift`; the gate still re-runs only on change (stamp is an output) | S | |
| U3 | **README install line builds one product** | `README.md:94` | `swift build --product` takes a single value and the last one wins. Use one `swift build -c release --product X` line per tool, or plain `swift build -c release` | MEASURED: after the README command (158 s, exit 0, no warning), `.build/release` held only `sfgen`. `sfverify`: +26 s; `swiftformal`: +4 s | The documented first step works | c (docs) | Make `check-examples.sh` run the README's install lines verbatim (extract the fenced block) and assert all three binaries exist | S | X8 |
| U4 | **Walk survives a trap (macOS, Linux)**: a trap becomes a `counterexample` with the real input | new `SwiftFormalTesting/TrapWalk.swift` behind `#if os(macOS) \|\| os(Linux)`; a `package` step hook in `SwiftFormal/Verify.swift:37` | The library publishes the index of the input being judged into a preallocated cell. A SIGTRAP/SIGILL handler writes `SWIFTFORMAL-TRAP-STEP n` with `write(2)` only, then re-raises. The user writes the exit test (two with confirmation). The parent helper `childWalk(result, over:)` returns one of `.walked` (agreed exit code), `.trapped(index, input)`, `.trappedInputUnknown`, `.unexpectedExit`; every case except `.walked` records an issue. It maps step to input (enumerated: `domain[n]`; sampled: replay `SplitMix64` n draws). Sketch in §3 | MEASURED (prototype, macOS 13 target): a 65,536-input walk of a trapping `average` reports "traps for input (1, 255) (step 511); confirmed by running it alone" in 0.100 to 0.118 s; no trap 0.070 to 0.082 s; in-process 0.016 s; a function calling `exit(1)` gives `unexpectedExit(.exitCode(EXIT_FAILURE))`. No crash reports were written. VERIFIED: the iOS interface marks the macro `@available(*, unavailable, message: "Exit tests are not available on this platform.")` | Removes a documented limit (MENTAL-MODEL, TRUST, walk.md) on macOS and Linux | c (additive API) | Test: a trapping function gives a counterexample with the right input for enumerated and sampled domains; a trap inside a property is reported as "while checking", not blamed on the function; a missing marker gives "trapped, input unknown" (never bounded or proved); a child that calls `exit(1)` or is killed is `unexpectedExit` and fails the test (prototype test 10); `check-api.sh`; iOS build in the CI `ios` job (code is compiled out) | M | G1 (pinned sequences make replay exact) |
| U5 | **Concrete playback for Scan** (after Kani) | `SFVerifyKit/VerifyCounterexample.swift:151` (`replay`), new `--emit-tests <file>` in `sfverify/main.swift`, `Report.swift` | For each `mayTrap`/`contractFails`, emit a Swift Testing test. A trap: `await #expect(processExitsWith: .success) { _ = f(args) }` (fails until fixed). A broken contract: `#expect(f_ensures(args, f(args)))`. Optional `--confirm` builds and runs them, then marks `counterexample.confirmed` true or false. Extend `replay` beyond scalar free functions where `ValueRenderer` text is valid Swift (`nil`, `.case`, payload enums, public memberwise structs) | MEASURED: `pick(_ o: Int8?)` gets a counterexample `o = nil` but no `replay` (scalar types only, `VerifyCounterexample.swift:152`). The exit-test mechanism costs about 50 ms per test (U4). VERIFIED: counterexamples are replayed only symbolically today (`explain`, line 10) | Each counterexample is checked against the real binary. The user gets a regression test for free | c | A fixture with known traps: the emitted file compiles and fails before the fix, passes after; `--confirm` agrees with SFOracleTests on the zoo | M | SFOracleTests; Kani concrete playback |
| U6 | **Generated code reported separately from hand-written code** | `SFVerifyKit/Verify.swift` (classification), `Report.swift:75,105`, `CheckReport.swift` | Treat functions whose file is under `.build/` or `DerivedSources/`, or named `@__swiftmacro_…`, plus derived conformances (`__derived_*`, implicit accessors of stored properties), as generated. Keep them in `functions` (so `swiftformal check` and the gate still see them), add an optional `origin` key (`source`, `macro`, `derived`, `package-generated`), and leave non-source ones out of the hand-written count and coverage. Decide origin from structure (file path under `.build`/`DerivedSources`, `@__swiftmacro_` file, SIL `[transparent]`/implicit flags), never from name patterns alone: a hand-written computed `.getter` must stay `source`. `swiftformal check` already knows macro expansions (`isMacroExpansion`) | MEASURED: GatedPackage `--build` "4 functions written by hand", coverage 50 % (both from U2's accessor). Two-target package with `@Observable`: "15 functions written by hand", coverage 20 %, for 2 written functions. `newuser.swift`: `Point.x.getter/setter` listed as "safe" and counted. `swiftformal check` on Examples/Walk lists `static Speed.__derived_enum_equals(_:_:), scope 1` as a user function | Honest coverage; less noise | c | `check-golden.sh` re-recorded with reason; a test per origin (derived sources, macro file, derived conformance) | S | |
| U7 | **"Explain" for unsupported and undecided** | `SFSIL/SILParser.swift:15` (`SILError.unsupported(String)`), `SFVerifyKit/Verify.swift:199` (category from text), `Report.swift:88` (detail hidden for unsupported), `Gate.swift:102` | Make `SILError.unsupported` carry the SIL instruction's `loc` and a category enum, instead of matching the text. Print `at file:line:col`, the construct and a fix hint from a static table (`generic call to abs<A>` → write `x < 0 ? -x : x`; `IndexingIterator` → `while` with an index; String → pass the count as `Int`; budget → narrow the types or add `_requires`). Add `sfverify --explain <name>`. With `--xcode --show-unsupported`, emit `note:` lines at the instruction. Rename "Undecided (budget)" to "Undecided" and give the reason (budget versus unknown results). In the gate, add the result (`returns 9`) and a note at the `_ensures` declaration. For a trap inside a callee, add "called from here" notes up the call chain, as PerformanceDiagnostics does | MEASURED on `newuser.swift`: `manhattan` is "unsupported — generics" because it calls `abs`; the detail "generic call to abs<A>(_:) with <Int16>" appears only in JSON, with no location. `greet` is listed under "Undecided (budget)" but its reason is unknown `String.count` results. The gate message for `cellIndex` omits the result. VERIFIED: swift `PerformanceDiagnostics.cpp:136-141` (`LocWithParent`), `DiagnosticsSIL.def:432` (`performance_called_from`)@6.4.0 | The user knows what to change | c | Golden updated; a table test that every category has a hint; `DiagnosticSpec`-style column tests for `--xcode` lines | M | F10 (same idea for macros), N-items (budget) |
| U8 | **SARIF and GitHub annotations** | `SFVerifyKit/Report.swift`, `CheckReport.swift`, the CLIs | `--format sarif` (SARIF 2.1.0: one rule per status, `level` error/warning/note, `physicalLocation` relative to `--package`, inputs and replay in `properties`) and `--format github` (`::error file=…,line=…::…`). Upload with `github/codeql-action/upload-sarif` | PROJECTED. SwiftLint ships a `sarif` reporter (precedent). The JSON already has every field needed | Results in GitHub code scanning and PR annotations, with no plugin | c (additive) | A SARIF schema file vendored under `docs/schemas`; validated in `metrics.py` like the scan schema; `check-cli.py` rows | S | Report JSON schema v1 |
| U9 | **`swiftformal doctor`** plus a debug-build warning | `SwiftFormalCLI/main.swift:63`; `sfverify/main.swift` | Checks the compiler against the pin (U1) and whether this `sfverify` is a debug build (`#if DEBUG`: print a warning outside `--gate`). Lists targets with `SwiftFormalGate` and their markers, flags the stamp-resource problem (U2), and flags a target that imports another module while the plugin gives it no flags (fails closed). Also reports swift-syntax resolved version, Testing exit-test availability on this platform, and whether `SWIFTFORMAL_WALK_LOG` is set | MEASURED: Examples/Metrics with release `sfverify`: 2.39 s. Debug: still unfinished after 6.5 CPU-minutes (killed). The gate in debug: 2.98 s versus about 0.5 s in release | Answers "why is it slow, why did it fail" in one command | c (additive) | `check-cli.py` rows; doctor's checks unit-tested with injected facts | S | F9 parser |
| U10 | **Better first errors** | `SFVerifyKit/SwiftPM.swift`, `SFVerify.packageFiles` | A typo in `--target` should say "no target 'Kernel' (targets: Kernels)", not `COMPILER FAILED`/`INVALID SIL`. A compile error "no such module" without `--build` should add "this target imports other modules: add --build". `swiftformal check` should not point to a `.out` file it never wrote (`Check.swift:178` returns early) | MEASURED: `--target Kernel --build` gives "COMPILER FAILED: … TSCUtility.Diagnostics error 0"; without `--build` it gives "INVALID SIL: no target Kernel"; two-target package without `--build` gives "COMPILER FAILED … no such module 'Base'" with no hint. `swiftformal check` on Examples/Walk prints a nonexistent path (C2 is the root cause) | Fewer dead ends | c | `check-cli.py` (G2) rows for each message | S | F9, C2 |
| U11 | **Swift Testing features at the floor**: warnings, attachments, a scoping trait | `SwiftFormalTesting/Prove.swift:10-20` | When `allowBounded: true` and the verdict is bounded, record `Issue.record(..., severity: .warning)` (today: silent). On non-proved verdicts, `Attachment.record` the report text and the JSON line. Add `@Suite(.swiftFormal(budget:allowBounded:))`, a `TestScoping` trait that sets a TaskLocal default budget (for example exhaustive on CI, sampled locally) | MEASURED: compiled at `-target arm64-apple-macos13.0` (`swift build -v`); the warning shows as "passed … with 1 warning"; attachment shown and saved with `--attachments-path`. VERIFIED: `ExitTest`, `Attachment`, `Issue.Severity`, `TestScoping`, `Test.cancel` have no `@available` in the 6.4 macOS interface (only image attachments do: macOS 13/12.3) | A spot check (`bounded`) is visible without failing | c | SwiftFormalTestingTests: bounded with `allowBounded` gives exactly one warning-severity issue; `check-api.sh` | S | |
| U12 | **`swiftformal check` reads the test event stream** | `SFVerifyKit/Check.swift:152` (console scraping), `Prove.swift:100` (env side file) | `swift test --event-stream-output-path P --event-stream-version 6.4`: issue records carry `isKnown`, `severity` and location; attachments carry the walk JSON (base64). This replaces both the `SWIFTFORMAL_WALK_LOG` side file and the "recorded a known issue at" text parsing | MEASURED: version 0 and 1 streams drop warning issues; 6.3 and 6.4 include `"severity":"warning"`. The flag is listed only under `--help-hidden` | Not tied to Swift Testing's console format | a (same verdicts) | CheckTests with a recorded stream fixture; keep the env path as fallback until the flag is public | M | S9 |
| U13 | **`#ensures` failures show the result** | `SwiftFormal/Contract.swift:36-38` | Record `"\(text()) (result: \(result))"`: the Walk counterexample then says what was returned | VERIFIED: the recorder appends only the predicate text | A clearer counterexample | c | ContractsTests snapshot | S | X2/F3 |
| U14 | **The gate's `sfverify` is a debug build** | `Package.swift` plugin dependency; `Plugins/SwiftFormalGate` | Ship a signed, release `sfverify` `artifactbundle` as the plugin's tool for tagged releases (the SwiftLint model). Keep the source-built tool for path dependencies. Or, cheaper: document `swift build -c release` for CI | MEASURED: plugin tool path `.build/out/Products/Debug/sfverify`; a passing gate takes 2.98 s versus 0.5 s; Examples/Metrics with a debug `sfverify` was killed unfinished after 6.5 CPU-minutes (release 2.39 s) | Gate time ÷6 or more; hard proofs feasible in a build | c | Release checklist: the bundle's checksum matches a reproducible build; `check-portability.py` on the bundled binary (G3) | M | B7, G3 |
| U15 | Editor integration without an LSP | docs | Document a VS Code task with the `$swiftc` problem matcher running `sfverify --xcode` (the lines already match), the SARIF Viewer extension for U8 output, and Xcode's display of plugin diagnostics | VERIFIED: diagnostic lines are `file:line:col: severity:`. UNVERIFIED here: whether Xcode nests `note:` under its `error:` (no GUI run) | Inline results in VS Code | c (docs) | `check-links` | S | U8 |

Order: U1, U2, U3 (correctness of what users are told; S each), then U6, U10, U11, U13 (S), U4 and U5 (M; the new capability), U7, U8, U9, U12, U14.

## 3. Design sketches

### U4: trap-safe walks (prototype in `SCRATCH/dx/repo/Sources/SwiftFormalTesting/TrapWalk.swift`)

Why the user must write the exit test:

- The body of `#expect(processExitsWith:)` runs in a child process.
- Only values that are `Codable & Sendable` can cross into the child, through a capture list with an explicit type. Measured: `[limit]` fails with "Type of captured value 'limit' is ambiguous"; `[limit = limit as UInt8]` works.
- A user's `(Input) -> Output` closure cannot cross, so a library function cannot start the child for it.
- The API is therefore two-part. A freestanding macro (`#expectProvedSurvivingTraps`) could later write both parts, but it would add swift-syntax to `SwiftFormalTesting`. Measured as below:

```swift
@Test func averageNeverTraps() async {
    let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        expectProvedReportingTraps("average", { average($0.0, $0.1) }, over: bytePairs) { Property.deterministic() }
    }                                       // child exits with code 86 when it walked everything
    guard case let .trapped(index, input) = childWalk(result, over: bytePairs) else { return }  // other cases already recorded
    // Second exit test, also written by the user: only the user's code can name `average`.
    let confirm = await #expect(processExitsWith: .failure) { [index = index as Int] in
        let x = bytePairs[index]; _ = average(x.0, x.1)
    }
    Issue.record("average traps for input \(input)\(confirm == nil ? " (not reproduced alone: a property trapped)" : "")")
}
```

Without the second exit test the user still gets the input, but cannot tell "the function traps" from "a property or observer trapped while checking this input". The report must then say "trapped while checking X".

**Details that matter**

- **Why `.failure`.** `#expect(processExitsWith:)` returns `nil` when the condition does not match (measured). The child therefore always exits non-zero: `exit(86)` after a full walk, or a signal if it traps. `.failure` matches both, so the parent always gets the result.
- **The cost of `.failure`.** It also matches any other exit, such as a function that calls `exit(1)` or a child killed by SIGKILL. `childWalk` therefore accepts only code 86 as `.walked`. Anything else is `.unexpectedExit` and records an issue (measured, test 10).
- **The handler.** It loads the published step and writes digits from a preallocated buffer with `write(2)`. It then restores `SIG_DFL` and `raise`s, so the exit status stays `.signal(SIGTRAP)`.
- **Never describe the input in the handler.** That allocates and is not async-signal-safe. The parent describes it.
- **Which step is published.** The step is set when the walk takes input `i`, not per call. `.deterministic()`'s second call therefore points to the same input.
- **Confirmation.** The parent runs `[index = index as Int] in _ = f(domain[index])` in a second child.
  - It traps: "the function traps on X".
  - It does not: "trapped while checking X (a property or observer)".
  - The marker is missing: "trapped; input unknown".
  - None of these is ever `bounded` or `proved`.
- **Sampled domains.** These need a `package` hook in `verify` that stores the step. The parent then replays `SplitMix64(seed)` that many draws. Wrapping the domain from outside would change the draw sequence that G1 pins.
- **Parallel tests.** Each exit test is its own process, so a single global cell is enough.
- **The walk log.** A child inherits `SWIFTFORMAL_WALK_LOG` and writes its own line when it finishes without a trap. This is fine, because it is one line per walk.
- **Platforms.** macOS and Linux only; Windows exists in swift-testing but is untested here. On iOS the code is `#if`'d out and the docs keep the current limit.
- **Soundness.** Nothing here can produce `proved`: the child's own `expectProved` decides that exactly as today. A trap is always a failure.

### U5: concrete playback (Scan → Swift Testing)

`sfverify --package . --target Kernels --build --emit-tests Tests/KernelsTests/ScanPlayback.swift` writes:

```swift
// Generated by sfverify from swiftc 6.4 SIL. percent(_:_:) may trap: Division by zero (Kernels.swift:19:36)
@Test func percent_traps_part0_whole0() async {
    await #expect(processExitsWith: .success) { _ = percent(0, 0) }   // fails today; passes once fixed
}
// cellIndex(_:_:_:_:) breaks its contract (x = 0, y = 29, width = 1, height = 10)
@Test func cellIndex_contract_1() { #expect(cellIndex_ensures(0, 29, 1, 10, cellIndex(0, 29, 1, 10))) }
```

- **`--confirm`** builds and runs only these tests with `--filter`, then sets `counterexample.confirmed`.
- **When a counterexample does not reproduce natively**, that is a disagreement between the model and the compiler. Report it as an internal error, the "please report this" path.
- **Scope.** Only free functions and `public`/`internal` static functions whose arguments render as valid Swift. Methods need a receiver, so they get a commented skeleton.
- **Exit tests are macOS-only**, but `sfverify` already is.

### U1: pin check

- **Where.** In `SFVerify.run`/`gate`, before compiling: `let toolchain = try PinnedCompiler.check(allowUnpinned: options.allowUnpinned)`.
- **Cost.** One `swiftc -version` spawn, about 70 ms today and about 10 ms after S2. It can be memoised per process.
- **On failure:**
  - **Gate:** `sfverify: error: [sfverify] compiler 'Apple Swift version 6.5 …' is not validated (pinned: 6.4 …); see docs/guides/compilers.md`. The build fails, and the error says how to proceed.
  - **Report:** header line `compiler: Apple Swift version 6.4 (pinned)`; JSON `"compiler"` (additive optional key).
- **Owner choice (Decision 1):** should plain `sfverify` refuse (exit 2), or warn and stamp every verdict "unpinned"? TRUST.md promises fail closed, which means refuse.

### U7: explain

- **Carry the location.** `SILError.unsupported(reason: String, construct: Construct, at: SILLocation?)`. The encoder knows the current instruction's `loc` when it throws, so the `at` field is filled there.
- **Same verdicts.** The category table in `Verify.swift:199` becomes a `switch` on `Construct`, so verdicts are unchanged.
- **Text output:**

```
· unsupported    manhattan(_:)  (newuser.swift:2)
      at newuser.swift:2:39: generic call to abs<A>(_:) with <Int16>
      fix: Scan reads concrete code only; write `x < 0 ? -x : x` or use `x.magnitude` (UInt16)
```

## 4. Decisions for the owner

1. **U1 strictness.** Should `sfverify` refuse an unpinned compiler (as TRUST.md says) or warn and mark the report? Is an `--allow-unpinned` escape hatch acceptable?
   - **The cost.** The pin has exactly one entry (`swiftlang-6.4.0.34.1`). Failing closed breaks every user's gate on their next Xcode point release, and every CI runner without that build (compilers.md, D5).
   - **So U1 needs a pin-update process alongside it:** a release per validated compiler, or a signed pin file users can update after running the oracle lane.
   - **Middle ground:** fail closed in `--gate`; in `sfverify` and `check`, warn and stamp the report.
2. **U4 API shape.** Ship the two-part helper (no macro, works now), or also a macro in a new `SwiftFormalTestingMacros` (adds swift-syntax to Walk users)? Also: the exit code (86), and whether `expectProved` itself should publish the step (a `package` hook in `verify`, one store per input).
3. **U5.** Is `--confirm` (it builds and runs user code) acceptable as an opt-in? Should `confirmed:false` count as `internalError` (fail closed)?
4. **U12.** Depend on the event-stream flag while it is only in `--help-hidden`?
5. **U14.** Ship a prebuilt release `sfverify` binary for the plugin? A binary verifier is a trust decision: it needs a reproducible build and checksum.
6. **U6** changes `total` and coverage numbers in reports and goldens (visible to existing users of the JSON).

## 5. Rejected ideas

- **Preamble macros / code-item macros for `#requires`/`#ensures`.** Both are `EXPERIMENTAL_FEATURE(…, false)` in `include/swift/Basic/Features.def`@6.4.0: not available in production compilers, and they would have to be enabled in the user's module. Body macros (SE-0415, baseline) are already used by `@Verify`.
- **A `#verify`/`#satisfies` macro that captures sub-expressions for Walk.** `#expect(verify(...).isProved)` already prints the full Report through sub-expression capture (MEASURED). Only `#ensures` would gain, and U13 covers most of that for about 1 % of the cost.
- **`@Verify` generating `@Test` peers.** It would put `import Testing` into production modules.
- **`Domain` as a `Collection` for `@Test(arguments:)`.** Counts saturate at `Int.max`; there is a Test.Case per input, so 1M inputs would be 1M cases; and "proved over the whole domain" would be lost. For small enums users can already pass `.allCases`.
- **A signal handler in core `verify` for everyone.** It changes process-wide state in apps (crash reporters) and on iOS. Keep it opt-in inside `SwiftFormalTesting` (U4).
- **Describing the input inside the signal handler.** It allocates and is not async-signal-safe. The parent describes it.
- **`@_semantics("sf.verify")` as a marker that survives into SIL.** Functions with semantics attributes are treated specially by the inliner, which would change `-O` code and the code being verified.
- **`--watch` built into the tools.** `swift build` with the gate is already incremental (unchanged rebuild 2.6 s, MEASURED). Document `fswatch -o Sources | xargs -n1 -I{} sfverify …` instead.
- **A custom LSP or SourceKit-LSP plugin.** SourceKit-LSP shows compiler diagnostics only. Problem matchers and SARIF (U8, U15) give inline results without a server to maintain.
- **`Test.cancel` for Walk.** There is no runtime condition to cancel on. The existing `.requiresPinnedCompiler` trait already skips oracle tests.
- **`@_optimize(speed)` to speed up the debug gate tool.** At `-Onone` the pass pipeline does not run performance passes. U14 is the real fix.

## 6. Onboarding measured (Q4)

| Step (README) | Result | Time |
|---|---|---|
| `swift build -c release --product swiftformal --product sfverify --product sfgen` | only `sfgen` built, exit 0 (U3) | 158 s cold (swift-syntax from cache) |
| `swift build -c release --product sfverify` | ok | 26 s |
| `sfverify --package Examples/GatedPackage --target Kernels --build` | first `proved`: `cellIndex` contract holds, `percent` safe; 2 unexpected unsupported (U2/U6) | 51 s first (builds the package and the plugin's debug `sfverify`), 6.6 s warm (scan itself 0.53 s) |
| break a gated function, `swift build` | correct `file:line:col: error:` + `note: replay:`; then a 25-line `sandbox-exec` command dump from swiftbuild | 40 s first, 2.6 s unchanged rebuild, gate 1.1 s (debug tool) |
| `swift test` in Examples/Walk | passes; prints nothing about `proved` (U11) | 20.7 s cold |
| `swift run -c release` in Examples/Prove | `proved` | 17.7 s cold, 2.2 s warm |
| `swiftformal check --scan Examples/Walk:Shipping --tests Examples/Walk:ShippingTests` | walk "did not report" (C2), nonexistent `.out` path, derived conformances listed (U6) | 22.5 s |
| debug `sfverify` on Examples/Metrics | (see U9/U14) | release 2.39 s; debug killed unfinished after 6.5 min of CPU |

Friction points hit, in order:

1. The README install line (U3).
2. Long absolute paths in every line with `--package` (relative paths are printed for relative file arguments; use paths relative to `--package`).
3. Unexpected functions in my 2-function target (U2, U6).
4. A passing walk says nothing.
5. "unsupported — generics" for a non-generic function (U7).
6. A typo in a target name gives `COMPILER FAILED`/`INVALID SIL` (U10).
7. A multi-module target without `--build` gives "no such module" with no hint (U10).
8. swiftbuild's sandbox dump after the gate's errors (upstream SwiftPM; our lines come first, so they stay visible).
9. A debug tool in the gate (U14).
10. Every Walk-only consumer still resolves swift-syntax (round 1 B7).

Note: KNOWN-ISSUES 2 ("cannot compile a target that uses a macro plugin", the `@TaskLocal` case) looks fixed. MEASURED: `sfverify --package . --target SwiftFormal` scans 139 functions both with and without `--build`, and an `@Observable` target scans with `--build`. Update or close that item.

## 7. Comparison with other tools (Q5)

| Tool | UX element | Transfers as |
|---|---|---|
| Kani | `--concrete-playback=print\|inplace` writes a `#[test]` named `kani_concrete_playback_<harness>_<n>` that replays the counterexample; `cargo kani playback` runs it; limitation: version and flags must match | U5 (generated Swift Testing test, `--confirm`; stamp the compiler version, as U1 does) |
| Kani | `#[kani::proof]`, `#[kani::unwind(n)]`, `#[kani::requires/ensures]`, `proof_for_contract`, `stub_verified` | Already mirrored by `// sf:verify`, `_requires`/`_ensures`; a per-function budget marker (`// sf:verify budget=200000`) is a cheap analogue of `unwind` (not ranked) |
| Dafny (VS Code) | Gutter icons per declaration (verified, failed, running), verification on save, counterexample view, `dafny generate-tests` | U8 + U15 (Problems panel, SARIF viewer); U5 for test generation |
| Prusti / Verus | `#[requires]`/`#[ensures]` attributes; Prusti Assistant and verus-analyzer for inline errors | Contracts already exist; inline errors via U15 rather than a forked LSP |
| Swift `@_noLocks`/`@_noAllocation` (`PerformanceDiagnostics.cpp`) | An attribute checked by a mandatory compiler pass; error at the offending instruction, with a chain of "called from here" notes (`DiagnosticsSIL.def:432`) | U7: error at the trap or unsupported instruction inside the callee, plus call-chain notes |

## 8. Sources

- Testing interfaces (Xcode 6.4): `…/MacOSX.platform/Developer/Library/Frameworks/Testing.framework/…/arm64-apple-macos.swiftinterface` (module flags `-target arm64-apple-macos14.0`; `ExitTest` line 611, macros 693/695, `Issue.Severity` 759, `TestScoping` 1259, `Test.cancel` 1354; `@available` only on image attachments) and the iPhoneOS interface (exit-test macros `unavailable`).
- Swift 6.4.0 sources: `include/swift/Basic/Features.def` (BodyMacros baseline; PreambleMacros, CodeItemMacros experimental, false); `lib/SILOptimizer/Mandatory/PerformanceDiagnostics.cpp:136-141,286`; `include/swift/AST/DiagnosticsSIL.def:359-379,432`.
- swift-testing proposals: ST-0007 (TestScoping), ST-0008 (exit tests), ST-0009 (attachments), ST-0012 (exit test capture lists), ST-0013 (issue severity); https://github.com/swiftlang/swift-evolution/tree/main/proposals/testing
- Kani concrete playback: https://model-checking.github.io/kani/reference/experimental/concrete-playback.html
- Dafny VS Code: https://github.com/dafny-lang/ide-vscode ; SARIF 2.1.0: https://docs.oasis-open.org/sarif/sarif/v2.1.0/ ; GitHub SARIF upload: https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/uploading-a-sarif-file-to-github
- Repo: README.md:94; docs/TRUST.md:31; docs/MENTAL-MODEL.md; Sources cited per row.
- Commands: `SCRATCH/dx/build-release.log`, `exitproto/Tests/KernTests/*.swift` (tests 1-9), `SCRATCH/dx/newuser.swift`, `SCRATCH/dx/twomod`.
