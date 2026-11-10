# SwiftFormal Open-Source Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SwiftFormal easy to understand, navigate, test, measure and contribute to, so it can be published as an open-source package, with **zero behavior regressions**.

**Architecture:** Keep every engine as it is. Change the *shape around the engines*: one mental model (the Inspector), one vocabulary, a small public surface, a tidy repo, tiered tests with a safety net, deterministic metrics, and contributor docs. Every phase is gated by the safety net from Phase 0.

**Tech Stack:** SwiftPM (tools 6.0, Swift 6.4), Swift Testing, swift-syntax 600..<700, DocC (`swift-docc-plugin`), `swift-format`, SwiftLint (CI only), `swift package diagnose-api-breaking-changes`, GitHub Actions, python3 (small scripts).

**Status:** plan only. Nothing has been changed in the repo except this file. Date: 2026-11-05.

---

## 0. One-page summary (read this first)

| # | Phase | What changes | Risk to behavior |
|---|---|---|---|
| 0 | Safety net | git, baseline, API snapshot, test inventory, golden verdicts | none |
| 1 | Declutter | move experiments/prototype/reports out of the root; 456 MB of build output out of the repo | none (no code) |
| 2 | Mental model | write the Inspector model + glossary; lock the vocabulary | none (docs) |
| 3 | Mechanical structure | split 4 big files, split the 1 giant test target, add layering check | very low (moves only) |
| 3B | Sandbox modularization | one registry of sandboxes (layering, fast loop, real-consumer loop), cards, `Scripts/sandbox.py`, evidence-based carve-outs (`SFToolchain`, `SFProcess`), honest iOS/macOS matrix | very low (moves only; carve-outs one per commit) |
| 4 | Names | fix 3 colliding type names, 1 colliding function name, naming per Swift API guidelines | low (compiler finds every use) |
| 5 | Surface | engine internals become `package`, only the front doors stay `public` | low (compiler + API diff) |
| 6 | API polish | collapse the `prove…` family, lowerCamelCase property factories | low (old names kept, deprecated) |
| 7 | Tests and CI | fast / slow / oracle lanes, skip-with-reason on other compilers, GitHub Actions | none to production code |
| 7B | Quality bar | dogfooding (SwiftFormal verifies itself), soundness zoo, differential + fuzz tests, type-driven tightening, swift-format + SwiftLint, warnings-as-errors, coverage and trusted-code ratchets | low (additive tests and gates; type changes go through the API diff) |
| 8 | Measure | deterministic metrics (conflicts, clauses), stable JSON schema, baseline compare | additive |
| 9 | Documentation | README rewrite, DocC, ARCHITECTURE, TRUST, doc coverage gate | none |
| 10 | Community and release | LICENSE, CONTRIBUTING, templates, CHANGELOG, 0.1.0 checklist | none |

Order matters: **safety net → remove noise → agree on words → move code → rename → narrow → polish → prove it works in CI → document → publish.**

---

## 1. Where the project is today (measured, not guessed)

| Fact | Evidence |
|---|---|
| ~10.9k lines of Swift in 16 targets; 219 tests; builds in ~14 s, **0 warnings** | `swift build` run for this plan |
| Fast tests (everything except `SFTests`) finish in **~10 s** | `swift test --skip SFTests` |
| `SFTests` in debug **did not finish in 13+ minutes** (38 CPU-min); one oracle test alone reports ~220 s | `swift test` run for this plan, stopped by hand |
| Root has **no git repo, no LICENSE, no CONTRIBUTING, no CI, no `.gitignore`, no formatter config** | `ls -a` |
| **~1.0 GB** of build output in `.build`; **456 MB** in `experiments/` (`.build`, `.artifacts`); `prototype/` 43 MB | `du -sh` |
| README is 23 KB and mixes "how to use it" with a changelog of experiments 0.0.3 to 0.0.7; `EXPLAINED.md` (27 KB) and `REPORT.md` (31 KB) sit in the root | `ls`, README |
| Three public types named `Verdict` / `Report` / `Counterexample` exist **in different modules** (`SwiftFormal`, `SFProve`, `SFVerifyKit`); import two modules and the names clash | grep of `public` declarations |
| `prove` means two different things: `SwiftFormalTesting.prove` (walks every input) and `SFProve.prove` (SAT proof) | `Sources/SwiftFormalTesting/Prove.swift`, `Sources/SFProve/Prove.swift` |
| ~740 `public` declarations; roughly 40% have a doc comment (`SFSIL` 190 public, `SFVerifyKit` 111, `SwiftFormal` 99, `SFGenKit` 92). Most are engine internals | grep |
| `SFProve` has four near-identical entry points: `prove`, `proveRefining`, `proveMaybeRefining`, `proveRefiningDetailed` (a "method family" the Swift guidelines say to replace with default arguments) | `Sources/SFProve/Refine.swift` |
| The proof cache and compiler pin live in one 727-line `SFSIL/ProofCache.swift`; other large files: `Solver.swift` 782, `SILParser.swift` 767, `LLVMParser.swift` 646 | `wc -l` |
| Compiler pin: only `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 …)` is accepted by `PinnedCompiler`. A contributor on any other Xcode will see failures | `Sources/SFSIL/ProofCache.swift` |
| The solver reports no statistics (conflicts used, clauses), so performance can only be measured by wall clock | `Sources/SFSAT/Solver.swift` |
| Good already: honest verdicts, fail-closed behavior, independent proof checker, deterministic budgets, a thoughtful `Domain`/`Property` API, doc comments on the core API | read of core sources |

**What this means:** the engineering is strong. The gap is *legibility*: a newcomer cannot tell which of three products they are looking at, which "proved" they are getting, or which of 16 modules to touch.

---

## 2. TRIZ pass: the contradictions and how each is dissolved

(Workflow: triage → IS/IT → AC/TC/PC → vepol → IFR → resources → matrix → concepts → evaluate. Matrix cells were looked up in `matrix.md`, not recalled.)

### Step 0: Triage
Yes, there are real contradictions (below). TRIZ applies.

### Step 1: Inventive situation
*System SwiftFormal checks Swift functions via three engines (walk every input, SAT proof, trap scan), producing the undesirable effects:*
NE1 three engines share names but give different guarantees; NE2 internal engine types are public, so the API looks huge; NE3 research history sits next to the product; NE4 the full test suite is too slow to run before a commit; NE5 speed is only visible as wall-clock noise; NE6 one pinned compiler blocks outside contributors.
**Inventive Task:** keep every engine and guarantee, remove the confusion. Root cause = NE1 (no single mental model); NE2 to NE6 hang off it.

### Step 2: Contradictions

| Level | Statement |
|---|---|
| AC | We need one simple story for newcomers, but we cannot hide that there are several engines. |
| TC-1 | Improve *ease of operation / understanding* (33) → worsens *loss of information* (24) (a single "proved" hides the different guarantees). Matrix R33/W24 → **4 Asymmetry, 10 Preliminary action, 27 Cheap short-living, 22 Harm into benefit** |
| TC-2 | Improve *ease of operation* (33) → worsens *device complexity* (36) (more docs, more layers). R33/W36 → **32 Color changes, 26 Copying, 12 Equipotentiality, 17 Another dimension** |
| TC-3 | Improve *ease of repair/maintenance* (34) → worsens *complexity* (36) (splitting into modules adds structure). R34/W36 → **35 Parameter changes, 1 Segmentation, 13 The other way round, 11 Cushion in advance** |
| TC-4 | Improve *reliability* (27) → worsens *ease of operation* (33) (more safety gates slow contributors). R27/W33 → **27 Cheap short-living, 17 Another dimension, 40 Composite** |
| **PC-1** | The word **"proved"** must be *one word* (so users learn one vocabulary) **and** *carry different evidence* (walked every input vs checked SAT proof) simultaneously. |
| **PC-2** | The **public surface** must be *tiny* (easy to learn) **and** *large* (the engines are tested, reused by the CLI and plugin) simultaneously. |
| **PC-3** | The **test suite** must be *thorough and slow* (exhaustive oracles) **and** *fast* (run on every change) simultaneously. |
| **PC-4** | The **repo** must *hold the research history* (evidence, honesty) **and** *not hold it* (a clean entry point) simultaneously. |
| **PC-5** | The **quality gates** (lint, format, coverage, warnings) must be *strict* (so quality only goes up) **and** *relaxed* (so a first-time contributor is not blocked by 10,000 old findings) simultaneously. |
| **PC-6** | The **verifier's own code** must be *small and trusted* (few lines to audit) **and** *large and capable* (SAT, bit-vectors, SIL parsing) simultaneously. |
| **PC-7** | A **sandbox boundary** must be *tight* (a contributor builds and tests one piece alone, nothing copied) **and** *wide* (engine pieces share `package`-level internals, which only works inside one package) simultaneously. |

**Gate 2 passed:** each PC names one element with two opposite states.

### Step 3: Vepol (at the conflict zone)
S1 = the documentation/API surface, Field = the reader's attention (informational), S2 = the newcomer's mental model. The vepol is **insufficient** (effect too weak: three vocabularies fight) and partly **harmful** (clashing names cause mistakes). Applicable standard classes: 1.1 (improve a weak vepol by adding a mediator/substance), 1.2 (remove harmful effect with a third substance), 2.2 (segment the fields). Used below as **Standard 1.2.1 (add an outside mediator between S1 and S2)** = the Inspector analogy sits between the code and the reader; **Standard 2.2.1 (segment the field)** = split attention by audience.

### Step 4: Ideal final result
- **IFR-1:** *The existing type names and the existing README example explain the whole project by themselves, at no extra cost.*
- **IFR-2:** *The word "proved" at the call site must be identical (one word) and differ (the evidence attached to it) simultaneously.*

**Gate 4 passed:** IFR-1 uses elements already present (the type names `Domain`, `Verdict`, `Report`); IFR-2 states opposite states of one element.

### Step 5: Resources already in the system (VPR)
1. **Substances:** the three honest verdict words (`proved` / `bounded` / `counterexample`) already used everywhere; `docs/research/*` already contains the reasoning; the experiments' `RESULTS.md` files already hold the evidence.
2. **Fields:** the compiler (type errors find every rename); the deterministic solver budget (a stable metric); `swift test list` (a free inventory).
3. **Space:** the root of the repo (only a few slots; everything else can go to `archive/` and `docs/`).
4. **Time:** build and test time already split naturally (10 s fast targets vs the slow `SFTests`).
5. **Functional:** `@testable`-free `package` access (Swift 5.9+) already lets engine modules share internals with tests without `public`; the `Report` in `SFVerifyKit` already carries `seconds`, `status`, `category`; the Build-Gate plugin already is the "occupancy permit".

### Step 6: Resolve (Quick path, then check)
Each principle was checked against the PC. Result: all seven PCs dissolve by **separation**, no compromise.

| PC | Separation | Principles used | Resolution |
|---|---|---|---|
| PC-1 "proved" | **by system level** (one word at the API level, evidence at the report level) | 12 Equipotentiality, 32 Color/marking, 26 Copying (analogy) | Every report prints *how* it was established ("walked 1,001 of 1,001 inputs" / "SAT proof, accepted by the independent LRAT checker"). The three verdict words stay identical in meaning across tools. Colliding *type names* get tier-specific names. |
| PC-2 surface | **in space** (front door vs engine room) | 4 Asymmetry, 1 Segmentation, 7 Nested doll | Products = 5 front doors. Everything else is `package` access: visible to our own tests and CLI, invisible to users. |
| PC-3 tests | **in time** (every change vs nightly/release) | 35 Parameter changes, 1 Segmentation, 10 Preliminary action | Lanes: **fast** (<60 s, each push), **slow** (release-mode SAT/oracle, nightly + before release), **oracle** (spawns the compiler; skipped with a reason when the compiler is not the pinned one). |
| PC-4 repo | **by condition** (kept, but not in the way) | 27 Cheap short-living, 34 Discarding/recovering, 17 Another dimension | Research moves to `archive/` (frozen, linked from the README as "Why this is trustworthy"), heavy build output leaves the repo as a tarball. |
| PC-5 gates | **in time + by condition** (strict for new code, baselined for old code, and the baseline only moves one way) | 35 Parameter changes, 23 Feedback, 10 Preliminary action | **Ratchets** (Phase 7B): every gate stores today's number as a baseline; a change may keep or improve it, never worsen it. New and touched files get the strict rules. Nobody has to fix history to contribute. |
| PC-6 trusted core | **in space** (small trusted kernel, large untrusted search) | 1 Segmentation, 4 Asymmetry, 23 Feedback | Already half-built: `SFCheck` (independent LRAT checker) re-verifies everything the big solver claims. The plan only **locks it in**: a layering rule (the checker imports nothing from the solver) and a size ratchet on the trusted lines. The solver may be as clever as it likes; a wrong answer is caught by the small checker. |
| PC-7 sandbox | **in space** (two different boundaries, drawn in two places) + **by system level** (build graph vs consumer graph) | 1 Segmentation, 17 Another dimension, 7 Nested doll | Compile boundary = **target** (`swift build --target X`, own test target, own card). Access boundary = **the one package** (so `package` access works and the public surface stays tiny). The *build* graph says what to recompile; a separate *consumer* graph (Phase 3B registry) says what to re-test, because a body change can break a consumer without any signature change. No second `Package.swift`, no `public` leakage. (Principles chosen by reasoning about the two graphs, not from a matrix lookup.) |

**Gate 6 passed (Quick path):** exact cells in `matrix.md` were looked up (R33/W24, R33/W36, R34/W36, R27/W33). The recommended principles resolve the PCs as separations, so no escalation to Systematic/ARIZ was needed.

### Step 7: Concepts (ranked)

