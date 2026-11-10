# SwiftFormal First Milestone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Keep execution inline: this milestone is a single compiler-extraction investigation, not independent work for multiple agents.

**Goal:** Establish whether a narrow, compiler-resolved view of real Swift functions exposes enough information to build a trustworthy first verifier.

**Architecture:** Keep the existing model DSL prototype unchanged. In a separate experiment, compile a fixed set of real functions, preserve the compiler artifacts, and run independent executable checks of their behavior. Use the resulting operation inventory to accept or reject an extraction approach before implementing a translator or macros.

**Tech Stack:** Installed Swift compiler, existing Swift Testing suite, existing Lean installation, Python 3 standard library for process isolation and artifact collection. No new package dependencies.

**Execution update:** The user subsequently authorized experimental version
0.0.1. Its implementation and deviations are recorded in
[compiler bridge results](../../../archive/experiments/compiler-bridge/RESULTS.md).
The checklist below preserves the original plan rather than tracking current
status. Stage 2 is now split into smaller learning versions, beginning with the
[0.0.2 extraction experiment](2026-11-03-swiftformal-0.0.2-experiment.md);
the five-function proof plan is deferred until extraction has evidence.

---

## What this plan does and does not authorize

This is the detailed plan for the first feasibility milestone, followed by the
product roadmap. It is not a request to implement every subsystem at once.

The original planning task created this document only. Do not initialize a Git
repository, install dependencies, add
compiler flags to an app, or change the prototype merely to prepare this plan.
When implementation is authorized, check the project instructions and worktree
state first. Commit coherent tasks only if a Git repository is already available
or the user separately authorizes creating one.

The existing prototype proves a separately written Lean model and tests selected
Swift implementations against it. It does not prove arbitrary Swift functions.
The first experiment must not receive a "Swift verified" label.

## Product decisions carried into this plan

- Product surface: contracts next to real functions; a proposed `@Contract`
  marker, not a promise of finalized macro syntax.
- Verification concerns the actual compiler-resolved implementation, not a
  handwritten replacement supplied by AI.
- Swift-to-model translation and the Swift compiler remain trusted components.
- Proof statements are generated mechanically. AI may fill authorized proof
  bodies but cannot weaken the contract, change exclusions, or omit obligations.
- Build checks must distinguish a proof, a counterexample, missing proof,
  unsupported code, timeout/unknown, and tool failure.
- Lean/solvers/proof agents are development-only tools outside the app link graph.
- Production validation remains whenever a proof relies on its input conditions.
- Begin with checked scalar arithmetic and branches; expand only after evidence.
- Ordinary builds replay saved proofs; AI repair is a separate, bounded action.
- The previous report's speculative week estimates are not delivery commitments.

## Roadmap and decision gates

| Stage | Deliverable | Gate before continuing |
|---|---|---|
| 1. Compiler bridge | The bounded experiment below | Can identify exact types, operations, control flow, checked-vs-wrapping behavior, dependencies, and source locations under a pinned configuration |
| 2. Small working verifier | Five pure functions checked from actual bodies against approved contracts | Correct implementations pass; business-rule and overflow defects do not; unsupported code and missing tools fail closed |
| 3. Developer integration | Contract annotation, structured/source diagnostics, package command, one real iOS project | One verified-build action runs the required checks; release contains no verification machinery |
| 4. Value pilot | 30-50 real functions, held-out bugs, compiler/tests baseline | Added assurance/defect detection justifies human time and CI cost; exclusions and failures are fully counted |
| 5. Evidence-led expansion | Small structs/enums and pure state transitions first | Each addition addresses measured pilot gaps without weakening the checking policy |

Stages 2-5 require their own bounded implementation plans after earlier results
resolve their technical choices. Do not guess a SIL grammar or type-resolution
API in advance to make the roadmap look more complete.

### Definition of the stage-2 slice

Start with `Int64`, `Bool`, immutable locals, branches, returns, checked
addition/subtraction, and comparisons. Add `UInt64` after validating signed
semantics; initially reject `Int`, wrapping arithmetic, multiplication/division,
collections, effects, recursion, loops, and async code.

This is narrower than the earlier feature wishlist deliberately. Subtraction
must preserve negatives and detect overflow, rather than copy Lean `Nat`.

The five intended functions are a clamped discount, increment under an upper
bound, bounded counter decrement, interval membership, and a scalar cap. Calls
such as `min`/`max` require exact resolved semantics; use explicit branches until
that dependency path is established.

