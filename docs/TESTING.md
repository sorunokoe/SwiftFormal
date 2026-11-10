# Testing

How tests are written, where they run, and what the repository measures about them. Why there are lanes:
[ADR 0004](decisions/0004-test-lanes.md). What the soundness tests look for: [soundness-zoo](guides/soundness-zoo.md).

## What runs where

CI runs on pull requests to `main`. There is no scheduled run: "by hand" checks are run before a release
([RELEASING](RELEASING.md), step 2).

| Check | Command | When | Gate |
|---|---|---|---|
| Build and tests, warnings are errors | `swift build --build-tests -Xswiftc -warnings-as-errors` | pull request | CI `fast` |
| Fast lane | `Scripts/test-lane.sh fast` | every commit | safety net, CI `fast` |
| Slow lane | `Scripts/test-lane.sh slow` | before a release, after an engine change | by hand |
| Slow lane, fast loop (1) | `Scripts/test-lane.sh slow-dev` | while changing an engine | none |
| All test bundles at once (2) | `python3 Scripts/test-bundles.py fast` or `slow-dev` | local loop | none |
| Oracle lane | `Scripts/test-lane.sh oracle` | before a release (pinned compiler) | by hand |
| Test inventory: no test disappears | `Scripts/check-test-inventory.sh` | every commit | safety net, CI `fast` |
| Golden verdicts | `Scripts/check-golden.sh` | every commit | safety net |
| [Planted-bug suite](#the-planted-bug-suite): mapper bug shapes, each caught by logic or a walk | `swift test --filter 'PlantedBugScanTests\|PlantedBugWalkTests'` | every commit (fast lane) | safety net, CI `fast` |
| Command-line contract (3) | `python3 Scripts/check-cli.py` | every commit | safety net, CI `fast` |
| Portability (4) | `python3 Scripts/check-portability.py` | every commit | safety net, CI `fast` |
| Prover cost and JSON schema ([PERFORMANCE](PERFORMANCE.md)) | `python3 Scripts/metrics.py` | every commit | safety net |
| Format, lint | `swift format lint --strict ...`, `swiftlint ... --baseline` | every commit | safety net, CI `lint` |
| Links and README snippets (5) | `python3 Scripts/check-links.py` | every commit | safety net, CI `links` |
| Examples build and run (6) | `Scripts/check-examples.sh` | pull request | CI `examples` |
| README install lines: one `--product` each (7) | `python3 Scripts/check-readme-install.py` | every commit | safety net, CI `links` |
| API docs, no warnings (8) | `SWIFTFORMAL_DOCS=1 swift package generate-documentation --target <name> --warnings-as-errors` | pull request | CI `docs` |
| Release hygiene (9) | `python3 Scripts/check-release-hygiene.py` | every commit | safety net, CI `hygiene` |
| Ratchets ([below](#quality-ratchets)) | `python3 Scripts/check-ratchet.py` | every commit | safety net, CI `ratchet` |
| Strict memory safety (10) | `Scripts/strict-memory-safety.sh` | before a release (optional) | by hand |
| Sanitizers on the fast lane | `Scripts/sanitize.sh <sanitizer>` | before a release (optional) | by hand |
| Coverage per module, against its floor | `python3 Scripts/measure-coverage.py`, then `python3 Scripts/check-ratchet.py --coverage .build/coverage-by-module.json` | before a release (optional) | by hand |
| S0 against the compiler's constant folder (11) | `SF_FOLDER_ORACLE=full Scripts/test-lane.sh oracle` | sampled: with the oracle lane; full: by hand | by hand |
| Summary pin (12) | `python3 Scripts/check-summary-pin.py` | every commit (about 1 s) | safety net |
| Compiler corpus (13) | `python3 Scripts/corpus-lane.py --sfverify .build/release/sfverify` | on a compiler pin upgrade | by hand |
| Mutation lane ([below](#the-mutation-lane)) | `python3 Scripts/mutation-lane.py` | before a release (optional) | by hand; `--check` in the safety net |
| Large differential and fuzz runs (14) | `SF_DIFFERENTIAL_SEEDS=100000 SF_FUZZ_ROUNDS=20000 swift test ...` | by hand | by hand |

Notes:

1. Same tests as `slow`, debug build with optimized engines: about 40 s once built, not 10+ minutes. Does not replace
   `slow` before a release.
2. slow-dev: 43 s of tests become 17 s; fast: 8 s become 3 s. Uses SwiftPM's private test runner, so
   `Scripts/test-lane.sh` stays the definition of the lanes.
3. argv to exit code, stdout, stderr of `swiftformal` and of the maintainers' `sfverify` and `sfgen`. Baseline:
   `Scripts/baseline/cli.txt`.
4. No `unsafeFlags` in the manifest a consumer sees. No CLI links `libswiftCompatibilitySpan.dylib` (macOS 13 to 15
   lack it).
5. Broken relative links, broken heading anchors, README code not copied from `Examples/`.
6. `Examples/Walk`, `Examples/Verify`, `Examples/Prove`, `Examples/GatedPackage`, then the README's install lines
   verbatim; each tool must exist. Release build, several minutes cold: too slow for the safety net.
7. SwiftPM builds only the last `--product` given.
8. `SwiftFormal`, `SwiftFormalTesting`, `SFProve`. Broken symbol links fail.
9. `LICENSE`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CHANGELOG.md`, the issue forms and the pull
   request template exist. No home-directory path, token or personal email outside `archive/`.
10. SE-0458: full build with `-strict-memory-safety`; warnings per file of `Sources/` may only fall. Skipped before
    Swift 6.2.
11. `S0FolderOracleTests`: every builtin on literals through `swift-frontend -emit-sil -Onone`. Folded values equal
    S0's, and the folder diagnoses a case (division by zero, overflow, oversized shift) exactly when S0 says undefined.
    Sampled: 17,124 cases, about 3 s. Full: 60,924 cases, about 13 s (debug).
12. Hashes the standard-library code behind each Scan summary (`Sources/SFSIL/SILSummaries.swift`), linked at `-O`,
    against `Scripts/baseline/stdlib-summaries.json` (keyed to compiler, SDK, target). Unpinned compiler: skipped with
    a warning. `--update` records and dumps the changed code for review.
13. `sfverify --json` on the 730 `.swift` tests of the pinned compiler's `test/SIL` and `test/SILOptimizer`, fetched by
    commit SHA into `.build/corpus/` (nothing vendored). Baseline `Scripts/baseline/corpus.json`: counts and a per-file
    hash of (symbol, status) pairs. Fails on a crash, a hang (over 120 s per file), an `INVALID SIL` or prover error not
    in `knownInvalid`, or a verdict flip. 370 files compile, 4,385 functions; 194 s with a debug `sfverify`, 6 jobs.
14. The SIL fuzzer damages 2 hand-written seeds and 9 seeds of real compiler output (`Tests/SoundnessZooTests/FuzzSeeds`,
    made from `Examples/` by `python3 Scripts/make-fuzz-seeds.py`). The fast lane runs a small share of the rounds.

`Scripts/safety-net.sh` runs the fast lane and every static gate. It must end with `SAFETY NET GREEN` before a commit.
It skips the API check (about a minute) when no module behind a public product changed since the branch left `main`.
`SAFETY_NET_FULL=1 Scripts/safety-net.sh` runs everything. CI always runs the API check.

## The mutation lane

`Scripts/mutation-lane.py` holds 14 mutants of the trusted semantic code (S0's encoder and interpreter, trap and
undefined-behaviour plumbing, literal parsing, failure-block detection). Each is an exact source replacement plus the
tests that should kill it, fastest first. The lane applies each one, builds, and runs its tests until one fails.

- It fails on a survivor, or a mutant that no longer applies or does not build. Last result: 14 of 14 killed, 4 min 50 s
  (debug).
- Sources are restored after each mutant, also on Ctrl-C. After a killed run: `--restore`.
- `--check` (safety net) only checks that every mutant still applies. If the replaced code changed, update the mutant
  in the same change.
- A survivor means a test gap: write the killing test (like `SILFailureBlockTests`) and add it to the mutant's list.
  Never delete the mutant.
- New mutant: break one claim of the trusted code and name the test that must notice.

## Conventions

- **Swift Testing only:** `@Test`, `@Suite`, `#expect`, `#require`. Macro expansion tests use
  `SwiftSyntaxMacrosGenericTestSupport` through `assertExpansion` (`Tests/SwiftFormalMacrosTests/ExpansionAssertions.swift`).
  The lanes pass `--disable-xctest` and refuse to run if a file under `Tests/` imports XCTest.
- **Lanes and tags** (`.slow`, `.oracle`, which target or suite a test goes in):
  [CONTRIBUTING](../CONTRIBUTING.md#test-lanes). Tests that need the pinned compiler use `.requiresPinnedCompiler` and
  skip elsewhere with a printed reason.
- **Names say what, when, with what result:** `solver_unsatCore_isAcceptedByChecker`. Do not rename older camelCase
  names: `Scripts/check-test-inventory.sh` fails if a baseline name disappears. A rename needs a line in
  `Scripts/baseline/test-renames.tsv`.
- **Parameterize, do not copy-paste:** `@Test(arguments:)`. Give argument types a `testDescription` so a failure names
  the case.
- **Determinism.** No clock, network, files outside the test's temporary directory, or unseeded randomness. Use
  `SplitMix64(seed:)` with seeds `0 ..< count`; failure messages include the seed. Replay:
  `SF_SEED=<seed> swift test --filter SATDifferentialTests`. Scale: `SF_DIFFERENTIAL_SEEDS` (default 200),
  `SF_FUZZ_ROUNDS` (default 150). Time limits use `.timeLimit`, never a sleep.
- **A bug fix comes with a test that fails without the fix.** A soundness fix (a wrong `proved`) adds a zoo case first,
  then the fix.
- **Known problems stay visible:** `withKnownIssue` plus an entry in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).
  `withKnownIssue` cannot catch a crash: skip that input and name the issue in a comment.
- **Flaky tests are quarantined, never retried until green.** Within 24 hours: `.disabled("flaky: <issue link>")` and
  an open issue. Then fix or delete.
- **Do not test the implementation** (constants, exports, trivial accessors). Test what a user can see, or a soundness
  property.

## Adding a soundness-zoo case

1. Pick the file. Walk, `prove`, `proveSigned`: `Tests/SoundnessZooTests/ZooTests.swift`. Scan (`sfverify`):
   `Tests/SFOracleTests/ScanZooTests.swift`.
2. Add one entry to `Zoo` (`walk(...)`, `signed(...)` or `bits(...)`) with its truth:
   - `.falseClaim`: the tool must refute it with an input that replays.
   - `.trueClaim`: the tool must prove it.
   - the `...BeyondBudget` variants: giving up is fine, a wrong verdict is not.
3. Keep it under about 2 seconds in debug. Use 5 to 8 bits for multiplication and division. If it cannot be fast, put
   it in a `*SlowTests` suite.
4. Run `swift test --filter SoundnessZooTests`. Pass means the tool never says `proved` for a wrong claim.

## The planted-bug suite

Small, generic mappers, each with one bug of a kind found in a real iOS app's 453 rules, and the same mapper fixed.
They live in `Tests/SwiftFormalTestingTests/PlantedBugs/`, one file per shape. Two suites check the same files:
`PlantedBugWalkTests` runs walks (`Prove(it:over:)`, and `runWalk` where a test needs the failing report), and
`PlantedBugScanTests` reads them with logic (Scan, through the `_requires` / `_ensures` peers that `@Verify` writes for
`#requires` / `#ensures`, placed by `#sourceLocation` where the compiler puts `@Verify`'s peers). Each buggy
mapper must be caught at its planted input, and each fixed one must prove.

| Shape | Logic (Scan) | Walk |
|---|---|---|
| 1. Two cases give the same text (`-2` and `2` both print "2") | caught | caught (`Injective`) |
| 2. `fatalError` in a branch only a filtering caller avoids | caught (`mayTrap`); safe with `#requires` | fixed only (a trap ends a walk) |
| 3. parse(format(x)) != x for one locale | known gap | caught (`RoundTrip`) |
| 4. `Int(_:)` of NaN | caught (`mayTrap`, NaN) | fixed only |
| 5. "-0" for a value that rounds to zero | caught for `"-\(n)"`; known gap for `String(format:)` | caught (`Satisfies`) |
| 6. A `default:` arm takes a case | caught | caught (`Matches(table:)`, `Outputs`) |
| 7. enum -> raw -> enum loses a case | caught | caught (`RoundTrip`) |
| 8. Off-by-one range boundary | caught | caught (grouping the outputs, `Satisfies`) |
| 9. A wrong arm over an enum that is only `CaseIterable`, as a binary framework exports it | caught | caught (`Satisfies` over `SignalStrength.domain`, no `Finite`; the fixed one proves over the generated `.signalStrength`) |
| 10. A mapper over a sealed class hierarchy forgets a subclass | known gap | caught (`Satisfies` over a domain `sfgen domains` generated) |
| 11. Types of a binary module: a wrong text for one case of its enum, a `switch onEnum(of:)` that forgets a case or mixes two up | caught | not written (the walk would link the binary module) |
| 12. Closures over rows: a `compactMap` that drops a row, an off-by-one in `first(where:)`, a `filter` that keeps the wrong rows, an `Optional.map` that returns the wrong arm; an `Int8(count)` over an array of unknown length; 12b: a row whose closure may hold the last reference to an object whose `deinit` traps, or whose superclass is of a binary module | caught; the unknown length is `bounded`, never a pass, and proved with a `#requires` that fixes it; 12b proves only with "deinit of TapTracker does not trap" (or of the binary superclass) listed, and is `unsupported` with `--no-opaque-calls` | caught (`Satisfies`); the trap is fixed only |
| 13. Text: two cases pick the same localization key, a format reads an argument it was not given, an interpolation prints the text of another case, and a key missing in one language | caught (`contractFails`, `mayTrap`; the catalogue by `swiftformal strings`); the fixed keys are a known gap | caught (`Injective`, `Satisfies`); the format is fixed only |
| 14. Foundation values: two `UUID`s swapped, rounding at a tie or of `-0.5`, `-0.0` printed, NaN through a guard, a due date one day early, `Decimal` division | caught (`Decimal`: `unsupported`, a gap) | not written |
| 15. Mapped correctly: a packed code where two seats collide only outside the walked samples, a decoder that loses a rare value, a rule that disagrees with its sibling at one boundary, a text rule that returns its raw key | caught by the relational claims (`Injective`, `RoundTrip`, `Agrees`, for every input, in `RelationalProofTests`), and the fixed ones proved; the raw key is walk-only | the samples pass (bounded); caught with the rare input or the whole range (`RoundTrip`, `Agrees`), and the raw key (`NeverOutputs`) |

A known gap is a `withKnownIssue` in `PlantedBugScanTests` with its entry in
[KNOWN-ISSUES.md](KNOWN-ISSUES.md#16-planted-bug-shapes-logic-cannot-catch-yet-by-design-for-now). Its buggy mapper
must still never be `safe` or `contractHolds` (`noBuggyMapperIsEverAPass`). When Scan learns to catch it, the known
issue is not recorded and the test fails: turn it into a plain expectation. The number caught may only grow. Every
test of both suites is in `Scripts/baseline/test-inventory.txt`, so none can be dropped silently.

Run it: `swift test --filter 'PlantedBugScanTests|PlantedBugWalkTests'` (about 12 s in a debug build; the fast lane
runs it). To add a shape, add a file with a `...Buggy` and a `...Fixed` mapper (Foundation only, no SwiftFormal
import) and one test in each suite. Shape 11 needs a binary module, so its mappers are in
`Tests/SFVerifyKitTests/Fixtures/BinaryTypes/PlantedBinaryTypes.swift`, scanned against the `Kit` module that
`BinaryFixture` builds once (a `.swiftmodule` and a static library with no SIL bodies, an Objective-C class target,
SKIE-shaped enums; cached under `.build/sf-fixtures`).

## Quality ratchets

These numbers may stay or improve, never get worse. They live in `Scripts/baseline/quality.json`, checked by
`Scripts/check-ratchet.py`:

- SwiftLint baseline findings (total and per rule), `try!` in `Sources`, lines with `Unsafe` in `Sources`, TODO and
  FIXME markers.
- Size of the trusted code (`SFCheck`, the compiler pin, the SIL semantic model): at most 10% growth, with a note in
  [TRUST.md](TRUST.md). Measure with `python3 Scripts/measure-trust.py`.
- Coverage per module (by hand), against a floor: the measured value minus one point.
- `-strict-memory-safety` warnings per file (by hand). Record a fall with `Scripts/strict-memory-safety.sh --update`.

If a number improved, the check fails until you record it with `python3 Scripts/check-ratchet.py --update`, in the same
change. Old findings never block you: SwiftLint runs against `Scripts/baseline/swiftlint-baseline.json`, and only new
findings fail.

### Strict memory safety warnings

The package stays at tools-version 6.0 and `.strictMemorySafety()` needs 6.2, so the flag comes from the command line.
Marking sites `unsafe` needs 6.2 syntax, which the 6.0 floor cannot parse.

On Apple Swift 6.4: 38 warnings in 8 files. What is left is real: the in-process demangler's `dlopen`/`dlsym` (11); the
trap walk's signal-safe globals and handlers (`SwiftFormalTesting`, 12); the walk probe's globals
(`SwiftFormal/Verify.swift`, 6); `open`/`close` of the walk log (1); `sfgen` (4); the proof cache's `open` with
`O_NOFOLLOW`, `fstat`, `lstat`/`stat` and `rename` (`SFVerifyKit/TrustedFiles.swift`, 5), which check a file on its
open descriptor so it cannot be swapped between check and read.

## Style

`swift format` owns layout: 140 columns, 4 spaces, existing line breaks kept. SwiftLint owns meaning, never whitespace.
Neither is a package dependency; CI is the authority. Commands: [CONTRIBUTING](../CONTRIBUTING.md#style-lint-and-ratchets).

## Measured results

2026-11-05, Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS arm64, debug builds, fast lane.

### Sanitizers

`Scripts/sanitize.sh <sanitizer> fast` with address, thread and undefined: all pass, no findings.

- The claim is small: no data race, memory error or undefined behavior in the code the fast lane reaches.
- The fast lane skips the slow targets (`SFBVTests`, `SFProveTests`, `SFSATTests`, `SFSILTests`) and the oracle lane.
  The solver is reached only through `SoundnessZooTests`, `SelfVerificationTests` and the fast `SwiftFormal*` tests.
- The package is almost all safe Swift: sanitizers mostly watch the few `Unsafe*` pointer uses in the solver and the
  swift-syntax C shims.
- `--sanitize=undefined` needs the UBSan runtime on this toolchain; `Scripts/sanitize.sh` adds it.
- Never run: the slow lane under a sanitizer (`Scripts/sanitize.sh address slow`), release builds under ASan.

### Coverage (line coverage, fast lane)

`python3 Scripts/measure-coverage.py`. Only files in `Sources/<Module>` count. Executable targets (`sfgen`,
`sfverify`) and the plugins are not measured (no test binary links them); their libraries `SFGenKit` and `SFVerifyKit`
are.

| Module | Lines | Covered | Percent | Floor in `quality.json` |
|---|---:|---:|---:|---:|
| SFCNF | 22 | 22 | 100.0 | 99.0 |
| SFSAT | 1324 | 1282 | 96.8 | 95.8 |
| SFSemantics | 226 | 221 | 97.8 | 96.8 |
| SFCheck | 269 | 257 | 95.5 | 94.5 |
| SwiftFormal | 862 | 795 | 92.2 | 91.2 |
| SFBV | 264 | 243 | 92.0 | 91.0 |
| SFVerifyKit | 1213 | 855 | 70.5 | 69.5 |
| SwiftFormalTesting | 171 | 122 | 71.3 | 70.3 |
| SFGenKit | 1048 | 699 | 66.7 | 65.7 |
| SFLLVM | 1167 | 770 | 66.0 | 65.0 |
| SwiftFormalMacros | 287 | 121 | 42.2 | 41.2 |
| SFProve | 575 | 212 | 36.9 | 35.9 |
| SFSIL | 2647 | 889 | 33.6 | 32.6 |

- `SFProve` and `SFSIL` look low because their own tests are in the slow lane. The fast lane reaches them only through
  the zoo, self-verification and gate tests.
- `SwiftFormalMacros` runs inside the compiler plugin, which the expansion tests only partly attribute.
- `python3 Scripts/measure-coverage.py --lane slow` measures the slow lane. It was never run; no floor is based on it.
- Floors are one point below the measurement so that a timing-dependent line does not fail a run. They are not
  targets. Do not chase 100%.
