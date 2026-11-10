# SwiftFormal Evidence-Driven Implementation Plan

> **For agentic workers:** Use `executing-plans` for the bounded milestone being
> implemented. Execute the existing first-milestone plan before designing the
> translator. The unchecked items below are future work, not completed features.

**Goal:** Build a Swift library and development tool that checks precise
properties of selected real Swift functions, with explicit assumptions,
reproducible evidence, and no verification machinery in production.

**Architecture:** Extract a small, compiler-resolved subset of Swift into a
typed intermediate representation, generate proof obligations mechanically,
and check them with Lean. Keep the current model DSL as a research/test baseline,
not as evidence that arbitrary Swift implementations are proved.

**Tech Stack:** SwiftPM, Swift Testing, the installed Swift compiler, and Lean.
Start with the existing tools; add macros, caching, SMT, and AI only after a
measured need.

---

## 1. Recommendation and scope

**Build a narrow verifier, not a universal Swift theorem prover.** The first
product should answer:

> For this exact function, build configuration, and stated input domain, does
> every execution satisfy the contract without a modeled arithmetic trap?

Assumptions for this plan: verification runs on a development machine or CI;
the first target is pure scalar business logic; native Swift remains the shipped
implementation. Start on the available macOS host. Linux tool support and an
actual iOS consumer require separate evidence before claiming support.

The fastest credible next step is already specified in
[the compiler-bridge milestone](2026-11-03-swiftformal-first-milestone.md).
It asks whether actual Swift operations can be recovered faithfully before
committing to a translator. Preserve that plan and the prototype.

This document adds the TRIZ analysis, trust requirements, formal-methods work,
performance experiments, and release gates. It is a roadmap, not permission to
implement all stages or a claim that later APIs are already designed.

**Do not promise "most performant" before measurement.** Optimize total
developer time and verification cost subject to a fixed correctness policy.
A faster system that silently accepts unsupported behavior is not an
optimization.

## 2. Evidence available now

### Local observations, 3 November 2026

| Observation | What it establishes | What it does not establish |
|---|---|---|
| Swift 6.4 and Lean 4.35.0 are installed | A local baseline is available | Compatibility with every Swift/Lean release |
| Existing three Swift Testing tests pass | The currently tested prototype behaviors work | Soundness of the prototype or completeness of its tests |
| Demo finds a naive discount mismatch and samples 10,000 agreeing fixed-code inputs | The model is useful as a test oracle | Equivalence for all Swift inputs |
| Lean accepts the four generated checkout theorems | These statements about the Lean model have proofs | Correctness of the separate Swift functions |
| A strengthened, false strict-discount claim fails checking | A meaningful negative control is rejected | Every false claim will be detected by this integration |
| `theorem unfinishedClaim : False := by sorry` exits with status 0 | Exit status alone is insufficient | That Lean has proved `False`; the result depends on `sorryAx` |
| The four model theorems depend only on `propext`, `Classical.choice`, and/or `Quot.sound` | Their audited dependencies fit the proposed logical-axiom allowlist | Correctness of the model-to-Swift connection |

Commands used:

```bash
lean --version
swift test --package-path prototype --quiet
swift run --package-path prototype --quiet formal-demo <session-output-directory>
```

The test command took 9.53 seconds wall time; the demo command took 14.71 seconds.
These are **single, uncontrolled invocations including SwiftPM overhead**, not
proof-engine benchmarks, cold-build measurements, or performance targets.
The test runner reported 0.005 seconds for its three tests.

Audit and negative-control sources are retained under this session's
`files/swiftformal-baseline/`. No prototype source was changed.

### Important limits found in the current code

- `prototype/Sources/FormalSpec/AST.swift` defines a separate specification
  language. `LeanEmitter.swift` translates that language, not production Swift.
- `SpecInterpreter.Value.nat` uses `UInt64`, whereas emitted Lean `Nat` is
  unbounded. The interpreter reports overflow; it is not an equivalent
  interpreter of every Lean natural-number computation.
- `Interpreter.swift` uses unseeded randomness. Preserve failing inputs, but
  add seeded generation before using this mechanism for reproducible studies.
- `Demo/main.swift` prints mismatches without making them a failing gate.
  Its missing-Lean path can also finish successfully. It is a demonstration,
  not a release-verification command.