For checked arithmetic, first try mathematical integers plus explicit
machine-range obligations and ordinary Lean arithmetic automation. Do not add a
mandatory Z3 backend or AI service before measuring a need.

## Stage 1 file map

All paths below are relative to `SwiftFormal/`.

| File | Responsibility |
|---|---|
| `prototype/` | Existing model-only baseline; no modifications |
| `experiments/compiler-bridge/Fixture.swift` | Good, wrong, and unsupported actual Swift functions |
| `experiments/compiler-bridge/main.swift` | Small executable entry point for isolated behavior checks |
| `experiments/compiler-bridge/collect.py` | Capture configuration, compile representations, and run known cases |
| `experiments/compiler-bridge/RESULTS.md` | Observed operation inventory, limits, and continue/stop decision |
| `experiments/compiler-bridge/.gitignore` | Ignore generated `.artifacts/` only |

The experiment uses no Swift package and no macro package. That keeps compiler
feasibility separate from annotation ergonomics.

## Task 1: Preserve and run the existing baseline

**Files:** Read `prototype/Package.swift`,
`prototype/Tests/FormalSpecTests/FormalSpecTests.swift`, and
`prototype/Sources/Demo/main.swift`. Modify none.

- [ ] **Step 1: Record tool configuration and worktree state.**

  Run from `SwiftFormal/`:

  ```bash
  pwd
  git rev-parse --show-toplevel
  xcrun swiftc --version
  xcrun swiftc -print-target-info
  ```

  A Git error is expected if the folder remains outside a repository; it is not
  permission to initialize one. If a repository exists, inspect `git status
  --short` and preserve changes not made by this work.

- [ ] **Step 2: Run the existing tests.**

  ```bash
  cd prototype && swift test
  ```

  Expected: the three existing tests pass. A pre-existing failure is a recorded
  baseline blocker, not evidence against the new compiler experiment.

- [ ] **Step 3: Run the existing model demonstration with Lean installed.**

  ```bash
  "$HOME/.elan/bin/lean" --version
  cd prototype && swift run formal-demo
  ```

  Expected: a naive-code mismatch, agreement for the fixed implementation on
  sampled inputs, and acceptance of the model theorems. Explicitly record that
  these are model proofs, not implementation-equivalence proofs. The demo's
  exit behavior alone is not a sufficient verification gate.

## Task 2: Add the minimal executable fixture

**Create:** `experiments/compiler-bridge/Fixture.swift`,
`experiments/compiler-bridge/main.swift`,
`experiments/compiler-bridge/.gitignore`.

- [ ] **Step 1: Write `Fixture.swift` exactly as follows.**

  ```swift
  public func clampedDiscount(_ subtotal: Int64, _ discount: Int64) -> Int64 {
      if discount > subtotal {
          return 0
      }
      return subtotal - discount
  }

  public func rawDiscount(_ subtotal: Int64, _ discount: Int64) -> Int64 {
      subtotal - discount
  }

  public func alwaysZero(_ subtotal: Int64, _ discount: Int64) -> Int64 {
      0
  }

  public func increment(_ value: Int64) -> Int64 {
      value + 1
  }

  public func wrappingIncrement(_ value: Int64) -> Int64 {
      value &+ 1
  }

  public func effectfulDiscount(_ subtotal: Int64, _ discount: Int64) -> Int64 {
      print("effect")
      return clampedDiscount(subtotal, discount)
  }

  public struct Amount {
      public let value: Int64

      public init(_ value: Int64) {
          self.value = value
      }

      public static func - (lhs: Amount, rhs: Amount) -> Amount {
          Amount(42)
      }
  }

  public func customSubtract(_ lhs: Amount, _ rhs: Amount) -> Int64 {
      (lhs - rhs).value
  }
  ```

  `clampedDiscount` is correct only under the intended nonnegative-input
  condition. The unrestricted function can still overflow on other inputs;
  include that case deliberately.

- [ ] **Step 2: Write `main.swift` exactly as follows.**

  ```swift
  let arguments = CommandLine.arguments
  guard arguments.count == 4,
        let a = Int64(arguments[2]),
        let b = Int64(arguments[3])
  else {
      fatalError("Expected operation and two Int64 arguments")
  }

  switch arguments[1] {
  case "clamped":
      print(clampedDiscount(a, b))
  case "raw":
      print(rawDiscount(a, b))
  case "zero":
      print(alwaysZero(a, b))
  case "increment":
      print(increment(a))
  case "wrapping":
      print(wrappingIncrement(a))
  case "effectful":
      print(effectfulDiscount(a, b))
  case "custom":
      print(customSubtract(Amount(a), Amount(b)))
  default:
      fatalError("Unknown operation")
  }
  ```

