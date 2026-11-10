# Performance, the next level: analysis and plan

Snapshot: main at 2cda3ca (2026-11-08). Three earlier rounds (2026-11-06 to 11-08) removed the obvious costs: process
spawning, text scanning, the closure comparison, linking in parallel, the toolchain probe, the SwiftPM builds of
`check` and `verify`. This report is about what is left once those are gone: changes to structure, representation,
algorithms and the verification strategy, with what other tools and the literature show about each.

Evidence (prototypes behind the measured numbers) is kept next to this file in
[2026-11-08-performance-next-level-evidence/](2026-11-08-performance-next-level-evidence/README.md).

How it was made: five investigations in parallel (the SAT and proof stack, the SIL front end and Scan pipeline, the
Walk library with LLVM and plugins, SAT/SMT research, verification-tool research), each measuring in its own scratch
copy, plus measurements of main for this report. Machine: M4 Pro, 14 cores, Swift 6.4, often loaded (load 4 to 45):
read every wall time as roughly ±30 %, ratios and counts as exact. Numbers are marked **measured** (on this code),
**literature** (reported by a paper or tool), or **projected** (an estimate). Sources are at the end.

## Status (2026-11-09)

Commit subjects carry an `NL-` prefix (the round-2 ledger uses the same letters: its S7 is the parse cache).

| Item | State | Measured (release, best of 3, same reports with `--stats`) |
|---|---|---|
| R1-lite | done on main by round-2 S7 (2328295), before this plan was started | |
| R2 | done (`NL-R2`) | k8192 CPU 53.6 → 50.0 s |
| S1 | done (`NL-S1`); `proveExactly` only, `Refine` still solves the whole formula | k8192 CPU 50.0 → 36.8 s, wall 8.4 → 7.5 s; Metrics (default budget) 108.5 → 77.2 s |
| S3 | done (`NL-S3`), answers of 2,000+ conflicts or out of budget, within a process | Metrics 77.2 → 38.7 s; k8192 unchanged |
| Trust gaps | done (`NL-T`): Refine lemmas listed in TRUST.md; no default proof-cache directory | |
| Phase 0 recipe | done (`NL-0`): `Scripts/sample-inclusive.py`, PERFORMANCE.md | after S1/S3, in `proveExactly`: 50 % encoding, 36 % checking (loading the whole formula), 4 % solving |
| S2 | done (`NL-S2`), approved by the owner; `SFCheck` 282 → 289 lines | k8192 CPU 37.6 → 32.9 s |
| R3, C2, V4 | wait for round 6 (`integration/app-study-round-6`): R3 and C2 touch `Compile.swift`/`Link.swift`, V4 `Verify.swift`, all rewritten there; C2 also changes the `at` locations reported in callees, so it needs a report check | |
| App-scale benchmark (Phase 0) | not started; needed before Phases C and D | |

---

## 1. Summary

**Where the time goes now**, measured on main:

| Workload | Wall | Where it goes |
|---|---:|---|
| `sfverify` on one small file | 0.17 s | mostly two compiler runs (one per build configuration) |
| `Examples/Metrics` (6 functions) | 111 s | one function, `mulCommutes32` (`a &* b == b &* a`, 32-bit): 300,000 conflicts and `undecided`, **twice** (once per configuration) |
| Generated module, 8,192 functions (65 MB of SIL) | 12.5 s | compile 8.6 s CPU (two configurations, type checking is 70 % of each), parse 2.4 s, verify 6.7 s; 46 million clauses built, 4,095 conflicts in total |
| `sfverify --package . --target SFSIL --build` | 9–25 s | compiling 6 linked modules twice (two configurations); then encoding: 89 % of engine CPU is the encoder, 87.6 % of every CNF is outside the goal's cone |
| An app target (a production iOS app, from an earlier evaluation) | 6–7 s warm, ~53 s cold per target | the compile side; verify is ~5 s for all 19 targets |
| A walk in a debug test (what `swift test` and ⌘U run) | 160–208 ns per input | 32 % runtime metadata lookups, 15 % retain/release: SwiftFormal's own unoptimized generic code |

Five facts decide the plan:

1. **The solver is not the bottleneck on real code.** Across SFSIL, 934 solver calls had 152 conflicts in total;
   874 of them had a goal cone of at most 2 clauses (the claim had already folded to a constant), yet the solver and
   the checker each loaded the whole formula. The cost is in front of the solver: compiling, reading text, re-parsing
   bodies, and encoding circuits nobody reads.
2. **Everything is done twice and thrown away.** Two compiler runs per configuration; each function body re-parsed
   7–15 times per configuration; byte-identical CNFs solved again in the second configuration; nothing kept between
   runs except the toolchain answers and compile commands.
3. **One compile can serve both configurations.** With `-assert-config DisableReplacement` the compiler keeps
   `builtin "assert_configuration"` in the SIL instead of folding it. On `Sources/SwiftFormal` (744 functions) it
   marks every function that differs between Debug and Release (110 marked, 107 differ, the one left differs only in
   per-compile UUIDs). **Measured.**
4. **The hard tail is exponential and structural.** The exact `a*b == b*a` miter needs 29.8 k, 119 k and 490 k
   conflicts at 8, 9 and 10 bits. No solver tuning changes that; normalising the formula (`b*a` → `a*b`) makes it
   trivial, and better multiplier encodings and abstraction shrink the rest.
5. **The Walk engine's cost is generic code in debug builds.** Specialised loops in the user's module walk an input in
   0.7 ns instead of 19 ns (release) and make 2^32-input domains provable in 0.5 s on 14 cores.