| # | Concept | Principles | Resources used | Ideality | Altshuller level |
|---|---|---|---|---|---|
| A | **The Inspector**: one analogy where *every existing type name maps to a role* (section 3) | 26 Copying, 12, 24 Mediator | existing names | high, almost free | 3 (new framing, no new machinery) |
| B | **Evidence line**: every report prints its basis in one fixed sentence shape | 32, 12 | existing report fields | high | 2–3 |
| C | **Front doors vs engine room** via `package` access | 4, 1, 7 | Swift's own access control | high | 3 |
| D | **Test lanes by cost** + deterministic metric (conflicts, clauses) instead of wall-clock | 35, 23 Feedback, 10 | solver budget, `swift test list` | high | 3 |
| E | **Archive + safety-net-first** ordering | 27, 34, 10 | git, tarball | high | 2 |
| F | **Ratchets + trusted kernel**: gates only move one way; the checker stays small and independent | 35, 23, 1, 4 | `SFCheck`, `swift format`, SwiftLint baseline | high | 3 |

**Step 8 stopping criterion met:** Concepts A, C, D, F score Level 3 and resolve PC-1/2/3/5/6/7 without adding new external components (only scripts and docs; tools run in CI, not as package dependencies). The plan below implements A–F.

---

## 3. The mental model: "SwiftFormal is a building inspector for your functions"

Say this in one sentence in the README, the DocC landing page, and the first slide of any talk:

> **SwiftFormal inspects your *real* function the way a building inspector inspects a *real* building: it walks every room, and then tells you honestly whether you get a certificate, a spot-check note, or a crack report with the room number.**

| Inspector world | SwiftFormal word | Where it lives |
|---|---|---|
| The building (not the blueprint) | the real compiled function | your code |
| The floor plan: every room | `Domain` | `SwiftFormal` |
| The building code (rules) | `Property`, `Contract` (`#requires`, `#ensures`) | `SwiftFormal`, `SwiftFormalContracts` |
| Inspector walks every room | `verify(...)`: **Walk** (Tier 1) | `SwiftFormal` |
| **Certificate** (all rooms visited) | `proved` | `Verdict` |
| **Spot-check note** (only some rooms) | `bounded` (sample or over budget) | `Verdict` |
| **Crack with a room number** (replayable) | `counterexample` | `Verdict` |
| Too many rooms (2^64): the structural engineer proves it from the plans | **Prove** (Tier 2): SAT solver on bit-vectors | `SFProve` |
| A second, independent engineer must countersign | the independent proof checker (`SFCheck`) | `SFCheck` |
| "Could anything collapse?" scan, no code book needed | **Scan** (`sfverify`): can this function trap? | `SFVerifyKit` |
| "Inspector declines to sign what they cannot inspect" | `unsupported` (fail closed, never guess) | reports |
| Occupancy permit: no permit, no move-in | the **Build Gate** plugin | `SwiftFormalGate` |
| Permit on file, only reused if nothing changed | proof cache | `SFSIL/ProofCache` |
| "Does the code catch a deliberately bad building?" | spec audit (mutants) | `SpecAudit` |
| Photograph of the building as it is today | `lockBehavior` / `expectLocked` | `SwiftFormalTesting` |
| The inspector's stated limits | the **trust ledger**: compiler, the domain you described | `docs/TRUST.md` |

Three tools in the bag, one verdict vocabulary:

| Tool | Question it answers | Verdict words | Evidence line (printed in every report) |
|---|---|---|---|
| **Walk** `verify` | "Does this rule hold for every input I listed?" | proved / bounded / counterexample | `walked 1,001 of 1,001 inputs of the real function` |
| **Prove** `SFProve` | "Does it hold for *all* values of these integer widths?" | proved / counterexample / unknown | `SAT proof, accepted by the independent LRAT checker` |
| **Scan** `sfverify` | "Can this function trap, and does its plain-Swift contract hold?" | safe / mayTrap / contractHolds / contractFails / undecided / unsupported | `read from compiler SIL (swiftc 6.4), proof checked` |

Rule for every doc and error message: **name the tool (Walk, Prove, Scan), then the verdict, then the evidence.**

---

## 4. Target structure

### 4.1 Repository root (after Phase 1)

```
SwiftFormal/
├── Package.swift
├── README.md                  # 1 screen: analogy, 30-second example, 3 tools, install
├── LICENSE
├── CONTRIBUTING.md            CODE_OF_CONDUCT.md   SECURITY.md   CHANGELOG.md
├── .gitignore  .swift-format  .spi.yml  .github/
├── Sources/                   # unchanged module names (see 4.2)
├── Tests/
├── Plugins/SwiftFormalGate/
├── Examples/GatedPackage/     # + Examples/Walk, Examples/Prove (small, runnable)
├── Scripts/                   # check-*.sh / *.py safety-net and CI scripts
│   └── baseline/              # frozen pre-refactor facts
├── docs/
│   ├── MENTAL-MODEL.md  ARCHITECTURE.md  TRUST.md  GLOSSARY.md  PERFORMANCE.md
│   ├── guides/                # how-tos: walk, contracts, prove, scan, gate
│   ├── decisions/             # short ADRs (one page each)
│   └── superpowers/           # existing plans and specs (kept)
└── archive/
    ├── README.md              # "why this is here, what it proved, how to rerun"
    ├── experiments/  prototype/  validation/  tools/
    ├── EXPLAINED.md  REPORT.md  research/
```

### 4.2 Modules: keep names, define roles (no renames of modules, fewer breakages)

| Layer | Modules | Visibility rule |
|---|---|---|
| **Front doors (public, documented, semver-governed)** | `SwiftFormal`, `SwiftFormalContracts`, `SwiftFormalTesting`, `SFProve` (facade only), `SwiftFormalGate` (plugin) | `public`, 100% doc comments (enforced) |
| **Tools (executables)** | `sfverify`, `sfgen` | CLI flags and `--json` schema are the contract |
| **Engine room (internal to the package)** | `SFCNF`, `SFSAT`, `SFCheck`, `SFBV`, `SFSemantics`, `SFSIL`, `SFLLVM`, `SFVerifyKit`, `SFGenKit`, `SwiftFormalMacros` | `package` access; not exposed to users |

Dependency direction (enforced by a script, Task 3.4):
`SFCNF` ← `SFSAT`, `SFCheck`, `SFBV` ← `SFProve`, `SFSemantics` ← `SFSIL` ← `SFLLVM`, `SFVerifyKit` ← `sfverify`. `SwiftFormal` depends on nothing. `SFCheck` must never import `SFSAT` or `SFBV` (the independent-checker rule from the verifier design spec §5).

> **Decision D1 (assumption, autopilot):** `SFVerifyKit` and `SFGenKit` stay *library products* for now because the plugin and tooling use them, but move to `package` access after one release, once nobody outside depends on them. Easy to reverse.

---

## 5. File map: what will be created / modified

| Path | Action | Responsibility |
|---|---|---|
| `.gitignore`, `.swift-format`, `.swiftlint.yml`, `.editorconfig`, `.git-blame-ignore-revs`, `.spi.yml` | create | hygiene, style, lint, Swift Package Index docs |
| `Scripts/baseline/quality.json`, `swiftlint-baseline.json` | create | ratchet numbers (warnings, lint findings, unsafe count, trusted lines, coverage) |
| `Scripts/check-ratchet.py`, `measure-trust.py`, `install-hooks.sh` | create | gates only move one way; optional pre-commit hook |
| `Tests/SelfVerificationTests/`, `Tests/SoundnessZooTests/` | create | SwiftFormal verifies itself; known-bad functions must never be `proved` |
| `docs/TESTING.md`, `docs/decisions/0007-type-driven-audit.md` | create | test conventions; type-driven audit decisions |
| `Scripts/baseline/{build.txt,test-inventory.txt,api-products.txt,golden-sfverify.json,timings.md}` | create | frozen facts before refactor |
| `Scripts/sandboxes.py`, `Scripts/sandbox.py`, `Scripts/check-sandboxes.py` | create | sandbox registry (single source of truth), fast/connected/affected loops, card checker |
| `docs/sandboxes/*.md`, `docs/guides/sandbox-workflow.md`, `docs/guides/platforms.md` | create | one card per sandbox; contributor workflow; honest platform matrix |
| `docs/decisions/0008-sfllvm-status.md` | create | owner decision: wire `SFLLVM` into `sfverify` or demote it |
| `Sources/SFToolchain/`, `Sources/SFProcess/` | create (move) | **only if** their go-rows in Task 3B.4 pass |
| `Scripts/check-layering.py` | modify | reads the registry; unknown targets fail |
| `Scripts/check-test-inventory.sh` | create | fail if a baseline test vanished |
| `Scripts/check-api.sh` | create | API diff vs baseline tag, with an allowlist |
| `Scripts/check-golden.sh` | create | `sfverify --json` output equals baseline (timing stripped) |
| `Scripts/check-layering.py` | create | allowed module dependency edges |
| `Scripts/check-doc-coverage.py` | create | every `public` decl in front-door modules has `///` |
| `Scripts/safety-net.sh` | create | runs all of the above |
| `archive/**` | create (move) | frozen research |
| `Sources/SFSIL/ProofCache.swift` | modify → split | 4 files: `SILFrontendVersion.swift`, `ProofDigest.swift`, `CompilerPin.swift`, `CachedVerifier.swift` |
| `Tests/SFTests/*` | modify → split | per-module test targets (see 3.2) |
| `Sources/SFProve/Prove.swift`, `Refine.swift` | modify | collapse `prove…` family |
| `Sources/SFSAT/Solver.swift`, `Sources/SFProve/Prove.swift` | modify | `SolveStats` (additive) |
| `Sources/SwiftFormal/Properties.swift` | modify | lowerCamelCase factories on `Property` |
| `Sources/SwiftFormalTesting/Prove.swift` | modify | `expectProved(...)` overload, deprecate `prove` |
| `docs/**`, `README.md`, `Sources/*/*.docc` | create / modify | documentation |
| `.github/workflows/*.yml`, issue/PR templates | create | CI and community |

---

## 6. Rules for the whole plan

1. **Every phase ends green on `Scripts/safety-net.sh`.** No exceptions, no "fix later".
2. **One concern per commit.** A move is a commit by itself (no edits inside a move).
3. **Behavior-preserving first, behavior-changing never** (nothing in this plan changes a verdict). Additive features (`SolveStats`, evidence line) are the only new behavior, with tests.
4. **Old names stay as `@available(*, deprecated, renamed:)` aliases for one minor version** where the type is part of a front-door module (Phase 4, 6). Engine-room renames need no alias.
5. API naming follows the Swift API Design Guidelines (labels read as grammar, mutating/non-mutating pairs, docs summary rules, role-based names, no method families where defaults do the job).
6. Commit trailer: `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.

---

# PHASE 0: Safety net (do this before touching anything)

### Task 0.1: Put the project under git and stop tracking noise

**Files:** Create `.gitignore`.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
.DS_Store
.build/
**/.build/
.swiftpm/
**/.artifacts/
**/__pycache__/
xcuserdata/
*.xcuserstate
DerivedData/
```

- [ ] **Step 2: Initialise and make the first commit**

```bash
cd <repo>
git init -b main
git add -A
git status --short | head -30        # confirm no .build / .artifacts content is staged
git commit -m "chore: import SwiftFormal as it is today

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git tag baseline-pre-oss
```
Expected: commit succeeds; `git ls-files | wc -l` is a few hundred, not tens of thousands.

- [ ] **Step 3: Preserve the heavy experiment evidence outside the repo (no deletion yet)**

```bash
tar -C . -cf - experiments prototype | zstd -T0 -19 -o ~/SwiftFormal-experiments-2026-11-05.tar.zst
zstd -t ~/SwiftFormal-experiments-2026-11-05.tar.zst && echo OK
```
Expected: `OK`. The small `RESULTS.md` and `measurement-summary.json` files are already tracked (the `.artifacts` ignore only affects big generated files; if `measurement-summary.json` is ignored, `git add -f` it and commit).

### Task 0.2: Freeze the baseline facts

**Files:** Create `Scripts/baseline/*`.

- [ ] **Step 1: Build baseline**

```bash
mkdir -p Scripts/baseline
swift build 2>&1 | tee Scripts/baseline/build.txt | tail -3
grep -c "warning:" Scripts/baseline/build.txt
```
Expected: `Build complete!` and `0`.

- [ ] **Step 2: Test inventory (module prefix stripped so test targets can later move)**

```bash
swift test list 2>/dev/null | sed -E 's/^[^.]+\.//' | sort -u > Scripts/baseline/test-inventory.txt
wc -l Scripts/baseline/test-inventory.txt
```
Expected: ~217 lines.

- [ ] **Step 3: Public API baseline for the front doors**

```bash
swift package diagnose-api-breaking-changes baseline-pre-oss \
  --products SwiftFormal SwiftFormalContracts SwiftFormalTesting SFProve \
  2>&1 | tee Scripts/baseline/api-products.txt | tail -5
```
Expected: "No breaking changes" (we compare the tag with itself; this proves the command works and records the form of its output).

- [ ] **Step 4: Golden `sfverify` verdicts**

Create `Scripts/check-golden.sh`:

```bash
#!/usr/bin/env bash
# Runs sfverify on the gated example and compares verdicts to the frozen baseline (timings removed).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product sfverify >/dev/null
out=$(.build/release/sfverify --package Examples/GatedPackage --target Kernels --build --json \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)
def strip(x):
    if isinstance(x,dict): return {k:strip(v) for k,v in x.items() if k not in ("seconds","compileSeconds","parseSeconds","verifySeconds","silBytes")}
    if isinstance(x,list): return [strip(v) for v in x]
    return x
print(json.dumps(strip(d),indent=1,sort_keys=True))')
if [ "${1:-}" = "--record" ]; then printf '%s\n' "$out" > Scripts/baseline/golden-sfverify.json; echo recorded; exit 0; fi
diff <(printf '%s\n' "$out") Scripts/baseline/golden-sfverify.json && echo "golden verdicts unchanged"
```