- [ ] **Step 3: Write `.gitignore` with this content.**

  ```gitignore
  .artifacts/
  ```

- [ ] **Step 4: Confirm both source files compile through Task 3's collector.**

  Do not add `@Contract` yet. Contract requirements for these cases are fixed
  explicitly below; this experiment tests extraction, not macro implementation.

## Task 3: Capture compiler artifacts and independent behavior

**Create:** `experiments/compiler-bridge/collect.py`.

- [ ] **Step 1: Write the following standard-library-only collector.**

  ```python
  import hashlib
  import json
  import subprocess
  from pathlib import Path

  ROOT = Path(__file__).resolve().parent
  OUT = ROOT / ".artifacts"
  OUT.mkdir(exist_ok=True)

  def run(command):
      return subprocess.run(
          command, cwd=ROOT, capture_output=True, text=True, timeout=60
      )

  def required(command):
      result = run(command)
      if result.returncode != 0:
          raise RuntimeError(
              f"Command failed: {command!r}\n"
              f"{result.stdout}\n{result.stderr}"
          )
      return result

  compiler = required(["xcrun", "--find", "swiftc"]).stdout.strip()
  metadata = {
      "compiler": compiler,
      "version": required([compiler, "--version"]).stdout,
      "target": json.loads(required([compiler, "-print-target-info"]).stdout),
      "source_sha256": hashlib.sha256(
          (ROOT / "Fixture.swift").read_bytes()
      ).hexdigest(),
      "commands": [],
  }

  modes = [
      ("silgen", ["-emit-silgen", "-Onone"]),
      ("sil-onone", ["-emit-sil", "-Onone"]),
      ("sil-optimized", ["-emit-sil", "-O"]),
  ]
  for name, flags in modes:
      destination = OUT / f"{name}.sil"
      command = [
          compiler, "-parse-as-library", "-module-name", "BridgeFixture",
          "-g", *flags, "Fixture.swift", "-o", str(destination),
      ]
      required(command)
      metadata["commands"].append(command)

  binaries = {}
  for mode in ["-Onone", "-O"]:
      binary = OUT / ("oracle-debug" if mode == "-Onone" else "oracle-release")
      command = [
          compiler, mode, "Fixture.swift", "main.swift", "-o", str(binary),
      ]
      required(command)
      metadata["commands"].append(command)
      binaries[mode] = binary

  maximum = str(2**63 - 1)
  minimum = str(-(2**63))
  cases = [
      ("clamped", "0", "1", "0"),
      ("clamped", "100", "20", "80"),
      ("clamped", maximum, "0", maximum),
      ("clamped", maximum, maximum, "0"),
      ("raw", "0", "1", "-1"),
      ("zero", "100", "20", "0"),
      ("increment", "0", "0", "1"),
      ("wrapping", maximum, "0", minimum),
      ("custom", "10", "3", "42"),
      ("effectful", "100", "20", "effect\n80"),
  ]
  observations = []
  for mode, binary in binaries.items():
      for operation, a, b, expected in cases:
          result = required([str(binary), operation, a, b])
          actual = result.stdout.strip()
          if actual != expected:
              raise AssertionError((mode, operation, a, b, expected, actual))
          observations.append({
              "mode": mode, "operation": operation, "inputs": [a, b],
              "stdout": actual, "returncode": result.returncode,
          })

      for operation, a, b in [
          ("increment", maximum, "0"),
          ("raw", minimum, "1"),
          ("clamped", maximum, "-1"),
      ]:
          result = run([str(binary), operation, a, b])
          if result.returncode == 0:
              raise AssertionError(
                  f"Expected trapping execution: {mode} {operation} {a} {b}"
              )
          observations.append({
              "mode": mode, "operation": operation, "inputs": [a, b],
              "returncode": result.returncode, "stderr": result.stderr,
          })

  (OUT / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
  (OUT / "observations.json").write_text(
      json.dumps(observations, indent=2) + "\n"
  )
  print(f"Captured 3 SIL artifacts and {len(observations)} executions.")
  ```

  Crash executions run in child processes. Do not try to catch a Swift trap with
  `do/catch`. A timeout, missing executable, compile failure, or unexpected
  output raises an error and must not become a successful observation.

