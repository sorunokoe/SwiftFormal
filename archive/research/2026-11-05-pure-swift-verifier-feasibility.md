# Research note: a verifier written entirely in Swift (no Lean, no Dafny)

Date: 5 November 2026. Status: research only. Nothing here is a design decision or a promise.
Builds on `2026-11-05-nl2vc-dafny-paper-analysis.md`.

**Question:** what would it take, what do we gain, and what could go wrong if SwiftFormal's
whole pipeline is Swift, reusing the *techniques* of Lean and Dafny but none of their tools?

Labels used below: **[verified]** I saw it in a source or ran it locally. **[judgment]** my estimate
or opinion. **[unverified]** plausible but I did not check.

## 1. Short answer

- **Yes, a Swift-only pipeline is feasible for a narrow scope.** Swift integers are fixed width, so
  for loop-free scalar code every question is a *bit-vector* question, which is decidable by
  bit-blasting to SAT. You do not need a theorem prover for that. [judgment, standard technique]
- **It is not feasible to match Dafny or Lean in power.** Dafny's strength is quantifiers, sets,
  sequences, ghost state and heap reasoning on top of Z3. Rebuilding that is a multi-year solver project.
  [judgment]
- **The honest trade is trust for speed and control.** We lose a kernel-checked proof by an
  independent, mature system. We gain in-process speed, structured AI feedback, and one toolchain.
  We can win back much of the trust with *proof certificates* checked by a tiny Swift checker.
- **Recommended shape [judgment]:** Swift owns everything except the solver search. Put the solver behind a
  protocol, ship a small built-in pure-Swift bit-vector solver, and allow an optional external solver
  as an untrusted helper whose answers are certificate-checked. "No Lean/Dafny" does not have to
  mean "no Z3/CaDiCaL ever".

## 2. What exists locally today

[verified, from the repo and my probes]

- About 600 lines of Swift already do SIL reading, an IR, and an interpreter
  (`experiments/scalar-extraction/Sources/ScalarExtraction`: `SILReader.swift` 331, `IR.swift` 125,
  `Interpreter.swift` 95, `CollectedSIL.swift` 180). Orchestration is Python (`run.py`).
- Lean does the proving (full Lean check about 58 s; whole experiment about 4 to 7 minutes, per README).
- Installed: Swift 6.4, Lean 4.35. **Not installed: z3, cvc5, bitwuzla, cadical, kissat, minisat, dafny, why3.**
  Any solver comparison needs an install step.
- The Swift compiler gives us two usable frontends on this machine:
  - `swiftc -frontend -emit-sil -Onone` gave canonical SIL in about 0.1 s for a tiny function. The checked
    comparison shows as `builtin "cmp_slt_Int64"` and the branch as `cond_br`.
  - `swiftc -frontend -typecheck -dump-ast -dump-ast-format json` gave a **fully type-checked AST as JSON**
    in about 0.17 s. It resolves each operator to its declaration (for example `&-` to
    `FixedWidthInteger.&-` with the generic substitution `Int`), and keeps source ranges. This needs
    `-sdk $(xcrun --show-sdk-path)`. The flag is a compiler-internal dump option, so treat its stability as
    unknown [unverified].

## 3. What "Swift only" would have to contain