```bash
chmod +x Scripts/check-golden.sh && Scripts/check-golden.sh --record && Scripts/check-golden.sh
```
Expected: `recorded`, then `golden verdicts unchanged`. (If the example reports path fields that differ per machine, strip those keys in the same `strip` list and re-record.)

- [ ] **Step 5: Timing baseline (honest, written down)**

```bash
( time swift test --skip SFTests ) 2>&1 | tail -4                    # expect ~10 s
( time swift test -c release --filter SFTests ) 2>&1 | tail -6       # first measurement; record it
```
Write both numbers and the machine into `Scripts/baseline/timings.md` (format: `date | machine | command | seconds`). If the release SFTests run also exceeds 15 minutes, record which tests dominate (`swift test -c release --filter SFTests 2>&1 | grep "passed after"` sorted by time) so Task 7.1 can split them.

### Task 0.3: The safety-net scripts

**Files:** Create `Scripts/check-test-inventory.sh`, `Scripts/check-api.sh`, `Scripts/safety-net.sh`.

- [ ] **Step 1: `Scripts/check-test-inventory.sh`**

```bash
#!/usr/bin/env bash
# No baseline test may disappear. New tests are fine. Renames must be listed in Scripts/baseline/test-renames.tsv (old<TAB>new).
set -euo pipefail
cd "$(dirname "$0")/.."
now=$(swift test list 2>/dev/null | sed -E 's/^[^.]+\.//' | sort -u)
missing=$(comm -23 Scripts/baseline/test-inventory.txt <(printf '%s\n' "$now"))
if [ -f Scripts/baseline/test-renames.tsv ]; then
  while IFS=$'\t' read -r old new; do
    missing=$(printf '%s\n' "$missing" | grep -vxF "$old" || true)
  done < Scripts/baseline/test-renames.tsv
fi
if [ -n "$missing" ]; then echo "Tests missing since baseline:"; printf '%s\n' "$missing"; exit 1; fi
echo "test inventory ok ($(printf '%s\n' "$now" | wc -l | tr -d ' ') tests)"
```

- [ ] **Step 2: `Scripts/check-api.sh`**

```bash
#!/usr/bin/env bash
# Compares front-door APIs with the baseline tag. Intended breaks go into Scripts/baseline/api-allowlist.txt (one regex per line).
set -uo pipefail
cd "$(dirname "$0")/.."
out=$(swift package diagnose-api-breaking-changes "${1:-baseline-pre-oss}" \
  --products SwiftFormal SwiftFormalContracts SwiftFormalTesting SFProve 2>&1)
status=$?
if [ -f Scripts/baseline/api-allowlist.txt ]; then
  out=$(printf '%s\n' "$out" | grep -v -f Scripts/baseline/api-allowlist.txt || true)
fi
printf '%s\n' "$out" | grep -E "💔|breaking" && { echo "unlisted API break"; exit 1; }
echo "api ok"
```

- [ ] **Step 3: `Scripts/safety-net.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build 2>&1 | tee /tmp/sf-build.txt | tail -1
test "$(grep -c 'warning:' /tmp/sf-build.txt)" = "0"
swift test --skip SFTests                       # fast lane, ~10 s
Scripts/check-test-inventory.sh
Scripts/check-golden.sh
Scripts/check-api.sh
[ -x Scripts/check-layering.py ] && python3 Scripts/check-layering.py || true
echo "SAFETY NET GREEN"
```

- [ ] **Step 4: Run it and commit**

```bash
chmod +x Scripts/*.sh && Scripts/safety-net.sh
git add -A && git commit -m "test: add the safety net and freeze baseline facts

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```
Expected final line: `SAFETY NET GREEN`.

**Slow lane rule:** before merging Phases 3, 4, 5 and 6, also run `swift test -c release --filter SFTests` once and compare pass count with the baseline (`timings.md`).

---

# PHASE 1: Declutter (no code changes)

### Task 1.1: Move research out of the front door

**Files:** Move `experiments/`, `prototype/`, `validation/`, `tools/`, `EXPLAINED.md`, `REPORT.md`, `docs/research/` into `archive/`. Create `archive/README.md`.

- [ ] **Step 1: Confirm nothing in `Sources/`, `Tests/`, `Plugins/`, `Package.swift` references these paths**

```bash
grep -rnE "experiments/|prototype/|validation/|tools/builtin-oracle|EXPLAINED|REPORT\.md" Sources Tests Plugins Package.swift Examples | head
```
Expected: no output. If a test reads `tools/builtin-oracle/oracle.swift` (the name `S0BuiltinOracleTests` suggests it may), move that file instead to `Tests/Support/builtin-oracle/` and update the path in that one test; re-run `swift test --filter S0BuiltinOracleTests`.

- [ ] **Step 2: Move with git (history kept), one commit**

```bash
mkdir -p archive
git mv experiments prototype validation tools EXPLAINED.md REPORT.md archive/
git mv docs/research archive/research
git commit -m "chore: move research history under archive/ (no code changed)

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

- [ ] **Step 3: Write `archive/README.md`**

```markdown
# Archive: how we got here

This folder is frozen history. It is kept because SwiftFormal's honesty comes from evidence, but you do not
need it to use or contribute to the library.

| Folder | What it was | Result |
|---|---|---|
| `experiments/` 0.0.3 to 0.0.7 | Lean proofs of Swift SIL, translation validation, control flow | led to the pure-Swift SAT prover |
| `prototype/` | first spec language and Lean emitter | superseded |
| `validation/` | run on 314 real `Rule` types of a production app | `RESULTS.md` |
| `research/` | feasibility and design notes | decisions summarised in `docs/decisions/` |
| `EXPLAINED.md`, `REPORT.md` | beginner explanation and first report | read `docs/MENTAL-MODEL.md` instead |