**The plan in one paragraph.** First, stop doing work twice: one compile for both configurations, each body parsed
once into a real intermediate representation with integer ids, the solver given only the goal's cone, an exact-formula
memo, and no loop planning for functions without loops (phases A–B). Then make the compile side incremental and
parallel: per-file SIL emission through the driver, a cache of linked modules, no SwiftPM null build, and a verdict
cache keyed by a function's Merkle hash so an edit re-verifies only what it touched (phases C–D). Then the hard tail:
word-level normalisation, better multiplier encodings with certified lemmas, assumption-based incremental solving with
a small checker extension, and deterministic cube splitting (phase E). In parallel, the Walk engine gets specialised,
data-parallel walks and escapes the debug penalty (phase W).

**Projected end state** (each step measured before the next): a large module 12.5 s → 3–4 s; an app target warm run
6–7 s → 1–2 s, and a one-function edit well under a second for everything unchanged; `mulCommutes32`-style claims
110 s → milliseconds; walks 5–26× faster in release and 6.5× in debug, with exhaustive proofs up to 32 input bits.

**Decisions only you can take** are collected in section 9: storing proofs across runs (and whether a cached proof is
re-checked), extending the trusted checker for incremental proofs, freezing `verify` as `@inlinable`, thread-safe
domain closures, and whether an external solver may ever run as an *optional* backend for the hard tail.

---

## 2. Architecture today, briefly

```
SwiftPM build (compile command)                       SFVerifyKit/SwiftPM*.swift
  → swiftc -frontend -emit-sil  ×2 configurations     SFVerifyKit/Compile.swift, FrontendArguments.swift
      (+ each local dependency, compiled from source)  SFVerifyKit/Link.swift
  → SIL text (tens of MB, debug locations on)
  → SILText.prepare: lines, locations, functions        SFVerifyKit/Compile.swift, CompileCollected.swift
  → SILModule(text:): bodies as [String: [String]]      SFSIL/SILParser.swift
  → per function, per use: parseFunction (re-parsed)    SFSIL/SILParser.swift
  → SILEncoder: inline callees, bit-blast builtins     SFSIL/SILEncoder*.swift, SFSemantics/S0.swift, SFBV
  → CNF (Tseitin, AND/XOR structural hashing)          SFBV/CNFBuilder.swift
  → SFSAT CDCL solver, LRAT log, trimmed               SFSAT/Solver.swift
  → SFCheck LRAT checker (trusted, 282 lines)          SFCheck/LRATChecker.swift
  → recheck in the Release configuration               SFVerifyKit/SFVerify.swift, SFSIL/ClosureComparison.swift
```

Module sizes (lines): SFSIL 8,723; SFVerifyKit 6,341; SwiftFormal 1,539; SFLLVM 1,317; SFGenKit 1,149;
SwiftFormalTesting 1,003; SFSAT 891; SFProve 804; SFSemantics 675; SwiftFormalMacros 510; SFBV 338; SFCheck 333.

Key data structures:

- **SIL**: text all the way to `parseFunction`. Bodies are `[String: [String]]` (one heap `String` per line); a parsed
  `SILFunction` has `String` SSA names and `String` block ids; types are re-resolved from text; generics (L7) are
  specialised by substituting text and parsing again.
- **Encoder**: `env: [String: Value]` per function; callees inlined by re-parsing them at every call site, up to 8
  deep; block merges as chains of `select`.
- **CNF**: `[[Int32]]` (one allocation per clause); AND/XOR gates hashed on literal pairs; literal 1 is the constant
  true, so constants fold per gate; `mux` costs 3 variables and 9 clauses per bit.
- **Solver**: one flat clause arena (`ContiguousArray<Int32>`, 3-word headers), two-watched literals with blockers and
  tagged binary watches, VSIDS on a binary heap, phase saving, first-UIP with recursive minimisation, Glucose-style
  restarts (full backtrack), LBD-based reduction (effectively two tiers), level-0 compaction. No preprocessing, no
  inprocessing, no assumptions, no incremental use.
- **Proofs**: hint chains logged per learned clause, trimmed backwards to what the refutation uses; converted to
  `LRATLog.Step` and copied once more into `LRATProof`. The checker keeps every clause in `[Int: [Int32]]`, inserts
  all original clauses up front, and follows hints (linear in hints).
- **Walk**: `verify` is generic and not `@inlinable`, so it runs unspecialised in the user's module; each input goes
  through the domain's closure chain (`product`: one division and one modulo per level), the user's closure, and an
  array of observer closures. `parallelism:` produces inputs and folds observers on the calling thread.

Bit-blasting sizes (clauses, both operands free), **measured**:

| op | 8 | 16 | 32 | 64 |
|---|---:|---:|---:|---:|
| add | 126 | 262 | 534 | 1,078 |
| `ult` | 129 | 265 | 537 | 1,081 |
| eq | 53 | 109 | 221 | 445 |
| select | 72 | 144 | 288 | 576 |
| mul (wrapping) | 514 | 2,298 | 9,706 | 39,882 |
| signed mul overflow flag | 2,086 | 8,894 | 36,718 | 149,198 |
| udiv | 1,629 | 6,589 | 26,493 | 106,237 |
| sdiv | 2,105 | 7,577 | 28,505 | 110,297 |
| shl by a variable | 174 | 486 | 1,254 | 3,078 |

---

## 3. Findings, layer by layer

### 3.1 Compiling to SIL

- **Type checking dominates a compile.** On the 8,192-function module: type check only 3.0 s, `-emit-sil` with
  debug info 4.3 s, without `-g` 4.0 s, raw SILGen 3.6 s, binary SIB 4.1 s. Printing text is ~20 % of a compile.
  **Measured.** A binary format would save little, and there is no SIB reader in the toolchain (`sil-opt` is not
  shipped).
- **The second configuration repeats everything**: type checking, SILGen, printing, reading, linking every dependency
  again. With both configurations the 8,192-function run takes 13.2 s, 92 s CPU, 932 G instructions and 792 MB; with
  one, 9.8 s, 46 s, 670 G and 493 MB. **Measured.** `-assert-config DisableReplacement` (finding 3 above) makes one
  compile enough.