These are planning inputs, not changes made in this task. Earlier statements in
`REPORT.md` and `EXPLAINED.md` such as "no verifier exists", "only trust the
checker", or "the shipped code is the proved code" are too broad to carry into
product claims. In particular, Swift integer input sets are finite, and
compiler, translation, specification, and integration assumptions still matter.

### External evidence that affects the design

- AWS Cedar demonstrates model proofs plus differential testing as a useful
  production method. AWS describes the implementation connection as testing,
  not a universal implementation-equivalence proof. [S1]
- SwiftSyntax provides source-accurate syntax; macro expansion is a syntactic
  transformation. Well-typed macro arguments do not give a macro implementation
  a general compiler-resolved semantic API. [S2, S3]
- SIL contains typed, high-level information and has raw and canonical stages.
  Its binary representation is explicitly unstable. Treat an extraction adapter
  as compiler-version-specific, not as a promised stable verifier interface. [S4]
- Swift checked arithmetic and wrapping arithmetic differ; operators may also
  be overloaded. Translating the token `+` is not enough to identify behavior. [S5]
- Lean supports transitive axiom auditing. `sorryAx` permits unfinished proofs;
  native-evaluation proofs can add compiler-trust axioms. [S6]
- SwiftZ3 is an available solver wrapper, not a Swift implementation verifier.
  Its existence does not remove the frontend or semantics problem. [S8]

None of these sources establishes SwiftFormal's eventual speed or adoption.
Published AI success percentages on other languages are not a backend benchmark
for this project.

## 3. TRIZ analysis

TRIZ is used here to expose the conflict, not as mathematical evidence.
Software "substances" and "fields" below are explicit information-processing
analogies. There is no claim of a physical discovery or a measured invention
level.

### Steps 0-1: Triage, undesirable effects, and inventive task

The request implies a latent conflict between stronger checking and execution
cost. The current architecture already resolves part of it by running Lean
outside production. Do not invent a runtime slowdown that has not been observed.

Undesirable effects:

- **NE1, observed limitation:** a model proof can be mistaken for a proof of
  the Swift implementation.
- **NE2, design risk:** verification and proof discovery can increase developer
  wait time and compute cost; the size is not yet measured.
- **NE3, avoidable design risk:** shipping verification work with the app would
  add runtime work and dependencies.

Causality: a missing implementation-to-model link causes NE1. More proof effort
on the same disconnected model does not fix it. Verification work on a critical
path creates NE2 or NE3 depending on where it runs; NE2 does not require NE3.

**Inventive situation:** SwiftFormal uses the existing Swift compiler, spec AST,
Swift tests, and Lean checker to reason about function behavior through
compilation, testing, and proof-checking computations. This produces useful
model evidence, but the connection to the Swift function is incomplete, and
additional checking consumes time.

**Inventive task:** establish source-bound evidence for a small real Swift
function using the existing development-time computation path, without moving
verification computation into production.

### Step 2: Administrative, technical, and physical contradiction

**Administrative:** We need trustworthy verification of Swift code without
making normal development and production prohibitively expensive.

**Technical:** Increasing the checking work used to establish reliability can
increase time spent waiting.

**Physical/digital-state formulation:**

> The verification computation must be active to establish the function's
> guarantee AND inactive to avoid production verification overhead simultaneously.

The opposing states belong to the verification computation, not to two different
components. Separation determines when each state holds. This formulation does
not imply that all build-time cost can disappear.

### Step 3: Vepol model at the conflict

Using the requested S1-tool/S2-object convention:

```text
S1: existing compiler/checker path
  -- Field: compilation and proof-checking computation -->
S2: representation of the selected function
```

The model is **insufficient for an implementation claim**: the current checker
receives a separately authored model rather than mechanically linked code.
Checking more statements about that model does not supply the missing link.

Apply **Standard 1.1.2, internal structural improvement**: extend this same
development-tool path with a source-linked representation and an explicit
obligation manifest. This is a proposed internal software change, not an
already-existing capability or a new production service.

### Step 4: Ideal final result

**IFR-1:** The existing compiler/checker path establishes the selected function's
guarantee by itself, without added cost, harm, or complexity.

**IFR-2:** The verification computation at the function-checking boundary must
be active to establish the guarantee, and inactive to avoid production
verification overhead simultaneously.

IFR-1 is an ideal, not a forecast. Actual proof work and frontend maintenance
have costs; report them instead of claiming they have been eliminated.

### Step 5: Existing resources

