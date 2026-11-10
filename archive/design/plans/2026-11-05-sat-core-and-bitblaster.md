# SAT core, proof checker and bit-blaster: Implementation Plan (Plan 1 of the pure-Swift verifier)

> **For agentic workers:** use superpowers:executing-plans. Steps use checkboxes.

**Status (2026-11-05): Tasks 1 to 6 done.** 20 tests pass in debug and release. Deviations: added solver
restarts and clause minimization and rewrote the checker with watched literals after measuring (see
research note section 12); `ScratchProfile`/`MulBench` benchmarks were run outside the repo. Because another
session is editing the root `Package.swift` concurrently, tests were run in an isolated copy.

**Goal:** a pure-Swift, deterministic path from a bit-vector goal to either `proved` (proof accepted by an
independent checker) or a counterexample. This is phase P1 of `archive/design/specs/2026-11-05-pure-swift-verifier-design.md`.

**Architecture:** new SwiftPM package at the repo root; `experiments/` stays frozen. Targets:
`SFCNF` (shared plain data types), `SFSAT` (CDCL solver), `SFCheck` (proof checker; imports only `SFCNF`,
never the solver), `SFBV` (CNF builder and bit-vector circuits), `SFProve` (glue: goal to verdict).

**Tech stack:** Swift 6.4, SwiftPM, Swift Testing. No external dependencies.

**Decision recorded:** v1 proofs are **RUP clause lists** (each learned clause must be derivable by unit
propagation; the checker does its own propagation). This replaces LRAT in the design for now: it needs no
hints, so the solver and checker stay simpler. LRAT hints are a later speed-up for P3 if checking is slow.

**Not in this plan:** SIL/AST front ends, VC generator, contracts, second encoder, loops (Plans 2 and later).

---

### Task 1: Package skeleton and shared types

**Files:** create `Package.swift`, `Sources/SFCNF/CNF.swift`

- [ ] Define `Clause = [Int32]` (DIMACS literals, never 0), `CNF { numVars, clauses }`, `SolveResult`
  (`sat(model)`, `unsat(proof)`, `unknown`), and `CNF.isSatisfied(by:)`.
- [ ] Run `swift build`. Expected: builds.

### Task 2: Independent proof checker (test first)

**Files:** create `Sources/SFCheck/RUPChecker.swift`, `Tests/SFTests/CheckerTests.swift`

- [ ] Tests: a valid hand-made refutation is accepted; a proof without the empty clause is rejected; a
  non-RUP clause is rejected.
- [ ] Implement `RUPChecker.check(cnf:proof:) -> Bool` by naive unit propagation over the clause database.
- [ ] Run `swift test --filter CheckerTests`. Expected: pass.

### Task 3: CDCL solver

**Files:** create `Sources/SFSAT/Solver.swift`, `Tests/SFTests/SolverTests.swift`

- [ ] Tests: trivial SAT, trivial UNSAT, pigeonhole 4 into 3 (UNSAT, proof accepted by `RUPChecker`),
  300 seeded random 3-SAT instances agreeing with brute force (model satisfies the CNF; proof accepted),
  corrupted proof rejected, conflict budget returns `unknown`.
- [ ] Implement two watched literals, 1UIP learning, backjumping, activity heuristic, phase saving,
  deterministic conflict budget, proof emission.
- [ ] Run `swift test --filter SolverTests`. Expected: pass.

### Task 4: CNF builder and bit-vector circuits

**Files:** create `Sources/SFBV/CNFBuilder.swift`, `Sources/SFBV/BitVec.swift`, `Tests/SFTests/BitVecTests.swift`

- [ ] Tests (differential against native Swift): add, sub, mul, ult, slt, eq, signed add and mul overflow
  flags; exhaustive 8-bit via constant folding; exhaustive 4-bit via the real solver.
- [ ] Implement Tseitin gates with constant folding, then the circuits.
- [ ] Run `swift test --filter BitVecTests`. Expected: pass.

### Task 5: Prove glue and end-to-end properties

**Files:** create `Sources/SFProve/Prove.swift`, `Tests/SFTests/ProveTests.swift`

- [ ] Tests: `x + y == y + x` proved at 16 bits; `x * 3 == x + x` yields a counterexample that satisfies
  the circuit; 64-bit clamp stays within `[lo, hi]` when `lo <= hi`; 64-bit add overflow condition
  matches the native `addingReportingOverflow`. Print wall time.
- [ ] Implement `prove(width:build:)` returning `.proved`, `.counterexample([UInt64])`, `.unknown`.
- [ ] Run `swift test`. Expected: all pass.

### Task 6: Record results

- [ ] Add measured timings and limitations to `docs/research/2026-11-05-pure-swift-verifier-feasibility.md`
  section "P1 measurements". Mark estimates versus measurements.