- **Linked dependencies are printed with debug info nobody reads**: `Link.swift` keeps only the cleaned text, and
  locations are only looked up in the scanned module. Without `-g -sil-print-debuginfo`, SIL text shrinks by two
  thirds with identical bodies. **Measured.**
- **One frontend process, one thread.** The driver can write SIL per source file during a normal parallel compile
  (`swiftc -c -j N -sil-output-dir`); on the 8,192-function module split into 14 files, 1.3–2.3 s instead of 5.2–6.1 s,
  9,656 of 9,656 bodies identical. **Measured.** This is also the doorway to incremental compiles: the driver already
  knows which files changed and which depend on them.
- **SwiftPM null builds cost ~2.3 s per invocation** even when nothing changed. **Measured.**

### 3.2 Reading SIL

- Everything up to `parseFunction` is text, and nothing parsed is kept: `SILModule.function` has 32 call sites, and
  one function is parsed 7–15 times per configuration — by verify, the loop planner, spec checks, the encoder at every
  call site (callees again per call site and depth), `honest`, `moreTraps` (up to 4 extra encodes), modular
  verification, and both sides of the closure comparison. In a sampled run, `SILModule.function` was the largest
  inclusive frame (~45 % of verify CPU); the top of the stack is `String` building, `malloc`, `Dictionary.find`,
  `Hasher` and string comparison. **Measured.**
- **`LoopPlan` runs a full scratch encode of every function**, callees included, to discover that it has no loop
  headers (`SILVerify.swift` `LoopPlan.init`, called from `Verify.swift` for every function). ~17 % of verify CPU.
  **Measured** (profile share); the fix is one guard.
- **`@opened("UUID")` names change on every compile.** Today that only causes extra rechecks; it would defeat any
  content-addressed cache.

### 3.3 Encoding and bit-blasting

- **The encoder, not gate building, is the cost**: SFSIL's 1.77 M clauses at ~51 ns each are ~0.1 s of 3.8 s encode
  CPU; the rest is the front end (parsing, `String` environments). **Measured / inferred.**
- **Most of every formula is dead**: 87.6 % of SFSIL's clauses, 99.4 % on generated kernels, 75 % on
  `mulCommutes32` lie outside the cone of the negated goal. Handing the solver only the cone left every conflict count
  unchanged on Metrics and the multiplier miters and cut solve time 7–35 %; a trivially folded claim drops to
  microseconds. **Measured** (prototype in a scratch copy).
- **Circuits are built eagerly**, including overflow flags and results that no claim reads (signed multiply overflow
  is 3.8× a wrapping multiply at 32 bits).
- **No word-level normalisation.** `a &* b` and `b &* a` become two different multipliers, which is why
  `mulCommutes32` is undecided. **Measured.**
- **Narrowing exists for sign extension only**; zero-extended operands (`UInt16(price) * …`) are multiplied at full
  width.
- **An ITE gate was prototyped**: it passes an exhaustive mux test but changes conflicts by −21 % to +15 %, and its
  first version reported a **false `contractFails`** that neither the checker nor a constant replay through the same
  encoder caught — only golden and native verdicts did. Every pre-CNF rewrite is trusted code and needs exhaustive
  tests. **Measured.**

### 3.4 The SAT solver and proofs

- **Solving is small on real code** (SFSIL: encode 3.80 s, solve 0.34 s, check 0.13 s CPU). **Measured.**
- **Checking is 19–28 % of solving on mid-size kernels and 8–12 % on hard miters**; the checker loads every original
  clause before checking (the round-1 idea E5 — index originals by id — was measured at −32 to −43 % and never
  landed). **Measured.**
- **The hard tail is exponential** (×4 conflicts per extra multiplier bit). Literature: CDCL quality matters by an
  order of magnitude on long instances (Kani: MiniSat 1004 s vs Kissat 63 s on s2n-quic), but SwiftFormal's queries are
  mostly tiny UNSAT formulas where inprocessing and modern heuristics give 1.2–2× at best (prototype of BVE +
  subsumption: −30 to −45 % on hard instances, regressions on small ones). **Measured / literature.**
- **The multiplication abstraction in `SFProve/Refine.swift` adds lemma clauses as axioms** that the checker accepts
  without proof (the file says so; `docs/TRUST.md` does not). It is used by `Prove`, not by Scan. A **trust gap** to
  close before Scan uses refinement.

### 3.5 Verification strategy

- **The second configuration re-solves identical formulas.** All six Metrics kernels give byte-identical CNFs in both
  configurations, and the closure comparison still marks them changed; `mulCommutes32` spends its budget twice. In
  SFSIL the second configuration adds 464 solver calls but only 11 new distinct CNFs. `recheck` includes `undecided`
  functions, so a function that ran out of budget spends a full second budget. **Measured.** That set is right: a
  Debug `undecided` can still be a Release-only `mayTrap`, so `undecided` must stay in it; the waste goes away with an
  exact-formula memo (S3) or one compile (C1), not by dropping it.
- **Nothing is incremental**: `moreTraps`, unwind deepening (k = 0…8), the 2-induction base and step, and the
  refinement loop each build a fresh encoder and solver.
- **Modular verification (H4)** already uses callees' contracts; the literature (Kani) reports "hours to seconds" from
  contracts on loop-heavy callees.
- **No cheap pre-filter.** Interval reasoning that discharges most overflow checks before bit-blasting is how ESBMC
  and IKOS scale (IKOS: ~98.7 % of checks proven by abstract interpretation on BioSentinel). **Literature.**

### 3.6 Caching and incrementality

- Kept between runs today: `ToolchainInfoCache`, saved compile commands. Not kept: SIL, parsed modules, verdicts,
  proofs. The proof cache (`ProofCache.swift`, `CachedVerifier.swift`) exists but is not wired, its key covers every
  witness and all module tables (one edit anywhere invalidates everything), and its default directory is the
  temporary directory (forgeable, as the file warns).