Evidence bundles (hundreds of MB of build output) are not in git. See `docs/decisions/0001-archive-policy.md`.
```

- [ ] **Step 4: Rerun safety net, commit.** `Scripts/safety-net.sh` must be green. Update relative links in moved docs only if a link checker (Task 9.5) finds them broken.

### Task 1.2: Trim the README to one screen (content moved, not deleted)

**Files:** Modify `README.md`; create `docs/guides/*.md` (see Phase 9 for final text).

- [ ] **Step 1:** Cut the whole `## Experiments (0.0.x)` block (README line ~148 to end) into `archive/experiments/CHANGELOG-0.0.x.md` verbatim.
- [ ] **Step 2:** Move the `sfverify`, Build-Gate and Tier-2 sections to `docs/guides/scan.md`, `docs/guides/gate.md`, `docs/guides/prove.md` verbatim (rewritten later in Phase 9; today they are correct and measured, so do not paraphrase now).
- [ ] **Step 3:** Leave README with: title, one-sentence analogy (section 3), the verdict table, the 8-line `@Verify` example, three links. Commit. Safety net green.

---

# PHASE 2: Mental model and vocabulary (docs only, decisions locked)

### Task 2.1: Write `docs/MENTAL-MODEL.md`

- [ ] **Step 1:** Copy section 3 of this plan (the one-sentence statement, the analogy table, the three-tools table, the naming rule) into `docs/MENTAL-MODEL.md`. Add one diagram (ASCII is fine) of "Walk / Prove / Scan" and which verdict words each returns.
- [ ] **Step 2:** Add a section "What the certificate does *not* cover" (compiler, the `Domain` you wrote, strings as opaque, traps cannot be caught in-process on Walk). Source text: product design spec §3 and §5a (already written and accurate).

### Task 2.2: Write `docs/GLOSSARY.md` and `docs/TRUST.md`

- [ ] **Step 1: Glossary** with 20 to 25 entries, each one sentence in plain words: Domain, Property, Contract, Walk, Prove, Scan, Verdict, proved, bounded, counterexample, unknown, unsupported, fail closed, budget, trap, SIL, SAT, bit-vector, LRAT/RUP proof, independent checker, proof cache, gate, spec audit, behavior lock.
- [ ] **Step 2: TRUST.md** one table per tool: *what is trusted* (compiler, domain, SIL reader, bit-blaster encoding), *what is checked independently* (SAT proof by `SFCheck`, counterexample replayed natively), *what is empirically tested* (oracle tests), *known limits* (copy from README limits and `archive/design/specs/2026-11-05-pure-swift-verifier-design.md` §6).

### Task 2.3: ADRs for decisions taken in this plan

- [ ] Create `docs/decisions/0001-archive-policy.md`, `0002-one-vocabulary-three-tools.md`, `0003-package-access-for-engines.md`, `0004-test-lanes.md`. Each one page: Context, Decision, Consequences. Commit. (No code touched; safety net trivially green.)

---

# PHASE 3: Mechanical structure (moves only)

### Task 3.1: Split `SFSIL/ProofCache.swift` (727 lines) by responsibility

**Files:** Modify `Sources/SFSIL/ProofCache.swift` → create `ProofCacheVersions.swift`, `ProofDigest.swift`, `CompilerPin.swift`, `CachedVerifier.swift`.

- [ ] **Step 1: Find the seams**

```bash
grep -n "^// MARK\|^public \(enum\|struct\)" Sources/SFSIL/ProofCache.swift
```
Seams seen at plan time: lines 21 to 50 versions/errors (`SILFrontendVersion`, `ProofCacheError`), 51 to 321 digests and toolchain fingerprints (`ProofDigest`, `CompilerToolchain`, `CompilerFingerprint`, `SemanticsDigest`), 322 to 571 pin (`CompilerPin`, `PinnedCompiler`), 572 to end cache (`CachedResult`, `CachedVerifier`).

- [ ] **Step 2:** Move each block verbatim into its own file with the same imports and the `#if canImport(CryptoKit)` guard where used. **Do not edit any line.** Keep the explanatory header comment (lines 8 to 17) on `CachedVerifier.swift`.
- [ ] **Step 3: Verify**

```bash
swift build 2>&1 | tail -2 && swift test --filter ProofCacheTests 2>&1 | tail -3
```
Expected: build complete, `ProofCacheTests` pass (18 tests). Commit `refactor: split ProofCache.swift (moves only)`.

### Task 3.2: Split `SFTests` (one target that depends on 9 modules) into per-module test targets

**Why:** a contributor changing `SFSAT` should run `swift test --filter SFSATTests` and get an answer in seconds; today they pull in the 20-minute target.

**Files:** Modify `Package.swift`; move files in `Tests/SFTests/`.

| New test target | Files moved (from `Tests/SFTests`) | Depends on |
|---|---|---|
| `SFSATTests` | `SolverTests`, `LRATTests`, `CheckerTests` | `SFSAT`, `SFCheck`, `SFCNF` |
| `SFBVTests` | `BitVecTests`, `NarrowingTests`, `MulHookTests` | `SFBV`, `SFCNF` |
| `SFProveTests` | `ProveTests`, `RefineTests`, `SymbolicTests` | `SFProve` |
| `SFSemanticsTests` | `S0Tests`, `S0BuiltinOracleTests` | `SFSemantics` |
| `SFSILTests` | `SILTests`, `SILAggregateTests`, `SILLoopTests`, `SpecAuditTests`, `ProofCacheTests` | `SFSIL` |
| `SFOracleTests` | `SILOracleTests`, `LLVMTests` | `SFSIL`, `SFLLVM` (these spawn the compiler; the slow lane) |
| `SFVerifyKitTests` | `SFVerifyTests`, `GateTests` | `SFVerifyKit` |

- [ ] **Step 1:** Check that no test file uses a helper from another file: `grep -n "^func \|^let \|^private func" Tests/SFTests/*.swift` and cross-grep the names. If one exists, move it to `Tests/Support/` (a small target `SFTestSupport`).
- [ ] **Step 2:** `git mv` the files per the table into `Tests/<Target>/`. One commit, no edits. The dependency column is a starting point (for example `MulHookTests` may also need `SFProve`); `swift build --build-tests` names any missing import, and the fix is to add that dependency to the target, not to move the file.
- [ ] **Step 3:** Edit `Package.swift`: remove `SFTests`, add the seven `.testTarget`s with exactly the dependencies in the table.
- [ ] **Step 4: Verify nothing was lost**

```bash
swift build --build-tests 2>&1 | tail -2
Scripts/check-test-inventory.sh      # module prefix is stripped, so moves do not count as removals
```
Expected: `test inventory ok (217+ tests)`.

- [ ] **Step 5:** Update `Scripts/safety-net.sh` fast lane to `swift test --skip SFOracleTests --skip SFSILTests --skip SFProveTests --skip SFSATTests` only after measuring each target's time in Task 7.1; until then keep `--skip SFTests` replaced by `--skip SFOracleTests`. Commit.

### Task 3.3: Split any other file over ~600 lines only if it has a natural seam

- [ ] `Solver.swift` (782), `SILParser.swift` (767), `LLVMParser.swift` (646) are cohesive parsers or one algorithm. **Do not split by size alone.** Leave them; add a header comment "reading guide" (5 lines: entry point, main phases, where tests are) to each. This keeps `git blame` useful.

### Task 3.4: Enforce the module layering

**Files:** Create `Scripts/check-layering.py`.

- [ ] **Step 1: Write the script**

```python
#!/usr/bin/env python3
"""Fails if a target depends on a module it is not allowed to see."""
import json, subprocess, sys

ALLOWED = {
    "SwiftFormal": set(),
    "SwiftFormalMacros": set(),
    "SwiftFormalContracts": {"SwiftFormal", "SwiftFormalMacros"},
    "SwiftFormalTesting": {"SwiftFormal"},
    "SFCNF": set(),
    "SFSAT": {"SFCNF"},
    "SFCheck": {"SFCNF"},          # independent checker: never SFSAT or SFBV
    "SFBV": {"SFCNF"},
    "SFProve": {"SFCNF", "SFSAT", "SFCheck", "SFBV"},
    "SFSemantics": {"SFCNF", "SFBV"},
    "SFSIL": {"SFCNF", "SFBV", "SFSemantics", "SFProve"},
    "SFLLVM": {"SFCNF", "SFBV", "SFProve", "SFSIL"},
    "SFVerifyKit": {"SFCNF", "SFBV", "SFProve", "SFSemantics", "SFSIL"},
    "sfverify": {"SFVerifyKit"},
    "SFGenKit": set(),
    "sfgen": {"SFGenKit"},
}
pkg = json.loads(subprocess.check_output(["swift", "package", "describe", "--type", "json"]))
bad = []
for t in pkg["targets"]:
    if t["type"] in ("test", "plugin") or t["name"] not in ALLOWED:
        continue
    deps = set(t.get("target_dependencies", []))
    extra = deps - ALLOWED[t["name"]]
    if extra:
        bad.append(f'{t["name"]} must not depend on {sorted(extra)}')
if bad:
    print("\n".join(bad)); sys.exit(1)
print("layering ok")
```

- [ ] **Step 2:** `chmod +x Scripts/check-layering.py && python3 Scripts/check-layering.py`. Expected `layering ok` (the table mirrors today's `Package.swift`). If it fails, the table is wrong, not the package: fix the table.
- [ ] **Step 3:** Commit; `Scripts/safety-net.sh` green.

---

# PHASE 3B: Sandbox-driven modularization (`/sandbox-driven-development`)

**Idea, in the project's own words.** Every change, small ones included, happens in a **sandbox**: a small piece that builds, tests and runs alone, holds real production code (nothing copied), and is checked against the **real consumer** early. For this library the "host app" does not exist; the **real consumers** play that role: the `sfverify` CLI, the `SwiftFormalGate` plugin through `Examples/GatedPackage`, `SwiftFormalTesting` users, and an iOS app that links Walk and Prove. In the Inspector story: *each sandbox is one inspector's desk; the consumers are the buildings that actually get inspected.*

**What the repo already gets right.** 14 library and macro targets are already small compile units (`SFCNF` 29 lines, `SFCheck` 333, `SFBV` 333, `SFSemantics` 261, `SwiftFormalContracts` 53), and `Examples/GatedPackage` already consumes the production source (not a copy). The work is to make that structure *navigable and enforceable*, not to invent it.

**Measured facts that shape the phase** (taken while writing the plan):
- `swift build --target SFSAT` builds one module and its closure in about 1.5 s warm. Cold cost is **not yet measured**; Task 3B.1 measures it (the skill warns that a test filter is not build isolation).
- `SFLLVM` is imported by **no production target** (only by tests). Its only "real consumer" check today is the oracle tests. That is a gap to state in its card, not to hide.
- iOS: `xcodebuild -scheme SwiftFormal | SwiftFormalTesting | SFProve -destination 'generic/platform=iOS Simulator'` **builds**. `SFVerifyKit` **fails** (`cannot find 'Process' in scope` in `SFSIL/SILVerify.swift:22,39`), although `Package.swift` declares `.iOS(.v16)` for the whole package. Process spawning lives in 7 files across `SFSIL`, `SFLLVM`, `SFVerifyKit`, `sfgen`.
- `SFSIL` is 2,937 lines in 5 files and mixes parsing/encoding with the toolchain pin, digests and cache (`ProofCache.swift`, which imports only `SFProve`/`SFSemantics`, not the parser).

> **Decision D9 (assumption):** one `Package.swift`, many sandboxes. Splitting into several `Package.swift` files would force engine internals back to `public` (`package` access does not cross packages) and undo Phase 5. Revisit only if someone needs the SAT kernel (`SFCNF`+`SFSAT`+`SFCheck`+`SFBV`) as a standalone package; then those become public on purpose, in a release of their own.

### Task 3B.1: The sandbox registry (one source of truth)

**Files:** Create `Scripts/sandboxes.py`; modify `Scripts/check-layering.py` to import it (so the allowed edges are written once).

- [ ] **Step 1:** Write the registry. Each entry says: what depends on what (compile graph), which test target is the fast loop, which **real consumer checks** must also run (consumer graph), and which platforms are real (verified, not declared).

```python
#!/usr/bin/env python3
"""Single source of truth for sandboxes: layering, fast loop, connected loop, platforms."""
from dataclasses import dataclass, field

@dataclass(frozen=True)
class Sandbox:
    deps: frozenset[str]                      # allowed compile dependencies (module names)
    tests: str | None                         # fast-loop test target, None if covered elsewhere
    consumers: tuple[str, ...] = ()           # commands that exercise the REAL consumers (connected loop)
    platforms: tuple[str, ...] = ("macOS", "iOS")   # only list what CI actually builds
    kind: str = "library"                     # library | tool | plugin | macro

GOLDEN = "Scripts/check-golden.sh"            # sfverify --json on Examples/GatedPackage (timing stripped)
GATE = "swift build --package-path Examples/GatedPackage"

SANDBOXES: dict[str, Sandbox] = {
    "SwiftFormal":          Sandbox(frozenset(), "SwiftFormalTests", ("swift test --filter SwiftFormalTestingTests",)),
    "SwiftFormalTesting":   Sandbox(frozenset({"SwiftFormal"}), "SwiftFormalTestingTests", ("swift build --package-path Examples/Walk",)),
    "SwiftFormalMacros":    Sandbox(frozenset(), "SwiftFormalMacrosTests", ("swift test --filter SwiftFormalContractsTests",), ("macOS",), "macro"),
    "SwiftFormalContracts": Sandbox(frozenset({"SwiftFormal", "SwiftFormalMacros"}), "SwiftFormalContractsTests", ("swift build --package-path Examples/Walk",)),
    "SFCNF":                Sandbox(frozenset(), None, ("swift test --filter SFSATTests", "swift test --filter SFProveTests")),
    "SFSAT":                Sandbox(frozenset({"SFCNF"}), "SFSATTests", ("swift test --filter SFProveTests",)),
    "SFCheck":              Sandbox(frozenset({"SFCNF"}), "SFSATTests", ("swift test --filter SFProveTests",)),   # independence rule: never SFSAT/SFBV
    "SFBV":                 Sandbox(frozenset({"SFCNF"}), "SFBVTests", ("swift test --filter SFProveTests",)),
    "SFProve":              Sandbox(frozenset({"SFCNF", "SFSAT", "SFCheck", "SFBV"}), "SFProveTests", ("swift test --filter SFSILTests", GOLDEN)),
    "SFSemantics":          Sandbox(frozenset({"SFCNF", "SFBV"}), "SFSemanticsTests", ("swift test --filter SFSILTests", GOLDEN), ("macOS",)),   # verify iOS in 3B.5, then widen
    "SFSIL":                Sandbox(frozenset({"SFCNF", "SFBV", "SFSemantics", "SFProve"}), "SFSILTests", (GOLDEN, GATE), ("macOS",)),
    "SFLLVM":               Sandbox(frozenset({"SFCNF", "SFBV", "SFProve", "SFSIL"}), "SFOracleTests", ("swift test -c release --filter SFOracleTests",), ("macOS",)),  # no production consumer yet: say so in the card
    "SFVerifyKit":          Sandbox(frozenset({"SFCNF", "SFBV", "SFProve", "SFSemantics", "SFSIL"}), "SFVerifyKitTests", (GOLDEN, GATE), ("macOS",)),
    "sfverify":             Sandbox(frozenset({"SFVerifyKit"}), None, (GOLDEN, GATE), ("macOS",), "tool"),
    "SFGenKit":             Sandbox(frozenset(), "SFGenKitTests", ("swift run sfgen --help",), ("macOS",)),
    "sfgen":                Sandbox(frozenset({"SFGenKit"}), None, ("swift run sfgen --help",), ("macOS",), "tool"),
    "SwiftFormalGate":      Sandbox(frozenset({"sfverify"}), None, (GATE,), ("macOS",), "plugin"),
}

def reverse_closure(changed: set[str]) -> set[str]:
    """Everything that (transitively) depends on a changed sandbox: the CONSUMER graph, not just the build list."""
    out, grew = set(changed), True
    while grew:
        grew = False
        for name, s in SANDBOXES.items():
            if name not in out and s.deps & out:
                out.add(name); grew = True
    return out
```
(The consumer commands above are the *starting* list; each must be a real command that exists after Phase 3.2 and Phase 7. If an Example does not exist yet, create it in Phase 9 and keep the entry commented until then. Never point a consumer entry at a fake.)

- [ ] **Step 2:** In `Scripts/check-layering.py` replace the inline `ALLOWED` dict with `from sandboxes import SANDBOXES`. **Unknown targets now fail** (`"<name> is not in Scripts/sandboxes.py: declare its layer"`) instead of being skipped. This is how a new target is forced to declare its place.
- [ ] **Step 3: Verify** `python3 Scripts/check-layering.py` prints `layering ok` and, after deleting one entry on purpose, fails; restore it. Commit.

### Task 3B.2: One-command sandbox loops

**Files:** Create `Scripts/sandbox.py`.

- [ ] **Step 1:** Implement three modes on top of the registry:

```text
Scripts/sandbox.py SFSAT                 # fast loop: swift build --target SFSAT; swift build --target SFSATTests; swift test --filter SFSATTests
Scripts/sandbox.py SFSAT --connect       # fast loop, then every command in SANDBOXES["SFSAT"].consumers
Scripts/sandbox.py --affected <git-ref>  # reads `git diff --name-only <ref>`, maps Sources/<X>/ and Tests/<X>Tests/ to sandboxes,
                                         # takes reverse_closure(), prints (and with --run, runs) fast + connected loops
```
Rules: the script **prints each command before running it** and prints a final line `Core: <n> passed; consumers: <n> passed; not run: <platform checks>` so a green package is never reported as a green product. If `swift build --target <X>Tests` is not supported by the installed toolchain, fall back to `swift test --filter <X>Tests` and print that fact.
- [ ] **Step 2: Measure what the loop buys.** For `SFSAT`, `SFBV`, `SFSIL`, `SwiftFormal`, record in `Scripts/baseline/timings.md`: cold `swift build --target <X>` (after `rm -rf .build`), warm incremental after touching one file, and the full `swift build`. If the cold target-only build is not meaningfully faster than the full build, say so in `docs/guides/sandbox-workflow.md` (honest cost), and keep the loop for its clearer failures and smaller test run, not for speed.
- [ ] **Step 3: Prove the loop catches what package-green cannot** (test the test). In a scratch worktree, change an `SFSAT` function **body** (for example weaken a learned-clause rule) without touching any signature; confirm `SFSATTests` alone may stay green while `Scripts/sandbox.py SFSAT --connect` (the `SFProveTests` and golden checks) goes red. If nothing goes red, the consumer list is too thin: add the missing check. Discard the worktree. Commit the script.

### Task 3B.3: Sandbox cards (a map people can read)

**Files:** Create `docs/sandboxes/<Name>.md` for every entry in the registry, `docs/sandboxes/README.md` (the table), and `Scripts/check-sandboxes.py`.

- [ ] **Step 1:** Card template (short; one screen):

```markdown
# SFSAT: the solver

**Job (Inspector view):** the structural engineer's calculator. Given a puzzle of yes/no clauses, finds a solution or a refutation.
**Raw input → typed → result:** clauses (`SFCNF`) → `Solver` → `.sat(model)` / `.unsat(proof)` / budget exhausted.
**Depends on:** SFCNF. **Must not depend on:** SFCheck, SFBV (see TRUST.md).
**Fast loop:** `Scripts/sandbox.py SFSAT`   **Connected loop:** `Scripts/sandbox.py SFSAT --connect`
**Real consumers:** SFProve (every proof), then `sfverify` golden verdicts.
**Platforms (CI-verified):** macOS, iOS.   **Run it:** Examples/Prove
**Known gaps:** none.   <!-- be honest here, for example "no production consumer yet" -->
```
- [ ] **Step 2:** `Scripts/check-sandboxes.py` fails if a registry entry has no card, a card is missing any of the seven headings above, or the card's "Depends on" differs from the registry. Add to the safety net and CI.
- [ ] **Step 3:** Link the table from `docs/ARCHITECTURE.md` and from the README "Where things live" section. Write `SFLLVM`'s card with the **Known gap: not wired into `sfverify`; verified only by the oracle lane**, and open an issue to wire it or demote it (owner decision, tracked in `docs/decisions/0008-sfllvm-status.md`).

### Task 3B.4: Carve-outs: behavior-preserving, one per commit, only with evidence

Rule from the skill: **a carve-out is a separate step from any behavior change**; tests stay green; no copies; no package that exists only to dodge a build. Each candidate below has a go / no-go test.

| Candidate | Evidence | Go if | No-go if | Result |
|---|---|---|---|---|
| **`SFToolchain`** carved from `SFSIL` (`CompilerPin`, `PinnedCompiler`, fingerprints, `ProofDigest`, `SemanticsDigest`, versions) | ~727 lines (`ProofCache.swift`), imports only `SFProve`/`SFSemantics`/`SFBV`/`SFCNF`; the pin is the *adapter* between "the real compiler" and our trusted model | `grep` shows `CachedVerifier` is the only piece that needs `SFSIL` symbols, so the new module has **no** dependency on parser/encoder/verify | any carved type calls into `SILParser`/`SILEncoder`/`SILVerify` (would create a cycle) | `SFToolchain` (deps: `SFCNF`, `SFBV`, `SFSemantics`, `SFProve`); `CachedVerifier` stays in `SFSIL`; tests move with it (`ProofCacheTests` → `SFToolchainTests` except the cache-verifier ones) |
| **`SFProcess`** (tiny, macOS-only): the one place that spawns `swiftc`, `swift`, `swift-demangle`, `clang` | `Process` used in 7 files; it is the reason iOS builds of `SFSIL`/`SFVerifyKit` fail; it is the effect boundary (real compiler, real stdout) | the `Process` call sites can be funnelled through one `async throws` function with a `ToolRunning` protocol, a real implementation, and a recorded fake for unit tests | call sites need more than run/capture/exit-code (then widen the API once, not per caller) | `SFProcess` + `ToolRunning`. **Unit tests use the fake; the oracle lane and the connected loop use the real runner** (a fake alone is never the integration check) |
| `SFVerifyKit` (1,279 lines, 7 files) split into report vs driver | the `ScanReport` JSON is already the contract | a **second consumer** of the report types appears (for example a Gate-only reader) | only the size bothers us | **No-go now.** Cohesive; re-check when it passes ~1,500 lines or gains a second consumer |
| `SFGenKit` (1,114 lines) | independent of the engines (only swift-syntax) | n/a | n/a | **No-go.** Already its own sandbox |
| `SFCNF` (29 lines, the shared alphabet) | small shared-types modules tend to become dumping grounds | n/a | grows past **150 lines** or gains a non-value type | **Guard instead of carve:** `Scripts/check-layering.py` fails if `SFCNF` exceeds 150 non-blank lines; if it must grow, redraw the boundary |
| `SFLLVM` | no production consumer | owner decides in ADR 0008 | n/a | **Decision, not a carve** |

For each **go** row, in this order: (1) add the module + registry entry + card; (2) `git mv` types verbatim (no edits); (3) add the new dependency edge; (4) `swift build` and `swift build --build-tests`; (5) `Scripts/check-test-inventory.sh` (no test lost), `Scripts/check-api.sh` (no public symbol lost; new module names go in the allowlist), `Scripts/check-golden.sh`; (6) commit `refactor: carve SFToolchain from SFSIL (moves only)`. If any step needs a code edit beyond imports and access levels, **stop and record why**; that is a behavior change and gets its own task.

### Task 3B.5: Honest platform matrix (iOS is a claim we must prove)

`Package.swift` declares iOS 16 for everything; today only part of it builds there.

- [ ] **Step 1:** Record what builds, per scheme, on `generic/platform=iOS Simulator` (already verified: `SwiftFormal`, `SwiftFormalTesting`, `SFProve` pass; `SFVerifyKit` fails on `Process`). Check the remaining ones (`SFSemantics`, `SFSIL`, `SFLLVM`, `SwiftFormalContracts`) and fill `platforms` in the registry from the results.
- [ ] **Step 2:** `docs/guides/platforms.md` table: **Walk** (SwiftFormal, Testing, Contracts): macOS + iOS. **Prove** (SFProve and the SAT kernel): macOS + iOS. **Scan and Gate** (needs a compiler to run): macOS only. Say plainly: "Scan inspects *code at build time on a Mac*; it is not shipped inside an iOS app."
- [ ] **Step 3:** CI job `ios`: for every registry entry whose `platforms` contains `iOS`, run `xcodebuild -scheme <S> -destination 'generic/platform=iOS Simulator' build`; and run the Walk and Prove test targets on a simulator destination (`xcodebuild test -scheme SwiftFormal-Package -destination 'platform=iOS Simulator,name=<available>'`; take the device name from `xcrun simctl list devices available`). macOS results never stand in for iOS results (skill red flag).
- [ ] **Step 4 (owner choice, decision D10):** keep Scan modules macOS-only and document it (default, zero code), **or** carve `SFProcess` (Task 3B.4) and guard its real runner with `#if os(macOS)` so `SFSIL` and `SFSemantics` build on iOS too. Do not guard `Process` call sites ad hoc in seven files.

### Task 3B.6: Contributor workflow written down

- [ ] Create `docs/guides/sandbox-workflow.md` and a short section in `CONTRIBUTING.md` ("How to make a change here"):
  1. **Name the behavior**: one concrete input, expected output, and one failing/edge example; for a bug, reproduce it first and watch the new test fail for the right reason.
  2. **Pick the sandbox**: new behavior → new small target with its test target, card and registry entry (no code goes into `SFVerifyKit` or the CLI just because it is convenient); change in a small sandbox → that sandbox; change in a large one (`SFSIL`, `SFVerifyKit`) → carve first (3B.4), separately.
  3. **Define the boundary**: raw units, valid states, sync/async, errors, cancellation; validate external data at the adapter (the SIL parser and `PinnedCompiler` are adapters; the SAT kernel gets typed clauses only, see Task Q.3).
  4. **Work in the sandbox, connect early**: `Scripts/sandbox.py <Name>`; at first working behavior run `--connect`. Examples are the "preview": runnable, consuming the *same* source via `.package(path: "../..")`, never a copy.
  5. **Verify and report honestly**: `Scripts/sandbox.py --affected main --run`, then the safety net; the PR template asks for the printed summary line (`Core: …; consumers: …; not run: …`), so gaps are visible.
- [ ] PR template (Task 10.1) gets the five lines above as a checklist. Commit.

### Phase 3B exit check

- [ ] `python3 Scripts/check-layering.py`, `python3 Scripts/check-sandboxes.py`, `Scripts/sandbox.py SFSAT --connect` and `Scripts/sandbox.py --affected baseline-pre-oss` all run; `Scripts/safety-net.sh` green.
- [ ] Every target in `Package.swift` is in the registry and has a card; every consumer command in the registry exists and was run once.
- [ ] `docs/guides/platforms.md` matches what the `ios` CI job actually builds.
- [ ] No module was added that is not a go-row of Task 3B.4.

---

# PHASE 4: Names (the compiler finds every use)

Rule: rename with the compiler (`swift build` shows all uses); for front-door modules keep a deprecated alias for one minor version; add every intended break to `Scripts/baseline/api-allowlist.txt`.

### Task 4.1: Remove the three colliding type names

| Today | New | Why |
|---|---|---|
| `SFProve.Verdict` (proved / counterexample / unknown) | `ProofVerdict` | does not clash with `SwiftFormal.Verdict`; `SymbolicVerdict` already exists in the same module |
| `SFVerifyKit.Report` | `ScanReport` | a **Scan** result; no clash with `SwiftFormal.Report` |
| `SFVerifyKit.Counterexample` | `ScanCounterexample` | same |
| `SFVerifyKit.Status` | `ScanStatus` | generic name, now tied to the tool |

- [ ] **Step 1: Write a failing "both imports compile" test** in `Tests/SFProveTests/NamingTests.swift` (new):

```swift
import SFProve
import SwiftFormal
import Testing

@Suite struct VocabularyTests {
    @Test func bothVerdictsCanBeNamedInOneFile() {
        let walked: Verdict = .proved(checked: 3)        // SwiftFormal, unqualified
        let proven: ProofVerdict = .proved                // SFProve
        #expect(walked.isProved)
        #expect(proven == .proved)
    }
}
```
Run `swift test --filter VocabularyTests`. Expected: **FAIL** to compile (`ProofVerdict` not found / `Verdict` ambiguous).

- [ ] **Step 2:** Rename `Verdict` → `ProofVerdict` inside `Sources/SFProve/Prove.swift` and fix each use the compiler reports (`SFProve`, `SFSIL`, `SFLLVM`, `SFVerifyKit`, tests). Use `swift build 2>&1 | grep error:` in a loop until clean.
- [ ] **Step 3:** In `SFVerifyKit`, rename `Report` → `ScanReport`, `Counterexample` → `ScanCounterexample`, `Status` → `ScanStatus`. **JSON output must not change**: these types are `Codable`, so JSON keys come from properties, not type names. The golden check proves that.
- [ ] **Step 4:** Run the new test (PASS) and `Scripts/safety-net.sh` (golden verdicts unchanged proves the CLI output is identical). Add the four `SFProve`/`SFVerifyKit` renames to `api-allowlist.txt`. Commit `refactor: give each tool its own result type names`.

### Task 4.2: Stop `prove` meaning two things

- [ ] **Step 1: Failing test** in `Tests/SwiftFormalTestingTests/ProveTests.swift` (add to existing file):

```swift
@Test func expectProvedAcceptsAFunctionAndADomain() {
    let report = expectProved("negate twice", { (value: Bool) in !(!value) }, over: .bool) {
        Deterministic()
    }
    #expect(report.isProved)
}
```
Expected: FAIL (no such overload).

- [ ] **Step 2:** In `Sources/SwiftFormalTesting/Prove.swift`, rename the two `prove(...)` functions to `expectProved(...)` (same parameters, same body) and keep the old name as:

```swift
@available(*, deprecated, renamed: "expectProved(_:_:over:budget:allowBounded:properties:assuming:sourceLocation:)")
@discardableResult
public func prove<Input, Output>(/* same signature, forwards to expectProved */) -> Report { ... }
```
Copy the real parameter list from the existing function at implementation time; the forwarding body is a single `expectProved(...)` call. Do the same for the `Finite` overload.

- [ ] **Step 3:** Update README/doc examples to `expectProved`. Rerun `swift test --filter SwiftFormalTestingTests`. Existing tests that call `prove` still pass (deprecation warning only; switch them to the new name in the same commit so the build stays at 0 warnings). Commit.

### Task 4.3: Naming audit against the Swift API Design Guidelines (list, then apply)

Findings at plan time (apply only the ones marked **do**; the rest are recorded as accepted trade-offs in `docs/decisions/0005-api-naming.md`):

| Finding | Guideline | Action |
|---|---|---|
| `Deterministic()`, `Matches(...)`, `Table(...)`, `Injective()`, `Image(...)`, `RoundTrip(...)`, `Satisfies(...)` are UpperCamelCase *functions* | "Everything except types and protocols is lowerCamelCase" | **do** in Task 6.2 (add `Property.deterministic()` etc., keep old as deprecated) |
| `verify_<name>()` generated by `@Verify` | lowerCamelCase | **accept**, document: macro `prefixed(verify_)` cannot capitalise the next letter; changing it needs explicit names per macro use. Record in ADR; revisit if Swift adds a naming option |
| `Domain.int(_:)`, `.bool`, `.of(_:)`, `.just(_:)`, `.samples(_:)` | reads as phrase at call site (`over: .int(0...10)`) | accept |
| `Domain.asSample` (non-mutating property returning a new value) | `as…` is for views/conversions, fine | accept |
| `Domain.evenlySpaced(_:)`, `.map`, `.filter` | `-ed`/noun forms for non-mutating, imperative reserved for mutating | accept |
| `Counterexample.input: String?` | role-based, but stringly typed | accept for v0.1, note in ADR (typed replay is a v0.2 idea) |
| `Report.isProved`, `hasNoCounterexample` | assertion-style Booleans | accept |
| `Verifier.verify(...)` | fine | accept |
| `MulAbstraction` public class with `install()` / `finalize()` lifecycle | hidden lifecycle is a trap for users | **do** in Phase 5: make `package` |
| `Property.Observer` public init | internals leaking | **do** in Phase 5: `@_spi(Extending)` (custom properties still possible via `Property.custom`) |
| `SFProve`: `proveRefining`, `proveMaybeRefining`, `proveRefiningDetailed` | "prefer default arguments over method families" | **do** in Task 6.1 |
| Module prefix `SF…` | short unambiguous prefixes are acceptable for engine modules that users never import | accept, since engines become `package` |

- [ ] **Step 1:** Create `docs/decisions/0005-api-naming.md` from this table (the *accept* rows with their reasons).
- [ ] **Step 2:** Commit. (Actions marked **do** are executed in Phases 5 and 6.)

---

# PHASE 5: Narrow the public surface

**Principle:** `public` = promise to strangers. Everything the CLI, plugin and tests need but users do not is `package`.

### Task 5.1: Demote engine modules one at a time (leaf first)

Order: `SFCNF` → `SFSAT` → `SFCheck` → `SFBV` → `SFSemantics` → `SFSIL` → `SFLLVM` → `SFGenKit` → `SFVerifyKit` → `SFProve` internals. For each module:

- [ ] **Step 1:** Replace `public` with `package` on every declaration (members and top-level) in that module, with one exception: nothing in `SFProve`'s documented facade (see Task 5.2).

```bash
# example for one module; review the diff, do not run blindly across modules
grep -rl "public " Sources/SFSAT | xargs sed -i '' -E 's/\bpublic (final class|class|struct|enum|protocol|func|var|let|init|static|typealias|subscript|extension)/package \1/g'
```
(`sed` is acceptable here only as a bulk mechanical step; commit the diff and read it. Do **not** change `public` on `override`/protocol-witness members that the compiler requires to match the protocol visibility; fix those by hand when the compiler reports it.)

- [ ] **Step 2:** `swift build --build-tests 2>&1 | grep error:` and fix leftovers (usually `public init` on a `package` type, or a `public` function exposing a `package` type, which becomes `package`).
- [ ] **Step 3:** `swift test --filter <ModuleTests>` for that module (fast lane). Commit one module per commit: `refactor(SFSAT): package access for engine internals`.

### Task 5.2: Define the `SFProve` facade (the only Tier 2 public API)

Documented to users today: `prove`, `ProofVerdict`, `proveSigned`, `SymbolicInt`, `SymbolicBool`, `SymbolicVerdict`, `SymbolicContext`.

- [ ] **Step 1:** Keep exactly those `public`. Everything else in `SFProve` (`MulAbstraction`, `RefineStats`, `RefineOutcome`, `proveRefining*`, `ProofFormat`) is `package`, unless Task 6.1 re-exposes one through the merged `prove`.
- [ ] **Step 2:** Run `Scripts/check-api.sh`. The report lists every symbol that left the public surface. Review it: each must be an engine type nobody outside the package should use. Paste the intended ones into `api-allowlist.txt`. Anything surprising: stop, move it back to `public`, and record why in `docs/decisions/0003-package-access-for-engines.md`.

### Task 5.3: Hide `Property.Observer` behind SPI

- [ ] In `Sources/SwiftFormal/Property.swift`, mark `Property.Observer` and `Property.custom(_:makeObserver:)` with `@_spi(Extending) public`; keep `Property.perInput(_:_:)` plain `public` (the supported way to write a custom property). Update the one or two internal users with `@_spi(Extending) import SwiftFormal`. Run `swift test --filter SwiftFormalTests`. Commit.

### Task 5.4: Gate the surface from now on

- [ ] **Step 1:** Create `Scripts/check-doc-coverage.py`:

```python
#!/usr/bin/env python3
"""Every `public` declaration in a front-door module must have a doc comment directly above it."""
import pathlib, re, sys

