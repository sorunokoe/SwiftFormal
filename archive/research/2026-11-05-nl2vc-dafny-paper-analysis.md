# Research note: arXiv 2604.22601 and what it means for SwiftFormal

Date: 5 November 2026. Status: research only. No code or design was approved or changed.

Paper: *From Natural Language to Verified Code: Toward AI Assisted Problem-to-Code
Generation with Dafny-Based Formal Verification* (arXiv:2604.22601v1, University of Alabama).
I read the full HTML text. I could not see its tables (they were images or stripped), so
numbers below come from the prose only.

## 1. What the paper does

- Builds **NL2VC-60**: 60 UVa Online Judge problems, rewritten into short generic requirements
  ("generalization"), each with a hand-written, Dafny-verified solution and uDebug test suites.
  Cost: about 300 person-hours plus 50 hours resolving author disagreements (about 6 hours per problem).
- Evaluates **7 open-weight LLMs** (Gemma 4-31B, GPT-OSS-120B/20B, Qwen3.5-9B, Qwen3-Coder-30B,
  Qwen3.6-35B-A3B, Codestral-22B) on **only 11 randomly chosen problems**, using Dafny 4.11.0.
- Three prompt tiers: **contextless** (NL only), **signature** (NL plus Dafny method signature),
  **self-healing** (feed the verifier's errors back, up to 10 repair attempts).
- Metric: `verify@k` (k = 1, 3, 5), best over 5 temperatures (0.0 to 0.8).
- Manual review of specification strength; uDebug tests as a "functional layer" to catch vacuous specs.

### Headline results (prose only)

| Setting | Result |
|---|---|
| Contextless | 5 of 7 models at 0%. Gemma 4-31B 54.55% (peak), Codestral 27.27% |
| Signature | GPT-OSS-120B 0% to 63.64%. Qwen3.5-9B 72.73% (best) |
| Self-heal from contextless | Gemma 4-31B 90.91%. Others stay near 0% |
| Self-heal from signature | GPT-OSS-120B 81.82%. Gemma stays above 80% |
| Errors | Syntax errors dominate without anchors (over 80% for GPT-OSS-20B). Signatures shift the problem to type and verification errors |

## 2. How much to trust it (read before borrowing numbers)

1. **n = 11.** Every percentage is k/11. 90.91% is 10/11, 81.82% is 9/11. A 95% Wilson interval
   for 10/11 is about **62% to 98%**; for 9/11 about 52% to 95%; for 8/11 about 43% to 90%.
   Differences between models are mostly within noise.
2. **Best-of-5-temperatures, chosen after the fact** ("optimal temperature for each model and
   prompt type"). The reported numbers are an optimistic maximum, not an expected rate.
3. **Functional layer is not reported.** `functional@k` is defined, and uDebug is the claimed
   defence against vacuity, but the results discussed are verification rates only. We cannot tell how
   many "verified" answers were vacuous.
4. **Vacuity is handled by tests plus manual review, not by a spec-strength measure.**
   That does not scale and does not prove the spec says what the requirement says.
5. **Contradictions in the setup.** RQ2 says signature plus "functional tests"; the prompt shows only
   a signature. The signature also leaks structure, so RQ2 is partly "spec given", not "spec invented".
6. **Listing 1 looks incomplete as printed.** The loop invariant only bounds `x`; nothing ties `count`
   to the set cardinality in the `ensures`. Either it is simplified for the paper or it would not verify.
7. **Dafny `int` is unbounded.** Proofs about it say nothing about Swift `Int64` overflow traps.
   This matters directly for us (see section 5).
8. **Cost claim** ("several-thousand-fold cost reduction") is not backed by a cost measurement.
9. arXiv v1 preprint, apparently not peer reviewed. I did not find or verify a dataset/code release link.

Treat the paper as a useful *design pattern and failure taxonomy*, not as evidence of a success rate.

## 3. Related work worth knowing (checked via abstracts/snippets, not full reads)

| Work | Why it matters to us |
|---|---|
| **Vericoding benchmark**, arXiv 2509.22908 | 12,504 specs (Dafny 3,029, Verus 2,334, Lean 7,141). Off-the-shelf success: Dafny 82%, Verus 44%, Lean 27%. Adding NL descriptions did not help much. Pure Dafny verification rose from 68% to 96% in a year. Much larger and sturdier than NL2VC-60. |
| **Clover**, arXiv 2310.17807 | Consistency checks among code, docstring, and formal annotation. Up to 87% acceptance of correct cases and no false positives on adversarial ones. This is a direct answer to "is the spec right?". |
| **DafnyPro**, arXiv 2601.05385 | Diff-checker (LLM may not change program logic), pruner (drop unneeded invariants), hint library. 86% on DafnyBench with Claude 3.5 Sonnet (+16 points). Fine-tuned 7B/14B reach 68%/70%. |
| **ATLAS**, arXiv 2512.10173 | Synthesizes 2.7K verified Dafny programs, 19K training examples. Qwen 2.5 7B Coder: 32.4% to 56.9% on DafnyBench. Soundness/completeness checks on specs with an LLM judge. |
| **AlphaVerus**, arXiv 2412.06176 | Tree search over repairs ("Treefinement") beats linear refinement. A critique step filters misaligned specs to stop reward hacking. |
| **Dafny as IR**, arXiv 2501.06283 | Generate verified Dafny, compile to the target language. Alternative architecture to ours (verify in a verifier language, ship the compiled output). |
| **DafnyBench**, arXiv 2406.08467 | Defines "cheating": changed or dropped `requires`/`ensures`, `{:verify false}`, `assume false`. Good anti-cheat checklist. |
| **Verified but Vacuous**, arXiv 2611.05590 (very recent preprint, abstract only) | Splits "verified" into A (verifier accepts), B (proof binds to the spec), C (spec captures the informal requirement). Argues one verified-rate number hides all of this. |
| **Aeneas** (Rust to Lean, ICFP 2022/2024) | Uses Rust ownership to turn borrows into a pure functional model, no heap reasoning. Overflow and panics modeled with a Result monad. Closest architectural cousin to what we are doing. |
| **Viper to Boogie validated translation**, arXiv 2404.03614 | Precedent for generating checkable proofs that a front-end translation is sound. Matches our translation-validation approach. |

One source I found (a "Lean 4 Verification Convergence" report) is vendor-style and unverified.
I did not rely on it.

## 4. Lessons, ranked by value to SwiftFormal

### L1. Report three separate things, not one "verified" (highest value)
The paper's own vacuity problem is what the A/B/C split names. SwiftFormal already separates
**translation validated** from **contract proved** (0.0.4). The missing piece is **C: contract fidelity**.
Concrete gates, all cheap:
- **Satisfiability**: the precondition is not empty and the postcondition is not trivially true.
- **Mutation kill rate**: apply small mutations to the verified implementation (flip a comparison,
  drop a clamp, off by one). A strong contract makes the proof fail for the mutants. Existing `clampedDiscount`
  buggy variants are already the seed of this.
- **Native example agreement**: already done (306 native comparisons).
- **Clover-style consistency**: docstring, contract, and code regenerated from each other and compared.

### L2. Freeze the contract; let AI write only the implementation and hints
DafnyPro's diff-checker and DafnyBench's cheating rules map to: contract is hashed and human-approved;
AI edits that touch it are rejected; `sorry`, new axioms, and "unsupported but accepted" paths already
fail closed in our checker. Keep that and make it a rule for the agent loop, not only the checker.

### L3. The Swift compiler removes the paper's biggest failure class
Syntax errors were over 80% of failures without anchors, caused by Dafny being rare in training data.
In SwiftFormal the AI writes ordinary Swift, which models know well and the compiler checks. What is left
is the small contract vocabulary (`#requires`, `#ensures`, invariants, `decreases`) and the invariant gap.
Keep that vocabulary tiny and Swift-looking.

### L4. Prompt tiers map to our API surface
"Signature prompting" worked best because the signature fixes the shape. For us the signature is the
Swift function plus the contract stub. Ship a tier model:
T0 NL only, T1 Swift signature plus approved contract, T2 plus structured verifier feedback.
Measure each separately.

### L5. The invariant gap is the real bottleneck; design for it
Models produce correct code but weak inductive invariants, and repeat the same insufficient one when
repairing. Mitigations from the literature and this paper:
- Run **bounded checking first** (fast counterexamples) before a full proof attempt.
- **Prune** invariants (DafnyPro) and keep a **small library of loop idioms** (counting, summing, min/max, search).
- **Detect repeated repair attempts** and force diversity; use **tree search** instead of a linear loop.
- Lower temperature for first attempts, higher for repairs (the paper's own tuning result).
- Budget: the paper used 10 repair attempts; make the cap and the cost part of every report.

### L6. Feedback must be structured, not just text
Self-healing worked only when errors were actionable. Our verifier should output machine-readable
diagnostics: stage (compile, unsupported construct, translation, contract, proof), source location,
counterexample inputs when available (Lean already gives these in 0.0.4), and which assumption was
unmet. Expose it as `--json` and later as an MCP tool.

### L7. Measure properly
The paper's weakest part is its statistics. Our benchmark should have 30+ Swift functions,
fixed seeds, fixed temperature per model, `verify@k` with confidence intervals, mutation kill rate
for specs, wall-clock and tokens per solved function. Keep failed runs.

## 5. Swift-specific differences that change the design

| Topic | Dafny paper | SwiftFormal consequence |
|---|---|---|
| Integers | Unbounded `int` | Swift `Int` traps on overflow; `&+` wraps. Proofs must use exact fixed-width semantics. Already done in 0.0.3 to 0.0.6. A Dafny-only route would lose this. |
| Source of truth | Dafny program is the artifact | Real Swift is the artifact. Translation must be validated per program (already our approach). |
| Frontend | Dafny parser | SwiftSyntax macros are syntactic only. Use them to capture contracts, not to get meaning. Semantics come from SIL (compiler-version specific, unstable). |
| Memory | Verifier-managed heap | Swift value types and the exclusivity rule make `inout` and structs easy to model as pure functions (Aeneas-style: forward value plus updated value). Classes, closures, existentials, generics, concurrency: out of scope at first. |
| Test oracle | uDebug community tests | No equivalent. Use native execution as oracle (already built), property tests, and spec mutation. |

## 6. Architecture options (decision still open)

A. **Swift to Dafny, use Dafny.** Fast to start, strong SMT automation, existing LLM benchmarks.
   Costs: new trusted translator, unbounded `int` mismatch, Dafny training-data scarcity returns.
B. **Current path: Swift to SIL to validated IR to Lean.** Strongest trust story, kernel-checked.
   Cost: low automation; loops and arithmetic proofs need work or AI help.
C. **Hybrid (recommended hypothesis, unmeasured):** keep the SIL-to-IR path and Lean certificates, add a
   fast automation tier on the validated IR (bit-vector SMT, or Lean's built-in arithmetic and
   bit-vector tactics) so AI repair loops get quick yes/no and counterexamples, with Lean as the final check.
   This needs a benchmark before it is chosen. Do not assume it is faster.

## 7. Suggested next experiments (small, each answers one question)

1. **Contract-vacuity gate:** mutation-test the existing `clampedDiscount` contract. Question: do weak
   contracts get caught? Cheap and closest to the paper's open flaw.
2. **Frozen-contract repair harness (no model needed first):** scripted "AI" edits that try to change
   the contract, add `sorry`, or return a constant. Question: does the checker reject all cheats?
3. **Loops with invariant and `decreases`:** one `for` loop function. Question: how often is the
   invariant the only missing piece, and does bounded checking give useful counterexamples?
4. **Real model loop:** T0/T1/T2 tiers on 10 to 30 tiny Swift functions. Question: what is the
   `verify@k` with intervals and how much does structured feedback add?
5. **Automation-tier benchmark (option C):** same IR obligations through Lean-only and SMT-first.

Existing roadmap item still comes first: `guard`, early returns, joined branches (README, 0.0.6 next step).

## 8. Open questions for the owner

- Who writes the contract in the intended workflow: human only, AI draft then human approval, or AI only?
  This sets how much weight lesson L1 and L2 carry.
- Is the first user a library author (verifying pure logic) or an app team using AI agents day to day?
- Acceptable wait time per verification inside an AI loop (seconds or minutes)? Today a full run is minutes.

## Sources

- https://arxiv.org/html/2604.22601v1 (full text read)
- https://arxiv.org/abs/2509.22908, https://arxiv.org/abs/2310.17807, https://arxiv.org/abs/2601.05385,
  https://arxiv.org/abs/2512.10173, https://arxiv.org/abs/2412.06176, https://arxiv.org/abs/2501.06283,
  https://arxiv.org/abs/2406.08467, https://arxiv.org/abs/2611.05590 (abstract/snippets only),
  https://arxiv.org/abs/2404.03614
- https://github.com/AeneasVerif/aeneas (overview documentation)
- Swift macros documentation (docs.swift.org) and WWDC23 "Expand on Swift macros"
- Local: `README.md`, `archive/design/plans/2026-11-03-swiftformal-evidence-driven-roadmap.md`
