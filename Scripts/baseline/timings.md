date | machine | command | seconds
--- | --- | --- | ---
2026-11-05 | Apple M4 Pro, macOS 27.0, Swift 6.4 | `swift test --skip SFTests` (debug, warm build) | 12
2026-11-05 | same (owner-reported) | `swift test --filter SFTests` (debug) | 780+ (13+ min)
2026-11-05 | same | `swift test -c release --filter SFTests` | not measured in Phase 0 (deliberately skipped: too slow; measure in Task 7.1)
2026-11-05 | same | `swift build --target SFSAT` (cold: fresh `--scratch-path`) | 9
2026-11-05 | same | `swift build --target SFBV` (cold) | 7
2026-11-05 | same | `swift build --target SFSIL` (cold) | 15
2026-11-05 | same | `swift build --target SwiftFormal` (cold) | 7
2026-11-05 | same | full `swift build` (cold) | 21
2026-11-05 | same | `swift build --target <X>` after touching one file (SFSAT, SFBV, SFSIL, SwiftFormal) | 2, 2, 3, 2
2026-11-05 | same | full `swift build` after touching one SFSAT file | 3
2026-11-05 | same | `Scripts/sandbox.py SwiftFormal --connect` (build, tests, SwiftFormalTestingTests, SwiftFormalContractsTests) | 31
2026-11-05 | same | `Scripts/sandbox.py SwiftFormalTesting --connect` | 14
2026-11-05 | same | `Scripts/sandbox.py SFGenKit --connect` | 16
2026-11-05 | same | `Scripts/sandbox.py SFVerifyKit --connect` (tests, golden, gate) | 47
2026-11-05 | same | `Scripts/sandbox.py SFSemantics --connect --skip-slow` (tests, golden) | 77
2026-11-05 | same | `Scripts/sandbox.py SFSemantics --connect` | not finished: its consumer `swift test --filter SFSILTests` was stopped by hand after about 10 minutes

## Task 7.1: test targets, one at a time (2026-11-05)

Machine: Apple M4 Pro (`sysctl -n machdep.cpu.brand_string`), macOS 27.0 (26A428), `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)`, build system `swiftbuild` (the default). Warm builds. "Wall" includes process start-up; "tests" is what Swift Testing printed. Swift Testing runs tests in parallel inside one target, so a test's own time is inflated by its neighbours.

| Target | Debug wall | Debug tests | Release wall | Release tests | Lane |
|---|---|---|---|---|---|
| `SwiftFormalTests` | 3 s | 0.01 s | not run | | fast |
| `SwiftFormalTestingTests` | 3 s | 0.01 s | not run | | fast |
| `SwiftFormalContractsTests` | 3 s | 0.08 s | not run | | fast |
| `SwiftFormalMacrosTests` | 4 s | 0.02 s | not run | | fast |
| `SFGenKitTests` | 2 s | 0.01 s | not run | | fast |
| `SFVerifyKitTests` | 3 s | 0.26 s | not run | | fast |
| `SFSemanticsTests` (before the split) | 43 s | 39.9 s | 11 s | 8.0 s | S0 slow tests and the builtin oracle: see below |
| `SFSATTests` | not run (see below) | | 13 s | 7.7 s | slow |
| `SFBVTests` | not run (11+ min, measured earlier) | | 8 s | 4.4 s | slow |
| `SFProveTests` | not run | | 4 s | 1.7 s | slow |
| `SFSILTests` | not run (about 10 min, stopped by hand earlier) | | 17 s | 14.6 s | slow |
| `SFOracleTests` | not run | | 33 s | 30.7 s | oracle |

Slow targets were **not** run to completion in debug in this task (earlier measurements: `SFBVTests` over 11 minutes, `SFSILTests` about 10 minutes, both stopped). Every slow target finished in release in well under a minute, so none hit the 20-minute limit.

Release tests need `-Xswiftc -enable-testing` (plain `swift test -c release` fails to build: `unable to resolve Swift module dependency to a compatible module: 'SwiftFormal'`, because other test targets use `@testable import`). A first release build of all tests with that flag took 149 s.

Per-test debug times of the three S0 tests that were slow (before the split): `encoderMatchesInterpreterExhaustivelyAt8Bits` 39.9 s, `interpreterMatchesCompilerBuiltins` (spawns `swiftc`) 25.2 s, `encoderMatchesInterpreterThroughSolverOnSamples` 3.7 s, `encoderMatchesInterpreterOnCastsAndWideValues` 3.3 s. Debug is 15 to 30 times slower than release for these tests (for example 2.77 s release against 39.9 s debug), which is how the release numbers were used to decide the `.slow` tags for the suites that cannot be run in debug.

### The lanes, as built (`Scripts/test-lane.sh`)

| Lane | Command | Wall | Tests |
|---|---|---|---|
| fast | `Scripts/test-lane.sh fast` (debug, warm) | 10 s | 7 test targets (`S0Tests` among them) |
| slow | `Scripts/test-lane.sh slow` (release), first run including the release rebuild | 172 s | 135 tests: `SFSATTests`, `SFBVTests`, `SFProveTests`, `SFSILTests`, `S0SlowTests` |
| slow | same, warm | 33 s | |
| oracle | `Scripts/test-lane.sh oracle` (release, warm) | 42 s (tests 38.2 s) | 17 tests |
