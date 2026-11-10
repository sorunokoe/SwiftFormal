# SFSIL: reading the compiler's own output

**Job (Inspector view):** the translator. It reads the compiler's lowered code (SIL) for a function, turns it into the puzzle the solver understands, and asks "can this trap?". It also keeps the proof cache and the compiler pin.
**Raw input → typed → result:** SIL text from `swiftc` → `SILParser` → `SILModule` → `SILEncoder` + `SFSemantics` → `SILVerifier` (using `SFProve`) → a verdict. `ProofCache` and `CachedVerifier` store and reuse verdicts; `PinnedCompiler` refuses compilers that were not checked.
**Depends on:** SFCNF, SFBV, SFSemantics, SFProve. **Must not depend on:** SFLLVM, SFVerifyKit.
**Fast loop:** `Scripts/sandbox.py SFSIL` (runs `SFSILTests`, slow in debug, unmeasured). **Connected loop:** `Scripts/sandbox.py SFSIL --connect`
**Real consumers:** `SFVerifyKit` and `sfverify`: `swift test --filter SFVerifyKitTests`, `Scripts/check-golden.sh`, and the gate on `Examples/GatedPackage`.
**Platforms (verified):** macOS only. It starts `swiftc` with `Process` (`SILVerify.swift`, `ProofDigest.swift`), which does not exist on iOS: the iOS build fails with `cannot find 'Process' in scope`.
**Known gaps:** the largest sandbox (about 2,965 lines in 8 files). The proof-cache and compiler-pin code could not be carved out without a cycle, see `docs/decisions/0009-carve-outs.md`. `SFSILTests` is slow and starts the compiler. A new compiler version must be added to the pin after the oracle lane has run on it. `SoundnessZooTests` (fast) fuzzes the SIL reader and encoder with truncated and mutated text: a result or a typed error, never a crash or a hang.