| Category | Resources actually available |
|---|---|
| Substances / information | **R1:** Swift source and demo functions. **R2:** the prototype spec AST, emitter, and generated Lean definitions |
| Fields / operations | **R3:** installed Swift compilation and Lean checking |
| Space | **R4:** existing local artifact storage and separate command-line processes; no extra server is needed |
| Time | **R5:** the existing pre-release development/test stage; this is movable work, not an assertion of idle CPU availability |
| Functional | **R6:** Swift Testing and differential comparison; **R7:** Lean's reusable theorem and axiom-audit facilities |

### Step 6: Separation first, then exact matrix lookup

Evaluate in the `thinking-triz` order:

| Separation | Result |
|---|---|
| **Time** | Verify before release, not per app call. This resolves production verification overhead and is already the prototype's direction. Keep it. |
| **Space** | Put checker, proof search, and test adapters in development-only targets, outside the app dependency graph. This enforces the time separation. |
| **Condition** | Reuse evidence only when the complete source/configuration/dependency identity still matches; otherwise recheck. This helps repeated work, not arbitrary changed code. |
| **Scale** | Prove small supported functions, compose through checked contracts later. This limits cost but leaves an honest coverage restriction on the rest of Swift. |

For the requested classical TRIZ cross-check, the exact supplied
`matrix.md` cell is **R27 Reliability / W25 Loss of time -> 10, 30, 4**.

- **10, Preliminary action:** move checking before production and perform
  expensive proof discovery outside routine builds.
- **4, Asymmetry:** separate flexible proof discovery from strict acceptance.
  AI may propose; a deterministic checker and policy decide.
- **30, Flexible shells/films:** no useful additional mapping is needed.
  A thin annotation wrapper does not solve source fidelity.

These are heuristic software mappings, not an empirical ranking of algorithms.
The known offline-checking pattern settles the runtime conflict, so follow
`thinking-triz`'s over-application guard: do not escalate to ARIZ just to claim
a novel invention. The missing compiler bridge needs engineering evidence.

### Steps 7-8: Three concepts and evaluation

Ideality is assessed qualitatively as useful assurance divided by development,
checking, maintenance, and runtime costs. There are no measurements that justify
a numerical ideality ratio or a "Level 3+" novelty claim.

| Concept | Mechanism, principle, and reused resources | Guarantee and IFR proximity | Cost / feasibility / heuristic level |
|---|---|---|---|
| **A. Model plus differential tests** | Keep R1-R3, R6-R7; use a model as a copy/oracle, Principle 26 | Zero production checker cost; implementation equivalence remains unproved | Lowest immediate cost; already demonstrated; Level 1-2 adaptation |
| **B. Compiler-linked small verifier: recommended** | Use R1, R3-R5, R7; internally connect resolved Swift operations to proof obligations, Standard 1.1.2 and Principles 10/4 | Source-linked proof under explicit compiler/translation assumptions; no production checker | Best fit to the actual goal; frontend feasibility unproved; Level 2 adaptation |
| **C. One restricted DSL generates Lean and native Swift** | Reuse R2-R3, R6-R7; one description has two outputs, Principle 6 and scale separation | Avoids separately handwritten implementations, but the Swift generator still needs correctness evidence | Feasible fallback with language restrictions and generator trust; Level 2 adaptation |

**Choose B conditionally on the compiler-bridge gate.** If it needs broad
heap/runtime modeling or a large compiler fork, stop and evaluate C. Keep A as
a useful baseline, never silently relabel it as B.

### Compact `thinking-triz` resolution

- **contradiction:** verification computation / active to establish evidence /
  inactive to avoid production verification cost.
- **ideal_final_result:** checked guarantees for selected Swift code, without a
  shipped checker or repeated open-ended proof discovery.
- **separation_tried:** time resolves runtime cost; space enforces it;
  condition permits safe reuse; scale limits the supported domain.
- **inventive_move:** none needed beyond known offline verification;
  preliminary action and asymmetric discovery/checking describe the design.
- **resources_reused:** R1-R7.
- **resolution:** compiler-linked proof obligations and Lean checking run in
  development tooling; ordinary Swift executes in the app.
- **residual_tradeoff:** verification latency, translation maintenance, a
  trusted toolchain, and limited language coverage remain. No guarantee of
  fast automatic proofs for arbitrary Swift is possible.

## 4. What "proved" must mean

### Start with one deliberately small language

