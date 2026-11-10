# SwiftFormal: Walk, the core

**Job (Inspector view):** the inspector who walks every room. It lists the inputs of a function (the floor plan) and runs the real function on each one.
**Raw input → typed → result:** a `Domain` (a list of values) and a `Property` → the walk (`runWalk`, `package`; users reach it through `Prove` in SwiftFormalTesting and through the `verify_<name>()` that `@Verify` writes, which calls the public but undocumented `_verifyContracts`) → `Verdict`: `proved`, `bounded` or `counterexample` with the failing input.
**Depends on:** SwiftFormalMacros only, a compiler plugin that writes the `@Verify` code while the user's code builds; nothing of it is linked into an app. **Must not depend on:** any other target (no engine, no Testing).
**Fast loop:** `Scripts/sandbox.py SwiftFormal` (about 30 s with the connected loop). **Connected loop:** `Scripts/sandbox.py SwiftFormal --connect`
**Real consumers:** `SwiftFormalTesting` (its test target), `Examples/Verify` (`@Verify` with `import SwiftFormal`), through `swift test --filter SwiftFormalTestingTests`. `SwiftFormalAppImportTests` (an app-shaped file next to SwiftUI) runs in the fast loop with `SwiftFormalTests`.
**Platforms (verified):** macOS, iOS (`xcodebuild -scheme SwiftFormal -destination 'generic/platform=iOS Simulator' build` succeeds).
**Known gaps:** the example is [`Examples/Walk`](../../Examples/Walk). A Swift trap inside a walked function cannot be caught in-process (see `docs/TRUST.md`). `Domain` and `runWalk` are checked with Walk itself in `SelfVerificationTests` (fast, `Scripts/sandbox.py SwiftFormal` runs it). `SoundnessZooTests` (fast) puts wrong claims (`x + 1 > x`, `abs`, `INT_MIN / -1`, ...) to `runWalk`: none may be proved, every counterexample is replayed.