- **Literature**: Boogie/Dafny entity checksums with dependency checksums gave >10× in IDE sessions; Kani's harness
  campaign 3.97× from parallelism plus caching; KLEE's independence + counterexample cache cut solver queries 13,717 →
  699 and time 300 → 20 s; CPAchecker's precision reuse 3.7× (≥222× with a complete precision); Infer reports a 70 %
  fix rate for diff-time reports against 0 % for batch.

### 3.7 Walk, macros, sfgen, plugins, CI

- **Per input**: generic release 11.5–19 ns; struct domain 25 ns; debug 160–208 ns; specialised loop in the user's
  module 0.72 ns (5 ns for structs). `@_optimize(speed)` on the library has no effect under `-Onone`; building only
  SwiftFormal with `-O` recovers 6.5×. **Measured.**
- **`verify(parallelism:)` (added in round 2) is 7× slower than serial on cheap functions** (4 M inputs: ~600 ms vs
  ~80 ms) because inputs are produced and observers folded on the calling thread. A prototype where workers produce
  their own inputs from index ranges and report the lowest failing index: 5.9 ms, 13× faster than serial.
  **Measured.**
- **SIMD adds only 15–20 % on top of specialisation**: the win is specialisation. **Measured.**
- **Trap walks** cost one exit test (~70–110 ms) per walk; `fork` is ~1 ms but unsafe in a multithreaded Swift process.
- **sfgen** calls each Rule three times per input; its generated suite is `@MainActor` (serial: 392 Rules in 575 s on
  a production app) and is one file (5-minute first build).
- **Gate plugin**: builds `sfverify` and the engine in the user's configuration (debug: 2.6 s vs 0.5 s per run; a hard
  proof 27 s in release vs >34 min in debug); the release artifact bundle exists but is not wired.
- **CI**: several jobs have no cache; the parallel bundle runner (35.6 → 13 s on the slow lane) is local only.

---

## 4. What other tools teach

Effects marked **[P]** were read in the primary source; **[S]** comes from an abstract, blog or search snippet only and
should be checked against the paper before it drives a decision.

| Tool / work | What it does | Reported effect | Fit for SwiftFormal |
|---|---|---|---|
| CBMC incremental BMC (Schrammel et al., FAC 2017) | One SAT instance, one unwinding at a time | ~10× vs non-incremental [S] | Yes: `--unwind` deepening, 2-induction base/step |
| Kani (ASE 2026; solver blog 2023) | MIR → CBMC; contracts, stubbing, parallel harnesses, caching | contracts: hours → seconds, 3.97× campaign [P]; Kissat 14–16× over MiniSat [S] | Yes: H4 already matches; add result cache and scheduler |
| ESBMC interval analysis (arXiv 2406.15281) | Wrapped intervals injected as assumptions | 203 unique SV-COMP solves [S] | Yes: wrapped intervals model fixed-width ints exactly |
| IKOS, Astrée | Sound abstract interpretation | ~98.7 % of checks proven (IKOS, BioSentinel) [S] | Yes as a pre-filter (trusted: needs its own soundness story) |
| Boogie/Dafny caching (CAV 2015) | Entity + dependency checksums | >10× in IDE sessions [S] | Yes: template for the verdict key |
| Prusti/ViperServer, Verus | Daemon, per-function queries, small queries | Verus 3–61× [S] | Partly: daemon after on-disk caches |
| KLEE (OSDI 2008), Green, GreenTrie | Independence (cone), counterexample cache, canonical keys | 15× wall, 28× solver [P] | Yes: cone + exact-CNF memo |
| CPAchecker precision reuse (FSE 2013) | Reuse abstraction precision across revisions | 3.7×, ≥222× [S] | Yes: reuse found invariants / unwind depth |
| FunFrog / eVolCheck | Interpolant summaries from UNSAT proofs | not quantified | Later: LRAT gives the resolution proofs |
| CaDiCaL 2.0/3.0, Kissat | Inprocessing, congruence closure, sweeping, LRAT | LRAT whole flow +30 % over solving [S] | Partly: budgeted level-0 preprocessing; tail only |
| Pollitt/Fleury/Biere SAT 2023; Schreiber SAT 2024 | Direct LRAT; on-the-fly checking | checking ≈ 1/9 of solving [S] | Yes: chain dedup, overlap checking |
| LIDRUP (Fazekas et al., LPAR 2024) | Proofs for incremental solving under assumptions | hints make checking cheap [S] | Yes, if the checker is extended |
| Bitwuzla abstraction (CAV 2024) | Abstract mul/div ≥ 32 bits, refine with lemmas | 12–90× on arithmetic sets; **33 % slower on QF_BV** [S] | Behind a benchmark gate only |
| Multiplier encodings (PoS 2026) | comba-cs, Booth radix-4, proof-guided choice | up to 64× [S] | Yes: SwiftFormal owns its bit-blaster |
| Lean `bv_decide`, CoqQFBV | Verified bit-blasting + external solver + verified LRAT checker | 88.7 % of QF_BV certified (CoqQFBV) [S] | Precedent for "fast untrusted solver + own checker" |
| SymCC (USENIX Sec 2020) | Compile instead of interpret | 12× over KLEE [S] | Yes for Walk: generate specialised walk code |
| Infer (CACM 2019) | Compositional summaries, diff-time reporting | 70 % vs 0 % fix rate [S] | Yes as a product rule: report the diff |
| Swift-specific | No published SIL-level verifier found (SMACK has basic Swift via LLVM; SWAN analyses SIL) | — | SwiftFormal's SIL layer appears novel |

---

## 5. The opportunities

Each: what, why, expected gain, effort (S/M/L), soundness and trust impact, prerequisites. Ids are used in the plan.

### Compile side

