# 0004: Tests run in lanes, and other compilers skip with a reason

## Context

One test target, `SFTests`, held the engine tests when this decision was made. A full run took over 13 minutes in debug. Some tests run large SAT problems, and some start `swiftc` or a native binary and compare its output with ours. The SIL reader was validated against exactly one compiler (`Apple Swift version 6.4`). On any other compiler the oracle tests fail in a way that looks like a bug in SwiftFormal, when it is really "this compiler has not been checked". (`SFTests` has since been split into the test targets listed in `Package.swift`.)

## Decision

- Put tests in three lanes. Each test says its lane with a Swift Testing tag from `SFTestSupport` (`.slow`, `.oracle`), and `Scripts/test-lane.sh` runs a lane:
  - **fast** (`Scripts/test-lane.sh fast`): everything not tagged. Runs on every commit and pull request. Measured: 10 seconds in debug on the maintainer's machine, warm.
  - **slow** (`.slow`; `Scripts/test-lane.sh slow`): a test that takes more than 2 seconds in debug, such as large SAT instances or exhaustive sweeps. Runs before a release, in release mode. Measured: 33 seconds warm, about 3 minutes with the first release build.
  - **oracle** (`.oracle`; `Scripts/test-lane.sh oracle`): a test that spawns a process (`swiftc` or a native binary). Runs before a release, on the pinned compiler only. Measured: 42 seconds warm.
- **The tags label; target and suite names select.** `swift test` in the Swift 6.4 toolchain has `--filter` and `--skip` (regular expressions over test names) but no way to select tags. So the script skips whole test targets (`SFBVTests`, `SFProveTests`, `SFSATTests`, `SFSILTests`, `SFOracleTests`) and every suite whose name ends in `SlowTests` (`S0SlowTests`, `BitVectorSelfSlowTests`, ...), and the tags record which tests belong to which lane. The oracle tests live in `SFOracleTests` for that reason (the S0 builtin oracle moved there from `SFSemanticsTests`).
- A test that needs the pinned compiler is skipped with a printed reason on any other compiler (`.requiresPinnedCompiler`). It does not fail. See `docs/guides/compilers.md`.
- `Scripts/safety-net.sh` runs the fast lane. It does not run the slow or oracle lanes, and the exhaustive 8-bit encoder checks (`S0SlowTests`) and the exhaustive 8-bit self-verification sweeps (`BitVectorSelfSlowTests`) are slow-lane tests, so they are not in it.
- A `proved` that is wrong is the worst kind of bug. The slow and oracle lanes are not optional for a release even though they are not run on every commit.
- Release test builds need `-Xswiftc -enable-testing` (the script passes it); otherwise `@testable import` in the other test targets fails to build.

## Consequences

- Contributors get an answer in under a minute for most changes.
- The slow and oracle lanes find soundness problems later than the fast lane would, so a change in the engine must run them before it is merged.
- Using a new compiler is an explicit step: run the oracle lane on it, review any SIL grammar differences, then add it to the verified list.