- [ ] **Step 2: Run the collector.**

  From `SwiftFormal/`:

  ```bash
  python3 experiments/compiler-bridge/collect.py
  ```

  Expected: three nonempty SIL artifacts and 26 recorded executions, including
  six nonzero-exit observations. A nonzero child exit corroborates the expected
  trap case but does not independently establish its cause: correlate its
  diagnostic and compiler operation during Task 4.

  This command does not download tools or run Lean. It measures host behavior
  only and must not be presented as an iOS validation.

- [ ] **Step 3: Confirm the negative examples are meaningfully wrong.**

  Under the approved discount rule and nonnegative inputs, `raw(0, 1) = -1`
  violates the rule, and `zero(100, 20) = 0` violates the expected result 80.
  `increment(Int64.max)` violates an unconditional no-trap claim but not a claim
  explicitly requiring `value < Int64.max`. Record that domain distinction.

## Task 4: Decide whether a trustworthy extraction route exists

**Create:** `experiments/compiler-bridge/RESULTS.md`.

- [ ] **Step 1: Read all three representations together with the recorded
  configuration.**

  The artifacts are:

  ```text
  experiments/compiler-bridge/.artifacts/silgen.sil
  experiments/compiler-bridge/.artifacts/sil-onone.sil
  experiments/compiler-bridge/.artifacts/sil-optimized.sil
  experiments/compiler-bridge/.artifacts/metadata.json
  experiments/compiler-bridge/.artifacts/observations.json
  ```

  Do not choose a representation merely because its syntax is easy to parse.
  Identify the earliest one that provides enough resolved meaning, including
  dependencies whose behavior is not visible in an opaque call.

- [ ] **Step 2: Record an operation inventory using actual artifact excerpts.**

  For each fixture, record its compiler symbol, argument/result types, basic
  blocks, branch/return values, arithmetic and overflow behavior, calls,
  source-location mapping, and the dependencies required to interpret it.

  Establish these specific distinctions:

  | Pair | Required distinction |
  |---|---|
  | Clamped vs raw discount | Reachable branch and distinct returned expressions |
  | Raw vs always-zero | Actual body, not function name or contract alone |
  | Checked vs wrapping increment | Trap/range obligation vs modular arithmetic |
  | Scalar vs custom subtraction | Resolved built-in operation vs user-defined method |
  | Pure vs printing discount | Additional effect and callee dependencies |
  | Debug vs optimized output | Which facts remain recoverable under each configuration |

  A hash difference, function-name match, or source-token match alone does not
  satisfy any row. If a callee is opaque, identify an explicit supported
  summarization/resolution path or mark it unsupported.

- [ ] **Step 3: Check connection to changed source.**

  Temporarily change only the final return of `clampedDiscount` to `return 0`,
  rerun the collector, and confirm the executable oracle rejects the
  `100, 20 -> 80` case. Compare the changed compiler body as well. Restore that
  one temporary change with a precise patch and rerun successfully.

  This is a controlled negative check, not permission to revert anyone else's
  work. The collector does not itself constitute an implementation verifier.

- [ ] **Step 4: Write the continue/stop decision with these headings.**

  ```markdown
  # Compiler bridge experiment results

  ## Configuration and exact commands
  ## Observed executable behavior
  ## Operation inventory and source mapping
  ## Chosen extraction representation and why
  ## Trusted dependencies and unsupported constructs
  ## Evidence against using the alternatives
  ## Continue, narrow, or stop
  ```

  Include excerpts and file references rather than unsourced conclusions.
  Explicitly state that macOS host execution does not cover an iOS build.

- [ ] **Step 5: Apply the gate, without inventing success.**

  Continue to the small-verifier plan only if every required distinction has a
  concrete extraction path, unresolved semantics are excluded, and the trusted
  dependencies can be stated.

  If early SIL is insufficient, test one narrower alternative suggested by the
  observed gap. If the remaining approach requires general Swift heap/runtime
  modeling or a large compiler fork, stop and recommend a narrower generated-code
  DSL instead. Do not report a model-only fallback as direct Swift verification.

## Task 5: Close the experiment and define stage 2 from evidence

**Files:** Review the experiment and this plan; leave `prototype/` unchanged.

- [ ] **Step 1: Rerun the collector and the existing Swift tests.**

  ```bash
  python3 experiments/compiler-bridge/collect.py
  cd prototype && swift test
  ```

  Expected: the recorded experiment cases and original three tests pass.

