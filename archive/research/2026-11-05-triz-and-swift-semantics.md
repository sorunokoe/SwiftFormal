# TRIZ pass and "Swift has no formal semantics"

Date: 2026-11-05. Status: research, no new verifier code. Labels: **[measured]** = I ran it today
(Swift 6.4, swiftlang-6.4.0.34.1, M4 Pro); **[doc]** = read in a primary source;
**[estimate]** = my judgment, unmeasured.

## 1. Short answer

Swift has no official formal semantics [doc: Featherweight Swift paper, SLE'20, covers only the type
system and omits assignment, concurrency and value/reference semantics; the language reference is prose].
We should not try to write one. We should **let the compiler do the elaboration** and formalize only
what it elaborates to:

1. Swift source is lowered by `swiftc` to SIL, then LLVM IR.
2. For scalar code, everything meaningful ends in about 30 `Builtin.*` operations that have LLVM
   meaning (`sadd_with_overflow`, `sdiv`, `shl`, `cmp_slt`, ...), plus `cond_br`, `br`, `cond_fail`.
3. LLVM's meaning of those operations is the best-specified part of the stack (LangRef; Alive2 and
   Vellvm formalize it).
4. So our "formal Swift semantics" = **a small, fail-closed semantics of lowered SIL for a whitelisted
   subset, validated three independent ways**, and every claim is stated *relative to the pinned compiler*.

This is the same move CompCert-style and Aeneas-style projects make: pick a smaller, better-defined
language than the source, and make the translation inspectable.

## 2. What "Swift semantics" actually consists of (evidence)

| Layer | Who defines it | Formal? | Evidence |
|---|---|---|---|
| Surface Swift (type checking, overloads, generics) | Prose + compiler | No | Featherweight Swift abstract; typed AST JSON dump exists but is a compiler artifact |
| Operator meaning (`+`, `/`, `<<`, `abs`) | **Swift stdlib source**, mostly `@_transparent` | Executable, not formal | [measured] `Int8` `/ % << *` and `+` at `-Onone` lower to `sdiv_Int8`, `srem_Int8`, `shl_Int8`/`ashr_Int8` + `cmp`, `smul_with_overflow_Int8`, `sadd_with_overflow_Int8`, all inlined |
| Traps | `cond_fail` + `_assertionFailure(...) -> Never` | Semi-formal | [doc] SIL.md "Runtime Failure": a failure may be reordered with side effects but not hoisted to paths where it would not have fired. [measured] 4 `_assertionFailure` sinks for `/`, `%`, shift, overflow in the Int8 probe |
| SIL control flow and values | `docs/SIL/SIL.md` (1988 lines) | Semi-formal prose; verifier enforces well-formedness | [measured] `-sil-verify-all` passes; [doc] "binary format is not stable" |
| Builtins | `Builtins.def` (1455 lines) | Names only; meaning is LLVM's | [doc] `*_with_overflow` are "analogous to llvm intrinsics" but flagged for compile-time diagnostics |
| LLVM IR | LangRef | Prose, but formalized by Vellvm (Rocq) and Alive2 (tool) | [measured] same Int8 probe emits `sdiv`, `srem`, `llvm.sadd.with.overflow.i8`, `llvm.smul.with.overflow.i8`, `shl`, `ashr` |
| Memory, ARC, classes, exclusivity | SIL.md + Ownership Manifesto + SE-0176 | Prose; runtime-enforced | [doc] exclusivity is dynamically enforced in release since Swift 5; typed memory access has UB rules |
| Undefined behavior | SIL.md "Undefined Behavior" | Defined as "meaningless program" | [doc] should not arise from valid Swift + correct stdlib |

Two findings change the plan:

- **The semantics of `+` is not in a spec; it is in Swift code.** [measured] After mandatory inlining the
  whole Int8 operator set contains only builtins, `cond_br`, `cond_fail`, and trap calls. The one
  leftover was an *unspecialized generic* `abs<Int8>` call. That is the first concrete gap: we must
  either specialize (`-O`-style), inline, or reject.
- **`-O` preserves the check structure for simple arithmetic.** [measured] `a + b` on Int64 gives the
  identical `sadd_with_overflow_Int64` + `cond_fail "arithmetic overflow"` at `-O` and `-Onone`.
  Loops differ (-O simplifies), so `-O` vs `-Onone` equivalence needs a check, not an assumption.

## 3. Proposed approach: a semantics stack, not a semantics of Swift

```
S3  Out of scope, REJECTED explicitly  : classes/ARC, existentials, async, floats, strings, unsafe pointers
S2  Library semantics = stdlib source   : obtained by mandatory inlining / specialization, never hand-written
S1  SIL control flow                    : br, cond_br, cond_fail, struct/tuple extract, integer_literal, return
S0  Bit-vector core (formal, ~30 ops)   : builtin ops with LLVM meaning, trap = distinguished outcome
```

Rules:

1. **Fail closed.** Any SIL instruction or builtin not in the whitelist returns `unsupported`, never
   a guess. The whitelist is the audit surface; its size is a reported metric.
2. **Semantics as data.** S0 is a table: op name -> (bit-width rule, result, flags, trap condition),
   interpreted by *both* the native-comparison harness and the encoder, so they cannot drift apart.
3. **Result shape** (the theorem we can honestly claim):

   `compiler(P) = SIL` ∧ `SIL ⊆ whitelist` ∧ `model(SIL) ⊨ spec` (SAT proof, independently checked)
   ⇒ the *compiled* P satisfies spec, **assuming** (a) `swiftc` lowers faithfully, (b) the S0 table matches
   LLVM, (c) the CNF encoder matches the S0 table.

   Evidence for (b) and (c) is below; (a) stays trusted.

### Three independent ways to validate the model

| # | Method | Catches | Status |
|---|---|---|---|
| V1 | **Native differential**: run real compiled Swift vs model on all inputs at 4/8 bits, sampled at 64 | encoder bugs, wrong trap/flag rules | Done for 4/8-bit in P1 (20 tests) |
| V2 | **Second frontend from LLVM IR** (Alive2-style): lower the *same function* to `-emit-ir`, model LLVM `sdiv`/`llvm.*.with.overflow` separately, then prove SIL-model ≡ IR-model with our own solver | SIL-reading mistakes, `-O` divergences | Not built. [estimate] 1-2 weeks; this *is* the planned Route 2 |
| V3 | **Equivalence of `-O` and `-Onone`** with the same engine (trap-aware refinement: if `-Onone` does not trap, `-O` returns the same value) | optimizer divergence | Not built. Uses V2 machinery |

V2 and V3 reuse code we already own (bit-blaster, solver, checker); they add a small LLVM-IR reader
instead of a new prover. That is the cheapest way to get an independent "second opinion" on semantics.

## 4. TRIZ pass

### Step 0: triage
Real contradictions exist (below). Not just a prioritization problem. Proceed.

### Step 1: IS / IT
- **System:** SwiftFormal verify path: Swift file -> `swiftc` -> SIL -> model -> CNF -> CDCL -> RUP proof -> checker -> verdict.
- **Supersystem:** compiler, stdlib, AI agent writing code, CI, user.
- **Function:** produce a *trustworthy* yes/counterexample about compiled Swift, within seconds.
- **Weak points [measured]:** variable x variable multiplication (8-bit 5.3 s, 12-bit+ unknown); semantic faithfulness only tested
  empirically; single encoder; `abs<T>`-style generics unresolved.