FRONT_DOORS = ["SwiftFormal", "SwiftFormalContracts", "SwiftFormalTesting", "SFProve"]
decl = re.compile(r"^\s*(@\w+(\(.*\))?\s+)*public\s+(?!import)")
missing = []
for module in FRONT_DOORS:
    for path in pathlib.Path("Sources", module).rglob("*.swift"):
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines):
            if decl.match(line) and "override" not in line:
                j = i - 1
                while j >= 0 and lines[j].strip().startswith("@"):
                    j -= 1
                if j < 0 or not lines[j].strip().startswith("///"):
                    missing.append(f"{path}:{i + 1}: {line.strip()[:80]}")
print("\n".join(missing) or "doc coverage ok")
sys.exit(1 if missing else 0)
```

- [ ] **Step 2:** Run it, then write the missing doc comments (summary rules: function = what it does and returns; property/type = what it *is*; initializer = what it creates; end with a period; document complexity on non-O(1) properties). Expected at plan time: tens, not hundreds, of gaps after Task 5.1 (e.g. `SwiftFormalContracts` has 6 public declarations with docs on macros but none on the re-export).
- [ ] **Step 3:** Add `Scripts/check-doc-coverage.py` to `safety-net.sh`. Commit.

---

# PHASE 6: API polish (additive, old names kept)

### Task 6.1: Collapse the `prove…` family

**Files:** Modify `Sources/SFProve/Prove.swift`, `Sources/SFProve/Refine.swift`; tests in `Tests/SFProveTests/`.

- [ ] **Step 1: Failing test**

```swift
@Test func provePicksItsStrategyWithAnArgumentNotAnotherFunctionName() throws {
    let direct = try prove(inputWidths: [8, 8]) { b, v in b.eq(b.add(v[0], v[1]), b.add(v[1], v[0])) }
    let refined = try prove(inputWidths: [8, 8], strategy: .refiningMultipliers) { b, v in
        b.eq(b.add(v[0], v[1]), b.add(v[1], v[0]))
    }
    #expect(direct == .proved)
    #expect(refined == .proved)
}
```
(`b.add`/`b.eq` are the builder operations used by existing tests; copy the exact spelling from `Tests/SFProveTests/RefineTests.swift` when writing the test.) Expected: FAIL (no `strategy:`).

- [ ] **Step 2: Implement**

```swift
public enum ProofStrategy: Sendable {
    /// Builds every circuit exactly. Best for adders, comparisons and branches.
    case exact
    /// Abstracts each multiplication and refines it only when the solver needs the exact product.
    case refiningMultipliers
}
```
Add `strategy: ProofStrategy = .exact` to `prove(...)` (placed after `conflictBudget`, labelled, defaulted, per the guideline that defaulted parameters come last and keep labels). `.refiningMultipliers` calls the existing `proveRefining` body. The old `proveRefining`, `proveMaybeRefining` become `package`; `proveRefiningDetailed` stays `package` for the stats consumers.

- [ ] **Step 4:** `swift test --filter SFProveTests` PASS. Commit.

### Task 6.2: lowerCamelCase property factories

**Files:** Modify `Sources/SwiftFormal/Properties.swift`; tests `Tests/SwiftFormalTests/SwiftFormalTests.swift`.

- [ ] **Step 1: Failing test**

```swift
@Test func propertiesReadAsDotFactories() {
    let report = verify("not", { (value: Bool) in !value }, over: .bool) {
        .deterministic()
        .injective()
        .satisfies("flips") { input, output in output == !input }
    }
    #expect(report.isProved)
}
```
Expected: FAIL (no `.deterministic()` member).

- [ ] **Step 2:** Add `extension Property { public static func deterministic() -> Property where Output: Equatable … }` and the matching `matches`, `table`, `injective`, `image(equals:)`, `image(within:)`, `roundTrip(through:)`, `satisfies` factories, each forwarding to the existing function. Keep the UpperCamelCase functions with `@available(*, deprecated, renamed: "Property.deterministic()")` (and equivalents). Move every call site in tests, README and examples to the new form in the same commit so the build stays at 0 warnings.
- [ ] **Step 3:** `swift test --filter SwiftFormalTests`; commit.

> **Decision D3 (assumption):** do this polish before 0.1.0 so the first public release has the guideline-conforming names; the deprecated aliases are removed in 0.2.

---

# PHASE 7: Tests in lanes and CI

### Task 7.1: Measure, then label the lanes

- [ ] **Step 1:** Time each test target in release and debug:

```bash
for t in SwiftFormalTests SwiftFormalTestingTests SwiftFormalContractsTests SwiftFormalMacrosTests SFGenKitTests \
         SFSATTests SFBVTests SFProveTests SFSemanticsTests SFSILTests SFVerifyKitTests SFOracleTests; do
  /usr/bin/time -p swift test --filter "$t" 2>&1 | grep -E "^real|Test run with" | tr '\n' ' '; echo " <- $t"
