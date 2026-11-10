# SFCNF: the shared alphabet

**Job (Inspector view):** the common language of the engineers. It only defines what a clause (a yes/no condition) and a formula are, so the solver, the encoder and the checker can talk about the same thing.
**Raw input → typed → result:** DIMACS-style integer literals → `Clause`, `CNF` and `SolveResult` values. There is nothing to run.
**Depends on:** nothing. **Must not depend on:** any other target. It is also capped at 150 non-blank lines (`Scripts/check-layering.py`); today it has 29. If it must grow, redraw the boundary instead.
**Fast loop:** `Scripts/sandbox.py SFCNF` (builds the target only; it has no test target of its own). **Connected loop:** `Scripts/sandbox.py SFCNF --connect`
**Real consumers:** every engine module (SFSAT, SFCheck, SFBV and everything above). The connected loop runs `swift test --filter SFSATTests`, `--filter SFProveTests` and `Scripts/check-golden.sh`.
**Platforms (verified):** macOS, iOS (`swift build --target SFCNF --triple arm64-apple-ios16.0-simulator ...` succeeds, and it is inside the `SFProve` iOS build).
**Known gaps:** no tests of its own: it holds only types. The consumers listed above include slow test targets (`SFSATTests`, `SFProveTests`, unmeasured; see `docs/guides/sandbox-workflow.md`). `SelfVerificationTests` checks `CNF.isSatisfied(by:)` against a hand-written formula (fast).
