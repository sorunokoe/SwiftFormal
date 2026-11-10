# SFTestSupport: the lane tags and fixture packages

**Job (Inspector view):** the sticky labels on test cases. It declares the Swift Testing tags `.slow` (more than 2 seconds in a debug build) and `.oracle` (starts `swiftc` or a native binary) that the test targets use to say which lane a test belongs to.
**Raw input → typed → result:** nothing to run. Test targets `import SFTestSupport` and write `@Suite(.tags(.slow))`. `FixturePackage` writes a package under `.build/fixtures/<name>` that depends on this checkout by path, as an app does (it sees only the public API), and builds one of its targets; a slow test asserts what compiles there and what the compiler says.
**Depends on:** nothing. **Must not depend on:** any production target (it must not pull a compiler front end into a test target that does not already have one).
**Fast loop:** `Scripts/sandbox.py SFTestSupport` (builds the target only; it has no tests).
**Real consumers:** the test targets `SFSATTests`, `SFBVTests`, `SFProveTests`, `SFSemanticsTests`, `SFSILTests`, `SFOracleTests`; `FixturePackage`: `SFGenKitTests` (`GeneratedTestsSlowTests`) and `SwiftFormalTestingTests` (`OneWayToWalkSlowTests`). Lanes are run with `Scripts/test-lane.sh` (see [ADR 0004](../decisions/0004-test-lanes.md)).
**Platforms (verified):** macOS. Not built for iOS and not claimed.
**Known gaps:** `swift test` cannot select tags yet (no `--skip-tag` in the Swift 6.4 toolchain), so the tags are labels and `Scripts/test-lane.sh` picks lanes by target and suite name. If a later toolchain can select tags, the script becomes one line per lane.