- [ ] **Step 2: Check artifact hygiene.**

  Commit source scripts, fixtures, and the evidence report only if version
  control is available and appropriate. Keep generated binaries, SIL dumps,
  local absolute paths, and crash logs under ignored `.artifacts/`. Do not
  recursively delete the project or session directories to clean up.

- [ ] **Step 3: Produce the next bounded plan, only if the gate passes.**

  The next plan must specify the observed SIL grammar/operation allowlist,
  typed representation, checked arithmetic/trap semantics, contract parser,
  ordinary Lean proof policy, proof-result/source binding, and exact
  positive/negative tests for the five-function slice.

  Tests must reject unknown instructions/callees, changed source with stale
  results, false or unsatisfiable contracts, missing Lean, missing proofs, and
  checker failure. A false contract that is merely unproved must not be reported
  as having a confirmed counterexample.

  Do not add caching, macros, a solver portfolio, framework retrieval, or AI
  repair to that slice unless a concrete dependency makes it necessary.

## Later-stage acceptance criteria

These are requirements for later plans, not unimplemented steps disguised as
completed functionality.

### Stage 2: Small working verifier

Five real pure functions, approved input domains, mechanically generated proof
statements, and no "proved" result when any required obligation is outstanding.
Prove modeled absence of traps as well as requested business behavior.

Counterexamples should be replayed against compiled Swift where possible.
Sampled model/implementation agreement remains a separate evidence label.

### Stage 3: Developer integration

Choose macro syntax after a small compiler-checked syntax experiment. Require
contracts on selected boundaries in one critical module, not every UI function.
Build/source proof checks, executed property tests, and ordinary tests must have
an explicit orchestration and destination.

`swift package verify` is a custom command-plugin proposal, not a built-in verb.
Xcode ordered scripts/targets can implement an after-compilation phase;
SwiftPM build-tool plugins alone are not a general post-compilation hook.

Inspect a real release app's dependency graph/link map and symbols. Provers and
test harnesses must never be linked into it; dead stripping is not the plan.

### Stage 4: Measure value on real code

Preselect 30-50 functions and freeze approved contracts before tuning. Hold back
some bugs/cases. Compare compiler plus ordinary tests, then generated tests,
source-linked proofs, and optional AI assistance separately.

Report additional confirmed defects caught, known-bad implementations accepted,
proof completion, unsupported/excluded fractions, cold/incremental/cached
latency, review/debugging minutes, AI cost, and toolchain-upgrade breakage.
Separate confirmed counterexamples from cases merely blocked as unknown.

No known-invalid case may be accepted as proved. Zero observed false successes
on this pilot is a necessary gate, not a general soundness theorem. Set concrete
latency/adoption budgets for the pilot before running it; do not claim measured
performance or choose a backend from unrelated published AI percentages.

### Stage 5: Expand only for measured gaps

Prefer small structs/enums and pure state-transition invariants before arbitrary
collections, loops, or async protocols. A state-machine builder must generate or
verify the actual transition function.

Z3 is optional and its solver-trusted result is not automatically a Lean proof.
Audit native-evaluation tactics separately from ordinary Lean proof checking.

Use reviewed, pinned API summaries if framework calls become a real coverage
gap. DocC retrieval is evidence for a summary, not a proof of framework behavior.
Do not introduce a custom predictive model based on the unresolved term "Jev."

## Sources and local context

- Existing prototype:
  `prototype/Sources/FormalSpec/AST.swift`,
  `prototype/Sources/FormalSpec/LeanEmitter.swift`,
  `prototype/Sources/Demo/main.swift`.
- Earlier reports: `REPORT.md`, `EXPLAINED.md`. Their broad statements about
  Swift verification, input domains, and trust are qualified by this plan.
- SIL documentation:
  https://github.com/swiftlang/swift/tree/main/docs/SIL
- Macro design and restrictions:
  https://github.com/swiftlang/swift-evolution/blob/main/proposals/0389-attached-macros.md
  https://github.com/swiftlang/swift-evolution/blob/main/proposals/0415-function-body-macros.md
- Xcode custom build phases:
  https://developer.apple.com/documentation/xcode/running-custom-scripts-during-a-build
- SwiftPM plugin boundaries:
  https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/Plugins/WritingBuildToolPlugin.md
  https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/Plugins/WritingCommandPlugin.md
