# Experiments changelog (0.0.x)

Moved from the top-level README, which has a one-screen version now. Paths inside this text were written when the folders were at the repository root; they now live under `archive/`.

---

## Experiments (0.0.x)

Research behind the library: Lean proofs of SIL, translation validation, and a SAT engine.

**Current experiment snapshot: 0.0.7 -- ordinary control flow and measured branch expansion.**

## Run 0.0.7

Uses the same pinned tools as 0.0.3 below:

```bash
python3 -B experiments/control-flow/run.py
```

The original function, strict `guard`, early return, joined `if` expression and
reused calculation all prove under the unchanged contract. Four branch-growth
fixtures also prove. Two deliberately wrong returns are rejected; `>=` and
deferred local initialization remain explicitly unsupported in these probes.

The recorded 13-case inventory has **nine full SIL contract proofs, two seeded
rejections, two unsupported forms, and 1,122 native/IR agreements**. Repeated
conditions exposed a proof-script bug, now fixed without weakening any proof.

The important scaling result: eight extra branch joins produce only 75 IR
instructions but **512 return obligations** and about 742 KB of model-proof
source. Shared continuations are still duplicated. The next experiment should
preserve shared blocks rather than add caching or another solver.

See [0.0.7 measurements and limitations](control-flow/RESULTS.md).
The recorded evidence spans an interrupted run, a same-limit retry, and a
selected remaining-case batch; `.artifacts/measurement-summary.json` under
`experiments/control-flow/` identifies each result. Full bound checks took
roughly 66-183 seconds in these noisy observations. These are not controlled
performance benchmarks or general Swift verification.

Use repeatable `--case NAME` arguments with a separate `--output PATH` for a
bounded rerun. Such batches always include the original baseline and report
their scope explicitly; they do not reuse cached proof acceptance.

## Run 0.0.6

Uses the same pinned tools as 0.0.3 below:

```bash
python3 -B experiments/local-variables/run.py
```

The original discount function and this harmless refactor now both prove:

```swift
let result = subtotal - discount
return result
```

Both readers recognize the local `let` debug metadata; unknown instructions
and unsupported metadata still fail closed. The exact same nonnegative-input,
clamped-subtraction contract applies to the actual returned value on every
path, with independent raw-SIL decoding and no modeled arithmetic trap.

```text
SwiftFormal 0.0.6 local-variable experiment: PASS
Original and local refactor: SIL CONTRACT PROVED under the same frozen contract.
Wrong return: SIL TRANSLATION VALIDATED, business contract UNPROVED.
306 native comparisons agree; 5 reader theorem audits; 2 evidence controls.
```

A deliberately wrong return still passes the old samples and translates
faithfully, but fails its return-value proof. Calling the correct local
variable `result` does not hide a different actual return.

This is a small compatibility improvement, not broad Swift support or a
performance improvement. One recorded run took about seven minutes; the bound
local-refactor check took about 123 seconds. The compiler, SIL grammar and
semantics, and checking infrastructure remain assumptions.

See [0.0.6 results and limitations](local-variables/RESULTS.md).
Generated sources, compiler artifacts, proof bundles, verdicts, and timings
are in `experiments/local-variables/.artifacts/`. Use `--output PATH` for a
separate single-writer run. The existing 0.0.5 checker is reused, not forked.

## Run 0.0.5

Uses the same pinned tools as 0.0.3 below:

```bash
python3 -B experiments/sil-validation/run.py
```

Lean now reads the **complete raw compiler artifact**, selects
`clampedDiscount` itself, and proves that the decoded instructions equal the
program used by the earlier proofs. No preselected function body is supplied.
Small kernel-checked state transitions make this practical without trusting
native evaluation to prove anything.

```text
SwiftFormal 0.0.5 SIL experiment: PASS
SIL CONTRACT PROVED: independent decoding of the complete compiler artifact.
14 root theorem audits; 158 checked byte chunks; 42 controls.
```

The nonnegative-input contract now applies to independently decoded
instructions. A deliberately buggy body still decodes and translates
faithfully, but fails its business contract.

**Still trusted:** the Swift compiler, the reader's grammar and reference SIL
semantics, byte/artifact binding, and checking infrastructure. This is not
end-to-end compiler verification. The recorded full Lean check took about
58 seconds; the complete experiment took about four minutes.