done | tee -a Scripts/baseline/timings.md
```
- [ ] **Step 2:** Apply Swift Testing tags to put each test in a lane (declare once in `Tests/Support/Tags.swift`):

```swift
import Testing
extension Tag {
    @Tag static var slow: Self        // seconds to minutes: large SAT instances, exhaustive sweeps
    @Tag static var oracle: Self      // spawns swiftc or native binaries
}
```
Tag with `@Suite(.tags(.slow))` or per test. Rule: **a test that takes >2 s in debug is `.slow`; one that spawns a process is `.oracle`.**

- [ ] **Step 3:** Lane commands (document in `CONTRIBUTING.md`):

| Lane | Command | Target time | When |
|---|---|---|---|
| fast | `swift test --skip .slow --skip .oracle` (use `--skip-tag` flags available in the installed toolchain; otherwise `--skip SFOracleTests`) | < 60 s | every commit, every PR |
| slow | `swift test -c release --filter "SFProveTests\|SFSILTests\|SFSATTests"` | measured in Step 1 | nightly + before release |
| oracle | `swift test -c release --filter SFOracleTests` | measured | nightly (pinned compiler only) |

### Task 7.2: Other compilers skip with a reason, they do not fail

- [ ] **Step 1: Failing test** in `Tests/SFOracleTests/CompilerPinTests.swift` (new): assert that a helper `OracleEnvironment.isPinnedCompiler` exists and returns a `Bool` without throwing, and that `Trait.requiresPinnedCompiler` is usable.

```swift
import Testing
@testable import SFSIL

@Suite struct CompilerPinTests {
    @Test func theEnvironmentCanSayWhetherTheCompilerIsPinned() {
        _ = OracleEnvironment.isPinnedCompiler
    }
}
```
- [ ] **Step 2:** Create `Tests/Support/OracleEnvironment.swift`:

```swift
import Foundation
import SFSIL
import Testing

enum OracleEnvironment {
    /// True when the installed `swiftc` is exactly one the SIL reader was validated against.
    static let isPinnedCompiler: Bool = {
        guard let toolchain = try? CompilerToolchain.current() else { return false }
        return (try? PinnedCompiler.check(toolchain: toolchain, allowUnpinned: false)) != nil
    }()
}

extension Trait where Self == ConditionTrait {
    static var requiresPinnedCompiler: Self {
        .enabled(if: OracleEnvironment.isPinnedCompiler, "needs the pinned compiler; see docs/decisions/0004-test-lanes.md")
    }
}
```
(Match the real names of the toolchain accessor in `Sources/SFSIL/CompilerPin.swift` after Task 3.1; use `grep -n "static func\|static var" Sources/SFSIL/CompilerPin.swift`.)
- [ ] **Step 3:** Apply `.requiresPinnedCompiler` to every test that runs `swiftc` and compares SIL text (the `.enabled(if: toolchain)` tests in `SILOracleTests`, `LLVMTests`, `S0BuiltinOracleTests`). Behavior on the pinned compiler is unchanged; on others the test is *skipped with a printed reason*. The fixture-grammar test in `ProofCacheTests` (line ~377) stays a failing test **on the pinned lane only** and becomes "report which compiler to re-validate" elsewhere.
- [ ] **Step 4:** Add a `docs/guides/compilers.md` table: supported compilers, how to add one (run oracle lane, review SIL grammar diffs, extend `verifiedCompilers`). Commit.

### Task 7.3: GitHub Actions

**Files:** Create `.github/workflows/ci.yml`, `nightly.yml`.

- [ ] **Step 1: `ci.yml`**

```yaml
name: CI
on: [push, pull_request]
jobs:
  fast:
    runs-on: macos-15            # use the runner image that ships the pinned Swift 6.4 toolchain; update when images change
    steps:
      - uses: actions/checkout@v4
      - run: swift --version
      - run: swift build
      - run: swift test --skip SFOracleTests
      - run: Scripts/check-test-inventory.sh
      - run: python3 Scripts/check-layering.py
      - run: python3 Scripts/check-sandboxes.py
      - run: python3 Scripts/check-doc-coverage.py
      - run: swift format lint --recursive Sources Tests Plugins
  api:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - run: Scripts/check-api.sh baseline-pre-oss