**C1. One compile for both configurations.** Compile once with `-assert-config DisableReplacement`; the encoder
reads `builtin "assert_configuration"` as a value; each function whose closure contains it is encoded once and solved
twice, with a unit clause fixing Debug (0) or Release (1); every other function is solved once. Removes `recheck`, the
closure comparison and the second compile of every dependency.
*Gain*: an **upper bound** of −26 % wall, −50 % CPU, −38 % memory on the 8,192-function module (measured by running
one configuration alone; C1 still solves twice for functions that contain the builtin, and DisableReplacement SIL is
~15 % larger); `--build` halves dependency compiles. *Effort*: M. *Soundness*: better than today (no reliance on closure-text
equality), but the configuration's semantics now come from one builtin: gate it with an oracle-lane test that, per
function, the DisableReplacement SIL with the builtin fixed to 0 (1) is equivalent to the Debug (Release) SIL
(`SILVerifier.proveEquivalent` exists), over the zoo, examples and the stdlib-heavy corpus. Two solves with unit
clauses keep every proof a plain refutation; `SFCheck` is untouched. Bump `SILFrontendVersion.semantics`.

**C2. No debug info for linked dependencies.** Drop `-g -sil-print-debuginfo` and the `prepare` pass for imported
modules. *Gain*: dependency SIL −66 %. *Effort*: S. *Soundness*: none (identical bodies, measured).

**C3. Per-file SIL emission through the driver.** Run Scan's compile as `swiftc -c -j N -sil-output-dir …` with its
own output-file map under `.build/swiftformal/`, then merge with `SILModule.link`. *Gain*: compile wall 3–4× on
multi-file targets (measured on a split module); real apps are compile-bound. *Effort*: M. *Soundness*: check per run
that every defined symbol is present once. *Prerequisites*: C1 (one flag set), R3 (UUIDs).

**C4. Cache linked modules across runs.** A parsed dependency module on disk, keyed by its filtered compile command,
the content hash of each source, the compiler identity and the configuration mode. *Gain*: a warm `--build` skips N
dependency compiles. *Effort*: M. *Soundness*: fail closed on any missing key input.

**C5. Skip SwiftPM's null build.** When manifest, `Package.resolved`, toolchain and source hashes are unchanged since
the saved plan, reuse it. *Gain*: ~2.3 s per warm run. *Effort*: M. *Soundness*: fall back to `swift build` on any
doubt.

**C6. Incremental SIL.** C3 with `-incremental`: the driver re-emits SIL only for changed files and their dependents;
a per-file parse cache keyed by SIL content. *Gain*: app warm run 6–7 s → 1–2 s (projected). *Effort*: L. *Soundness*:
trusts the driver's dependency tracking, as the developer's own build does; keep `--clean`.

### Reading SIL and the IR

**R1. Parse each body once into an immutable IR.** A per-module, lazily filled, thread-safe cache of
`Result<FunctionIR, SILError>`; symbols interned to `Int32`; SSA values numbered densely; blocks as indices; types
resolved once into a module type table; the encoder's environment an array; CFG, loop plan, callee list and a Merkle
hash computed once per function; L7 generic specialisation as substitution on the IR, keyed by (symbol, substitutions).
*Gain*: most of the ~45 % parse share, much of the encoder's `String` work, and memory. *Effort*: M for "cache the
parsed function", L for the full IR. *Soundness*: neutral if the IR is a pure function of the text (golden JSON and
oracle lanes gate it). **Trap**: since round 3, `SILModule.tablesText` reflects every stored property of `SILModule`
into proof-cache keys, so a parse cache stored there would leak into keys: keep the cache outside `SILModule`'s stored
fields (or exclude it by label, as `bodies` and `headers` are), and start a fresh one in `replacingBody`.
*Prerequisite for*: V1, S4, S5.

**R2. No loop planning without loops.** Check `CFG(function).headers.isEmpty` before `LoopPlan`. *Gain*: ~−17 % of
verify CPU. *Effort*: S. *Soundness*: none.

**R3. Normalise `@opened("…")` UUIDs** in order of first appearance per function. *Gain*: no spurious rechecks; a
prerequisite for any cache. *Effort*: S. *Soundness*: none.

### Encoding and SAT

**S1. Give the solver only the goal's cone.** Record each clause's owning gate in `CNFBuilder`; at the hand-off,
load the cone with its original clause ids; extend models to all variables by evaluating gates forward and keep the
full `isSatisfied` check. Do not short-circuit a constant-true goal to `proved` — keep every `unsat` checked (with S2,
checking a trivial proof costs microseconds). *Gain*: trivial claims ~30× cheaper to solve; hard ones −7 to −35 %
(measured). *Effort*: S/M. *Soundness*: the solver is untrusted; the checker still checks against the full formula.

**S2. Checker reads original clauses by id, on demand** (round-1 E5 plus lazy loading). *Gain*: checking becomes
O(proof); −32 to −43 % measured in round 1. *Effort*: S. *Trust*: trusted change (~+10–15 lines against the 282-line
ratchet); needs the rejection tests and fuzzing.

**S3. Exact-formula memo within a run.** Key by SHA-256 of the CNF plus full equality; reuse a checked verdict for an
identical formula; re-check models. *Gain*: removes second-configuration duplicates and the double budget of
`undecided` functions (`mulCommutes32`: −50 %). *Effort*: S. *Soundness*: none beyond hash plus equality. Becomes
mostly redundant after C1.

**S4. Word-level normalisation before bit-blasting**: canonical operand order for commutative operations; unsigned
narrowing for zero-extended operands; constant division by multiplication; the interval pre-pass the design spec
promised. *Gain*: `mulCommutes32` 300 k conflicts → 0; narrower multipliers wherever operands are widened.
*Effort*: S–M each. *Trust*: all trusted encoder code; exhaustive tests up to 12 bits, golden and native verdicts (the
ITE lesson above).