See [0.0.5 evidence, accepted profile, and trust boundary](sil-validation/RESULTS.md).
Generated evidence is in `experiments/sil-validation/.artifacts/`.
Use `--output PATH` for a separate single-writer run.

## Run 0.0.4

Uses the same pinned tools as 0.0.3 below:

```bash
python3 -B experiments/translation-validation/run.py
```

For the same `clampedDiscount` function, Lean now checks two separate claims:

- **Faithful translation:** an independent instruction interpreter and the
  generated model agree for every signed `Int64` input pair, including traps.
- **Correct business behavior:** for nonnegative inputs, the interpreted
  instructions return the exact clamped subtraction without trapping.

```text
SwiftFormal 0.0.4 translation experiment: PASS
TRANSLATION VALIDATED for all signed Int64 input pairs; IR CONTRACT PROVED for nonnegative inputs.
10 contract theorem audits; 306 native comparisons; 18 controls.
```

Six deliberate translation errors fail, each with a Lean-checked counterexample.
The two buggy implementations from 0.0.3 still translate faithfully, but fail
the business contract. Correct translation does not mean correct business logic.

**Still trusted:** the Swift compiler, SIL reader, direct instruction encoding,
reference semantics, and checking infrastructure. This is per-program
translation validation, not a proof of the compiler or every possible
translator input.

See [0.0.4 evidence and the remaining trust boundary](translation-validation/RESULTS.md).
Generated proof sources, bundles, native observations, counterexamples, and
timings are in `experiments/translation-validation/.artifacts/`.
Use `--output PATH` for a separate single-writer run.

## Run 0.0.3

Requires the observed Apple Swift 6.4 toolchain (`swiftlang-6.4.0.34.1`),
macOS SDK 27.0, arm64, Python 3.11+, and Lean 4.35.0 at revision
`eb6cafb7290e8bd5f2937522d8d804f58f02bafc`. Other configurations are rejected.
The Swift packages use only local dependencies.

```bash
python3 -B experiments/lean-proof/run.py
```

The experiment compiles the real `clampedDiscount` function, extracts its
validated control flow, generates a Lean model and proof obligations, and
checks every required theorem.

```text
SwiftFormal 0.0.3 proof experiment: PASS
MODEL PROVED: exact clamped subtraction and no modeled trap for all nonnegative Int64 inputs.
6 theorem audits; 23 negative controls.
The compiler and Swift-to-Lean translation remain trusted.
```

For every allowed pair, the model returns `subtotal - discount` when the
discount fits within the subtotal, otherwise zero. It cannot take a modeled
arithmetic-trap path. This is an all-input proof of that model, **not a proof
of the Swift compiler or our translation**.

Two deliberately broken implementations still passed the old samples. The new
proofs failed; native runs independently confirmed a wrong result and an
overflow trap. Missing, changed, incomplete, and stale proof evidence is rejected.

Generated Lean, proof bundles, the environment fingerprint, diagnostics,
controls, and timings are in `experiments/lean-proof/.artifacts/`.
Use `--output PATH` for a separate run; each output directory is single-writer.

See [0.0.3 results, proof boundary, and standalone checker](lean-proof/RESULTS.md).
Version 0.0.4 reuses its model generator and checking policy, exposing a
model-only Lean module and sharing the bound-checking implementation. The
0.0.3 workflow still runs independently with the same proof meaning.

## Run 0.0.2

Requires the observed Apple Swift 6.4 toolchain (`swiftlang-6.4.0.34.1`),
macOS SDK 27.0, arm64, and Python 3. Other extraction configurations are
deliberately rejected. There are no third-party package dependencies.

```bash
python3 experiments/scalar-extraction/run.py
```

This runs the package checks, rebuilds the real Swift fixtures, extracts their
unoptimized compiler output, and compares our interpreter with both native builds.

```text
SwiftFormal 0.0.2 extraction experiment: PASS
Extracted 4/7 functions; explicitly rejected 3.
564 native comparisons agree (76 traps).
15 negative controls behaved as expected.
```

**PASS means agreement on the recorded examples, not a proof for every input.**
The interpreter can faithfully execute incorrect business logic; contracts and
proofs are still needed.

The useful learning: a changed discount function passed all 0.0.1 samples, but
gave `10` instead of `7` for a new input. The extractor picked up that changed
behavior; stale source and artifacts were rejected.

