# SFCheck: the second engineer who countersigns

**Job (Inspector view):** the independent checker. It reads the solver's proof step by step and agrees or refuses. It does no searching and shares no code with the solver.
**Raw input → typed → result:** a CNF and an LRAT proof → `LRATChecker` / `RUPChecker` → accepted, or a rejection naming the step.
**Depends on:** SFCNF. **Must not depend on:** SFSAT, SFBV, or anything else. This is the independence rule in `docs/TRUST.md`; `Scripts/check-layering.py` fails on any other dependency.
**Fast loop:** `Scripts/sandbox.py SFCheck` (runs `SFSATTests`, slow in debug, unmeasured). **Connected loop:** `Scripts/sandbox.py SFCheck --connect`
**Real consumers:** SFProve: a `proved` is accepted only after this checker agrees. Then `Scripts/check-golden.sh`.
**Platforms (verified):** macOS, iOS (`swift build --target SFCheck --triple arm64-apple-ios16.0-simulator ...`, and inside the `SFProve` iOS build).
**Known gaps:** it has no test target of its own: its tests live in `SFSATTests`, together with the solver tests. Slow, see the SFSAT card. `SoundnessZooTests` (fast) feeds the checkers fuzzed and random proofs of satisfiable formulas; neither checker may accept one.
