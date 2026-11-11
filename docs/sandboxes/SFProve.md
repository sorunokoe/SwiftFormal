# SFProve: symbolic proofs, whole integer ranges

**Job (Inspector view):** the structural engineer who proves a claim for all values at once, instead of walking every room. A second engineer (`SFCheck`) must countersign every certificate.
**Raw input → typed → result:** a claim over signed integers of given widths (`proveSigned`, `SymbolicInt`, `SymbolicBool`) → `SFBV` encodes, `SFSAT` solves, `SFCheck` checks → `.proved` / `.mayTrap(inputs)` / `.claimFails(inputs)` / `.unknown`.
**Depends on:** SFCNF, SFSAT, SFCheck, SFBV. **Must not depend on:** SFSIL, SFSemantics, SFLLVM, SFVerifyKit (the engine must not know about the compiler front end).
**Fast loop:** `Scripts/sandbox.py SFProve` (runs `SFProveTests`, slow in debug, unmeasured). **Connected loop:** `Scripts/sandbox.py SFProve --connect`
**Real consumers:** `SFSIL` (through `swift test --filter SFSILTests`, slow) and `sfverify` (`Scripts/check-golden.sh`).
**No product:** `SwiftFormalTesting` re-exports it (`import SwiftFormalTesting`).
**Platforms (verified):** macOS, iOS (built as a dependency of the `SwiftFormalTesting` scheme for the iOS Simulator).
**Known gaps:** the example is [`Examples/Prove`](../../Examples/Prove), a test that imports `SwiftFormalTesting`. Both test consumers are slow, so the quick loop is `--skip-slow` (golden only). Tests were not run on an iOS simulator. `SelfVerificationTests` runs `prove` on identities of two's-complement arithmetic (fast suite `ProofSelfTests`, slow suite `ProofSelfSlowTests`). `SoundnessZooTests` (fast) puts wrong claims (overflow, signed versus unsigned, division, midpoint) to `proveSigned` and `prove`: none may be proved, every counterexample is replayed on plain Swift.
