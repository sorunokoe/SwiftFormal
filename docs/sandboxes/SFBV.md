# SFBV: the bit-vector encoder

**Job (Inspector view):** turns arithmetic into the puzzle the solver understands. A 32-bit addition becomes a set of yes/no clauses.
**Raw input → typed → result:** fixed-width bit vectors (`BitVec`) and operations (add, multiply, shift, divide, compare) → `CNFBuilder` → a `CNF` for `SFSAT`.
**Depends on:** SFCNF. **Must not depend on:** SFSAT, SFCheck (the encoder never calls the solver).
**Fast loop:** `Scripts/sandbox.py SFBV` (runs `SFBVTests`: **11+ minutes in debug, it was killed unfinished**). **Connected loop:** `Scripts/sandbox.py SFBV --connect`
**Real consumers:** SFProve and SFSemantics. The connected loop runs `swift test --filter SFProveTests`, `--filter SFSemanticsTests` and `Scripts/check-golden.sh`.
**Platforms (verified):** macOS, iOS (`swift build --target SFBV --triple arm64-apple-ios16.0-simulator ...`, and inside the `SFProve` iOS build).
**Known gaps:** `SFBVTests` is very slow and is the main reason the safety net skips it. It also imports `SFSIL` and `SFLLVM` (the multiplier-hook tests), so a change in those modules can break this test target. Use `--skip-slow` for a quick loop, and run the full target in release or overnight. `SelfVerificationTests` compares the circuits with Swift's own operators: exhaustively at 8 bits (`BitVectorSelfSlowTests`, slow lane), by proof at 32 bits and on seeded samples at 64 bits. Its fast suites take about 3 s.
