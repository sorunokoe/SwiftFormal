# SFSemantics: what Swift's integer operations mean

**Job (Inspector view):** the building code for arithmetic, written once. It says what `add with overflow`, `shift`, `truncate` and the other low-level operations mean, in one table (`S0`).
**Raw input → typed → result:** an operation and its arguments → `S0` → either a plain value computed by the reference interpreter (`evaluate`) or a circuit for `SFBV` (`encode`), and an "undefined behavior" flag.
**Depends on:** SFCNF, SFBV. **Must not depend on:** SFSIL, SFProve (the table must be readable without the compiler front end).
**Fast loop:** `Scripts/sandbox.py SFSemantics` (about 50 s, `SFSemanticsTests`). **Connected loop:** `Scripts/sandbox.py SFSemantics --connect` (adds `SFSILTests`, slow, and the golden check; about 77 s with `--skip-slow`)
**Real consumers:** `SFSIL` (it reads the table) and, through it, `sfverify`: `swift test --filter SFSILTests` and `Scripts/check-golden.sh`.
**Platforms (verified):** macOS, iOS (`swift build --target SFSemantics --triple arm64-apple-ios16.0-simulator ...` succeeds; SwiftPM makes no Xcode scheme for it).
**Known gaps:** `SFSemanticsTests` also depends on `SFSAT`. The consumer `SFSILTests` is slow. No iOS test run.