### Step 2: contradictions
- **TC1 (engineering parameters):** improve *Reliability (27)* / worsen *Device complexity (36)*.
  Matrix cell R27xW36 -> principles **13, 35, 1**. Improve *Reliability* / worsen *Adaptability (35)*: **35, 13, 8, 24**.
- **TC2:** improve *Speed (9)* of proofs / worsen *Reliability (27)* (budgets and shortcuts risk wrong answers).
  Matrix cell R09xW27 -> principles **11, 35, 27, 28**: cushion in advance (graceful `unknown` instead of a wrong or slow answer),
  parameter changes (narrow widths), cheap disposable fast path (interval proof first, bit-blast fallback), replace mechanical system
  (different representation).
- **PC (Gate 2 form):**
  *The semantic model must be **complete** (cover real Swift so it is faithful) **and** **tiny** (a short whitelist so humans can audit it)
  simultaneously.*

### Step 3: Vepol
S1 = SIL program (object), S2 = our model/encoder (tool), Field = logical equivalence (informational).
Link is **insufficient**: S2 is a hand-written reading of S1, correct only as far as we have tested. Standards applied:
**1.3.2** (fragment S2 into small per-operation table entries so each is exhaustively checkable) and **1.4.2** (change the
measuring tool S2' : add a second, differently-built reader of the same program, the LLVM IR model, so the model's accuracy
becomes measurable). Standard numbers refer to `standards.md`.

### Step 4: Ideal final result
- **IFR-1:** the semantics defines itself. Nobody writes it; it is exactly what the real program does.
- **IFR-2:** the real compiled binary is the semantics, with no model at all.
  Not reachable (the solver needs a symbolic form), but it tells us to push the model toward *data derived from the compiler and executed code*, not prose.

### Step 5: resources already in the system (VPR)
1. `swiftc` itself: SIL, LLVM IR, `-sil-verify-all`, typed AST JSON (with `compiler_version` field).
2. The stdlib source: already defines operator behavior; mandatory inlining exposes it.
3. Native execution: free oracle for every function (the thing we verify can be *run*).
4. Existing SIL reader + interpreter in `experiments/scalar-extraction` (frozen, reusable).
5. Our own SAT solver + checker: can prove equivalences, not just user specs.
6. 14 idle CPU cores: portfolio/parallel proof attempts and parallel differential runs.
7. The AI agent: untrusted source of ranges, invariants, and decompositions, cheap to check.
8. `unknown` verdict + conflict budget: a built-in safe failure channel.

### Step 6: resolve (quick path: matrix + principles)

| Principle (from matrix) | Application here |
|---|---|
| **13 The other way round** | Do not formalize Swift then check programs. Let the compiler elaborate and formalize only its output. |
| **1 Segmentation** | Semantics stack S0-S3 with an explicit trust level per layer. |
| **24 Mediator** | SIL and LLVM IR are *mediators* between Swift and our model; two mediators give two independent readings. |
| **35 Parameter changes** | Change the representation: bit-vector width narrowing for multiplication, e.g. prove at needed width from range facts. |
| **11 Cushion in advance** | `unknown` with a replayable conflict budget is the pre-built safe failure for hard proofs. |
| **10 Preliminary action** | Precompute exhaustive 4/8-bit truth tables once, check them in CI; run interval analysis before bit-blasting. |
| **26 Copying** | Cheap copies of reality: run native code on inputs, compare with model (differential). |
| **23 Feedback** (my addition from `principles.md`, not a matrix cell result) | Every proof result is fed back against native execution (counterexamples must reproduce natively; proofs sampled). |
| **25 Self-service** | The verifier proves its own claims: V2/V3 use our solver to check our encoder and `-O` against `-Onone`. |

### Step 7: concepts

- **C1: Semantics-by-compiler.** S0 table + whitelist; semantics of operators come from inlined stdlib, never hand-written.
- **C2: Two mediators.** SIL model (Route 1) and LLVM IR model (Route 2); prove them equivalent per function (V2).
- **C3: Self-check loop.** Use the solver to check `-O ≡ -Onone` (trap-aware) and encoder ≡ reference interpreter at small widths (V3).
- **C4: Condition-separated multiplication.** Interval analysis first; narrow operand widths when ranges are known; bit-blast the rest;
  `unknown` with a replayable budget otherwise. AI-supplied range lemmas are checked, not trusted.
- **C5: Parallel portfolio.** 4-8 solver configurations (seed/restart/phase) on idle cores, first result wins; the checker still validates.

### Step 8: evaluate

| Concept | Ideality (benefit / cost+harm) | Altshuller level | Needs new external components? | Verdict |
|---|---|---|---|---|
| C1 | High: removes hand-written semantics | 3 (uses compiler as resource in a new role) | No | **Adopt** |
| C2 | High: independent second reading | 3 | No (small LLVM IR reader) | **Adopt (Route 2)** |
| C3 | Medium-high | 2-3 | No | Adopt after C2 |
| C4 | High for the measured bottleneck | 2 | No | Adopt now (cheapest, fixes the only [measured] failure) |
| C5 | Medium | 2 | No | Later; low risk |

Stopping criterion met: C1+C2 together are Level 3 and resolve the PC without adding a prover (completeness is delegated to the compiler;
the auditable model stays small).

## 5. /thinking-triz output

- **contradiction:** parameter = *semantic model*; state_1 = **complete** for faithfulness to real Swift; state_2 = **tiny** for auditability.
- **ideal_final_result:** the model is complete because it is *derived*, and tiny because only the derived target is hand-audited.
- **separation_tried:**
  - time: build the model once (S0 table), check per-compile with translation validation -> partially helps, does not shrink the model.
  - space: split layers S0-S3 -> **works**: complete coverage lives in the compiler/stdlib layer, the audited core stays ~30 ops.
  - condition: whitelist per function; unsupported constructs fail closed -> **works** (completeness is per-accepted-program, not global).
  - scale: element vs aggregate: validate each op exhaustively at 4/8 bits, argue uniformity to 64 -> helps, **not a proof**.
- **inventive_move:** *The other way round* (13) + *Mediator* (24): the compiler elaborates; two IRs act as mediators.
- **resources_reused:** swiftc (SIL/IR/verifier), stdlib source, native execution, SAT solver/checker, existing SIL reader, idle cores.
- **resolution:** S0 table + whitelist as the only hand-audited semantics; Route 1 (SIL) and Route 2 (LLVM IR) encoders proved
  equivalent per function with our own solver; native differential as third check; claims stated relative to pinned compiler version.
- **residual_tradeoff:** we still **trust the compiler's lowering** and the S0 table vs LLVM; width-uniformity (4/8 -> 64) is argued, not proved;
  nothing outside the whitelist (classes, ARC, concurrency, floats, strings, generics not specialized) is verified. This is a real, permanent
  limit of "no formal semantics", reduced but not eliminated.

## 6. Improvement backlog (ranked)