Stage 2 supports `Int64`, `Bool`, constants, immutable locals, branches, returns,
comparisons, and checked addition/subtraction. Resolve every operation and
dependency exactly. Compiler-introduced scaffolding is accepted only through
explicitly justified lowering rules.

Initially reject `Int`, wrapping arithmetic, multiplication/division, floats,
custom operator semantics, unknown calls, heap objects, collections, loops,
recursion, effects, and async code. Reject an unknown operation rather than
silently dropping it. Add `UInt64` only after signed semantics are established.

This sacrifices coverage, not honesty. It does not prove an entire application.

### Concrete first contract

For the actual `clampedDiscount` function from the first-milestone plan:

```text
Inputs: s and d are Int64.
Precondition P: s >= 0 and d >= 0.
Postcondition Q:
  0 <= result <= s
  if d <= s, result = s - d
  if d > s, result = 0
Safety: no reachable arithmetic trap under P.
```

Contract arithmetic above denotes mathematical integers. Machine range
obligations are separate. The equality clauses matter: a function returning
zero for every input satisfies a weak bound but violates the intended rule.

The core theorem shape is:

```text
For every representable input x satisfying P:
  evaluation of extractedIR(x) terminates with a value y,
  no modeled trap occurs,
  and Q(x, y) holds.
```

For the initial loop-free subset, termination follows from its finite
evaluation structure. Loops cannot later inherit that guarantee without a
termination argument. Bounded exploration, if added, must report its bound.

### Three separate correctness obligations

1. **Source connection:** the extracted representation preserves the selected
   Swift function's behavior. Initially the extractor and Swift compiler are
   trusted, with adversarial and differential validation. Do not call them
   formally verified.
2. **Proof-rule soundness:** formalize the small representation's evaluation and
   verification-condition rules in Lean, including traps and path conditions.
   Prove that discharged conditions imply the theorem above. This reduces
   trust in the condition generator but does not prove the Swift extractor.
3. **Contract adequacy:** the rule captures intended behavior and its input
   conditions are meaningful. Use human review, concrete witnesses, independent
   examples, and non-equivalent mutations. Proof does not choose product intent.

Require a checked witness satisfying each precondition; an impossible
precondition must not make a release claim vacuously pass. At call boundaries,
prove the precondition or retain real input validation. Do not remove safety
checks just because a conditional theorem exists.

### Result and proof policy

Record target and evidence separately from outcome:

| Field | Required meaning |
|---|---|
| Target | Separate model, extracted implementation, or generated implementation |
| Outcome | Checked proof, replayed counterexample, unproved, unsupported, timeout/unknown, or tool error |
| Scope | Input conditions, modeled behavior, configuration, and any bounds |
| Trust | Kernel/axioms, compiler, extractor, semantics and integration policy versions |
| Identity | Source/body, contract, generated obligations, dependency closure, tool versions, target/SDK, flags, and policy digests |

An SMT result, sampled agreement, and a Lean-checked proof are different
evidence kinds. A timeout is not a counterexample. A failed tactic is not proof
that the contract is false.

The acceptance gate must:

- Reconstruct the expected obligations from the current inputs and require
  every one, including arithmetic safety and precondition witnesses.
- Audit actual theorem types and transitive axiom dependencies. Initially allow
  only `propext`, `Classical.choice`, and `Quot.sound`; reject `sorryAx`,
  user-added assumptions, and native-evaluation trust axioms.
- Keep definitions, theorem statements, imports, and semantics under reviewed
  control. AI may supply proof terms/scripts only in a constrained proof slot.
  Hashing statements alone does not protect changed definitions.
- Use isolated, pinned checker inputs. Text grep and a green process exit are
  not substitutes for inspecting the elaborated proof environment.
- Treat stale or incomplete evidence, missing tools, cancellation, and process
  failure as non-success. Never cache only a Boolean "passed".

The final trust boundary still includes the specification, extraction/linkage
logic, proof kernel and allowed axioms, Swift compilation and runtime assumptions,
and the build/release gate. Kernel checking is not a proof of this whole chain.

## 5. Minimal architecture

```text
Selected real Swift source + approved contracts + build configuration
                         |
                 compiler-resolved artifact
                         |
              checked subset extractor (trusted)
                         |
                  typed, versioned IR
                         |
           Lean semantics + generated obligations
                         |
          saved proofs + bounded deterministic tactics
                         |
      Lean checker + theorem/axiom/completeness audit
                         |
           source-bound report + required CI gate

Native Swift build ----------------------------------> shipped app
Independent executable probes ----------------------> regression evidence
Optional proof discovery ----------------------------> proposed proofs only
```

