# Design: SwiftFormal pure-Swift verifier (v1 scope)

Date: 2026-11-05. Status: **approved by delegation ("decide yourself"); P1 built (see plan and research note section 12).**
Change since drafting: v1 proofs are RUP clause lists, not LRAT (simpler; LRAT is a later speed-up).
Based on: `docs/research/2026-11-05-pure-swift-verifier-feasibility.md` and
`docs/research/2026-11-05-nl2vc-dafny-paper-analysis.md`.

## 1. Decisions taken (from the user's answers)

| Question | Decision |
|---|---|
| External solvers (Z3, cvc5, CaDiCaL)? | **No.** The shipped default is pure Swift. External solvers may be used only as *test-time fuzz oracles* on a developer machine, never in the verify path and never required. |
| First targets | Chosen by us (section 3). |
| Latency | **Milliseconds to a few seconds** per function. Hard budget: 5 s wall, enforced by a deterministic conflict budget, not a timer. |
| Independent second opinion | **Wanted.** Delivered by two independent pure-Swift routes (section 6). Lean stays as an optional dev-time cross-check while it still finds bugs. |

## 2. Goal and non-goals

**Goal:** given a Swift function with contracts, return one of `proved`, `counterexample` (replayable on
the real compiled function), or `unknown(reason)`, in at most a few seconds, as structured JSON an AI
repair loop can consume. Everything runs from `swift build`.

**Non-goals for v1:** quantifiers, strings, floating point, classes/reference aliasing, closures,
generics beyond monomorphic scalars, concurrency, proving the Swift compiler correct.

## 3. First targets (v1 scope)

Pure functions over fixed-width integers and `Bool`, plus a small tuple/struct of those:

1. Money and pricing: discount, clamp, rounding, percentage math (existing `clampedDiscount`).
2. Saturating and checked arithmetic helpers, range and bounds predicates.
3. Small state-machine transition functions over `enum` with scalar payloads.
4. Counted loops with a scalar accumulator (sum, popcount, gcd-style), where an invariant is a Swift `Bool`.
5. Fixed-size array indexing (`InlineArray`/bounded) with a statically known length, added after 1 to 4.

Reason: these are common in iOS business logic, fit the bit-vector fragment, and have unambiguous
native semantics to test against.

## 4. Approaches considered

- **A. Bit-blast + own CDCL + proof certificate (recommended).** Fully pure Swift, deterministic,
  proof-producing. Cost: 64-bit multiply/divide are expensive (mitigated, section 7).
- **B. Symbolic execution by operator overloading only.** Fast to prototype, but cannot intercept `if`;
  keep as a spike and cross-check, not the engine.
- **C. Own SMT solver with theories (LIA, arrays).** Powerful but a multi-year Z3 rebuild. Deferred
  until measured need.

Choose **A**, with B as a cheap cross-check and C as a later tier.

## 5. Architecture

```
Swift source ──swiftc──► SIL text ──► SIL reader ──┐
             └──────► typed AST JSON ─► AST reader ─┴► IR  ──► VC generator ──► BV expressions
                                                                                   │
 contracts (#requires/#ensures/#invariant macros) ──► Contract IR ─────────────────┘
                                                                                   ▼
                      simplify + range analysis ──► bit-blaster ──► CNF ──► CDCL solver
                                                                                   │
                           SAT  ──► model ──► counterexample ──► replay on native Swift
                           UNSAT ─► LRAT proof ──► proof checker ──► `proved`
                           budget hit ─────────────────────────► `unknown(reason)`
```

Swift package layout (modules, each with one purpose and a small interface):

| Module | Purpose | Depends on |
|---|---|---|
| `SFIR` | Typed IR, operators with explicit trap semantics | none |
| `SFFrontendSIL` | SIL text to IR (grows from existing reader) | SFIR |
| `SFFrontendAST` | Typed AST JSON to IR, names and source spans for diagnostics | SFIR |
| `SFContracts` | Contract macros and contract IR | SFIR |
| `SFVC` | Weakest-precondition VC generator, passive form, loop rules | SFIR, SFContracts |
| `SFBV` | Bit-vector expression DAG, hash-consing, simplifier, interval analysis | SFIR |
| `SFSAT` | CNF, CDCL solver, LRAT emitter | none |
| `SFCheck` | **Independent** proof checker and independent model evaluator | SFSAT types only |
| `SFReplay` | Counterexample to native execution on the real function | SFIR |
| `SFReport` | Structured JSON diagnostics, trust ledger | all |
| `sfverify` | CLI and SwiftPM command plugin | all |