| # | Item | Why | Effort [estimate] | Closes |
|---|---|---|---|---|
| 1 | Interval analysis + width narrowing for multiplication | only measured failure (8-bit mul 5.3 s; 12-bit+ unknown) | days | R-perf |
| 2 | S0 table as data, shared by interpreter, encoder, tests | removes drift; makes whitelist auditable | 1-3 days | R3 |
| 3 | **Done (see 6b).** SIL frontend for scalar subset with fail-closed whitelist (reuse `SILReader`) | needed anyway for P2 | 1-2 weeks | R3, R-frontend |
| 4 | Handle `abs<T>`-style generics: require `-O`-style specialization or reject | only measured frontend gap | days | R3 |
| 5 | LLVM IR reader + second encoder, per-function SIL≡IR proof (V2) | independent semantic second opinion | 1-2 weeks | R3, trust |
| 6 | `-O` vs `-Onone` trap-aware refinement check (V3). **Basic scalar form done (see 6b)** | verifies what ships, not what we modeled | 1 week after #5 | R3, R-compiler |
| 7 | **Done.** Solver upgrades (clause deletion, heap VSIDS, preprocessing, portfolio) | general speed | 1-2 weeks | R-perf |
| 8 | LRAT instead of RUP if checking time becomes dominant | only if measured slow | later | perf |
| 9 | Pin by `compiler_version` (present in AST JSON) and by SIL grammar fixture tests | compiler instability | days | R-compiler |

## 6b. Progress: backlog items 1 and 2 (implemented, measured)

**Item 1, multiplication narrowing (C4).** `BitVec.swift` now reads a structural range off the literals
(`signedWidth`: the smallest k such that a value is the sign extension of its low k bits), so it cannot disagree with the circuit.
`mul`, `addSigned`, `subSigned` and the signed overflow flags build at the width the operands need.
`input(width:signedBits:)` declares a range structurally, so no separate assumption is needed.
- [measured, release] "64-bit signed multiply cannot overflow when both operands are 32-bit signed": proved in **0.006 s**
  (was `unknown` after 300k conflicts, ~270 s). 33x32 bits correctly yields a replayable counterexample in 0.010 s.
- Narrowed circuits proved equal to plain circuits (mul, add, sub, all three overflow flags) for 5 width combinations, 0.7 s.
- Not helped: genuine full-width variable x variable multiplication. Commutativity at 8 bits is still ~5 s; that needs a stronger solver (item 7, in progress).
- Range propagates through adds, so a later multiply stays narrow (test `rangePropagatesThroughAdds`).

**Item 2, S0 table (C1).** New target `SFSemantics`, file `S0.swift`. One declaration of ~33 builtin families
(add/sub/mul, sdiv/udiv/srem/urem, and/or/xor, shl/lshr/ashr, six overflow ops, ten compares, trunc/zext/sext, int_expect).
`S0Instance(builtinName:)` parses SIL names (`sadd_with_overflow_Int8`) and **fails closed**: `fadd_*`, `sdiv_exact_*`,
`Word`, unsupported widths and wrong cast directions return nil. Each instance has a reference interpreter (`evaluate`)
and a circuit encoder (`encode`). Division, remainder and shifts report **undefined** (zero divisor, `INT_MIN / -1`,
shift amount >= width) as a separate outcome that a verifier must prove unreachable, not as a trap.
- [measured] interpreter == Swift's native checked arithmetic on every Int8 pair for every op, and on edge values plus 500 random pairs at 16/32/64 bits.
- [measured] encoder (constant-folded) == interpreter on every Int8 pair for every op; through the real solver on random 8-bit pairs.
- [measured] mutation check: breaking `ashr` to a logical shift fails 3 tests.
- New circuits in `BitVecOps.swift`: barrel shifters, negate, restoring divider, unsigned overflow flags.
- [measured] **independent oracle**: `tools/builtin-oracle/oracle.swift` calls `Builtin.*` directly (`swiftc -parse-stdlib`, no stdlib wrappers),
  1.9M cases (all 40+ builtins exhaustively at Int8, 25x25 edge values at Int64), compiled at both `-Onone` and `-O`;
  the interpreter agrees on every case (test `S0BuiltinOracleTests`, 8.7 s). Cases with violated preconditions are skipped, since those are the `undefined` outcomes.
- Limits: the Int64 check is edge values only, not exhaustive; the circuit encoder is checked against the interpreter (exhaustive at 8 bits on constants, sampled at wider widths and through the solver), not directly against the oracle; the oracle's skip conditions for undefined behavior come from the LLVM LangRef, so they are an argument, not a measurement.

### Backlog item 7: solver upgrade (done, measured by a sub-agent, release, M4 Pro)

`Sources/SFSAT/Solver.swift` was rewritten: flat `[Int32]` clause arena, blocker-literal watches with a binary-clause fast path, unsafe-pointer propagate loop,
heap VSIDS, LBD-based clause reduction, recursive clause minimization, level-0 simplification, EMA restarts, proof trimming.

| Instance | Before | After |
|---|---|---|
| clamp64 `prove()` | 0.187 s | 0.044 s |
| 8-bit mul commutativity (solve only) | 1.87 s | 0.34 s |
| pigeonhole 8 | 1.94 s | 0.25 s |
| random 3-SAT n=200 x10 | 2.63 s | 0.82 s |

- The gain is throughput (about 5x conflicts per second). Conflict counts moved only +-10-20%, so hard instances run out of budget at about the same width:
  10-bit and 12-bit multiplication commutativity are still `unknown`.
- With the faster solver the proof checker dominates: 8-bit commutativity checks in about 2 s, 9-bit in about 36 s (php9: 2.6 s solve, 25 s check). That makes backlog #8 (LRAT) the next solver-side bottleneck.
- Rejected: parameter tuning (within noise), Luby restarts (equal to EMA). Not tried: bounded variable elimination, rephasing, vivification.
- 3 new solver tests (mixed-length clauses vs brute force, threshold random 3-SAT with checked proofs, pigeonhole proof). Forced frequent reductions also passed.

### Backlog items 3 and 6 (basic): SIL frontend for the scalar subset (done, measured, release, M4 Pro)

New target `SFSIL` (`SILParser`, `SILEncoder`, `SILVerify`). `swiftc -frontend -emit-sil` lowers the real source; we parse the SIL text,
accept only a fail-closed whitelist, encode it as one circuit and prove `requires => no trap, no undefined, ensures` with `SFProve`.
- **Accepted:** `integer_literal`, `struct`/`struct_extract` of one scalar (`Bool`, `Int`/`UInt`, `Int8..64`, `UInt8..64`), `tuple_extract`,
  `builtin` (only if the S0 table accepts name, arity and types), `cond_fail`, `br`/`cond_br`/`return`, `apply` of another supported function (inlined, depth <= 8, no recursion),
  scalar `alloc_stack`/`store`/`load`. Failure-message plumbing (`string_literal`, `StaticString`) is ignored. A block ending in `unreachable` after an `assertionFailure` call is a trap.