Keep two initial production packages after the experiment succeeds:

| Planned package/path | Responsibility |
|---|---|
| `Packages/SwiftFormal/` | Small verification library: validated IR, result/evidence model, semantics-facing data; focused unit tests |
| `Packages/SwiftFormalTools/` | Compiler adapter, Lean emission/runner, reporting, CLI composition, and real end-to-end integration tests |
| `Proofs/SwiftFormal/` | Pinned Lean semantics, soundness lemmas, example proofs, and policy audits |

Keep the existing `prototype/` unchanged as a named baseline. Do not create these
packages during planning. Final file-level translator tasks depend on the
compiler artifact inventory; guessing a grammar now would be false precision.

The CLI owns process lifecycle and composition, not a second copy of the
verification algorithm. It must invoke the same library tested independently.
No server, daemon, solver portfolio, or custom theorem-proving kernel is needed.

Macros are later annotation/diagnostic conveniences, not semantic authorities.
A command wrapper can explicitly order compilation, extraction, checking, and
reporting. SwiftPM build-tool plugins should not be assumed to provide a general
post-compilation hook. [S7]

## 6. Delivery stages and stop/go gates

| Stage | Deliverable | Required evidence before the next stage |
|---|---|---|
| **0. Baseline and claim policy** | Preserve the prototype; define evidence labels, trusted components, and supported claims | Model proofs, sampled agreement, false claims, and missing proofs are visibly distinct |
| **1. Compiler bridge** | Execute the existing detailed experiment; inspect raw/canonical/optimized representations and real executions | Recover exact types, branches, calls, checked-vs-wrapping behavior and source identity; reject unresolved behavior |
| **2. Five-function vertical slice** | Actual-body verification for clamped discount, bounded increment/decrement, interval membership, and scalar cap | Correct cases proved, deliberately wrong bodies never accepted, overflow obligations enforced, and Lean soundness lemmas for the tiny IR checked |
| **3. Required verification command** | One development command, structured diagnostics, reproducible tool setup, one actual consumer | Missing checker/proof, stale evidence, unknown instruction, and interrupted execution all block required verification |
| **4. Frozen pilot** | Compare the verifier with compiler/tests on independently selected functions and bugs | Assurance, coverage, human-time, and performance results meet the predeclared pilot gates below |
| **5. Focused optimization and expansion** | Improve the measured bottleneck; add one justified language feature at a time | Same correctness policy and held-out evidence; no hidden drop in coverage or weakened assumptions |

Stage 3 includes macOS package integration first, then an actual iOS build and
release artifact inspection before any iOS claim. Reject `-Ounchecked` and
unrecognized compilation settings. `-Onone` and `-O` observations must remain
distinct and be tied to the configuration used to produce the shipped code.
Do not equate a macOS proof run with validating an iOS executable.

### Immediate execution checklist

- [ ] Execute Tasks 1-3 in
  [the first-milestone plan](2026-11-03-swiftformal-first-milestone.md):
  preserve baseline, create fixtures, collect compiler artifacts and 26
  executable observations.
- [ ] Execute its Task 4: inventory semantics and decide which representation,
  if any, can support a trustworthy narrow extractor.
- [ ] Apply a proposed **five-engineer-day investigation cap**, not a delivery
  estimate. If blocked, record the exact missing information and evaluate one
  evidence-motivated alternative; do not start a broad compiler rewrite.
- [ ] Execute its Task 5: write the observed decision and the next bounded
  implementation plan. Preserve all failures and exclusions.
- [ ] Only after a passing bridge gate, write the Stage 2 plan with the actual
  operation grammar, tests, Lean rules, and file-level changes.

Within each implementation task: add a focused failing test, implement the
smallest behavior, check the library, then check the actual CLI/compiler/checker
path. Fake-only tests cannot establish integration correctness.

Schedule later stages from measured Stage 1-2 throughput, not from an unsupported
"complete library in a few weeks" estimate. The first five functions are an
alpha milestone, not a production-readiness claim.

## 7. Proof-driven development of the verifier

Construct an independent test matrix rather than testing an emitter against
another emitter sharing the same faulty rule.