**S5. Encode only what the goal reads.** Trap conditions first; results and overflow flags built lazily when a claim
reads them. *Gain*: dead-logic CPU (~1.1 of 3.2 s on generated kernels). *Effort*: M/L. *Trust*: trusted encoder.
*Prerequisite*: R1.

**S6. Incremental solving where no proof is needed.** `moreTraps` keeps the solver and adds blocking clauses; unwind
deepening k = 0…8 on one solver; the refinement loop; early exit when a trap site's condition is constant false.
*Gain*: one encode per function instead of up to 6. *Effort*: M. *Trust*: none (models are re-checked by evaluation).

**S7. Proofs under assumptions** (LIDRUP-style): encode a function's loop segment once, guard each obligation (INIT,
STEP, EXIT, ENTRY) and the 2-induction step with activation literals; each sub-proof derives the clause of negated
assumptions. *Gain*: shared encoding and learned clauses across obligations (CBMC reports ~10× for incremental BMC).
*Effort*: M/L. *Trust*: a small, well-defined checker extension — **your decision** (section 9).

**S8. Multiplier and divider encodings.** Choose per problem among shift-add, carry-save Comba and Booth radix-4;
certify each encoding once per width (8/16/32/64) by an LRAT-checked miter against the reference circuit; certify the
`Refine` lemma families the same way so they stop being axioms. *Gain*: up to 64× on multiplication (literature).
*Effort*: M. *Trust*: removes a trust gap rather than adding one.

**S9. Budgeted level-0 preprocessing in the solver** (subsumption, bounded variable elimination, equivalent-literal
substitution, vivification of tier-1/2 learned clauses), scheduled by an effort budget, logged as LRAT steps.
*Gain*: 1.2–2× on the hard tail; must not slow tiny formulas. *Effort*: M. *Trust*: none.

**S10. Deterministic cube splitting for the hard tail.** Split on high operand bits (which also enables narrowing),
solve each cube with a deterministic budget on its own core, combine with RUP steps. *Gain*: near-linear in cores on
hard claims (projected). *Effort*: M. *Trust*: none (the untrusted side renumbers ids).

**S11. SAT sweeping (FRAIG) for miters**: `--cross-check llvm`, configuration differences. *Gain*: 10–100× on similar
circuits (literature). *Effort*: M/L. *Trust*: none.

**S12. Proof plumbing**: deduplicate repeated ids in hint chains; one copy instead of `LRATLog` → `LRATProof`; a flat
literal arena for `CNF.clauses` (touches trusted `SFCNF`, low priority).

### Verification strategy and caching