The package and CLI share the same Swift implementation. Generated inputs,
compiler artifacts, comparisons, controls, and timings are in
`experiments/scalar-extraction/.artifacts/`. Use `--output PATH` for a separate
run; each output directory is single-writer.

See [0.0.2 results and the library/CLI boundary](scalar-extraction/RESULTS.md).
Version 0.0.3 exposes the existing validated IR read-only so its proof package
can reuse it. The interpreter's behavior is unchanged, and the comparison
workflow still passes. The compiler-bridge fixture sources and prototype remain
unchanged.

## Run 0.0.1

Requires macOS, an installed/selected Xcode toolchain, and Python 3. The observed
configuration was Apple Swift 6.4, macOS SDK 27.0, arm64, and Python 3.14.8.
The compiler experiment does not require Lean or third-party Python packages.

From this directory:

```bash
python3 experiments/compiler-bridge/collect.py
python3 -B -m unittest discover -s experiments/compiler-bridge -p 'test_*.py' -v
```

The collector compiles the same fixtures into three compiler representations
and two native executables. It records 26 executions: 20 expected returned
outputs and six deliberately triggered arithmetic traps across `-Onone` and
`-O`.

```text
SwiftFormal 0.0.1 compiler experiment: PASS
Captured 3 SIL artifacts and 26 executions.
Report: .../experiments/compiler-bridge/.artifacts/report.json
This is a compiler experiment, not a verifier.
```

**PASS means the observed examples match the experiment's expectations.**
Some fixtures deliberately contain incorrect business logic. This is neither
an all-input proof nor a claim that those functions are safe.

Generated evidence lives under `experiments/compiler-bridge/.artifacts/`:

| File | Contents |
|---|---|
| `report.json` | Run status, version, source hashes, compiler/SDK/target, exact commands, timings, outputs, signals, and artifact hashes |
| `silgen.sil` | Raw compiler representation before mandatory lowering |
| `sil-onone.sil` | Canonical representation without optional optimization |
| `sil-optimized.sil` | Canonical representation with `-O` |
| `oracle-debug`, `oracle-release` | Native executables used for the observations |

The collector exits nonzero on unexpected behavior or tool failure. A new run
replaces the report with `running` before collecting; failure cannot leave a
previous `passed` report looking current. Always check both the command exit
status and the report status. A leftover artifact alone is not a successful run.

Use `--output PATH` for separate runs, `--fixtures PATH` for controlled fixture
variants, and `--swiftc PATH` to select a compiler. Do not run two collectors
against the same output directory concurrently.

## What 0.0.1 established

**Canonical `-Onone` SIL is the selected extraction input.** It exposes
checked arithmetic, branches, and source locations without needing to reconstruct
the behavior of opaque standard-library calls.

The important surprise: checked `+` and wrapping `&+` use the same arithmetic
builtin. Their overflow handling differs. A verifier must follow the values and
trap instructions, not classify code by operator spelling or builtin name alone.

See [the evidence and limitations](compiler-bridge/RESULTS.md) and
[the completed 0.0.2 plan](../design/plans/2026-11-03-swiftformal-0.0.2-experiment.md).

## Version policy

These are learning snapshots. APIs, representations, architecture, and file
layout may change completely between experimental versions, including patch
versions. Do not build production dependencies on them.

Each version should preserve its question, reproducible inputs, observed
results, negative controls, and next decision. We can replace an approach;
we must not quietly weaken what a successful result means.

Version 0.0.6 preserves the independent **SIL-to-Lean instruction handoff**
while accepting a local-variable refactor under the same contract. Next,
exercise `guard`, early returns, joined branches, and reused expressions,
and measure shared-continuation growth before prioritizing certificate
caching. The reader's interpretation of SIL still needs independent
validation; do not expand assurance claims on the strength of this single
function.

## Existing research

- [`prototype/`](../prototype/) is the earlier Swift spec DSL and Lean-model demo.
  It proves model statements and samples agreement with separate Swift code.
  It remains unchanged.
- [Evidence-driven roadmap](../design/plans/2026-11-03-swiftformal-evidence-driven-roadmap.md)
  describes the longer-term proof and measurement requirements.
- [`REPORT.md`](../REPORT.md) and [`EXPLAINED.md`](../EXPLAINED.md) are historical
  research. Their broad assurance claims must be read with the qualifications
  in the roadmap and experiment results.