```
- [ ] **Step 2: `nightly.yml`** (cron) runs the slow and oracle lanes in release, uploads `sfverify --json` output and the metrics from Task 8.3 as artifacts.
- [ ] **Step 3:** If no runner has the required toolchain, the oracle lane runs locally and CI states so in `docs/guides/compilers.md` (honest, not hidden). The `ios` job from Task 3B.5 is added to `ci.yml`. Commit.

### Task 7.4: Formatter and lint

- [ ] Moved to **Phase 7B, Tasks Q.4 and Q.5** (formatter and linter are now two tools with separate jobs). Nothing to do here.

---

# PHASE 7B: The quality bar (formal verification, type-driven design, tests, linters, formatters)

**Goal:** a verification library must hold itself to a higher bar than ordinary code. This phase answers five questions with a gate for each: *Does it verify itself? Do the types forbid wrong states? Is the test suite able to catch a wrong "proved"? Is style automatic? Does quality only go up?*

**Rule for the phase (PC-5):** every gate is a **ratchet**. Record today's number in `Scripts/baseline/quality.json`; CI fails only if a number gets worse; improving it requires updating the file in the same PR. New and touched files get the strict rules; old findings do not block contributors.

| Pillar | Tasks | Gate (CI) |
|---|---|---|
| Formal verification | Q.1, Q.2, Q.6 | soundness zoo + differential tests + self-verification green; trusted-code size ratchet |
| Type-driven design | Q.3 | compiler flags on; API diff reviewed |
| Tests | Q.2, Q.7 | coverage ratchet per module; seeds printed; flake policy |
| Linters | Q.5 | SwiftLint, new-code strict, baseline for old |
| Formatters | Q.4 | `swift format lint` clean |

### Task Q.1: Dogfood: SwiftFormal verifies itself

A verifier that is not used on its own code is a weak advertisement. Use the three tools on the project's own small, pure functions. Each is a new test, no production change.

**Files:** Create `Tests/SelfVerificationTests/` (new test target depending on `SwiftFormal`, `SwiftFormalTesting`, `SFProve`, `SFBV`, `SFCNF`).

- [ ] **Step 1: Inventory candidates** (read-only): list pure functions with small inputs in `SFBV` (bit-vector adders, shifts, comparators), `SFCNF` (literal/variable encoding helpers), `Domain` (cardinality, enumeration). Write them into `Tests/SelfVerificationTests/CANDIDATES.md` (path, one-line property).
- [ ] **Step 2: Walk (Tier 1)**: for each small-domain function, state the property and `expectProved` it. Examples of properties (verify they hold; they are the *spec*, not a guess): `Domain.count == Array(domain).count`; variable↔literal encode/decode round trip; a bit-vector 8-bit `add` circuit equals Swift's `&+` for all 65,536 pairs (differential against the language, not against itself).
- [ ] **Step 3: Prove (Tier 2)**: for wider ones (32-bit), use `SFProve` to prove the circuit equals the Swift operator, and require that the independent checker accepted the proof (see Q.6).
- [ ] **Step 4: Scan (Tier 3)**: run `sfverify` over the package's own pure helpers as an *example* in `docs/guides/dogfooding.md`; record what is `proved`, `bounded`, `unsupported` honestly, including failures.
- [ ] **Step 5:** Mark these tests `.fast` where < 2 s, otherwise `.slow`. Commit. **Honesty rule:** if a self-check finds a real bug, it is a P0 per the soundness policy (Task 10.1); do not weaken the property to make it pass.

### Task Q.2: The soundness zoo, differential tests and fuzzing

The one failure that matters is a **false "proved"**. Test for it directly.

**Files:** Create `Tests/SoundnessZooTests/`, `Tests/SFSATTests/DifferentialTests.swift`, `Tests/SFSILTests/FuzzTests.swift`.

- [ ] **Step 1: Known-bad zoo.** A table of deliberately wrong functions, each paired with the *only acceptable* verdict:

```swift
struct ZooCase: Sendable {
    let name: String
    let expected: Expected          // .counterexample, .notProved (bounded or unsupported), never .proved
}
```
Seed it with the classic traps: off-by-one at `Int.max`/`Int.min`, signed overflow, `abs(Int.min)`, shift by ≥ width, unsigned wraparound, NaN and `-0.0` comparisons, empty-collection edge, a property true on all but one input in a large domain. For every case run Tools Walk, Prove and Scan where each applies. **Pass = the tool never says `proved`.** Adding a case is the standard way to fix a soundness report (Task 10.1).
- [ ] **Step 2: Differential SAT test.** Generate random small CNFs with a fixed, printed seed; compare `Solver` against a 30-line brute-force enumerator (≤ 12 variables): same SAT/UNSAT answer; every SAT model satisfies all clauses; every UNSAT proof is accepted by `SFCheck`. Seed list: `[1, 2, 3, … 200]` in the fast lane, 20,000 in the nightly lane.
- [ ] **Step 3: Metamorphic checks** (cheap, powerful): permuting clause order, renaming variables, and duplicating clauses must not change SAT/UNSAT. Add each as a parameterized Swift Testing test (`@Test(arguments:)`).
- [ ] **Step 4: Parser fuzz (deterministic).** Feed `SILParser` and `LLVMParser` (a) every committed fixture truncated at every 7th byte, (b) mutations (byte flip, line delete, line duplicate) from a fixed seed. Pass = no crash, no hang (per-case timeout), and the result is either a parse or a typed error. Failures found become fixtures.
- [ ] **Step 5 (optional, nightly only):** mutation testing with a Swift mutation tool (for example Muter) on `SFCheck` and `SFSAT` **only**; report the surviving mutants, no gate yet (record the score as a ratchet after one run). Not run per PR: too slow, and not an installed dependency.
- [ ] Commit per step. None of this changes production code.

### Task Q.3: Type-driven design, compiler-guided and additive

Principle: **make illegal states unrepresentable, and let the compiler find the work.** Every change here either (a) is a compiler flag or (b) adds a type. Each goes through `Scripts/check-api.sh`; intended API changes are listed in the allowlist and `CHANGELOG.md`.

- [ ] **Step 1: Compiler flags, one at a time, per module.** In `Package.swift` define once:

```swift
let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),          // `any P` written out: no accidental boxing
    .enableUpcomingFeature("InternalImportsByDefault"),// imports are not re-exported by accident
    .enableUpcomingFeature("MemberImportVisibility"),  // an extension member needs its module imported
]
```
Apply to `SwiftFormal` first, run `swift build`, fix every error the compiler lists (mechanical), run `Scripts/safety-net.sh`, commit; then the next module. Stop a module's adoption if a fix needs a behavior change; record why. Language mode stays Swift 6 (strict concurrency is already complete there); confirm with `swift build -v | grep -c swift-6` or the `swiftLanguageModes` setting, and **do not lower it**.
- [ ] **Step 2: Warnings are errors in CI only** (`swift build -Xswiftc -warnings-as-errors`). Not in `Package.swift`: a consumer's newer compiler must never fail on our warnings. Baseline today is 0 warnings, so this locks it in.
- [ ] **Step 3: Audit table (read the code, then decide; do not assume).** For each row, open the named file, decide yes/no, write the decision in `docs/decisions/0007-type-driven-audit.md`:

| Question | Where to look | Typical fix if "yes" |
|---|---|---|
| Can `Report`/verdict values hold a combination that makes no sense (for example a counterexample on a `proved`, an optional that is always set for one case)? | `Sources/SwiftFormal/Report.swift`, `SFVerifyKit/Report.swift` | move data into the enum case payload so the case owns what it needs |
| Can anyone outside the engine construct a "proved" result? | `ProofVerdict`, `SFVerifyKit.Status` | `package init` + a `ProofCertificate` value that only the engine/checker creates; the Gate plugin reads it, cannot forge it |
| Raw `Int` for things that are different kinds (variable, literal, clause index, width, budget)? | `SFCNF`, `SFSAT`, `SFBV` | small `struct Variable { var rawValue: Int }` style newtypes with `@inlinable` accessors; **measure before and after** with the Phase 8 metrics (must be identical conflict counts) |
| Stringly-typed identities (compiler version, digests, cache keys)? | `Sources/SFSIL/CompilerPin.swift`, `ProofCache*.swift` | `ToolchainFingerprint`, `Digest` types validated once at the boundary ("parse, don't validate") |
| Untyped `throws` where the error set is closed? | engine modules | Swift 6 typed throws `throws(SolveError)`; keep public API `throws` unless the set is part of the contract |
| Public protocols and types that are not meant for outside conformance or subclassing? | all public types | `final`, or `package`; document "not for conformance" |
| Mutable state shared across tasks? | `ProofCache`, global caches | `actor`, or `struct` + explicit `Sendable`; run the TSan lane (Q.6 Step 3) |
| Domain-size and budget arguments that can be zero or negative? | `Domain`, `verify(…budget:)` | a `Budget` type with a validated initializer, or a `precondition` with a documented message |

- [ ] **Step 4:** Implement only the "yes" rows, **one commit each**, each green on the safety net. If a row would change a verdict, JSON value or conflict count, stop and write why in the decision record instead of doing it.

### Task Q.4: Formatter: `swift-format` (Apple)

Why this one: ships with the toolchain (`swift format`), so it always matches the compiler in the pinned lane; no extra version to manage.

- [ ] **Step 1:** Create `.swift-format` (version 1, `lineLength` 140, 4-space indent, ordered imports, `AllPublicDeclarationsHaveDocumentation` **off** here; documentation coverage is gated by `Scripts/check-doc-coverage.py` so there is one owner for that rule).
- [ ] **Step 2: One-time formatting commit** containing **only** formatting: `swift format --in-place --recursive Sources Tests Plugins Package.swift`. Gate: `Scripts/safety-net.sh` green and `git diff -w --stat` is small. Record the commit hash in `.git-blame-ignore-revs` and tell contributors to run `git config blame.ignoreRevsFile .git-blame-ignore-revs`. If the diff touches more than ~40% of lines, instead format only new and touched files and record why.
- [ ] **Step 3:** CI: `swift format lint --strict --recursive Sources Tests Plugins Package.swift`. Add `.editorconfig` (indent, final newline, UTF-8) for non-Swift files.
- [ ] **Step 4:** `Scripts/install-hooks.sh` installs an optional `pre-commit` hook that runs `swift format lint` and SwiftLint on staged files only. Optional, never required: CI is the authority.

### Task Q.5: Linter: SwiftLint (semantics only, never whitespace)

**Contradiction to avoid:** two tools that both want to own whitespace fight forever. **Separation:** `swift-format` owns layout; SwiftLint owns meaning. SwiftLint's layout rules (`line_length`, `trailing_whitespace`, `vertical_whitespace`, `opening_brace`, `indentation`-style rules, `trailing_comma`, `sorted_imports`) are disabled in config.

- [ ] **Step 1:** Create `.swiftlint.yml`:

```yaml
included: [Sources, Tests, Plugins]
excluded: [archive, .build, Examples/*/.build]
disabled_rules: [line_length, trailing_whitespace, vertical_whitespace, opening_brace, trailing_comma, sorted_imports, todo]
opt_in_rules:
  - force_unwrapping
  - force_cast
  - force_try
  - implicitly_unwrapped_optional
  - explicit_acl            # only for Sources (see per-path config); every declaration states its access
  - missing_docs            # public/package API must be documented
  - unused_import
  - unused_declaration
  - redundant_nil_coalescing
  - empty_count
  - first_where
  - contains_over_first_not_nil
  - discouraged_optional_boolean
  - fatal_error_message
  - overridden_super_call
  - override_in_extension
  - private_over_fileprivate
  - sorted_first_last
  - reduce_into
custom_rules:
  no_print_in_library:
    regex: '\bprint\('
    included: 'Sources/(SwiftFormal|SFBV|SFCNF|SFSAT|SFCheck|SFProve)/'
    message: "Library code must not print. Return data; let the CLI print."
    severity: error
  no_unsafe_without_comment:
    regex: '\b(unsafeBitCast|withUnsafe\w+|Unsafe(Mutable)?(Buffer)?Pointer)\b'
    message: "Unsafe API: add a one-line `// SAFETY:` comment and record it in quality.json (ratchet)."
    severity: warning
```
(All rule names above were checked against SwiftLint 0.63.2 (`swiftlint rules`), and `--baseline`/`--write-baseline` exist there. Re-check if the installed version differs. Tests may relax `force_unwrapping`/`force_try` via a nested `Tests/.swiftlint.yml`.)
- [ ] **Step 2: Baseline, do not mass-fix.** `swiftlint lint --write-baseline Scripts/baseline/swiftlint-baseline.json` then CI runs `swiftlint lint --baseline Scripts/baseline/swiftlint-baseline.json --strict`: old findings are ignored, new ones fail (PC-5). Fixing old findings is welcome in small, separate PRs that regenerate the baseline (the count can only go down: `Scripts/check-ratchet.py` compares the baseline's finding count with `quality.json`).
- [ ] **Step 3:** SwiftLint is **not** added to `Package.swift` (a plugin dependency would be resolved by every consumer). It runs from CI (`brew install swiftlint` or the official action) and the optional hook.
- [ ] **Step 4:** Safety: run the safety net after any lint-driven code change; lint fixes are separate commits from format commits.

### Task Q.6: Trusted core, sanitizers, coverage

- [ ] **Step 1: Lock the independence of the checker (PC-6).** Extend `Scripts/check-layering.py`: `SFCheck` may import only the standard library and `Foundation`; it must **not** import `SFSAT`, `SFCNF`, `SFProve`, `SFBV`. Add a test that every UNSAT result returned through `SFProve` goes through `SFCheck` (a counter on the checker, or a `proofChecked` flag asserted in `SelfVerificationTests`).
- [ ] **Step 2: Trusted-code ratchet.** `Scripts/measure-trust.py` counts non-blank, non-comment lines in `SFCheck` (and lists the other trusted pieces: compiler pin, SIL semantic model) into `quality.json`. CI fails if `SFCheck` grows by more than 10% without an updated baseline and a note in `docs/TRUST.md`. The point: the part users must trust stays small and visible.
- [ ] **Step 3: Sanitizers (nightly).** `swift test --sanitize=address` and `--sanitize=thread` on the fast lane. `Unsafe*` usage is counted by `grep -rn "Unsafe" Sources | wc -l` into `quality.json` as a ratchet.
- [ ] **Step 4: Coverage ratchet.** `swift test --enable-code-coverage` then `xcrun llvm-cov report` per module; store percentages in `quality.json`. Rule: **a module's coverage may not fall**; the trusted modules (`SFCheck`, `SFSAT`, `SFCNF`, `SFBV`, `SwiftFormal`) also have a floor chosen *from the measured value*, not from a round number. Do not chase 100%; do not count generated or macro code.

### Task Q.7: Test conventions (written down, then enforced where cheap)

- [ ] Add `docs/TESTING.md`:
  - Swift Testing only (`@Test`, `#expect`, `#require`), tags `.slow`/`.oracle` (Task 7.1); XCTest only where the macro-testing support requires it (`SwiftFormalMacrosTests`).
  - Name `testing what → condition → result`, for example `solver_unsatCore_isAcceptedByChecker`.
  - Parameterize instead of copy-paste (`@Test(arguments:)`).
  - Any randomness uses a seed that is **printed on failure** and replayable with `SF_SEED=…`.
  - A bug fix comes with a test that fails without the fix; a soundness fix adds a zoo case (Q.2).
  - Flaky test policy: quarantine with `.disabled("flaky: <issue link>")` within 24 h and open an issue; never retry-until-green.
- [ ] Add `Scripts/check-ratchet.py` to CI (reads `quality.json`: warnings, lint findings, unsafe count, trusted lines, per-module coverage). Commit.

### Phase 7B exit check

- [ ] `swift build -Xswiftc -warnings-as-errors`, `swift format lint --strict …`, `swiftlint lint --baseline … --strict`, `python3 Scripts/check-ratchet.py` all pass.
- [ ] `Scripts/safety-net.sh` green: no verdict, JSON value or test lost (Phase 0 guards).
- [ ] Soundness zoo: **zero** cases where a tool says `proved`.
- [ ] Add the new jobs to `.github/workflows/ci.yml` (`lint`, `ratchet`) and `nightly.yml` (sanitizers, 20,000-seed differential, coverage, mutation report).

---

# PHASE 8: Measurability

### Task 8.1: Solver statistics (additive)

**Files:** Modify `Sources/SFSAT/Solver.swift`, `Sources/SFProve/Prove.swift`; tests `Tests/SFSATTests/SolverTests.swift`.

- [ ] **Step 1: Failing test**

```swift
@Test func solverReportsWhatItSpent() {
    let cnf = pigeonholeCNF(holes: 4)              // existing helper used by the UNSAT tests; reuse its name
    let result = Solver.solveLRAT(cnf, conflictBudget: 100_000)
    guard case .unsat = result.outcome else { Issue.record("expected UNSAT"); return }
    #expect(result.stats.conflicts > 0)
    #expect(result.stats.variables == cnf.variableCount)
    #expect(result.stats.clauses == cnf.clauses.count)
}
```
(Adapt to the real return shape of `solveLRAT`: today it returns the outcome enum directly. The task is to wrap it as `SolveResult { outcome, stats }` and keep `solveLRAT` as an outcome-only shim, so existing tests do not change.)
- [ ] **Step 2:** Implement `package struct SolveStats: Sendable, Equatable { var conflicts: Int; var variables: Int; var clauses: Int }`. The loop already has `conflicts` (line ~721). Return it.
- [ ] **Step 3:** Thread `stats` into `ScanReport` per function as `solverConflicts`, `cnfVariables`, `cnfClauses` (new optional fields, so existing JSON consumers keep working). Run `Scripts/check-golden.sh`: it will now differ by the new keys. **Re-record the golden once** and review the diff: only additions allowed. Commit.

### Task 8.2: One stable JSON schema

- [ ] Add `schemaVersion: 1` to `ScanReport` and document every field in `docs/guides/scan.md`. Add a decoding test: a frozen sample JSON from the baseline decodes into `ScanReport` (guards against accidental key renames). Commit.

### Task 8.3: Performance baseline by deterministic metrics, not wall clock

**Why (TRIZ principle 23 Feedback, principle 10):** wall time is noisy on shared machines (the existing tests already say "timings noisy"). Conflicts and clause counts are exact.

**Files:** Create `Scripts/metrics.py`, `Scripts/baseline/metrics.json`; create `Examples/Metrics/` with 6 small kernels (adder, clamp, discount, popcount loop, index kernel, a multiply case that stays `undecided` by design).

- [ ] **Step 1:** `Scripts/metrics.py` runs `sfverify --json` on `Examples/Metrics`, extracts `{function: {status, solverConflicts, cnfClauses}}`, writes JSON. `--record` writes the baseline; default mode compares.
- [ ] **Step 2:** Compare rules: status must be identical; conflicts and clauses may change by at most +10% (otherwise CI fails with the function name and the numbers). Wall time is printed, never compared.
- [ ] **Step 3:** Record the baseline, add to nightly. Document in `docs/PERFORMANCE.md`: what is measured, how to read it, the known hard cases (wide multiplication/division, copied from README "Limits").

### Task 8.4: Scaling notes where limits are known

- [ ] `docs/PERFORMANCE.md` section "What scales": domain size (Walk: budget 1,000,000 evaluations by default, seeded sample beyond), SAT width (adders fast; 16-bit double multiply undecided at 100,000 conflicts; numbers already measured in the README), proof cache (cold vs warm timings already printed by `ProofCacheTests`). Copy the existing measured numbers with their dates; do not invent new ones.

---

# PHASE 9: Documentation people actually read

### Task 9.1: README (one screen, analogy first)

- [ ] Final shape: (1) the one-sentence analogy, (2) the 3-verdict table, (3) a 10-line example per tool (Walk, Prove, Scan) taken from `Examples/` so they compile in CI, (4) install snippet, (5) "How much to trust it" link to `docs/TRUST.md`, (6) "Contributing" link. Target: under 150 lines.

### Task 9.2: Runnable examples that CI builds

- [ ] Create `Examples/Walk` (a tiny package with an enum rule and `@Test` using `expectProved`), `Examples/Prove` (the discount example with `proveSigned`), keep `Examples/GatedPackage`. Add a CI step `swift build --package-path Examples/Walk` for each. An example that stops compiling fails CI, so the README cannot rot.

### Task 9.3: DocC

- [ ] Add dependency `.package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")` **only when generating docs** (guard with an environment variable in `Package.swift` so users do not fetch it):

```swift
if ProcessInfo.processInfo.environment["SWIFTFORMAL_DOCS"] != nil {
    package.dependencies.append(.package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"))
}
```
(`import Foundation` at the top of `Package.swift`.)
- [ ] Create `Sources/SwiftFormal/SwiftFormal.docc/SwiftFormal.md` (landing page = the Inspector analogy, topic groups: Describing inputs, Stating properties, Reading verdicts, Contracts, Testing) and equivalents for `SFProve`. Build: `SWIFTFORMAL_DOCS=1 swift package generate-documentation --target SwiftFormal --warnings-as-errors`. Expected: no warnings. Add `.spi.yml` (`builder: configs: - documentation_targets: [SwiftFormal, SwiftFormalContracts, SwiftFormalTesting, SFProve]`) for Swift Package Index hosting.

### Task 9.4: `ARCHITECTURE.md`

- [ ] One page: the diagram from the verifier design spec §5 updated to the real modules; the layering table (section 4.2); "how a Scan request flows" (source → `swiftc` → SIL → `SILParser` → `SILEncoder` → `CNFBuilder` → `Solver` → `LRATChecker` → report); "where to add a SIL instruction", "where to add a Domain combinator", "where to add a property" (three short recipes with file names and the test to add).

### Task 9.5: Link and snippet checks

- [ ] Add a `Scripts/check-links.py` that fails on broken relative links in `*.md` (moved docs will break some; fix them here). Add to CI. Commit.

---

# PHASE 10: Community files and the 0.1.0 release

### Task 10.1: Legal and community

> **Decision D4 (assumption, change if you disagree):** license **Apache-2.0** (the Swift ecosystem norm; includes a patent grant, which matters for a verification library). MIT is a one-line swap. Nothing else in the plan depends on it. The owner must confirm before publishing.

- [ ] Create `LICENSE`, `CONTRIBUTING.md` (setup, the three lanes, the safety net, naming guideline summary, "add a test that would fail without your change", commit style), `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1), `SECURITY.md` (verification tools: soundness bugs are security-relevant; how to report privately), `.github/ISSUE_TEMPLATE/{bug,soundness,feature}.yml` (the **soundness** template asks for: tool, verdict given, why it is wrong, minimal reproduction), `.github/pull_request_template.md` (checklist: lane results, API diff reviewed, docs updated).
- [ ] Add a `docs/decisions/0006-soundness-policy.md`: a false `proved` is a P0 bug; fix gets a regression test in the oracle lane.

### Task 10.2: CHANGELOG and versioning

- [ ] `CHANGELOG.md` (Keep a Changelog format). First entry `0.1.0` lists: the three tools, the verdict words, the renames from Phase 4 and 6 (old → new table), the package-access change. Versioning: SemVer; pre-1.0 minor versions may break, always listed.

### Task 10.3: Release checklist (copy into `docs/RELEASING.md`)

- [ ] `Scripts/safety-net.sh` green on a clean clone (`git clone . /tmp/sf-clean && cd /tmp/sf-clean && Scripts/safety-net.sh`)
- [ ] release-mode slow and oracle lanes pass on the pinned compiler; numbers added to `timings.md`
- [ ] metrics baseline unchanged or consciously re-recorded with a note
- [ ] `SWIFTFORMAL_DOCS=1 swift package generate-documentation --warnings-as-errors` clean
- [ ] every example builds; README snippets are copied from them
- [ ] API diff vs `baseline-pre-oss` reviewed and fully explained by `CHANGELOG.md`
- [ ] LICENSE confirmed by the owner; no secrets or private paths (`grep -rn "/Users/" . --include='*.md' --include='*.swift'` is empty except `archive/`)
- [ ] tag `0.1.0`

---

## 7. Regression-risk register

| Risk | Where | Guard |
|---|---|---|
| A rename silently changes JSON output | Phase 4 | `Scripts/check-golden.sh` (timing-stripped `sfverify --json` equals baseline) |
| A test is lost when moving files | Phase 3.2 | `Scripts/check-test-inventory.sh` (names without module prefix) |
| A public symbol disappears by accident | Phase 5 | `Scripts/check-api.sh` + allowlist reviewed by a human |
| A test target no longer finds a helper | Phase 3.2, 5 | `swift build --build-tests` before every commit |
| `package` access breaks the Build-Gate plugin or CLI | Phase 5 | golden check builds and runs `sfverify` through `Examples/GatedPackage`; run `swift build` inside `Examples/GatedPackage` once per phase |
| Solver or encoder behavior changes while "just adding stats" | Phase 8.1 | the stats change only *returns* a value already computed; slow lane run before and after; metrics must be identical |
| Skipping tests hides a real failure on a non-pinned compiler | Phase 7.2 | the skip prints its reason; the pinned lane is mandatory before release |
| Formatting commit hides a logic change | Phase 7B Q.4 | formatting-only commit; safety net must be green; reviewers use `git diff -w`; hash in `.git-blame-ignore-revs` |
| Type-driven change (newtypes, typed throws, flags) alters behavior or performance | Phase 7B Q.3 | one commit each; API diff; golden check; conflict and clause counts identical (Phase 8 metrics); stop and record rather than force it |
| Strict gates scare away contributors | Phase 7B | ratchets: baselines for old code, strict only for new code; hook is optional, CI is the authority |
| Linter and formatter fight | Phase 7B Q.5 | SwiftLint layout rules disabled; `swift-format` owns layout |
| Lint tool pulled into consumers' builds | Phase 7B Q.5 | SwiftLint and format run in CI only, never as `Package.swift` dependencies |
| New self-verification test finds a real bug | Phase 7B Q.1 | counts as a win and a P0 under the soundness policy; the property is never weakened to pass |
| Moving `archive/` breaks a test fixture | Phase 1.1 | grep step before the move; fast lane after |
| A carve-out (`SFToolchain`, `SFProcess`) hides a behavior change or makes a dependency cycle | Phase 3B.4 | go/no-go test per row; moves only; separate commit; golden + inventory + API diff; stop if any edit beyond imports/access is needed |
| Package-green is mistaken for product-green (a body change in `SFSAT` passes its own tests but breaks `SFProve` or a golden verdict) | Phase 3B.2 | consumer graph in the registry; `--connect` and `--affected` run real consumers; Step 3 proves the loop catches a body-only change |
| iOS support claimed but not built | Phase 3B.5 | `ios` CI job builds every registry entry that lists iOS; docs state Scan is macOS-only |
| A fake stands in for the real compiler in a "connected" check | Phase 3B.4 (`SFProcess`) | fake only in unit tests; oracle lane and `--connect` use the real runner |
| Shared-types module (`SFCNF`) becomes a dumping ground | Phase 3B.4 | 150-line cap checked by `check-layering.py` |

## 8. Definition of done (what "good shape" means here)

1. A newcomer can state what the library does in one sentence after reading the first 10 lines of the README (the Inspector).
2. `import SwiftFormal; import SFProve` compiles without ambiguity. The word `prove` means one thing.
3. `swift package diagnose-api-breaking-changes` shows only listed, explained changes; the public surface is the five front doors.
4. Fast lane < 60 s; every module has its own test target; a failing slow/oracle test names the tool and the compiler.
5. Performance is tracked by exact numbers (conflicts, clauses) with a baseline and a +10% alarm.
6. Docs build without warnings; every example in the README compiles in CI.
7. A contributor finds LICENSE, CONTRIBUTING, issue templates, a soundness-bug policy, and a one-command check (`Scripts/safety-net.sh`).
8. No verdict, no JSON field value, and no test from `baseline-pre-oss` was lost or changed (except where `CHANGELOG.md` says so).
9. **Verification bar:** the soundness zoo has zero false `proved`; SAT is differential-tested against brute force; every UNSAT proof is accepted by the independent checker; SwiftFormal verifies some of its own code and `docs/guides/dogfooding.md` says honestly what was and was not proved.
10. **Type-driven bar:** `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility` on in every module that can take them; the type-driven audit (`0007`) has a decision per row; nobody outside the engine can construct a `proved`.
11. **Style bar:** `swift format lint --strict`, `swiftlint --baseline --strict`, and `-warnings-as-errors` are green in CI; coverage, lint findings, unsafe count and trusted-code size cannot get worse.
12. **Sandbox bar:** every target is a registered sandbox with a card, a one-command fast loop, and a named real-consumer loop; `Scripts/sandbox.py --affected <ref>` tells a contributor exactly what to run; the platform table in `docs/guides/platforms.md` equals what CI builds (iOS included); no sandbox is a copy of host code.

## 9. Open questions for the owner (defaults chosen, change any)

| # | Question | Default used above |
|---|---|---|
| D1 | Keep `SFVerifyKit` / `SFGenKit` as public library products for now? | yes, demote after one release |
| D2 | One shared verdict *type* across tools? | **no**: same words, tool-specific type names, evidence line in every report (cheaper, no new module, no coupling of `SwiftFormal` to the engines) |
| D3 | Rename property factories before 0.1.0? | yes, old names deprecated |
| D4 | License | Apache-2.0 |
| D5 | Which runner provides the pinned Swift 6.4 toolchain? | `macos-15` in the plan; replace with whatever has it, or self-hosted |
| D6 | Keep the large experiment evidence | outside git as a tarball, summaries inside `archive/` |
| D7 | Formatter and linter | `swift-format` (formatting) + SwiftLint (meaning only), both in CI, neither a package dependency; old lint findings baselined |
| D8 | Type-driven changes (newtypes, typed throws, `ProofCertificate`) before 0.1.0? | only rows of the audit that keep verdicts and metrics identical; others deferred to 0.2 with a note |
| D9 | One `Package.swift` with many sandboxes, or several packages? | **one** (keeps `package` access and a tiny public surface); a standalone SAT-kernel package only on demand, as public API |
| D10 | iOS scope for the Scan modules | macOS-only and documented (default); optional `SFProcess` carve-out would let `SFSIL`/`SFSemantics` build on iOS |
| D11 | What to do with `SFLLVM` (no production consumer) | decide in ADR 0008: wire into `sfverify` or mark experimental; until then its card says so |

---

## Self-review

**Spec coverage.** *Easy to maintain / navigate* → Phases 1, 3, 9.4. *Reason about / mental model / analogy* → section 3, Phase 2. *Best practices, Apple/Swift guidelines* → Phases 4, 5, 6 (API Design Guidelines audit table), 7.4, 9.3. *Architectural patterns* → section 4.2 layering with enforcement (3.4). *Open-source ready* → Phase 10, 1, 7.3. *Scalable* → layering, test lanes, per-module targets, `docs/PERFORMANCE.md`. *Measurable* → Phase 8. *Testable* → Phases 3.2, 7, 7B. *Modularization / sandbox-driven development* → Phase 3B (registry, loops, cards, evidence-based carve-outs, platform matrix). *Formal verification, type-driven design, tests, linters, formatters* → Phase 7B (Q.1 to Q.7) with ratchets. *Performant* → Phase 8 (measure first; no engine changes proposed). *No regressions* → Phase 0 plus register in section 7. *Triz* → section 2 with matrix cells, separations and the Level-3 stop. All points map to a task.

**Placeholders.** Three tasks ask the implementer to copy a real identifier at the moment of writing (builder method spelling in 6.1, solver result shape in 8.1, toolchain accessor name in 7.2). Each states exactly where to look and what the shape must be; none leaves behavior undefined.

**Type consistency.** New names used consistently: `ProofVerdict`, `ScanReport`, `ScanCounterexample`, `ScanStatus`, `ProofStrategy`, `SolveStats`, `OracleEnvironment`, `expectProved`, `Property.deterministic()` etc. Phase 7B adds `ProofCertificate`, `ToolchainFingerprint`, `Budget` (all *candidates*, only if the audit says yes).