| Area | Required positive and negative evidence |
|---|---|
| Arithmetic | Signed minima/maxima, negative values, checked overflow, and unreachable-overflow branches |
| Control flow | Both branches, boundary comparisons, short-circuit behavior, and early returns |
| Source fidelity | Change a real function body while holding its contract constant; the result must change or be rechecked |
| Operation identity | Same operator spelling with different resolved implementations; unsupported overloads must not acquire built-in semantics |
| Proof policy | False statement, `sorry`, additional axiom, changed definition, missing obligation, and forged/stale result |
| Tool integration | Missing Lean, timeout, cancellation, truncated output, crash, and unknown compiler version |
| Specification quality | Satisfiable preconditions; expected concrete behavior; wrong-but-bound-respecting implementations such as always-zero |

Use exhaustive checks over reduced-width reference domains to test arithmetic
rules, plus native 64-bit boundary executions. A reduced-width enumeration is
not a proof about all `Int64` behavior. Run potentially trapping Swift executions
in child processes and confirm the cause, not merely a nonzero exit.

For interpreter/emitter comparisons, a separately implemented executable oracle
can expose mismatches, but agreement does not prove translation correctness.
Mechanically checked IR/condition-generation theorems provide a different and
stronger form of evidence.

For each added operation, require its semantics, proof rule, local correctness
lemma, negative cases, and actual compiler-to-checker integration before
declaring the operation supported.

## 8. Data-driven pilot and performance

### Freeze the experiment before optimizing

Use **40 independently selected real functions** from small numeric rules and
pure decisions: 20 for development, 20 held out. Inventory how many fit the
declared subset rather than silently replacing difficult cases. Keep related
function families in the same partition to limit leakage.

Create three reviewed, non-equivalent defect variants per function where
possible: wrong branch/boundary, wrong result, and unsafe arithmetic or missing
guard. Report the actual mutant count; do not force meaningless variants just
to reach 120. Keep equivalent/uncompilable mutants out of the denominator and
document those exclusions.

Freeze contracts, input domains, expected behavior, and defect labels before
tuning the tool. Preserve fixed random seeds, minimized failure inputs, exact
revisions, command lines, tool binaries, and machine configuration.

Compare on the same corpus:

1. Swift compiler and existing tests.
2. The same baseline plus generated/differential tests.
3. Source-linked proofs plus the same baseline.
4. Optional AI-assisted proof discovery, measured separately.

Count a blocked build separately from a confirmed defect. Replay proposed
counterexamples against the actual Swift body when possible.

### Metrics and provisional acceptance budgets

These numbers are proposed project gates, **not observed performance**:

| Metric | Initial gate or reporting rule |
|---|---|
| Known-invalid implementations accepted as proved | **0**; any occurrence stops release and requires a root-cause fix |
| Missing/stale/unsupported/error cases reported as proved | **0** across the fail-closed integration suite |
| Held-out language coverage | At least **10 of the 20 held-out functions** supported; otherwise narrow the product claim or improve coverage before calling the pilot successful |
| Held-out proof completion | At least **80% of supported held-out functions**, counting a function only when all its obligations pass |
| Scope transparency | Publish supported/total functions and obligations, exclusions, unknowns, and timeouts alongside the 80% figure |
| Added defect detection | Report confirmed defects missed by each baseline, separating seeded mutations from naturally occurring bugs; unknown/blocked cases are not confirmed detections |
| Interactive incremental cost | Target **p95 <= 2 seconds additional wall time** above the equivalent normal incremental build, including adapter, proof check, audit, and reporting |
| Small CI proof batch | Target **p95 <= 60 seconds** additional wall time for a fixed 100-obligation batch, excluding first tool installation but including proof replay and audit |
| Per-obligation bound | Initially stop automated checking after **10 seconds wall time**; report timeout, never success |
| Production overhead | No verification runtime dependency, inserted proof checks, or proof data in the app artifact |
| Human cost | Record contract authoring/review, proof repair, and debugging minutes separately, including failed attempts |
| AI cost | No AI in the default verification command; separately record attempts, time, tokens/cost if explicitly enabled |

If a performance budget proves unrealistic, change scope or redesign the
bottleneck explicitly. Never meet it by lowering the acceptance policy or
removing hard cases from the published denominator.

Measure total developer-visible latency as well as stage breakdowns:
compile/extract, normalize, generate conditions, elaborate/replay proofs,
kernel checking where observable, audit, and report. Do not label combined Lean
execution time as pure kernel time when the instrumentation cannot separate it.

