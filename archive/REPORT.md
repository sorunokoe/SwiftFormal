# Formal Verification for Swift in the Age of AI

*Research report, 28 October 2026. Built from four parallel research tracks (Lean/AI landscape, Swift and peer-language tooling, Swift DSL design, AI-era workflows) and a working prototype in [`prototype/`](prototype/).*

---

## 1. Summary

**Short answer:** Swift has no formal verification tools today. But you can build a useful version now, without changing the Swift compiler. The approach is a **small spec DSL in Swift** (a result builder) that:

1. **outputs Lean 4** definitions and theorems, which Lean's kernel then checks, and
2. **runs the same spec inside Swift**, so it can be compared against the real production code on many random inputs. AWS uses this approach for Cedar.

The AI writes the code and the proofs. A human reviews only the short spec. Lean decides whether the proofs are valid.

I built and checked this end to end (see §7). The Lean kernel accepted 4 checkout theorems. The differential test caught a discount bug written the way an AI might write it (`subtotal - discount` going negative).

Five facts shape the recommendation:

| Fact | Why it matters | Source |
|---|---|---|
| Claude proved "no crash on any input up to 64 MB" for **239 entry points in 123 OSS-Fuzz libraries**, about 180 million lines of Rocq proof, in a few weeks | AI-written proofs work at large scale now. You don't need to read the proofs, only the spec and the checker. | [Anthropic](https://www.anthropic.com/research/formal-verification) |
| In the "vericoding" benchmark, LLMs succeed **82% in Dafny, 44% in Verus, 27% in Lean** | Lean is the hardest target for AI today. Keep the generated Lean simple: plain functions, no Mathlib, `grind`/`omega`. | [arXiv 2509.22908](https://arxiv.org/abs/2509.22908) |
| Across benchmarks the pattern is the same: **code is easy, specs are harder, proofs are hardest**, and AI can "game" weak specs | Human review should focus on the spec. The tooling has to catch empty or always-true specs. | Verina, CLEVER, AlphaVerus (§8) |
| AWS Cedar: a Lean model about **10x smaller** than the Rust code, proved, then **differentially tested** against production on every release | The cheapest, best-proven path. The Lean model never ships in the app. | [lean-lang.org/use-cases/cedar](https://lean-lang.org/use-cases/cedar/) |
| Swift has **no verifier** (no Kani, Verus, Prusti or Aeneas equivalent). Apple uses formal methods heavily, but on C crypto and protocols, not on Swift. | This is an open space. Anything shipped here is new. | §3 |

---

## 2. What the three sources say

### 2.1 Anthropic: "Formal verification" (with Theorem)

- **Method: turn tests into proofs.** They took existing OSS-Fuzz harnesses and turned "this fuzz test never crashes" into a formal spec over the **compiled RISC-V binary**. Claude wrote the Rocq proofs and the Rocq kernel checked them. What you have to trust: the RISC-V/Linux model, the theorem statements, and the Rocq checker. Not the 180M lines of proof.
- **Bugs found along the way:** an underflow that only shows up on ~20 MB inputs, an out-of-bounds read needing a 64 MB input, a rediscovery of CVE-2026-56132 in libexpat, and a file-restriction feature that wasn't always enforced (a logic bug that never crashes). *"Even just attempting this process yields real bugs."*
- **Beyond memory safety:** fuzz tests often assert properties such as round-trip, idempotence, or equivalence with a reference. Proving "never crashes" therefore proves those properties too.
- **Other experiments:** a zlib (RFC 1950) spec proved against the x86 binary; a Python interpreter in Rust proved with **Verus** against CPython semantics (99.95% match on 1.7M random programs); a week of work on a PDF reader found about a year's worth of security bugs.
- **Cost is falling:** Opus 5.5 proves half of 36 tasks with about **40% fewer tokens** than Opus 5. A **shared proof workspace** cuts tokens by **17%**, because proofs get reused, much as Mathlib grows.
- **Their own limits:** *"Formally verified does not mean bug-free."* The proofs assume single-threaded, static RISC-V binaries on musl. ASan doesn't catch every memory bug. Callers can still misuse the library.
- **Conclusion:** verification will go from "bolted-on" to "built-in", *"driven not only by LLMs but also by innovations in language design and development workflows"*. That second part is where a Swift DSL fits.

Released artifacts: [oss-verify-proofs](https://github.com/theorem-labs/oss-verify-proofs), [rocq-linux-process-semantics](https://github.com/theorem-labs/rocq-linux-process-semantics), and a [Claude skill](https://github.com/theorem-labs/oss-verify/blob/main/.claude/skills/add-project/SKILL.md).

> **Note:** this work uses **Rocq** (and Verus), not Lean. The idea is the same: LLMs make proofs cheap, and a small trusted checker makes them safe to accept.

### 2.2 Lean 4 ([lean-lang.org](https://lean-lang.org/))

- **A programming language and a proof assistant in one.** Specs, code and proofs live in the same language. It has a small trusted kernel.
- **Automation:** `grind` (congruence closure, E-matching, linear arithmetic, case splitting), `omega`, `simp`, `decide`, `bv_decide` (bit-vectors). The Lean FRO roadmap says *"AI-generated proofs are becoming a major source of `grind` and `bv_decide` usage"* and plans to make error messages easier for agents to read.
- **Program verification:** `Std.Do` Hoare triples `⦃P⦄ prog ⦃Q⦄` with a verification-condition generator. ⚠️ **`mvcgen` has been replaced by `vcgen`.** New code should use `vcgen` ([docs](https://lean-lang.org/doc/reference/latest/The--mvcgen--tactic/)).
- **Compiles to C.** `@[export sym]` exposes Lean functions to C, `@[extern]` imports C functions. The FFI is officially **unstable**. Before calling exported symbols you must run `initialize_<Module>()` and `lean_io_mark_end_initialization()` ([reverse-ffi example](https://github.com/leanprover/lean4/tree/master/tests/lake/examples/reverse-ffi)).
- **No first-class Swift bridge.** The FRO's new FFI work ("Nerodia") is Python-first, *"because the AI ecosystem is dominated by Python"*. Swift would go through C, which it handles well.
- **Trust tooling:** `lake check [--paranoid]` re-checks builds with independent kernels. This matters once AI writes most of the proofs. (De Moura has described an AI "proof" that fooled two kernels through separate bugs.)
- **Versions:** stable **v4.35.0** (installed and used in §7); v4.36 is in release candidate. Releases come fast, so plan for some churn.
- **Industry use listed on the site:** Cedar (AWS), Aeneas (Rust→Lean, used by Microsoft for SymCrypt ML-KEM/SHA-3), Veil (distributed protocols), ArkLib (SNARKs), SampCert (AWS differential privacy).

### 2.3 Mathlib ([use-cases/mathlib](https://lean-lang.org/use-cases/mathlib/))

- More than **2 million lines**, about **291k theorems**, **140k definitions** and **772 contributors** ([stats](https://leanprover-community.github.io/mathlib_stats.html)). Every contribution is reviewed by a human, and the library has linters and CI.
- It's the training data and lemma search base for almost every AI prover (AlphaProof, Numina/Kimina, DeepSeek-Prover, Goedel-Prover, Seed-Prover, Aristotle).
- **For Swift work, you mostly don't need Mathlib.** App logic (money, counters, state machines, parsers) is covered by core Lean (`Nat`, `Int`, `List`, `grind`, `omega`). Mathlib adds a multi-GB cache and slow builds. Bring it in only for real math (probability, real analysis, number theory). The useful lesson from Mathlib is the **pattern**: proofs are reusable and compound over time. Anthropic's 17% saving from a shared workspace is the same effect.

---

## 3. Where Swift stands today

**No formal verifier exists for Swift.** ESBMC supports 9 front-end languages and Swift isn't one of them. CBMC is C/C++ only. There's no Swift Dafny, Verus or Kani, and no accepted contract proposal in swift-evolution. *(This comes from searching and finding nothing. Private prototypes could exist.)*

**But Swift already has much of the groundwork:**

| Swift feature | What it gives a verifier |
|---|---|
| Swift 6 strict concurrency (`Sendable`, actors, region isolation SE-0414) | Freedom from data races, enforced by the compiler (not mechanically proven) |
| `~Copyable` (SE-0390), `borrowing`/`consuming` (SE-0377), `~Escapable` + lifetimes (SE-0446), `Span` | Rust-like ownership, which is what lets Aeneas skip memory reasoning |
| Typed throws (SE-0413) | Exact error types, so postconditions are easier to state |
| Enums + exhaustive `switch` | State machines and typestate, often enough to make bad states impossible to write |
| SIL + Ownership SSA, with a SIL ownership verifier | The natural hook point for a future verifier (like MIR for Rust tools) |
| Macros (SE-0382/0389, body macros SE-0415) | Room for `@Requires`/`@Ensures` syntax, like `verus!{}` |
| Result builders (SE-0289) | Spec ASTs written in plain Swift (used in the prototype) |
| SwiftPM build/command plugins | Run `lean`/`lake`/`z3` during `swift build` and show diagnostics in Xcode |
| C/C++ interop | Link Lean-compiled C code |
| Swift Testing + [swift-property-based](https://forums.swift.org/t/propertybased-easy-quickcheck-for-swift-testing-on-all-platforms/82222), [SwiftCheck](https://github.com/typelift/SwiftCheck) | The property-testing layer |
| [swift-z3](https://github.com/LuizZak/swift-z3) | Z3 callable from Swift (a solver, not a verifier) |

**Apple itself:** iMessage PQ3 was verified with Tamarin, independently by ETH Zürich ([eprint 2024/1395](https://eprint.iacr.org/2024/1395)). corecrypto ML-KEM/ML-DSA were proved equivalent to their spec ([Apple security blog](https://security.apple.com/blog/formal-verification-corecrypto/)). All of that is C, assembly or protocol work. None of it targets Swift.

---

## 4. What other languages did

| Tool | Language | How you write specs | Backend | AI results |
|---|---|---|---|---|
| **Verus** | Rust | Inside the code: `verus!{}` macro, `requires`/`ensures`, `spec fn`/`proof fn` | Z3 | AutoVerus over 90% on 150 tasks; Anthropic's Python-interpreter proof |
| **Aeneas + Charon** | Rust → Lean/F*/Coq | No annotations; translates MIR to pure functions ("backward functions" handle `&mut`) | Interactive (Lean) | Microsoft SymCrypt: AI drafts proofs, humans review |
| **Kani** | Rust | Harnesses with `kani::any()` and contracts | CBMC bounded model checking | Firecracker: 27 harnesses in CI, found a rate-limiter bug |
| **Prusti / Creusot / Flux** | Rust | Attributes / Why3 / refinement types | Viper / Why3 / SMT | — |
| **Dafny** | Its own language → C#/Java/Go/Py/JS | First-class syntax | Boogie → Z3 | **82%** vericoding; AWS authorization engine (1B calls/sec) |
| **Cedar method** | Rust + Lean | Separate Lean model | Lean proofs + **differential random testing** | Lean runs a test case in ~5 µs vs ~7 µs for Rust, so millions of cases fit in CI |
| **SPARK, Frama-C, Stainless, Nagini, Kotlin contracts** | Ada, C, Scala, Python, Kotlin | Contracts in code | SMT | Kotlin contracts are the lightest: they only feed facts to the compiler |

**What Swift can take from this:** Rust's tools came out of years of funded work (AWS, Microsoft, ETH, the Verify-Rust-Std contest at $10–20k per challenge). Swift doesn't need to rebuild all of it. **The Cedar method needs no compiler changes**, and that's where to start.

---

## 5. Design options for a Swift DSL

| # | Option | How it works | Effort | Guarantee | AI fit |
|---|---|---|---|---|---|
| **f** | **SMT only** | DSL → SMT-LIB → Z3/cvc5 | Low | Proof, but only for decidable properties (arithmetic, bounded) | Very high (fully automatic) |
| **e** | **Differential testing (Cedar)** | Executable model + Swift code, random cross-checking | **Lowest** | Strong testing, not a proof | High |
| **b** | **Spec DSL → Lean + AI proofs** | Result-builder AST → `.lean`; AI fills proofs; Lean checks | Medium | **Proof about the model** | High (the "fill in the `sorry`" loop) |
| **a** | **Contract macros** | `@Requires`/`@Ensures` → runtime checks + property tests + proof obligations | Medium | Runtime checks; proofs via (b) | High |
| **d** | **Lean as the source of truth** | Write and prove in Lean → C → link into Swift | High | **The shipped code is the proved code** | Medium (FFI glue is fiddly) |
| **c** | **Swift → Lean translation (Aeneas-style)** | SwiftSyntax/SIL → pure Lean for a value-type subset | Very high (research) | Proof about the real code | Medium |

**Hard constraints the design has to respect:**
- **Macros have no type information** and are sandboxed (no file or network access). Macros can only produce syntax. Running Lean or Z3 has to happen in a **build or command plugin**.
- **Plugins have no network access by default.** Fetching toolchains or Mathlib (`lake exe cache get`) must happen in setup or CI, not during the build.
- **Option (d) on iOS is unproven.** Nobody has published Lean code statically linked into an iOS app. GMP (LGPL) is a licensing concern; the research agent reported a `USE_GMP=OFF` build flag, but I didn't verify it. This needs a spike before anyone relies on it.

---

## 6. Proposed architecture: one spec, three uses

```
                      ┌────────────────────────────┐
   Human reviews ───▶ │  Swift Spec DSL (small)    │ ◀── AI may draft, human approves
                      │  result builder → Spec AST │
                      └──────┬─────────┬───────────┘
                             │         │
          ┌──────────────────┘         └───────────────────┐
          ▼                                                ▼
 ┌──────────────────┐                         ┌──────────────────────────┐
 │ LeanEmitter      │                         │ SpecInterpreter (Swift)  │
 │ → Checkout.lean  │                         │ same semantics as Lean   │
 │ defs + theorems  │                         │ (Nat truncation, x/0=0)  │
 └────────┬─────────┘                         └────────────┬─────────────┘
          ▼                                                ▼
 ┌──────────────────┐   AI loop: fill proofs   ┌──────────────────────────┐
 │ Lean kernel      │ ◀── lean-lsp-mcp / REPL  │ Differential random test │
 │ accepts/rejects  │                          │ vs production Swift code │
 └────────┬─────────┘                          └────────────┬─────────────┘
          └──────────────► SwiftPM plugin ◀─────────────────┘
                     diagnostics in Xcode / CI gate
```

**The layers, from cheapest to strongest:**

0. **Types first (free).** Use enums for states, `~Copyable` for one-shot tokens (a payment intent can't be captured twice), typed throws, and `Sendable`. Many bugs disappear without writing any proof.
1. **Contracts (`@Requires`/`@Ensures` macro).** These expand to `precondition`/`assert` plus a property-based test using Swift Testing. AI agents get pass/fail feedback right away.
2. **Spec DSL → Lean model + differential test.** The model is proved in Lean and used as a test oracle for the Swift code. This is the main value of the design (prototyped in §7).
3. **AI proof loop.** An agent (Copilot/Claude) uses [`lean-lsp-mcp`](https://github.com/oOo0oOo/lean-lsp-mcp) or the [Lean REPL](https://github.com/leanprover-community/repl) to replace `by grind` with real proofs until Lean accepts them. The checks from §8.2 block cheating.
4. **(Optional) Lean → C → Swift** for a few critical kernels, such as rounding or a crypto helper, after an iOS linking spike.
5. **(Research) SIL → Lean translation** for a pure value-type subset, an Aeneas for Swift.

**What a mature DSL could look like** (sketch; the prototype implements a smaller version):

```swift
@Verified
@Requires(discount <= subtotal)
@Ensures(result + discount == subtotal)
func applyDiscount(subtotal: Cents, discount: Cents) -> Cents { subtotal - discount }

let PaymentFlow = StateMachine(PaymentState.self, PaymentEvent.self) {
    Transition(.created,    on: .authorize, to: .authorized)
    Transition(.authorized, on: .capture,   to: .captured)
    Transition(.captured,   on: .refund,    to: .refunded)
    Invariant("never captured without authorization") { trace in
        trace.firstIndex(of: .captured).map { trace[..<$0].contains(.authorized) } ?? true
    }
}
```
These compile to Lean `inductive` types, a `step` function, and theorems such as `∀ trace, valid trace → captured ∈ trace → authorized precedes captured`. The same spec drives a Swift Testing property test against the real `PaymentCoordinator`.

---

## 7. Prototype (built and verified)

Location: [`prototype/`](prototype/). Swift 6.4, Lean 4.35.0, about 350 lines in total.

| File | What it does |
|---|---|
| `Sources/FormalSpec/AST.swift` | Spec language: `Nat`, `Bool`, `+ - * /`, `min`, comparisons, `&& || ! ==>`, if/else, calls. Swift operators build the AST. |
| `SpecModule.swift` | `@resultBuilder` + `Function(...)` / `Theorem(...)` |
| `LeanEmitter.swift` | Outputs Lean 4 (`def`, `theorem … := by grind [defs]`), separating `Prop` (∧ → =) from `Bool` (&& ==) |
| `Interpreter.swift` | Runs the spec in Swift **with Lean's semantics**, plus `differentialTest(...)` |
| `Sources/Demo/main.swift` | Checkout spec → `lean/Checkout.lean` → differential test → Lean kernel check |

**The spec (what a human reviews):**
```swift
let checkout = SpecModule("Checkout") {
    Function("applyDiscount", ("subtotal", .nat), ("discount", .nat)) { p in
        ifThen(p[1] <= p[0], p[0] - p[1], else: 0)
    }
    Theorem("discount_never_exceeds_subtotal", ("s", .nat), ("d", .nat)) { v in
        call("applyDiscount", v[0], v[1]) <= v[0]
    }
    Theorem("tax_never_exceeds_amount", ("a", .nat), ("bps", .nat), proof: "...") { v in
        (v[1] <= 10_000) ==> (call("taxCents", v[0], v[1]) <= v[0])
    }
    // + capQuantity, valid_discount_is_exact, never_sell_more_than_stock
}
```

**Generated Lean (excerpt):**
```lean
def applyDiscount (subtotal : Nat) (discount : Nat) : Nat :=
  (if (discount ≤ subtotal) then (subtotal - discount) else 0)

theorem discount_never_exceeds_subtotal (s : Nat) (d : Nat) :
    ((applyDiscount s d) ≤ s) := by grind [applyDiscount, capQuantity, taxCents]

theorem tax_never_exceeds_amount (a : Nat) (bps : Nat) :
    ((bps ≤ 10000) → ((taxCents a bps) ≤ a)) := by
  intro h
  unfold taxCents
  apply Nat.div_le_of_le_mul
  rw [Nat.mul_comm 10000 a]
  exact Nat.mul_le_mul_left a h
```

**Actual run output (`swift run formal-demo`):**
```
Wrote …/prototype/lean/Checkout.lean
✗ applyDiscount (naive) disagrees with spec: inputs=[0, 1] spec=0 production=18446744073709551615  (UInt64.max = negative result)
✓ applyDiscount (fixed) agrees with spec on 10,000 random inputs
✓ Lean kernel accepted all theorems
```

**Checks I ran:**
- `swift test`: 3/3 pass (Lean-style `Nat` semantics, emitter output, differential test finds and clears a bug).
- **Negative control:** changing `≤` to `<` in a theorem makes Lean reject it (`grind failed … ⊢ False`). The pipeline doesn't accept everything.
- `grind` proved 3 of the 4 theorems automatically. The non-linear tax theorem needed a 5-line manual proof. **That's the gap an AI agent fills.**

**What the prototype shows in practice:**
1. **Model vs. reality mismatch is real.** Lean `Nat` subtraction stops at 0, while Swift `Int` goes negative and `UInt` traps. The differential test caught this at once. Anthropic says the same thing: bugs live where the spec or model differs from the real machine.
2. **Boundary values matter.** The prototype mixes `0` and `1` into the random inputs, which is how it found `[0, 1]` quickly.
3. **No Mathlib needed**, so builds take seconds.

**Run it:** `cd prototype && swift run formal-demo` (needs Lean, installed with [elan](https://github.com/leanprover/elan)).

**Not covered yet:** `Int`, enums and state machines, lists, structs, a SwiftPM plugin, the AI loop, contract macros. See §10.

---

## 8. Workflow: who does what

### 8.1 Roles

| Step | Who | Output |
|---|---|---|
| 1. Write or approve the **spec** (DSL) | **Human**, possibly drafted by AI | 20–100 lines, reviewed line by line |
| 2. Write the implementation | AI agent | Swift code |
| 3. Write the proofs | AI agent + `lean-lsp-mcp` / REPL | Lean tactic scripts |
| 4. Check | **Lean kernel** + differential test + Swift Testing | Pass/fail in CI and Xcode |
| 5. Investigate mismatches | AI, escalating to a human | Fix the code or fix the spec |

Kleppmann puts it this way: *"rather than having humans review AI-generated code, I'd much rather have the AI prove to me that the code it has generated is correct."* De Moura: *"testing provides confidence, proof provides a guarantee."*

### 8.2 Guarding against "spec gaming" (the biggest risk)

Benchmarks show AI writes specs that are empty or simply copy the implementation. AlphaVerus documents `assume(false)` abuse, and Verina reports 72.6% correct code but only **4.9%** correct proofs. Add these checks:

- **No `sorry`, no new `axiom`.** Check `#print axioms <theorem>` in CI; only Lean's standard axioms are allowed.
- **Theorem statements can't change without review.** Only proof bodies may be edited by AI. Hash the statements.
- **Non-vacuity check.** For every `A → B`, show that `A` is satisfiable with an example (`example : ∃ s d, d ≤ s := ⟨1, 0, by decide⟩`).
- **Mutation testing the spec.** Break the model on purpose (`≤` to `<`, +1). A theorem should fail, as in the negative control in §7. If nothing fails, the spec is too weak.
- **Use independent kernels** (`lake check --paranoid`) once proof volume grows.

### 8.3 AI tooling available today

- [`lean-lsp-mcp`](https://github.com/oOo0oOo/lean-lsp-mcp): diagnostics, goal states, LeanSearch/Loogle, for Claude Code/Copilot
- [Lean REPL](https://github.com/leanprover-community/repl), [LeanInteract](https://github.com/augustePoiroux/LeanInteract), [Pantograph](https://github.com/leanprover/Pantograph): programmatic proof stepping
- Theorem's [OSS-verify Claude skill](https://github.com/theorem-labs/oss-verify/blob/main/.claude/skills/add-project/SKILL.md): a template for a "verify this Swift module" skill
- **Model choice:** if Lean proofs prove too hard for agents (27% vericoding baseline), the SMT route (Z3) is fully automatic for arithmetic and finite state.

---

## 9. What to verify in an iOS app

**Worth it** (small, pure, high-stakes, easy to specify):
- **Money:** prices, discounts, tax, rounding, currency conversion, splitting payments. *There are almost no public fintech case studies here, so this is open ground.*
- **State machines:** login/MFA, payment and subscription, onboarding, permissions and feature flags, the same kind of logic AWS models with TLA+/P.
- **Offline sync / CRDT merge:** Kleppmann's Isabelle proofs cover the *algorithm*; you still need to check your *implementation* against it (differential testing).
- **Parsers and codecs** for untrusted input (deep links, QR payloads, binary formats). Round-trip theorems: `decode(encode x) = x`.
- **Date, time and unit conversion** (rounding, DST-safe arithmetic as pure functions).
- **Concurrency protocols** in custom sync engines: start with deterministic simulation testing (TigerBeetle/Antithesis style); Swift 6 checks are the minimum.

**Not worth it:** UI layout, animation, view-model glue. There's no precise spec to prove against (Galois: *"Specifications Don't Exist"*). Snapshot and UI tests are the right tools there.

---

## 10. Risks and limits

| Risk | Mitigation |
|---|---|
| **The spec is wrong** (the proof is correct but proves the wrong thing) | Human reviews the spec; non-vacuity checks and spec mutation tests (§8.2) |
| **The model differs from Swift** (Nat vs Int, overflow, `Decimal`, floating point) | Differential tests on every build; model Swift integers with fixed-width types (Lean `UInt64`/`BitVec`, `bv_decide`) |
| **Lean is hard for AI** (27%) | Keep the generated Lean first-order and Mathlib-free; fall back to SMT; keep proofs reusable (shared lemma library) |
| **Macros can't see types** | Keep translation in build/command plugins or a runtime AST (as the prototype does) |
| **Toolchain weight** | Lean is a few hundred MB; avoid Mathlib (multi-GB). Run Lean in CI, not inside the app. |
| **Shipping Lean in an iOS app (option d)** | Not proven; GMP licensing. Spike first, and default to "Lean only in CI". |
| **Lean API churn** (`mvcgen` → `vcgen`, unstable FFI) | Pin the toolchain with `lean-toolchain`; keep emitted Lean simple |
| **Kernel bugs** | `lake check --paranoid`, multiple kernels |
| **Cost** | Proofs can take many tokens; reuse lemmas and use a shared workspace (−17% at Anthropic); verify only the critical core |

---

## 11. Roadmap

| Phase | Deliverable | Effort | Value |
|---|---|---|---|
| **0 (done)** | Prototype: DSL → Lean + interpreter + differential test | — | Shows the idea works |
| **1** | Add `Int`/`UInt64`/`BitVec` semantics, structs, enums, lists; `StateMachine` builder; a `.leanProof` hash lock; `#print axioms` gate | 1–2 weeks | Covers money and state machines |
| **2** | SwiftPM **command plugin** `swift package verify` (runs `lean`/`lake`, shows diagnostics) + **build plugin** for CI | 1 week | Xcode/CI integration |
| **3** | `@Verified`/`@Requires`/`@Ensures` **macros** → runtime checks + Swift Testing property tests + link to the spec module | 2 weeks | Everyday syntax for developers |
| **4** | **AI loop**: an agent skill/MCP that turns `sorry` into a proof (lean-lsp-mcp), spec-gaming checks, a shared lemma library | 2–3 weeks | Proofs without proof experts |
| **5** | SMT backend (swift-z3) for decidable properties, as a fast first pass | 1–2 weeks | Fully automatic coverage |
| **6** | Spike: Lean → C → static library for iOS (USE_GMP=OFF) | 1 week spike | Decide on option (d) |
| **7 (research)** | SwiftSyntax/SIL → Lean for a pure value-type subset | Months | Proofs about the real code |

**Possible open-source angle:** there's no Swift verification ecosystem yet. A package like `swift-formal` (spec DSL + Lean emitter + differential testing + agent skill) would be the first. It also gives you material for case studies and posts.

---

## 12. Sources

**Primary (read directly)**
- Anthropic: Formal verification: https://www.anthropic.com/research/formal-verification · [appendix PDF](https://www-cdn.anthropic.com/files/4zrzovbb/website/6867eadf760258fa8b42a504600cd3c036d16358.pdf)
- Lean: https://lean-lang.org/ · Mathlib: https://lean-lang.org/use-cases/mathlib/ · Mathlib stats: https://leanprover-community.github.io/mathlib_stats.html

**Lean & AI provers**
- Lean FFI: https://lean-lang.org/doc/reference/latest/Run-Time-Code/Foreign-Function-Interface/ · reverse-ffi example: https://github.com/leanprover/lean4/tree/master/tests/lake/examples/reverse-ffi
- `grind`: https://lean-lang.org/doc/reference/latest/The--grind--tactic/ · `mvcgen`→`vcgen`: https://lean-lang.org/doc/reference/latest/The--mvcgen--tactic/
- FRO roadmap Y4: https://lean-lang.org/fro/roadmap/y4-1/
- Vericoding: https://arxiv.org/abs/2509.22908 · DeepSeek-Prover-V2: https://arxiv.org/abs/2504.21801 · Goedel-Prover-V2: https://arxiv.org/abs/2508.03613 · Seed-Prover: https://arxiv.org/abs/2507.23726 · Aristotle: https://arxiv.org/abs/2510.01346 · PutnamBench: https://trishullab.github.io/PutnamBench/
- LeanDojo: https://arxiv.org/abs/2306.15626 · LeanAgent: https://arxiv.org/abs/2410.06209 · lean-lsp-mcp: https://github.com/oOo0oOo/lean-lsp-mcp · REPL: https://github.com/leanprover-community/repl · Pantograph: https://github.com/leanprover/Pantograph

**Software verification**
- Cedar: https://lean-lang.org/use-cases/cedar/ · https://github.com/cedar-policy/cedar-spec · https://aws.amazon.com/blogs/opensource/lean-into-verified-software-development/
- SampCert: https://github.com/leanprover/SampCert · Aeneas: https://github.com/AeneasVerif/aeneas · Veil/Loom: https://github.com/verse-lab/loom
- Verus: https://github.com/verus-lang/verus · AutoVerus: https://arxiv.org/abs/2409.13082 · Kani: https://github.com/model-checking/kani · Verify Rust std: https://github.com/model-checking/verify-rust-std
- Dafny: https://dafny.org/ · DafnyBench: https://arxiv.org/abs/2406.08467 · Clover: https://arxiv.org/abs/2310.17807 · AlphaVerus: https://arxiv.org/abs/2412.06176 · CLEVER: https://arxiv.org/abs/2505.13938 · Verina: https://arxiv.org/abs/2505.23135
- AWS systems correctness (CACM 2025), AWS authorization in Dafny (ICSE 2025), Zelkova: https://www.amazon.science/blog/a-billion-smt-queries-a-day

**Essays**
- Kleppmann: https://martin.kleppmann.com/2025/12/08/ai-formal-verification.html
- de Moura, "When AI Writes the World's Software, Who Verifies It?" (Feb 2026, leodemoura.github.io)
- Tao, "Math 2.0" (Oct 2026, terrytao.wordpress.com)
- Provably safe AI: https://arxiv.org/abs/2405.06624 · Galois, "Specifications Don't Exist"

**Swift**
- SE-0382/0389/0415 (macros), SE-0289 (result builders), SE-0390/0377/0446 (ownership), SE-0413 (typed throws), SE-0414 (region isolation): https://github.com/swiftlang/swift-evolution
- SIL Ownership: https://github.com/swiftlang/swift/blob/main/docs/SIL/Ownership.md · C++ interop: https://www.swift.org/documentation/cxx-interop/
- swift-z3: https://github.com/LuizZak/swift-z3 · SwiftCheck: https://github.com/typelift/SwiftCheck · PropertyBased: https://forums.swift.org/t/propertybased-easy-quickcheck-for-swift-testing-on-all-platforms/82222
- Apple: PQ3 (Tamarin, ETH): https://eprint.iacr.org/2024/1395 · corecrypto: https://security.apple.com/blog/formal-verification-corecrypto/

**Not confirmed by a second source:** some homepage news items on lean-lang.org (Sept 2026 items such as "con-leche" and the prime-gap result), Math Inc/Gauss and Axiom figures, the `USE_GMP=OFF` route for iOS, and Lean linking on iOS. Some 2026 posts (de Moura, Tao, the SymCrypt post) were only read on their source pages.