Rule: `SFCheck` must not import the solver or the bit-blaster implementation, so the trust anchor stays small.

## 6. Trust model and the independent second opinion

Claim a result `proved` only if **all** hold:

1. **Route 1 (primary):** bit-blast, CDCL, LRAT proof, accepted by `SFCheck`.
2. **Route 2 (independent):** a *second, separately written* encoder (different structure, for example
   ripple-carry vs prefix adders, written without sharing code with route 1) produces its own CNF, and the
   result and proof must agree. A disagreement is reported as an internal error, never as `proved`.
3. **Native differential tests (continuous):** each operator is tested against real Swift execution:
   exhaustively at 8 and 16 bits and by random sampling at 64 bits.
4. **Translation validation** of IR against the compiler artifact (existing 0.0.4 work).
5. **Optional dev-time cross-check:** existing Lean path and, if a developer has them, Z3/cvc5 as fuzz
   oracles. Not in the user's verify path.

Stated gaps (always printed in the report): the LRAT proof covers the CNF, not the faithfulness of the
encoding to Swift semantics (covered by 2 to 4 only empirically); Swift has no formal semantics; the
compiler is trusted; results are relative to the pinned compiler version.

## 7. Meeting the latency target

- In-process, no process spawn, no file round trips. Hash-keyed proof cache per function and contract.
- Determinism: fixed seeds, conflict-count budget, no wall-clock-dependent decisions.
- Cheap-first ladder per obligation: constant folding, interval analysis (discharges most overflow checks),
  bounded concrete tests for fast counterexamples, then SAT.
- Hard cases (64-bit multiply, divide, variable shifts): interval pre-pass, constant-operand strength
  reduction, and if still over budget return `unknown(multiplication-too-wide)` rather than hanging.
  Spike P3 decides whether more is needed.
- Success target: median under 200 ms and 95th percentile under 5 s on the v1 target set. These are
  goals to be measured, not promises.

## 8. Contracts

```swift
@Verify
func clampedDiscount(price: Int, percent: Int) -> Int {
    #requires(0 <= price && price <= 1_000_000)
    #requires(0 <= percent && percent <= 100)
    #ensures { $0 >= 0 && $0 <= price }
    ...
}
```

- Contracts are ordinary Swift `Bool` expressions, so tests can also run them dynamically.
- Macros only capture text and source spans. They carry no semantics; the verifier reads the checked AST.
- Loops use `#invariant` and `#decreases`. Ghost code is stripped in release builds.
- No `assume` allowed in AI-authored mode. Contract hash is frozen during repair loops.

## 9. Error handling

- Unsupported construct: fail closed with `unsupported(<construct>, span)`; never guess.
- Compiler version mismatch or unknown SIL instruction: `unsupported(compiler)`.
- Proof check fails or routes disagree: `internal-error`, exit code distinct from `unknown`.
- Counterexample that does not reproduce natively: `internal-error`, not a bug report.

## 10. Testing strategy

- Per-operator differential tests against native Swift (Swift Testing).
- Property tests: random small programs, compare solver verdict with brute force at 8 bits.
- Solver tests: SAT/UNSAT corpora, mutated proofs must be rejected by `SFCheck`.
- Negative controls: wrong contracts must yield counterexamples that replay natively.
- Regression: reproduce existing 0.0.4 and 0.0.6 Lean verdicts exactly.

## 11. Phases with kill criteria

| Phase | Deliverable | Pass if | Stop or pivot if |
|---|---|---|---|
| P0 | AST JSON reader for names/spans, symbolic-type spike on `clampedDiscount` | Counterexample found without Lean | Needs large source changes |
| P1 | SFIR, SFBV, SFSAT, SFCheck on existing scalar functions | Same verdicts as Lean; proof accepted | Unexplained disagreement |
| P2 | Second encoder, exhaustive 8/16-bit differential suite, mutated-proof tests | Gates catch seeded bugs | Soundness bugs keep surviving |
| P3 | Benchmarks incl. 64-bit multiply/divide | Meets section 7 targets | p95 over 5 s on core targets |
| P4 | Loops, invariants, bounded checking | Counted-loop targets proved | Invariant burden blocks |
| P5 | AI repair loop on 10 to 30 functions, spec-mutation checks | Non-trivial verify@k with intervals | Models game the contracts |

## 12. Open items for the user

- Confirm the target list in section 3.
- Confirm "unknown beats slow": exceeding the budget returns `unknown`, never waits.
- Confirm Lean stays optional and dev-only during P1 and P2, then is dropped if it finds nothing.
- Repository layout: add a new SwiftPM package at the repo root, leaving `experiments/` frozen as evidence.