Use at least 30 paired runs per steady-state scenario on a fixed machine;
alternate baseline and candidate ordering, publish raw samples, p50/p95, and
uncertainty. Include peak memory, cold dependency/build setup separately,
warm proof replay, one-function edits, and changed toolchain/configuration.
If noise overlaps the claimed improvement, report it as inconclusive.

Runtime performance needs a separate experiment on the real consumer:
compare the same native function/build with verification tooling enabled and
disabled, inspect dependencies/link maps/symbols, and check startup and hot-path
behavior. No verifier in the link graph supports the design claim; one noisy
microbenchmark does not establish "zero overhead" by itself.

Zero observed invalid acceptances is a necessary gate, **not a soundness proof**
or an estimate of a universal zero failure probability. Small held-out samples
also leave large uncertainty; publish counts, not just percentages.

### Optimize only in response to the measurements

| Measured bottleneck | First intervention | Correctness condition |
|---|---|---|
| Repeated work on unchanged inputs | Content-addressed evidence reuse | Include the full identity/dependency closure; release checking must not trust an unverified cached Boolean |
| Repeated equivalent obligations | Canonicalize and deduplicate | Preserve source mapping and prove/test the normalization rules |
| Repeated proof discovery | Reusable lemmas and checked-in proofs | Replay against current obligations; no automatic contract edits |
| Process startup dominates | Batch independent Lean checks | Every obligation and dependency audit still runs |
| Proof search dominates | Better obligation decomposition and bounded tactics | No discarded paths or added assumptions |
| Genuine supported-theory gap | Benchmark one SMT backend on the frozen corpus | Solver-trusted evidence remains labeled separately unless proofs are reconstructed/checked under the same policy |

Do not initially build persistent solver daemons, speculative parallel portfolios,
a remote cache, or a custom prover. Add each only when its measured benefit
exceeds its implementation and maintenance cost.

## 9. Expansion order

After the pilot, prefer the feature with the best observed reduction in excluded
real cases per unit of semantics/proof/maintenance work.

The likely order is `UInt64`, small structs/enums, pure state transitions, then
carefully selected bounded collections or loops with invariants. A state-machine
API must generate or verify the actual transition implementation; testing a
separate transition diagram does not prove production behavior.

For loops, distinguish bounded checking from inductive safety proofs and
termination. For external functions, record reviewed, versioned assumptions or
reject the call; documentation retrieval is not an implementation proof.
Concurrency, floating-point semantics, unsafe memory, and general framework
behavior are separate research scopes, not implied by Swift 6 type safety.

AI is optional proof discovery after deterministic verification works. It must
not edit accepted contracts, theorem statements, semantics, or exclusions to
make a result green. Proposals cannot cross the acceptance boundary unchecked.

**Release message:** say exactly which functions, properties, input domains,
builds, and trust assumptions were checked. Do not market a whole app as
"bug-free", a model-only proof as implementation verification, or a favorable
pilot as proof of universal speed.

## Sources

- **S1:** AWS, *Lean into verified software development*:
  https://aws.amazon.com/blogs/opensource/lean-into-verified-software-development/
- **S2:** SwiftSyntax:
  https://github.com/swiftlang/swift-syntax
- **S3:** Swift SE-0382, especially type-checked arguments and syntactic translation:
  https://github.com/swiftlang/swift-evolution/blob/main/proposals/0382-expression-macros.md
- **S4:** Swift SIL introduction, stages, types, and format:
  https://github.com/swiftlang/swift/blob/main/docs/SIL/SIL.md
- **S5:** The Swift Programming Language, Advanced Operators:
  https://github.com/swiftlang/swift-book/blob/main/TSPL.docc/LanguageGuide/AdvancedOperators.md
- **S6:** Lean reference, Axioms, including auditing, `sorryAx`, and native evaluation:
  https://lean-lang.org/doc/reference/latest/Axioms/
- **S7:** Swift SE-0303, Package Manager Extensible Build Tools:
  https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md
- **S8:** SwiftZ3:
  https://github.com/LuizZak/swift-z3

Sources were consulted on 3 November 2026. Moving `main` and `latest` URLs are
research references, not dependency pins; implementation must record exact
toolchain and source revisions. TRIZ lookups used the supplied skill's
`matrix.md` R27/W25, `standards.md` 1.1.2, and principles 10 and 4.