| # | Component | Reuses technique from | Swift-specific notes | Effort [judgment, one expert dev] |
|---|---|---|---|---|
| 1 | Frontend: SIL text reader (exists) and/or typed-AST JSON reader | Boogie/Viper-style IVL front ends | SIL is unstable between compiler versions; pin version, fail closed | have 0.0.x; 2 to 4 weeks to broaden |
| 2 | Contract capture: `#requires`, `#ensures`, `#invariant`, `decreases`, `@Verify` | Dafny, Design by Contract | SwiftSyntax macros are syntactic only; use them to record text and spans, not meaning | 2 to 3 weeks |
| 3 | Verification-condition generator on a small IR | Boogie (passive form), Flanagan-Saxe linear-size VCs, Hoare/Dijkstra wp | Traps (overflow, array bounds, division) become explicit proof obligations | 3 to 6 weeks |
| 4 | Loops: invariant check + havoc + ranking function | Dafny `invariant`/`decreases` | Start with `for i in a..<b` and `while` only | 2 to 4 weeks |
| 5 | Expression layer: simplifier, constant folding, range facts | Bitwuzla-style rewriting (Lean's `bv_decide` copies these) | Pure Swift enums with indirect cases; hash-consing needed | 2 to 4 weeks |
| 6 | Bit-blaster to an AIG/CNF | Boolector/Bitwuzla/Z3, Lean `bv_decide` | 64-bit add/compare cheap; **multiply/divide/shift are expensive** | 2 to 4 weeks |
| 7 | SAT solver (CDCL) with LRAT-style proof output | MiniSat/CaDiCaL | Basic CDCL is small. Competitive performance (restarts, inprocessing, tuned heuristics) is months to years | basic 1 to 3 weeks; fast: open ended |
| 8 | Certificate checker for SAT proofs (LRAT) | cake_lpr, LRAT checkers in Coq/ACL2 | Small and simple by design; this is the trust anchor | 1 to 2 weeks |
| 9 | Counterexample extraction and replay on native Swift | CBMC/Kani, Dafny "better counterexamples" | Run the model on the real compiled function to confirm the bug | 1 to 2 weeks |
| 10 | Linear integer arithmetic (simplex or omega) | SMT arithmetic solvers | Avoids bit-blasting blow-up on sums and loop bounds; needed once loops appear | 4 to 8 weeks |
| 11 | Invariant help: bounded checking first, Houdini-style pruning, k-induction | Houdini (Flanagan-Leino), CBMC, k-induction | Directly attacks the paper's "invariant gap" | 3 to 6 weeks |
| 12 | Structured diagnostics (JSON) for AI repair loops | DafnyPro, AlphaVerus | Our own format; stable and versioned | 1 to 2 weeks |
| 13 | Assurance report and trust ledger | Existing 0.0.x evidence work | Already a strength of this repo | ongoing |

Rough total for a **credible narrow MVP** (rows 1 to 9 and 12 to 13: scalar code, straight-line plus
branches, simple counted loops, counterexamples, certificates): **about 3 to 6 months for one
experienced developer** [judgment, high uncertainty]. Rows 10 and 11 add 2 to 4 more months.
A *competitive* solver and rich theories (arrays, strings, floats, quantifiers) is a different,
multi-year project.

## 4. The key technical insight: Swift's finite integers help

- Loop-free scalar function: the whole obligation is quantifier-free bit-vector logic. Decidable,
  and counterexamples come for free. Lean's own `bv_decide` does exactly this pipeline
  (verified bit-blaster to AIG to CNF to CaDiCaL to LRAT proof, then a Lean-verified LRAT checker)
  [verified, Lean docs]. We would replicate the idea without Lean's verified parts.
- With simple loops, obligations stay quantifier-free if invariants are quantifier-free boolean Swift
  expressions. That is natural for AI and humans: **an invariant is just a Swift `Bool` expression**.
- The hard boundary is **collections and quantifiers** ("for all i in 0..<n"). Dafny handles them with
  Z3 quantifier instantiation (E-matching). Its triggers are a known source of unstable proofs; Dafny
  has dedicated guidance on brittleness and a research line on trigger selection [verified, Dafny blog and
  CAV 2016 title]. A homemade Swift solver should **avoid quantifiers** at first and use bounded
  sequences, fuel for recursion, and explicit loop invariants instead.
- Known hard case: bit-blasting **64-bit multiplication and division** is slow for any SAT-based solver.
  Mitigation [judgment]: range analysis first, prove no-overflow with intervals, and reason about
  products in linear arithmetic when one factor is a constant.

## 5. Frontend options (each has a different failure mode)

| Option | How it works | Pros | Cons |
|---|---|---|---|
| F1 SIL text (current) | `swiftc -emit-sil`, parse, translate | Exact checked-arithmetic and trap semantics; compiler already resolved everything | SIL text and binary formats are not stable across versions [verified, SIL docs]; needs the compiler at verify time |
| F2 Typed AST JSON | `-dump-ast -dump-ast-format json` | Keeps source names, ranges, resolved operator decls and generic substitutions; good for diagnostics and contract spans | Dump flag stability unknown [unverified]; semantics of `+` vs `&+` still need a model; verbose |
| F3 Own parser (SwiftSyntax) plus own type checking | Parse and resolve ourselves | No compiler version dependence | **Trap:** overload resolution, generics, operators, protocol conformances. Re-implementing the type checker is a huge and error-prone project. Not recommended. |
| F4 Symbolic types / concolic by re-execution | Compile real code with `typealias Int = SymInt64` (or generics), overloaded operators build expressions, branches decided by replay | No SIL or AST parsing; runs the real code through the real compiler; fast to prototype | `if` cannot be overloaded, so branches need a helper or replay; stdlib uses concrete `Int`; semantic drift; only bounded exploration. [unverified, spike needed] |
| F5 Compiler-internal (Swift code inside swift compiler tree) | The compiler's own SIL optimizer is written in Swift (`SwiftCompilerSources`) and has a Swift API over SIL [verified] | Rich, typed SIL API | It is in-tree: needs building the compiler; not a supported out-of-tree package interface [judgment]. Not for a normal SwiftPM user. |

[judgment] Keep F1 as the semantic source of truth, add F2 for names/spans/diagnostics and as an
independent cross-check of what the code "says", and run F4 as a cheap spike because it needs no parser.

## 6. Benefits of writing it all in Swift

1. **One toolchain.** `swift build`, SwiftPM plugins, Xcode and CI on macOS. No `elan`, Lean version
   pinning, or Python orchestration. Today's runs take minutes; a native in-process solver can answer small
   queries in milliseconds [judgment, unmeasured], which matters for AI repair loops.
2. **Spec, code and checker in the same language** (the Verus argument: specs written in the host
   language are easy for people and models to write [verified, Verus paper]). Contracts are ordinary
   Swift predicates, so they can also run as **runtime assertions in tests**: one contract, checked both
   dynamically (cheap) and statically (proved).
3. **AI-friendly.** Models know Swift far better than Dafny or Lean tactics (the Dafny paper blames data
   scarcity). The remaining unfamiliar surface is a few macros.
4. **Full control of diagnostics.** We choose counterexample format, error codes, and deterministic
   resource limits (conflict-count budgets rather than wall time, to avoid flaky proofs), and can
   hash/cache results per function.
5. **Swift features we can use directly:** macros for contracts and ghost-code erasure, result builders for
   spec DSLs, strong value-type semantics and exclusivity for an `inout`-as-functional-update model
   (Aeneas-style idea [verified for Rust]), typed throws for precise error modelling, Swift Testing for
   dual checks, `Span`/`InlineArray`/`~Copyable` for solver performance [verified these exist; speedups
   are workload specific].
6. **Dogfooding and distribution.** A Swift package is simple for Swift teams to adopt, fork and audit.
7. **Less dependency risk.** No dependency on Lean or a C++ solver build. (The existing `swift-z3` wrapper
   needs Z3 sources/binaries and is "ongoing development, API may change" [verified]).

## 7. Risks and costs

| # | Risk | Severity [judgment] | Mitigation |
|---|---|---|---|
| R1 | **Soundness bugs in our own solver/encoder.** An unverified verifier can say "proved" wrongly. Established solvers also have such bugs, but ours is new and unfuzzed | Critical | Certificates (LRAT) checked by a tiny separate checker; fuzz against external solvers *in tests only*; exhaustive checks at 8/16-bit widths; mutation tests; fail closed on any unsupported feature |
| R2 | **Trust in encoding is not covered by an LRAT proof.** A SAT certificate proves the CNF is UNSAT, not that the CNF faithfully encodes Swift semantics. Lean's `bv_decide` closes this with a verified bit-blaster; we would not | High | Differential testing of every operator against native Swift on exhaustive small widths and random 64-bit samples (existing 306-comparison style); independent second encoder; keep the trust ledger explicit |
| R3 | **No formal Swift semantics.** Swift has none; our "reference semantics" is an interpretation. Lean did not solve this either, but a mechanized model at least made it explicit | High | Keep native execution as oracle; record the compiler version; label claims "relative to Swift 6.4 SIL semantics as we modelled them". **Mitigation plan: see `2026-11-05-triz-and-swift-semantics.md` (semantics stack S0-S3, fail-closed whitelist, SIL≡LLVM-IR and -O≡-Onone proofs)** |
| R4 | **Compiler instability.** SIL/AST dump formats change; each release may break the reader | Medium-High | Version pin, golden tests per compiler, auto-reject unknown instructions (already done) |
| R5 | **Solver performance.** SAT in Swift faces ARC, bounds checks and exclusivity checks in hot loops. Could be several times slower than C/C++ [unverified] | Medium | Use `Span`/unsafe buffers carefully, avoid classes in inner loops, measure early; allow external solver as pluggable backend |
| R6 | **Scope creep: re-implementing Z3.** The easy 20% is quick; the last 80% (theories, quantifiers, heuristics) is endless | High | Hard scope fence: QF bit-vectors, bounded arrays, simple loops. Revisit only on measured need |
| R7 | **Expressiveness gap for real iOS code.** Strings (Unicode graphemes), floats (IEEE), classes and reference aliasing, closures, generics, async, `Codable` are out of reach early | High | State the supported subset in every report; target pure logic (pricing, parsing numbers, state machines, reducers) first |
| R8 | **Perception and claims.** "Verified by a homemade tool" is a weaker claim than "checked by Lean" | Medium | Use precise wording tied to the trust ledger; never claim end-to-end compiler verification |
| R9 | **Macro and swift-syntax churn.** swift-syntax versions track compiler versions and build time has been a pain point [unverified detail] | Medium | Keep macros thin; keep real logic outside macros |
| R10 | **Opportunity cost.** Months spent on solver internals do not improve the AI workflow | Medium-High | Phase gates with kill criteria (section 9) |
| R11 | **Lose AI proof-ecosystem.** Lean has strong open provers (e.g. Goedel-Prover-V2 reports 88.1% pass@32 on MiniF2F [verified, ICLR 2026 paper]) and Dafny has benchmarks; Swift contracts have none | Medium | Build our own benchmark; invariants as Swift expressions are in-distribution for general code models |
| R12 | **Dependence on one person's solver quality for reproducibility.** Nondeterminism in heuristics gives flaky results | Medium | Fixed seeds, conflict budgets, proof hashes |

## 8. Techniques to reuse, and where each comes from

| Technique | Source | Use in SwiftFormal |
|---|---|---|
| Hoare logic, wp/sp calculus | Floyd-Hoare, Dijkstra; paper cites Hoare 1969 | VC generator |
| Intermediate verification language | Boogie (Dafny's back end); Viper; Why3 | Our small IR is the IVL; SIL and AST are front ends |
| Passive form / DSA to keep VCs linear | Flanagan-Saxe (Boogie) | Avoid exponential blow-up on diamond-shaped branching (the repo's `control-flow` experiment already measures "diamonds") |
| Modular verification | Dafny, Verus | Call = assert pre, havoc frame, assume post |
| Loop invariants + `decreases` | Dafny | `#invariant`, `#decreases` macros |
| Houdini, k-induction, bounded model checking | Flanagan-Leino; CBMC-style | Cheap invariant candidates and fast bug finding before proofs |
| Bit-blasting + CDCL + LRAT | Boolector/Bitwuzla/Z3; CaDiCaL; LRAT; `bv_decide` | Core engine and trust anchor |
| Independently checked proofs | cake_lpr (formally verified LRAT checker); Carcara for cvc5 Alethe proofs (Alethe covers bit-vectors per cvc5 docs) [verified] | Small Swift checker; optional second checker |
| Translation validation | Viper to Boogie validated translation (2404.03614); our 0.0.4 | Keep: prove IR matches compiler artefact |
| Linear ghost state / functional model of borrows | Verus, Aeneas | `inout` and value types as pure updates; ghost code erased by macro |
| Fuel / bounded unrolling for recursion | Dafny | Recursive spec functions without quantifiers |
| AI guardrails | DafnyPro diff-checker and pruner; DafnyBench cheating rules; AlphaVerus critique | Frozen contract, no `assume`, spec-strength gates |
| Deterministic proof budgets | Dafny resource limits and brittleness guidance | Conflict-count limits, proof cache keyed by hash |

## 9. Suggested phased path with kill criteria

Each phase answers one question and may be stopped.

| Phase | Build | Question | Stop / pivot if |
|---|---|---|---|
| P0 spike (days) | F4 symbolic-types spike on `clampedDiscount`; typed-AST reader for names/spans | Can we get counterexamples without SIL? | Needs more than minor changes to source |
| P1 | IR to bit-vector expressions to **tiny CDCL** with DRAT/LRAT output, **plus Swift LRAT checker**, on the existing scalar functions | Do we reproduce Lean's 0.0.4/0.0.6 verdicts (same proofs, same failures, same counterexamples)? | Any disagreement not explained by a bug in the new engine |
| P2 | Trust tests: exhaustive 8/16-bit differential checks of each operator vs native Swift; fuzz against an external solver (test only) | How many bugs does a new engine have, and are they caught by the gates? | Soundness bugs keep appearing after the gates |
| P3 | Benchmark vs Lean path and, if installed, Z3/CaDiCaL: time per function, 64-bit multiply/divide cases | Is pure Swift fast enough for AI loops? | Median over 5 s on target functions, or solver-bound cases dominate |
| P4 | Loops: `#invariant`, `decreases`, bounded checking first, Houdini pruning | Does bounded checking plus invariants cover real counted loops? | Invariant burden remains the blocker |
| P5 | AI repair loop on 10 to 30 functions with frozen contracts | `verify@k` with intervals; spec-mutation kill rate | Models cheat or rates are near zero |
| Keep Lean? | Retain Lean only as an *optional second opinion* during development | Does it still find bugs the Swift gates miss? | Never finds anything: drop it |

Keep the Lean path alive until P1 and P2 pass, since it is the current independent check.

## 10. Recommendation

1. **Go Swift-first for everything except heavy search**, behind a `SolverBackend` protocol. Ship a small
   deterministic built-in solver; allow external solvers as untrusted helpers.
2. **Make certificates the trust story:** SAT proof checked by a small Swift checker, plus differential
   tests of every encoded operator against real Swift execution. Say clearly what is not covered (R2, R3).
3. **Fence the scope hard:** bit-vectors, bounded collections, simple loops. No quantifiers, strings,
   floats, classes, concurrency.
4. **Do P0 and P1 first.** They cost weeks, not months, and either confirm or kill the approach with
   evidence, by reproducing the verdicts we already have under Lean.
5. Treat all effort numbers here as guesses until P1 gives a real velocity measurement.

## 11. Open questions

- Is it acceptable to use an external SAT/SMT binary as an *optional* untrusted helper, or must the
  default install be pure Swift? (Changes R5 and R7 sharply.)
- Is "independent second opinion" required for release claims? If yes, keep Lean or Carcara-style checking.
- Which real Swift functions are the target (pricing, parsers, reducers, state machines)? Their needs
  (arrays, strings) decide how far past bit-vectors we must go.
- Target latency in an AI loop: milliseconds, seconds, or minutes?

## 12. P1 measurements (added after building Plan 1)

Measured on this machine (Apple M4 Pro), Swift 6.4, release build, one thread. Code: `Sources/SFCNF`,
`SFSAT`, `SFCheck`, `SFBV`, `SFProve`; tests in `Tests/SFTests` (20 tests, all pass in debug and release).

| Case | Result | Time (solve + independent proof check) |
|---|---|---|
| Clamp stays in `[lo, hi]` when `lo <= hi`, all 64-bit signed values | proved, proof accepted by checker | 0.18 s |
| Same claim without the precondition | counterexample, replays on native Swift | about 1 ms |
| 64-bit signed add overflow flag vs native `addingReportingOverflow` | counterexample matches native | about 1 ms |
| No overflow when both operands are inside ±2^62 | proved | well under 1 s |
| `x * 3 == x + x + x`, 64-bit | proved | 0.07 s |
| `x * y == y * x`, 8-bit | proved | **5.3 s** |
| `x * y == y * x`, 12, 16 and 20-bit | **unknown** after 300k conflicts | about 200 s each |
| No signed overflow in `x * y` when both are inside ±2^31, 64-bit | **unknown** after 300k conflicts | about 270 s |

What this shows:

- **Add, compare, select, multiply-by-constant at 64 bits: fast and well inside the latency goal.**
  Proofs are independently checked.
- **Variable by variable multiplication is the confirmed hard case**, as predicted. A basic solver fails even on
  small widths. This is the main risk to the milliseconds-to-seconds target (R5/R6 above). Mitigations to try
  next: interval analysis to discharge range-bounded overflow checks without SAT, narrowing multiplier
  widths from range facts, and a better solver (clause deletion, heap-based decisions, preprocessing).
- **Solver quality mattered a lot.** The first version needed 237,832 conflicts (18 s solve, 42 s check) at
  48 bits. Adding restarts and clause minimization cut that to 4,515 conflicts (0.12 s).
- **The first checker was too slow** (quadratic). A watched-literal rewrite made checking about 30 times
  faster (1.0 s to 32 ms at 32 bits). Checking cost is now similar to solving cost.
- **Debug builds are about 40 times slower** (clamp 64-bit: 7.1 s debug vs 0.18 s release). A shipped verifier
  must be a release build.
- **The checker caught nothing wrong in the solver so far**, but it did show that my first *checker* mishandled
  repeated literals. A regression test now covers it. Proofs are RUP lists, not LRAT (see the plan).
- Not yet done: second independent encoder, fuzzing against external solvers, 128-bit and wider checks.

## Sources

- Lean `bv_decide` pipeline: https://lean-lang.org/doc/api/Lean/Elab/Tactic/BVDecide.html
- LRAT: https://arxiv.org/abs/1612.02353; cake_lpr (verified checker): SAT Competition 2026 checker note
- cvc5 Alethe proofs and Carcara: https://cvc5.github.io/docs/cvc5-1.3.2/proofs/output_alethe.html
- Verus: https://arxiv.org/abs/2303.05491; Aeneas: https://github.com/AeneasVerif/aeneas
- Viper to Boogie validated translation: https://arxiv.org/abs/2404.03614; BoogieV (Boogie VC pipeline in Dafny): https://github.com/boogie-org/BoogieV
- Dafny brittleness: https://dafny.org/blog/2023/12/01/avoiding-verification-brittleness/; trigger selection (CAV 2016)
- Swift compiler SIL in Swift: https://github.com/swiftlang/swift/tree/main/SwiftCompilerSources
- SIL stability notes: Swift SIL documentation (binary SIL is not stable across compiler versions)
- Swift performance types: WWDC25 "Improve memory usage and performance with Swift" (Span, InlineArray, exclusivity)
- swift-z3: https://github.com/LuizZak/swift-z3
- Goedel-Prover-V2: ICLR 2026 proceedings paper
- Local probes: `swiftc -frontend -emit-sil` and `-dump-ast -dump-ast-format json` on Swift 6.4 (this machine)