**V1. Verdict cache keyed by a function's Merkle hash and read set.** Key: the function's IR hash plus its callees'
(SCCs for recursion), plus the *read set* the encoder actually consulted (types, witnesses by type and requirement,
globals, summary rows — enforced by making `SILModule`'s storage reachable only through a recording façade), plus the
options and the compiler and semantics fingerprints. Store the whole `FunctionReport`; locations come from the current
compile. *Gain*: an edit re-verifies only what it touched (a one-function edit in the 8,192-function module: verify
3.6 s → under 0.5 s, projected); the Build Gate re-spends no budgets. *Effort*: L. *Trust*: **your decision**: a cached
`proved` either skips `SFCheck` (TRUST.md changes) or keeps the trimmed LRAT proof and re-checks it on a hit (disk, but
trust unchanged). Cache directory inside `.build/swiftformal/`, never the temporary directory.
*Prerequisites*: R1, R3, C1.

**V2. Interval pre-pass**: wrapped-interval analysis over the IR that discharges `cond_fail`s before bit-blasting and
turns surviving ranges into assumptions. *Gain*: literature suggests most overflow checks; here, mostly encoder and
solver work saved on easy functions. *Effort*: M. *Trust*: trusted (a new analysis); or use it only to *order* and
*prioritise*, never to discharge, until it has its own oracle tests.

**V3. Reuse what a previous run learned**: the k or invariant 2-induction found, the unwind depth that sufficed,
the configuration of the solver that answered — stored with the verdict, tried first after an edit (CPAchecker's
precision reuse). *Effort*: S once V1 exists.

**V4. Scheduling**: order functions by expected cost (closure size, last run's time) so the longest start first;
run loop obligations and unwind depths in parallel. *Gain*: tail latency. *Effort*: S.

**V5. A warm daemon** (keep parsed modules, the cache index and solver state in memory) — **deferred**: the compiler
has no resident mode, build plugins are sandboxed, and C4/C6/V1 keep most of it on disk at similar cost. Measure after
V1.

### Walk

**W1. Specialised walks generated in the user's module.** `@Verify` (and a `#walk` / `Prove` fast path) recognise
domain syntax (`.int`, `.allCases`, `.bool`, `product`, `@Finite`) and emit nested loops in the domain's enumeration
order with the function and checks inlined; anything else falls back to `verifyContracts`. *Gain*: 19 → 0.7 ns per
input (26×) in release; 2^32-input domains provable in ~0.5 s on 14 cores. *Effort*: M/L. *Risk*: additive API; the
first counterexample must equal the generic walk's (nested loops = product order); sampled walks keep generic draws.

**W2. Data-parallel walks.** Workers take index ranges and build their own inputs; stateless properties run in the
worker; the report takes, per property, the lowest failing index; stateful observers keep the ordered fold. *Gain*: 13×
over serial on cheap functions (measured), against today's 7× loss. *Effort*: M. *Decision*: requires thread-safe
domain closures, which `parallelism:` does not require today.

**W3. Escape the debug penalty.** Document and support a walk test target built `-O` (needs `@inlinable verify` or
W1); `swiftformal check --walks-release` in its own scratch path. *Gain*: up to 6.5×. *Effort*: S. *Decision*:
`@inlinable` freezes internals into the API.

**W4. Wire in the release `sfverify` artifact bundle for the plugins.** *Gain*: gate 2.6 → 0.5 s; hard proofs
>34 min → 27 s; no engine build on a user's first build. *Effort*: S/M.

**W5. Scan undecided → exhaustive walk** for functions with ≤ ~32 input bits, in both configurations, through
`Playback`'s generated tests. *Gain*: `undecided` → proved in under a second. *Effort*: L. *Decision*: how to label
"proved by walking" in Scan reports.

**W6. sfgen**: fuse the three passes (−33 % calls; re-records `__SFLocks__`), shard the generated file, and drop
`@MainActor` if Rules allow (why it is there is undocumented).

**W7. CI and test infrastructure**: caches on the uncached jobs; the parallel bundle runner as the lane runner; the
no-traits build as its own job.

---

## 6. Plan

Every phase keeps the rule of the earlier rounds: identical reports (timings removed) against the previous build on
the standard inputs (gate, Metrics, GatedPackage, Walk, generated chain and kernel modules, SFSIL on a fixed source),
golden verdicts, solver metrics (re-recorded only where a change is meant to change search), all test lanes. Each step
is measured before the next is started; projected gains are not promises.

### Phase 0 — a benchmark the plan can be measured on (days)

0. A generated, reproducible **app-scale package** (several targets, many files each, local dependencies between
   them, generics, loops, a few multiplications) next to the existing inputs, with warm, cold and one-file-edit
   timings recorded in `Scripts/baseline/`. Phases C and D are meant for apps, and every standard input today is
   either one file or tiny. Plus a **profiling recipe that works**: `sample` on a release `sfverify` returned empty
   call graphs here several times (it attaches ~4.5 s late); use the scaling harness, `xctrace`, or a release build
   with timers behind an environment variable, and write the recipe into `docs/PERFORMANCE.md`.

### Phase A — stop the obvious double work (days; no trust change)

1. **R2** loops only when there are loop headers.
2. **C2** no debug info for dependencies.
3. **R3** normalise `@opened` UUIDs.
4. **S1** solver gets the goal's cone.
5. **S3** exact-formula memo (also stops `undecided` functions spending a second budget).
6. **V4** longest-first scheduling.
7. **R1-lite** cache the parsed `SILFunction` per module.

Expected (projected): large-module verify CPU −40 to −50 %; `Examples/Metrics` 111 s → ~55 s.

### Phase B — one compile, and the trusted checker's fast path (1–2 weeks)

8. Oracle gate for DisableReplacement equivalence, then **C1** (remove `recheck` and the closure comparison).
9. **S2** checker reads originals by id (trusted; review as a soundness change).

Expected: the 8,192-function module ~13 s → ~5–6 s with A.

### Phase C — the intermediate representation (2–4 weeks)

10. **R1** full IR (interned ids, type table, IR-level generic specialisation, stored CFG / loop plan / Merkle hash).
11. **S5** goal-directed, lazy encoding on the IR.
12. **S6** incremental solving for `moreTraps`, unwind and refinement.

### Phase D — incremental and parallel compile side, verdict cache (3–5 weeks; decisions first)

13. **C3** per-file SIL emission; **C4** dependency module cache; **C5** skip null builds; measure on an app after each.
14. **V1** verdict cache with Merkle keys and read sets (after your decision on stored proofs); **V3** reuse.
15. **C6** incremental SIL.

Expected: app target warm 6–7 s → 1–2 s; a one-function edit re-verifies one function.

### Phase E — the hard tail (ongoing)

16. **S4** commutative normalisation and unsigned narrowing first (retires the `mulCommutes32` sentinel), then the
    interval pre-pass **V2** (first as a prioritiser).
17. **S8** multiplier encodings and certified lemmas; then refinement in Scan with an exact/refining portfolio.
18. **S7** proofs under assumptions (after your decision on the checker extension).
19. **S9** budgeted preprocessing; **S10** deterministic cubes; **S11** sweeping for cross-check.

### Phase W — Walk (in parallel with B–D)

20. **W4** artifact bundle, **W3** debug escape, **W7** CI (days).
21. **W2** data-parallel walks (after the closure decision), then `Parallelism.auto`.
22. **W1** specialised walks from `@Verify`; then **W5** Scan undecided → walk.
23. **W6** sfgen (after the lock and actor decisions).

Dependencies: R3 before any cache; C1 before C3/C6; R1 before S5, V1 and S7; S2 before S7; W1 before W5.

---

## 7. Trust and soundness

What changes the trusted computing base, and how each is kept honest:

| Change | Trusted? | Guard |
|---|---|---|
| C1 one compile | The reading of one compiler builtin | Oracle equivalence per function against Debug and Release SIL; semantics version bump |
| R1 IR | The SIL reader, as today | Golden JSON, oracle lanes, fuzz seeds; IR must be a pure function of the text |
| S1 cone, S3 memo, S6, S9–S11 | No (untrusted side) | Every `unsat` still checked against the full formula |
| S2 checker by id | **Yes** (SFCheck) | Rejection tests, fuzzing, ratchet note (+10–15 lines) |
| S4, S5, S8 encoder rewrites | **Yes** (encoder) | Exhaustive tests to 12 bits, golden and native verdicts; per-width LRAT-checked miters for encodings and lemmas |
| S7 proofs under assumptions | **Yes** (checker extension) | Your decision; LIDRUP-style, small and specified |
| V1 verdict cache | Depends on your decision | Re-check stored LRAT on a hit (trust unchanged) or trust at rest (TRUST.md change); private directory; models always replayed |
| V2 intervals | **Yes** if it discharges checks | Start as a prioritiser only |
| External solver backend | No (if its LRAT goes through SFCheck) | Your design decision says no; see 9 |

Two existing gaps to fix regardless of performance work: the `Refine` lemma clauses are axioms the checker does not
prove (document in TRUST.md now; certify per width with S8), and the unwired proof cache defaults to a forgeable
directory.

---

## 8. Not recommended, and why

- **Binary SIL (SIB), libSIL or SwiftCompilerSources as the reader**: printing is ~20 % of a compile; no SIB reader
  ships; it would replace the oracle-tested text reader with compiler-version-bound C++.
- **`-sil-print-function` filters**: Scan cannot know a closure before reading the module.
- **SIMD walks**: 15–20 % over specialisation.
- **Portfolio or cube-and-conquer for the typical query**: they are tiny; only the tail benefits (S10 covers it).
- **Int-blasting, algebraic multiplier methods, bounded variable addition, Kissat as a backend** (Kissat has no
  incremental API and no LRAT).
- **A daemon before on-disk caches** (V5).
- **Taking SIL from the developer's own `swift build`** (`-Xswiftc -sil-output-dir`): one configuration only, and it
  makes Scan and plain builds rebuild each other's products.
- **`fork`-based trap walks**: risky in a multithreaded Swift process; only with a watchdog design.

---

## 9. Decisions for you

1. **Stored proofs (V1).** Re-check the stored LRAT on every cache hit (trust unchanged, disk cost) or trust a stored
   verdict at rest (faster, TRUST.md changes)? Recommendation: re-check.
2. **Checker extension for proofs under assumptions (S7).** A small, specified change to `SFCheck`. Recommendation:
   yes, after S2, with its own rejection tests.
3. **External solver.** The design says no external solver in the verify path. An *optional* CaDiCaL backend for
   obligations over a time threshold, with its LRAT checked by `SFCheck`, keeps trust unchanged and has precedents (Lean
   `bv_decide`, CoqQFBV) — but it does not touch the dominant costs, and multiplier hardness is exponential for every
   solver. Recommendation: keep the decision; revisit only if S4/S8/S10 leave a tail that matters.
4. **`@inlinable verify` (W3)**: freezes internals into the public API. Recommendation: yes, or go straight to W1.
5. **Thread-safe domain closures (W2)**: new opt-in or a guarantee change.
6. **sfgen**: re-record locks for pass fusion; why the generated suite is `@MainActor`.
7. **"Proved by walking" (W5)**: how Scan reports label it.

---

## 10. Sources

Verification tools and techniques:
- Schrammel et al., "Incremental Bounded Model Checking for Embedded Software", FAC 29(5) 2017 —
  https://arxiv.org/pdf/1409.5872
- Delmas et al., "Kani: A Model Checker for Rust", ASE 2026 — https://arxiv.org/abs/2607.01504; Kani solver blog —
  https://model-checking.github.io/kani-verifier-blog/2023/08/03/turbocharging-rust-code-verification.html
- Menezes et al., "Interval Analysis in Industrial-Scale BMC Software Verifiers", arXiv 2406.15281
- Leino & Wüstholz, "Fine-Grained Caching of Verification Results", CAV 2015 —
  https://www.microsoft.com/en-us/research/wp-content/uploads/2016/12/krml245.pdf
- Lattuada et al., "Verus: A Practical Foundation for Systems Verification", SOSP 2024
- Cadar, Dunbar, Engler, "KLEE", OSDI 2008 — https://llvm.org/pubs/2008-12-OSDI-KLEE.pdf
- Visser, Geldenhuys, Dwyer, "Green", FSE 2012; Jia, Ghezzi, Ying, "GreenTrie", ISSTA 2015 — arXiv 1501.07174
- Beyer et al., "Precision Reuse for Efficient Regression Verification", FSE 2013 — arXiv 1305.6915
- Distefano et al., "Scaling Static Analyses at Facebook", CACM 62(8) 2019
- IKOS tutorial (NASA) — https://ntrs.nasa.gov/api/citations/20220007431/downloads/SWS_TC3_IKOS_Tutorial.pdf
- Poeplau & Francillon, "SymCC", USENIX Security 2020
- Garzella et al., "Leveraging Compiler IR for Multi- and Cross-Language Verification" (SMACK, Swift), VMCAI 2020

SAT, proofs, bit-vectors:
- Biere et al., "CaDiCaL 2.0", CAV 2024; Pollitt et al., "CaDiCaL 3.0", SAT 2026 (LIPIcs 377)
- Pollitt, Fleury, Biere, "Faster LRAT Checking than Solving with CaDiCaL", SAT 2023 (LIPIcs 271:21)
- Schreiber, "Trusted Scalable SAT Solving with On-The-Fly LRAT Checking", SAT 2024
- Fazekas, Pollitt, Fleury, Biere, "Certifying Incremental SAT Solving", LPAR 2024
- Fazekas, Biere, Scholl, "Incremental Inprocessing in SAT Solving", SAT 2019
- Baek, Carneiro, Heule, "A Flexible Proof Format for SAT Solver-Elaborator Communication" (FRAT), arXiv 2109.09665
- Biere, Fazekas, Fleury, Froleyks, "Clausal Congruence Closure", SAT 2024; "Clausal Equivalence Sweeping", FMCAD 2024
- Pollitt et al., "Revisiting Clause Vivification", PoS 2025
- Niemetz & Preiner, "Bitwuzla", CAV 2023; Niemetz, Preiner, Zohar, "Scalable Bit-Blasting with Abstractions", CAV 2024
- Biere et al., "Proof-Guided SAT Encoding Selection for Bit-Vector Multiplication", PoS 2026 (CEUR Vol-4289)
- Böving et al., "bv_decide" (Lean), OOPSLA 2025; CoqQFBV, CAV 2021
- Mishchenko et al., FRAIGs (2005); SAT sweeping, ICCAD 2006
- Eén & Sörensson, "Temporal Induction by Incremental SAT Solving", 2003
- Schreiber & Sanders, "MallobSat", JAIR 80 2024

Numbers taken from abstracts or snippets only (not checked against the full paper): Verus 3–61×, Schrammel ~10×,
Kani solver blog figures, Boogie caching >10×, ESBMC 203 solves, IKOS 98.7 %, Infer 70 %/0 %.
