# SFSAT: the solver

**Job (Inspector view):** the structural engineer's calculator. Given a puzzle of yes/no clauses, it finds a solution or shows that none exists.
**Raw input → typed → result:** clauses (`SFCNF`) → `Solver` → `.sat(model)` / `.unsat(proof)` / budget exhausted. `solveLRAT` also logs a proof that `SFCheck` can verify.
**Depends on:** SFCNF. **Must not depend on:** SFCheck, SFBV (see `docs/TRUST.md`).
**Fast loop:** `Scripts/sandbox.py SFSAT` (runs `SFSATTests`, slow in debug, unmeasured). **Connected loop:** `Scripts/sandbox.py SFSAT --connect`
**Real consumers:** SFProve (every proof), then `sfverify`'s golden verdicts (`Scripts/check-golden.sh`). Checked once on purpose: weakening one `Solver` function body made the golden check and the gate fail.
**Platforms (verified):** macOS, iOS (`swift build --target SFSAT --triple arm64-apple-ios16.0-simulator ...`, and inside the `SFProve` iOS build).
**Known gaps:** `SFSATTests` is slow and was not run to completion in Phase 3B; use `--skip-slow` for a quick loop. That test target also covers `SFCheck`, so the two share one fast loop. `SelfVerificationTests` (fast) checks the clause semantics the solver relies on. `SoundnessZooTests` (fast) compares the solver with brute force on 200 seeded random formulas and checks every model and UNSAT proof (`SF_DIFFERENTIAL_SEEDS` raises the count; a run before a release uses 100000).