- **Rejected with an error, never guessed:** loops, generics, indirect calls, structs with several fields, arrays, classes, floats, anything not in S0.
- **Trap vs undefined.** `sdiv` is only defined after the `cond_fail` guards. The encoder tracks a `live` literal (not yet trapped), so `undefined` only counts on paths still running. Without it, division by zero looked like undefined behaviour at `-O`.
- **Structural hashing** (`CNFBuilder`): identical AND/XOR gates are shared. Effect on the `-O` vs `-Onone` equivalence test (div and rem on Int32):
  **405 s and still `unknown` -> 0.4 s `proved`**, because the two compilations contain the same divider and now it is literally one circuit. The mixed 16-bit multiplier proof (about 50 s) was replaced by cheap structural facts plus an exact proof on 4-bit operands.
- [measured] 12 end-to-end tests, about 20 fixture functions each compiled at `-Onone` and `-O`; whole `SILFrontendTests` run: 5.7 s.
  - **Native differential:** about 120 inputs per function are run on the real compiled binary (crashes count as traps) and compared to the circuit. Full agreement.
  - Proved: clamp stays in range; `(a+b)/2` traps exactly when the sum overflows; division needs both preconditions; checked narrowing traps exactly outside the range; smart shift never traps; calls are inlined; a failed `precondition` is a trap with a counterexample.
  - **`-O` and `-Onone` agree** on trap set, undefined set and value, for every supported function (backlog #6, basic form).
  - Unsupported constructs are rejected: a loop at both levels, and generic `min<T>` at `-Onone` (it stays a generic call; the `-O` specialization is proved). This is the open backlog item 4.
- `prove(...)` gained `inputSignedBits:` (an assumption the caller states) and a throwing claim closure.
- **Limits.** We trust the compiler lowering (checked only by the native sampling and `-O`/`-Onone` agreement, not proved); no loops (needs invariants or bounded unrolling); full-width variable x variable multiplication is still hard; the sample is about 120 inputs per function, not exhaustive.

Full SFTests suite: 54 tests pass in release (35 before the SIL work).

## 6c. TRIZ round 2: one ideal final result for all remaining limits

**Step 0 (triage): contradiction present, so TRIZ applies.**

**Step 1: undesirable effects (all stated in section 6b/7).**
N1 no loops. N2 no structs/arrays; generics fail at `-Onone`. N3 compiler lowering is trusted, only sampled. N4 variable x variable multiplication is `unknown`.
N5 the RUP checker is slow (9-bit commutativity: 36 s). N6 native agreement samples ~120 inputs.
Causality: N1, N2, N3, N6 share one root. Each new Swift construct needs new semantic rules, and every rule is trusted code. N4 and N5 are separate speed effects.
- IS: the verifier accepts Swift via a fail-closed whitelist, producing "coverage is bought with trusted rules". Goal: more coverage, no more trust.
- IT: make coverage grow without growing what must be trusted.

**Step 2: contradictions.**
- AC: we want to verify real Swift, but cannot cover it without enlarging the set of rules we must trust.
- TC (matrix, exact cells): improve 35 *Adaptability* (coverage), worsens 27 *Reliability* (trust): R35xW27 = **35, 13, 8, 24**. Reverse R27xW35 = **13, 35, 8, 24**. R27xW36 (complexity) = **13, 35, 1**. R39xW27 (speed vs trust) = **1, 35, 10, 38**.
- **PC (Gate 2):** the *accepted language of the trusted kernel* must be **small** to be audited and trusted AND **large** to cover real Swift, simultaneously.

**Step 3: Vepol (conflict zone only).** S1 = encoder whitelist, Field = semantic evidence (informational), S2 = a Swift construct. Insufficient vepol: the evidence is a one-time table per feature, not a per-use check.

**Step 4: IFR.**
- IFR-1: elements already in the system (swiftc, the compiled binary, the SAT proof stream, the AI author) vouch for every translation by themselves, and the kernel does not grow.
- IFR-2: the kernel's language is small (audit scale) and the *checked* language is large (use scale).

**Step 5: resources (VPR), only things already here.**
1. Substance: `swiftc` itself (specializer, inliner, unroller, scalar replacement, SIL verifier). 2. Substance: the natively compiled binary, an executable meaning for every construct.
3. Field: the SAT solver already emits a proof stream (a free certificate). 4. Functional: the AI author, which proposes invariants and contracts (the point of the project).
5. Time: build time, idle between compiler upgrades (validate the S0 table once per `compiler_version`). 6. Space: ~12 idle cores on this machine. 7. Functional: counterexamples (every `.counterexample` is already a replayable test). 8. Functional: S0 is data, so new ops are rows, not code.

**Step 6: path.** Quick (the matrix cells above). The principles map to concrete moves, not midpoints, so no escalation. Separation tried: **system level** (small kernel, large untrusted front ends), **time** (validate once, apply many times), **condition** (accept a construct only when this instance passes its own check). All three worked; they combine.

**Step 7: concepts (principle, resources, mechanism, [estimate] or [measured]).**

| # | Concept | Principle | Resources | Mechanism |
|---|---|---|---|---|
| C1 | **Untrusted proposers, trusted checkers** (the master move) | #13 other way round, #24 mediator | AI, solver proof stream | Kernel = tiny scalar core (S0 + trap/undefined + bit-vector memory) + RUP/LRAT checker. Every front end (loops, arrays, generics, contracts) is untrusted and emits an artifact the kernel only *checks*. Coverage grows outside the kernel. |
| C2 | **Let the compiler remove constructs first** | #35 parameter change, #10 preliminary action | swiftc | [measured] constant-bound loop: 8 blocks at `-Onone`, **1 block** at `-O` (fully unrolled). Struct built and used through calls: pure scalar `builtin`s at `-O`. `[Int32]` literal index: no allocation at `-O`. So the current frontend already accepts these at `-O`. |
| C3 | **Loops by cutpoints** | #1 segmentation, #13 | AI, solver | Variable-bound loop stays a back edge (measured: 7 blocks at `-O`). Cut at the header: havoc live variables, assume AI-proposed invariant, check three loop-free queries (init, step, exit). Each is already supported by the encoder. Verdict says "all n", never "bounded" unless labelled. |
| C4 | **N-version triangulation of the lowering** | #8 counterbalance, #26 copying | swiftc, binary | SIL encoder, a second LLVM IR encoder, native replay of every counterexample, `-O`≡`-Onone`, and `-sil-verify-all` (measured: accepted, exit 0) must agree. Disagreement means reject. |
| C5 | **Abstract-then-refine multiplier** | #15 dynamics, #16 partial action | solver | Treat `x*y` as an uninterpreted function with cheap sound lemmas (zero, bound, parity, commutativity). If the counterexample is spurious, bit-blast exactly. Soundness is kept because the exact circuit is the fallback. [estimate: not built] |
| C6 | **Solver searches, checker only follows** | #13, #10 | proof stream, cores | LRAT hints written by the solver; checker does unit propagation along given IDs, linear time. Proof chunks can be checked in parallel. [estimate: not built] |
| C7 | **Compiler constant folder as a free oracle** | #26 copying | swiftc | Feed literals to `f` at `-O`; the folded result is an independent value to compare with the circuit, with no process spawn. Exhaustive native check at Int8 (65k pairs) for structure. [estimate: not built] |

**Step 8: evaluation.**
- **C1 is the primary recommendation: Altshuller level 3** (the Lean/Dafny "small kernel, big elaborator" idea, moved to a new domain: Swift compiler output). It resolves the PC with no new external component. Stopping criterion met, so no escalation to Systematic or ARIZ.
- C2 is the cheapest win (level 2, already measured). C3, C5, C6 are known techniques (level 2) made cheap by C1's structure. C4 is level 2 to 3 (independent semantic decoders). C7 is level 2.
- **Residual trade-off (honest):** (a) N-version checks share `swiftc`'s front end, so a miscompilation upstream of SIL is a common-mode failure we can narrow (via `-O`/`-Onone` and replay) but not remove. (b) Arrays with symbolic length need a theory of arrays or a length bound, so those verdicts must say "bounded". (c) The invariants are as good as the AI's proposals, but a wrong invariant fails the check, never silently passes.

**Resulting backlog (ranked, effort is an estimate).**
1. Flatten struct-of-scalar signatures and accept `-O` fixed-size array literals (days; uses C2).
2. Cutpoint loops with checked invariants (1-2 weeks; C3).
3. Constant-folding oracle plus exhaustive Int8 native check (days; C7).
4. LRAT (about a week; C6, also needed because the checker is now the bottleneck).
5. LLVM IR second encoder (1-2 weeks; C4, the old #5).
6. Multiplier abstraction-refinement (about a week; C5).
7. Proof cache keyed by SIL hash plus `compiler_version` pin (days; old #9).

Probe files lived in `/tmp/triz` and were removed. Commands: `swiftc -frontend -emit-sil -parse-as-library -sdk $(xcrun --show-sdk-path) {-Onone,-O}`.

## 6d. Round 2 implemented (five parallel agents; release, M4 Pro, noisy shared machine)

Full `SFTests`: **138 tests, 17 suites, all pass** (111 before the loop/aggregate merge). Each agent worked in its own sandbox; I merged and re-ran everything.

| Backlog item | Result [measured] |
|---|---|
| Structs / fixed arrays | `proveAggregate`: structs and tuples of scalars (nested) in parameters and results, flattened per leaf. `-O` fixed arrays that the compiler lowers to scalar tables (literal, runtime index, local mutation). Heap and symbolic-length arrays, classes, enums, optionals, closures, generics stay rejected. 10 tests, native differential check on every accepted function. |
| Loops by cutpoints | `proveLoopFunction` with user invariants: INIT, STEP, EXIT as separate loop-free proofs. Nested and sequential reducible loops, at `-Onone` and `-O`. Result says "termination not proved" unless a ranking variant is given (innermost loops only). Mutation tests: too-weak invariant fails EXIT, non-inductive fails STEP, false at entry fails INIT. 17 tests. |
| Const-fold oracle | Folding at `swiftc -O` agrees with the circuit on 4200 and with native runs on 2160 comparisons, 0 differences. ~2000 inputs/s vs ~450 for the native route. Same compiler front end, so it is a cheap cross-check, not an independent one. |
| Exhaustive Int8 | 26 two-argument functions x 65,536 pairs at both levels: 1.37M non-trapping pairs compared natively on every value. Only 2,800 of 336,976 predicted traps were confirmed natively (sampled), so the trap set is checked less strongly than the values. ~15 s. |
| Proof cache + pin | Key covers callee SIL text, compiler, SDK, optimization, encoder version, an automatic S0-behaviour hash, claim ID, widths and budget. Counterexamples are always replayed and dropped if stale. Unpinned compiler throws. 5 grammar-fixture snippets fail loudly if the SIL text format changes. A cache hit only pays off for proofs slower than ~1 ms. |
| LRAT | Solver writes hints, a new independent 207-line checker follows them. Check time vs RUP: mul8 2.1 s -> 0.064 s (33x), pigeonhole-8 0.7 s -> 0.010 s (72x), pigeonhole-9 84 s -> 0.093 s (~900x). Solver overhead 2-13%. 240 random near-threshold instances all checked; 11 mutation kinds all rejected. Proofs can be tens of MB as text (mul9: 40 MB). Not supported: RAT steps. |
| LLVM IR second encoder | New `SFLLVM`, written fresh from the LangRef. SIL = IR is proved for 21 functions at both levels (+1 at `-O`). IR-only: `ctpop`, `ctlz`, `bswap`, and `sumTo` at `-O` (LLVM closes the loop). 8 deliberate IR mutations all caught. Native sampling: 2880 + 3120 cases agree. Caveat: both encoders share the BV circuit primitives, so a bug there is common-mode; the native test and per-instruction oracle are the defence. |
| Multiplier abstraction-refinement | `proveRefining`. Commutativity at 10/12/16/32 bits, associativity at 8/16/32 and distributivity at 8/16 now prove in about a millisecond; plain `prove` was `unknown` at all of them. Cause: structural rewrites (flattened sorted product chains, shifted operands, distributivity across nodes), not search. Claims that truly need the real multiplier (e.g. `(a+1)^2 == a^2+2a+1`) refine to the exact circuit and are as hard as before. Trust note: the lemma clauses are part of the formula the checker sees, so they are audited by a test that forces exact products and must stay satisfiable; 5 injected wrong lemmas were all caught. |

**Known seams and limits (honest).**
- Multiplication abstraction is now inside the SIL/LLVM provers (see 6e). The abstraction only helps claims that need algebra of products; claims that need the true multiplier are as hard as before.
- Variable-bound loops need an invariant from the caller (the AI); a wrong invariant fails, it never passes. `inputSignedBits` is not available in the loop API. Constant-bound loops need nothing at `-O`.
- Dead agents' first sandboxes under `/tmp` were lost once; the second round used the session folder. Two sandboxes' generated files were written with a script instead of the edit tool (process slip, not a semantic issue).
- Not done: LRAT proofs are not yet written to disk for an external checker (no external checker is installed to cross-check the text format).
- Remaining ranked ideas: LRAT binary format and parallel check; shared type for `LRATLog`/`LRATProof`; ranking variants for nested loops; arrays with a length bound, labelled "bounded"; pin `compiler_version` for new toolchains after re-running the grammar fixtures.

## 7. Honest limits and open questions

- **[doc, not measured]** I did not verify whether the typed AST JSON format is stable across versions; it carries a
  `compiler_version` field, so pinning is possible, stability is unknown.
- I did not find a mechanized formal semantics of SIL. I searched; absence in search is not proof of absence.
- Alive2 is a bounded translation validator (not itself verified); Vellvm is mechanized in Rocq. Neither covers Swift-specific SIL.
- UB: SIL says UB-containing programs are meaningless. Our whitelist avoids UB sources (raw pointers, unchecked casts), which is an argument, not a proof.
- Trap reordering: SIL allows runtime failures to be reordered relative to side effects. Our model treats trap as a distinguished outcome; for
  pure scalar functions this is exact; for functions with side effects it needs care (reject for now).

Open: which Swift subset after scalars (structs and fixed-size arrays are the natural next, via an Aeneas-style functional model)?
How much of the stdlib can be mandatory-inlined at `-Onone` without specialization?

## 8. Sources

- swiftlang/swift `docs/SIL/SIL.md` (Runtime Failure, Undefined Behavior, OSSA), `include/swift/AST/Builtins.def`.
- Swift.org, "Swift 5 Exclusivity Enforcement"; SE-0176.
- Racordon & Buchs, "Featherweight Swift: A Core Calculus for Swift's Type System", SLE 2020.
- Lopes et al., "Alive2: Bounded Translation Validation for LLVM", PLDI 2021.
- Zakowski et al., "Modular, Compositional, and Executable Formal Semantics for LLVM IR" (Vellvm), ICFP 2021.
- Local probes today: `swiftc -frontend -emit-sil -Onone/-O`, `-emit-ir`, `-sil-verify-all`, `-dump-ast-format json`.

### 6e. `mulHook`: the multiplier abstraction inside the real-Swift provers [measured]

`CNFBuilder` now has three optional hooks: `mulHook`, `unsignedMulOverflowHook`, `signedMulOverflowHook`. `MulAbstraction.install()` sets them, so a product built by the SIL or LLVM encoder (or by a caller's `requires`/`ensures`) becomes an abstract node. Constant and narrow-operand shortcuts still run first, and the abstraction's own exact circuits switch the hooks off while they are built. `SILVerifier.prove`, `proveAggregate`, `proveEquivalent` and `LLVMVerifier.prove` take `refining: Bool = false` (default behaviour unchanged). The shared driver is `proveMaybeRefining`.

| Claim, real `swiftc` output | Plain `prove` (budget 20k conflicts) | `refining: true` |
|---|---|---|
| `a &* b` = `b &* a`, Int32, `-Onone` and `-O` | `unknown` | proved, ~0.1 s |
| `(a&*b)&*c` = `a&*(b&*c)`, Int32 | `unknown` | proved |
| `a&*(b&+c)` = `a&*b &+ a&*c`, Int32 | `unknown` | proved |
| checked `a * b` = `b * a`, Int16/UInt16 (trap sets must match) | not run | proved |
| LLVM IR of `a &* b`, `result == b*a` | not run | proved |
| false claim (`+1`) | n/a | counterexample, replayed natively |

Plain `prove` on the first three took 4.9 s in total and ended `unknown`. On Int8, plain and refining give the same verdicts (one true, one false claim). Full suite: 146 tests in 18 suites pass.

Limits: it helps only claims that need algebra of products. A claim that needs the real multiplier refines to the exact circuit and costs the same as before. Loop obligations (`proveLoopFunction`) do not use `refining` yet.

## 6f. TRIZ round 3: "proved" is only as good as the spec

**Step 0 (triage): contradiction present.** The prover must be trusted to say "proved" AND the thing it proves (the spec) is written by the same AI that wrote the code.

**Step 1: undesirable effects (all follow from sections 6b to 6e).**
N1 `requires` can be unsatisfiable, so every proof is vacuous. N2 `ensures` can be a tautology. N3 `ensures` can be too weak to notice a wrong implementation. N4 the loop API needs a human or AI invariant per loop (a wrong one fails, but writing one is work). N5 no function contracts, so callees are always inlined (large call trees cost the whole tree). N6 residual common-mode risk in the shared BV primitives and in `swiftc`'s front end.
Causality: N1 to N3 share one root: nothing in the system tests the meaning of the spec, only its truth. N4 and N5 are cost effects (what the AI must supply, what the solver must re-do). N6 is the trust floor.
- IS: the verifier decides whether code meets a spec, producing "proved" even when the spec is empty or weak. Goal: a "proved" that carries evidence the spec means something, with no new trusted component.
- IT: make the spec testable by machinery already in the system.

**Step 2: contradictions.**
- AC: we want AI-written specs (cheap, scalable), but cannot trust a spec written by the same author and blind spots as the code.
- TC (exact matrix cells): improve 27 *Reliability* (a verdict that means something), worsens 33 *Ease of operation* (more for the AI to write and review): R27xW33 = **27, 17, 40**; reverse R33xW27 = **17, 27, 8, 40**. Detectability: R37xW27 = **27, 40, 28, 8**. For invariants, R38xW27 (automation vs reliability) = **11, 27, 32**.
- **PC (Gate 2):** the spec must be **trusted (an independent judge of the code)** AND **untrusted (written by the code's own author)** simultaneously.

**Step 3: Vepol.** S1 = the spec (`requires`/`ensures`), Field = informational (a verdict), S2 = the function. Harmful vepol: the field acts on S2 only when the spec is strong, and nothing measures that. Standards applied (Systematic path, read from `standards.md`): **4.2.1** build a measurement S-F system (the spec's strength becomes something measured), and **1.2.2** introduce a modified copy of S2 (mutants of the function are sacrificial copies that absorb the test).

**Step 4: IFR.**
- IFR-1: the prover and the compiler output, both already in the system, vouch for the spec by themselves.
- IFR-2: the function at the conflict zone must be **correct** (so the spec holds) and **wrong** (a mutant) simultaneously; a spec is good only if it accepts the first and rejects the second.

**Step 5: resources (VPR).** (1) Substance: the compiler's SIL text, which is editable lines. (2) Field: the prover's counterexample engine and LRAT-checked unsat verdicts. (3) Functional: `proveEquivalent`-style two-encoder circuits on shared inputs. (4) Space: the many cheap small edits of one function. (5) Functional: `SILModule` already parses on demand, so a mutated copy costs nothing.

**Step 6: path.** Quick (matrix cells above). #27 *cheap short-living objects* gives mutants: thousands of throwaway wrong programs. #40 *composite* gives code plus spec plus mutants as one object. #17 *another dimension* gives a second axis for a verdict: truth and strength. #8 and #28 give counterweight and replacement of human review by a machine. #22 *turn harm into benefit* is my addition, not in the cell: wrong code, normally the harm, becomes the instrument.

**Step 7: concepts.**
| # | Concept | Principles | Status |
|---|---|---|---|
| S1 | **Spec audit**: `requires` satisfiable, `ensures` not tautological, `ensures` determines the result (full spec) or not (property) | #28, #17 | **built, measured** |
| S2 | **Mutation testing of the spec** on the compiler's SIL: flip comparisons, swap + and -, change constants, swap branch targets. A mutant that differs on an input meeting `requires` but still satisfies the spec is a *survivor* with a witness | #27, #22, #40 | **built, measured** |
| S3 | **Houdini-style invariant filtering**: the AI proposes many candidate invariants (cheap, short-lived), the solver keeps the largest inductive subset; the final loop proof is unchanged and checked | #11, #27, #32 | not built; needs the loop counterexample to expose the post-state |
| S4 | **Function contracts**: prove a callee once against its contract, let callers assume it (assume-guarantee) | #1 segmentation, #24 mediator | not built |
| S5 | **Common-mode defence**: exhaustive small-width checks of each BV primitive against native arithmetic | #26 | partly done earlier (Int8 exhaustive, oracle) |

**Step 8: evaluate.**
- S1+S2 are the primary recommendation. Altshuller **level 2** (vacuity checking is known from model checking, mutation testing from software testing). The contribution is the combination: the same checked prover supplies both the verdict and the audit, with no new trusted code. The PC is resolved by separation **by condition**: the same function is correct for the proof and wrong for the mutant test. The stopping criterion asks for level 3, which I do not claim; I did not escalate to ARIZ because the concrete fix was cheap and measurable.
- S3 is level 2, the most valuable next step for N4. S4 is level 2 but needs a soundness argument for assumed contracts.

**What was built** (`Sources/SFSIL/SpecAudit.swift`, `SILVerifier.auditSpec`; 6 tests, all pass; full suite 152 tests in 19 suites).
- `requiresSatisfiable`, `ensuresConstrainsResult`, `ensuresDeterminesResult` (each a checked proof or a witness; `nil` when out of budget), `isVacuous`.
- Mutation operators: comparison flips, `add`/`sub`/`and`/`or` swaps, overflow-builtin swaps, `+1` on multi-bit literals, branch-target swap. Equivalent mutants are detected by proof and excluded. Each survivor carries a witness input.

| Experiment [measured, release, M4 Pro] | Result |
|---|---|
| `clamp(x, lo, hi)`, spec `r <= hi` only | proved, but has survivors (the spec accepts wrong clamps) |
| same, range plus identity-in-range spec (what I first wrote) | proved, mutation score 1.0, **`ensuresDeterminesResult == false`**: the audit correctly said my own spec left out-of-range results open |
| same, full spec (below gives `lo`, above gives `hi`, else `x`) | no survivors, score 1.0, determines the result |
| `requires` unsatisfiable, `ensures r == 5` on `abs` | plain `prove` says **proved**; audit says vacuous |
| `ensures` is `r < 5 \|\| r >= 5` | audit: constrains nothing |
| `x*3+7` with a parity-only spec | proved; survivor (`x*3+9` has the same parity) |
| same function with the exact spec | all literal mutants killed |

Both `-Onone` and `-O` give the same classification on `clamp`. A full audit of these functions takes well under a second.

**Honest limits.**
- Mutants are small and syntactic. A spec that kills all of them can still be wrong (for example, if it states the wrong intent). A surviving mutant is evidence of weakness; zero survivors is not evidence of correctness.
- Only 4 mutants exist for `clamp` at `-Onone`, because the operator set is small. More operators (drop a `cond_fail`, change a width) would add coverage; I did not add them.
- Scalar results only; aggregates and loops are not audited yet.
- Equivalence of a mutant is decided under `requires`, so a mutant that only differs outside the precondition is correctly not counted as a weakness.
- The mutation operates on SIL, so it tests the spec against the compiler's meaning of the code, not against the source text.

**Backlog after this round.** (1) S3 Houdini invariants (expose the post-state in `LoopCounterexample`). (2) S4 contracts. (3) Audit for aggregates and loops. (4) More mutation operators. (5) `refining` in the loop API. (6) LRAT binary format.

## 6g. v1 `sfverify`: real-project results and honest limits [measured, release, M4 Pro, Swift 6.4]

**What v1 is.** `swiftc -emit-sil -g -Xllvm -sil-print-debuginfo` → parse → bit-blast → CDCL. Per function: `requires ⇒ ¬trap ∧ ¬undefined ∧ ensures`.
Locations come from the SIL debug info. With `--build`, the exact `swiftc` flags of a SwiftPM target are taken from `swift build -v`, so
packages that need `-package-name`, `-D` conditions or experimental features compile unchanged. Fixed along the way: structs nested in
types or in `extension` blocks were invisible to the type scanner (it only read column-0 declarations), which made every `_Word`-like type "unsupported".

| Target [measured] | Functions | Proved safe | May trap | Unsupported | Coverage | Time (compile / verify) |
|---|---|---|---|---|---|---|
| swift-collections `InternalCollectionsUtilities` `-Onone` | 113 | 25 | 11 | 77 | 32% | 0.65 s / 0.11 s |
| same, `-O` | 106 | 30 | 6 | 70 | 34% | 0.62 s / 0.10 s |
| swift-collections `HeapModule` | 75 | 10 | 8 | 57 | 24% | 0.28 s / 0.09 s |
| swift-collections `BitCollections` | 390 | 4 | 0 | 386 | 1% | 0.87 s / 0.28 s |
| `AppCoreA` / `AppResources` / `AppProgress` (app code) | 1041 / 324 / 240 | 9 / 6 / 1 | 0 | rest | ≈1–2% | ≤2 s |
| `AILanguage` (SpecParser, SpecChecker, …), `VaultDomain`, `MCPProtocol`, `QuarkHelper`, `AppMapping`, `SageCore` | 18–554 each | 0 | 0 | all | 0% | 0.1–19.5 s (SageCore compile) |

**What it found in swift-collections (all in the model's terms; none is a confirmed upstream bug).**
- `-Onone`: `_UnsafeBitSet._Word.contains(_:)`, `init(upTo:)`, `shiftedUp(by:)` and the `_HeapNode` index functions trap on out-of-range arguments: these are the library's own `assert`s. Their callers must guarantee the preconditions.
- `-O` (release): the asserts disappear; what remains is real arithmetic: `_UnsafeBitSet.Index._successor()` overflows at `UInt.max`, `_predecessor()` at 0, `wordCount(forBitCount:)` overflows for `count = -32`, and `Index.init(_:)` traps on negative values. The first two are unreachable in the library's use; the point is that the tool names the exact boundary, and proves 30 other functions (shifts, masks, unions, `==`, `<`, `isEmpty`, `isFull`, `complement`, ...) safe for all inputs.
- A "may trap" without a spec means "some input traps", not "the program is wrong". Struct invariants (such as `_HeapNode`'s `level == floor(log2(offset+1))`) are not modelled, so functions that rely on them are reported with inputs that violate the invariant.

**Honest limits.**
- Coverage on idiomatic app code is 0–2%: String, enums, Optional, classes, closures, protocols, generics, `for-in`, floats. v1 is a verifier for numeric/bit/index kernels, not for app plumbing.
- Pointers and buffers (`UnsafeBufferPointer<_Word>`) are out of scope, so `BitSet` is mostly unsupported even though `_Word` is covered.
- Loops need invariants (`proveLoopFunction`); the CLI does not infer them yet.
- Proof cache is not wired into the CLI. No native replay (`--confirm`) yet.
- `-Onone` reports debug-only asserts as traps; `-O` is the release meaning.

**Next, by expected value.** (1) Optional/enum of scalars (tag plus payload leaves). (2) Struct invariants as `Type_invariant`. (3) Houdini loop invariants. (4) Pointer/buffer model with a bounds-only memory (array theory). (5) Opaque leaves for untouched non-scalar fields.

## 6h. The build gate: compile-time feedback [measured, debug and release, M4 Pro]

Goal: the best feedback is the build itself, so a marked function that is not proved must stop the build.

**Design.** `sfverify --gate` proves only functions marked `// sf:verify` (a comment, so the verified target needs no macro, import or plugin of its own)
plus any function that has `_requires`/`_ensures` next to it. Every non-proved outcome of a gated function is an `error:` with `file:line:col`:
may trap (with the input), contract fails, undecided, unsupported (with the reason), not found, or the file does not compile. A gate that passes when it understood nothing would be a lie, so it fails closed.
A SwiftPM build-tool plugin (`SwiftFormalGate`, also an `XcodeBuildToolPlugin` for Xcode/Tuist targets) runs it with the target's sources as inputs and a stamp as output, so unchanged targets are not re-proved.

**Measured.**
| Scenario | Result |
|---|---|
| Two gated functions (8-bit index kernel with contract, 16-bit percentage), release `sfverify` | pass in 0.5 s |
| Same, through the plugin in a debug `swift build` | pass in 2.6 s; unchanged rebuild 0.28 s |
| Same, `xcodebuild` on the package; Tuist-generated Xcode project (2 functions) | pass; 4.6 s in the Tuist project |
| Contract bound loosened (11 → 12): overflow | `swift build` and `xcodebuild` both fail with `Kernels.swift:4:13: error: ... when x = 0, y = 0, width = 12 ...` |
| `Int8` midpoint `(a + b) / 2` in the Tuist project | fails at `Demo.swift:7:57`, counterexample `a = -128, b = -128`; fixed version passes |
| 16-bit index kernel with 2 multiplications | undecided at 100 000 conflicts (5.1 s, release) |
| 32-bit version of the same | undecided at 300 000 conflicts (26.9 s release); **over 34 minutes in a debug-built `sfverify`** before I killed it |

**What it cost me / mistakes.** My first example used 32-bit multiplication and ran for 34 minutes in the plugin's debug-built tool: the conflict budget alone does not bound time.
The fix is a wall-clock limit (`--time-limit`, default 60 s, measured: a 3 s limit stops a hard proof at 3.16 s and names the function) and a lower gate budget (50 000).
The plugin's tool is built in the configuration you build, so the same proof is several times slower in debug; a prebuilt release tool would be faster (not built yet).

**Limits.** The plugin sees only the target's own files, so imports of other modules fail closed; `--package --build --gate` compiles such targets, but calls into another module are unsupported (no body to read).
Supported types are unchanged (integers, `Bool`, structs of those); wide multiplication and division are hard for SAT. This gate suits numeric/bit/index kernels, not app plumbing such as a production app's Rules.

## 6i. TRIZ round 4: covering every Rule of a production app [design; results in §6j]

**Inventive situation.** SwiftFormal's Tier 1 checks a Rule by running it over a `Domain` a person wrote by hand.
Measured on the app's 470 Rules: 43 were covered, 90 enum-input candidates skipped (74 because the input is a struct or a Kotlin sealed class), and writing one domain takes minutes of reading headers.
Undesirable effects: (NE1) most Rules have no domain at all; (NE2) each domain is hand-written, so cost grows with the number of Rules; (NE3) the honest fix, "all combinations of all fields", explodes (a struct of six fields with 10 values each is 10⁶ inputs).
Inventive task: remove NE1–NE3 (the authoring cost and the explosion) while keeping the verdict honest (`bounded` unless the whole domain was enumerated).

**AC.** We need every Rule checked, but cannot afford a person per Rule.
**TC.** Improving *reliability* (coverage of behaviours) worsens *device complexity* (more domain code, more generator) and *loss of time* (more inputs per Rule).
**PC.** The input domain at the Rule boundary must be **large** (every field combination, to cover all behaviour) AND **small** (a few hundred values, to run in milliseconds) simultaneously.
Separation: **by condition and by system level**. Per field the values only need one representative per behaviour class (small), while *across* fields we need every pair of classes (large in coverage).

**Vepol.** S1 = the domain generator, S2 = the Rule, Field = information (inputs flowing in, outputs flowing back).
The vepol is incomplete: nothing already in the system tells the generator what a Rule's input looks like or which values matter. Standard 1.1.1 (build the missing element) with the missing element taken from inside the system: see the resources below.

**IFR-1.** The Rule's own source and the compiler's description of its input types produce the domain by themselves, with no person and no new runtime component.
**IFR-2.** The domain at the Rule boundary is large in coverage (all pairs of behaviour classes) and small in size (hundreds of values) at once.

**VPR (all already in the system).**
1. *Substance:* the Rule's body. Its `switch` cases, `case` patterns, comparison literals (`> 100`, `== "x"`) are exactly the behaviour classes. Harvest them with swift-syntax (already a dependency).
2. *Substance:* the Rule's stored properties (`struct Input { let a: Int; let b: Bool }`), readable from the same syntax tree.
3. *Field:* the compiler's symbol graph (`swift symbolgraph-extract`). Measured: on SharedKt it takes 41 s once and yields 15 984 symbols: 1 550 initialisers, 886 enum cases, 11 663 `conformsTo` edges. For `DomainRecord` the conformance closure reaches 20 constructible classes with typed initialisers. This is the *Swift view* the compiler sees, including SKIE names.
4. *Functional:* `Domain` combinators (`union`, `optional`, `arrays`, `product`) and `partition`, which already report collisions.
5. *Time:* generation can happen once, offline, before the 114-second simulator test run, and the output is a plain test file.
6. *Functional:* the build-tool plugin and `--stamp` cache from the gate, for later incremental use.
7. *Space:* the app's rule table (not public), which already maps each Rule to its input type and source file.

**Resolution (Quick path, exact matrix cells).** Improve *Reliability* (27) against *Device complexity* (36): principles **13, 35, 1**; against *Loss of time* (25): **10, 30, 4**.
Applied: **1 Segmentation** (cut each field into behaviour classes), **13 The other way round** (derive the domain from the code under test instead of writing it for the code), **35 Parameter changes** (change the product of all fields into an all-pairs cover), **10 Preliminary action** (pre-compute the type universe once, before tests run). 30 (flexible shells) and 4 (asymmetry) gave nothing I could use, so I dropped them.

**Concepts.**
| # | Concept | Principle | Resources | Ideality / feasibility |
|---|---|---|---|---|
| A | Per-field *class values*: literals harvested from the Rule body (±1), plus fixed edges (0, 1, −1, empty string, `nan`) | 1, 13 | VPR 1, 2 | High: zero authoring; risk: misses behaviour hidden in called helpers |
| B | *All-pairs cover* across fields instead of the full product | 35 | VPR 2, 4 | High: size grows ~log in field count; risk: bugs needing three-field interaction are missed (verdict stays `bounded`) |
| C | *Type universe from the symbol graph*: build Kotlin protocol/sealed inputs from their constructible classes, depth-bounded | 10, 13 | VPR 3 | Medium-high: the only way to reach 74 skipped Rules; risk: cycles, needs the framework built |
| D | *Behaviour lock*: commit a digest of every output over the generated domain; any refactor that changes behaviour fails with a diff | 26 Copying | VPR 4 | High: gives AI refactors a semantic diff without a hand-written spec |
| E | Generator as a build-tool plugin | 24 Mediator | VPR 6 | Deferred: symbol-graph extraction (41 s) is too slow per build; keep it an explicit command |

**Evaluation.** A+B+C together resolve the PC by separating *by system level* (class values per field, pair coverage across fields) with no new runtime component, only a generator that reads what the compiler and the Rule already contain. Altshuller level 3 (a known cover technique moved to a new domain and fed from the program itself). D is level 2 but cheap. E is rejected on time.
What stays unsolved: the *meaning* of a Rule. A generated domain finds crashes, non-determinism, collisions and behaviour changes, not "this label is wrong". A person still writes properties for that (earlier runs did).

