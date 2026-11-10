# 0.0.4: instruction-to-model correspondence

## Result

**The generated model and an independent Lean interpreter agree for every
signed `Int64` input pair for the selected function.** Lean also transfers the
original nonnegative-input contract onto the interpreted instruction program.

This is per-program translation validation. It is not a universal proof of
the translator, a verified SIL parser, or a verified Swift compiler.

The most useful distinction is now observable: both deliberately buggy Swift
implementations translate faithfully, yet fail the business contract. Six
deliberately incorrect translations fail correspondence, and a separate Lean
proof establishes a concrete mismatch for each.

## Reproduce

From the workspace root:

```bash
python3 -B experiments/translation-validation/run.py
```

Requirements remain Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS SDK 27.0,
arm64, Python 3.11+, and Lean 4.35.0 at revision
`eb6cafb7290e8bd5f2937522d8d804f58f02bafc`.
Only local Swift package dependencies are used.

`--output PATH` selects a separate single-writer artifact directory.
`--lean PATH` selects the initial Lean executable/shim; the shared checker
resolves the pinned concrete toolchain.

After the full run, recheck the stored baseline without rebuilding:

```bash
binary_path=$(swift build --package-path experiments/translation-validation --show-bin-path)
python3 -B experiments/translation-validation/verify.py \
  --emitter "$binary_path/translation-emitter" \
  --collection experiments/translation-validation/.artifacts/bridge/report.json \
  --fixtures experiments/compiler-bridge \
  --contract experiments/lean-proof/contract.json \
  --bundle experiments/translation-validation/.artifacts/bundle.json \
  --output experiments/translation-validation/.artifacts/verdict.json
```

Default success is `IR CONTRACT PROVED`. Adding `--translation-only` checks
correspondence and sampled agreement without requiring the business contract;
its distinct success status is `TRANSLATION VALIDATED`. It must not be treated
as contract success.

The original 0.0.3 commands still work and retain their earlier meaning.

## Two independent representations

```text
real Swift -> compiler SIL -> existing validated scalar IR
                                 |
                +----------------+----------------+
                |                                 |
       direct instruction data             existing symbolic tree
                |                                 |
       Lean reference interpreter          generated Lean model
                |                                 |
                +----- checked correspondence ----+
```

The direct exporter preserves instruction order, SSA identifiers, operand
identifiers, blocks, branch targets, and block arguments. It does not derive
the instruction program from the symbolic tree or generated return expression.
Debug instructions remain no-ops. Existing reader validation supplies static
type and control-flow restrictions.

`ReferenceIR.lean` implements value lookup, argument binding, instruction
evaluation, branches, and returns. Boxed `Int64`, raw words, Boolean bits, and
overflow tuples are distinct runtime values.

Arithmetic computes the mathematical sum/difference, a signed wrapped partial
result, and an independent overflow bit:

```text
wrapped(x) = ((x + 2^63) mod 2^64) - 2^63
overflow(x) = not (-2^63 <= x <= 2^63 - 1)
```

The interpreter retains both tuple projections and executes `cond_fail`
separately. It does not replace the checked sequence with the model's range
guard. Missing/mistyped operands and invalid control transfers produce
`invalidIR`; exhausted execution fuel produces `exhausted`.

The baseline uses fuel 20. Correspondence proves a returned value or arithmetic
trap, not fuel exhaustion or invalid IR, for every allowed signed input pair.
This is a checked bound for this program, not a generic termination theorem.

## What Lean proves

The correspondence theorem states, in abbreviated form:

```text
for all subtotal and discount within signed Int64 bounds:
    interpret(instructionProgram, subtotal, discount)
      = lift(generatedModel(subtotal, discount))
```

`lift` maps the model's return/trap constructors to the interpreter's outcomes.
Negative inputs and arithmetic traps are included in this theorem.

The business contract has a narrower domain: both inputs must be nonnegative
`Int64` values. The interpreted instructions must return
`subtotal - discount` when `discount <= subtotal`, otherwise zero. They must
not trap.

The default proof checks ten required theorem audits:

| Inventory | Purpose |
|---|---|
| Six `SwiftFormalV003` theorems | Nonempty precondition, return/safety obligations, exact model result, no modeled trap |
| `SwiftFormalV004.correspondence` | Full signed-input equality between interpreted IR and model |
| `SwiftFormalV004.sampledAgreement` | Lean interpretation agrees with the existing Swift IR interpreter on 51 recorded pairs |
| `SwiftFormalV004.totalCorrectness` | Transfer the model's contract to the interpreted instructions |
| `SwiftFormalV004.noTrap` | No interpreted arithmetic trap on the nonnegative domain |

The translation-only source checks just correspondence and sampled agreement.
It contains the model definitions but not the old business-contract proofs, so
an incorrect business implementation can genuinely pass that stage.

The sampled theorem is supplemental evidence, not the basis of the universal
correspondence theorem. Its expected observations come from the existing Swift
IR interpreter, and are checked by kernel reduction with `decide`, not
`native_decide`.

Generated proofs split the model's branch/range predicates, simplify the
concrete instruction execution, and use a proved in-range wrapping lemma.
Only the unused-simp-argument linter is locally disabled for the generated
uniform simplification list; proof errors, `sorry` diagnostics, and the axiom
policy remain enforced. The current experiment rejects more than 256
instructions or eight distinct predicates rather than promising scalable
proof search.

## Evidence

There are 51 input pairs per body: a seven-by-seven signed boundary grid plus
`(10, 3)` and `(-10, -3)`. Every pair is compared against both native
optimization modes.

| Body | Native comparisons | Native traps | Correspondence | Business contract |
|---|---:|---:|---|---|
| Original | 102 | 16 | Validated | Proved |
| Wrong-result branch | 102 | 10 | Validated | Unproved |
| Overflow branch | 102 | 14 | Validated | Unproved |

All 306 native observations agree with the recorded Swift IR results; Lean
separately checks those results against its instruction interpreter.
The two changed bodies still pass the original collector's 26 observations.
At `(10, 3)`, the wrong-result variant returns `10` instead of `7`; the overflow
variant traps. Both native builds reproduce those defects.

There are 18 controls:

| Controls | Count | Outcome |
|---|---:|---|
| Each buggy body: failed contract, stale bundle, stale source | 6 | `UNPROVED`, `INVALID EVIDENCE`, `INVALID ARTIFACT` |
| Deliberate translation errors below | 6 | Failed correspondence plus a proved concrete mismatch |
| Missing correspondence, altered program, altered interpreter identity, altered proof | 4 | `INVALID EVIDENCE` before checking supplied Lean |
| Missing bundle | 1 | `MISSING PROOF` |
| Missing Lean after a successful verdict | 1 | Nonzero exit and `TOOL ERROR` |

The six incorrect-translation controls are:

| Mutation | Concrete mismatch input |
|---|---|
| Reverse the model's comparison | `(10, 3)` |
| Generate addition instead of subtraction | `(10, 3)` |
| Ignore the model's overflow guard | `(Int64.max, -1)` |
| Change behavior only for negative subtotals | `(-10, -3)` |
| Miswire an encoded block argument | `(3, 10)` |
| Drop an encoded trap instruction | `(Int64.max, -1)` |

Each malformed translation has a failed universal correspondence attempt and
a separate, successful `mismatchAtWitness` proof. This distinguishes a genuine
translation counterexample from merely unsuccessful proof search.
The negative-only mutation is outside the business precondition but still
fails the stronger signed-input correspondence check.

Fixed malformed translation sources are internal test fixtures exercising the
Lean checker. Editing a stored production bundle is not a supported proof
authoring interface: regeneration rejects it before execution.

Focused package tests check direct block-argument export. Lean instruction
tests cover wrapped overflow and underflow, tuple projection, operand errors,
unsupported arithmetic flags, simultaneous argument transfer, traps, bad
arity, invalid IR, and fuel exhaustion. Python tests check reference-resource
binding, distinct success statuses, and bootstrap failure.

## Acceptance and remaining trust

The checker reuses 0.0.3's fail-closed process/JSON/axiom policy and environment
fingerprinting. All required audits must be present exactly once, and only
`propext`, `Classical.choice`, and `Quot.sound` are allowed axioms.

Both sources must include the current independent interpreter and direct
program data. The packaged interpreter must match its current source hash.
The complete bundle is compared with fresh regeneration before execution and
again afterward. Additional checker/reference source identities are checked
alongside the emitter, inputs, bundle, and Lean environment.

The remaining trusted components include:

- The Swift compiler and the existing SIL reader/validator.
- The direct export from Swift IR into Lean instruction data.
- The reference semantics, contract definitions, and their correspondence to
  the intended Swift/LLVM behavior.
- Lean's kernel and permitted foundational axioms, the checking infrastructure,
  toolchain, and host environment.

The symbolic model generator no longer needs to be assumed faithful for an
accepted program: correspondence is checked instead. But a common error in the
initial IR or direct encoding can still invalidate the connection to real Swift.
The native observations support that connection; they do not prove it for all
inputs. Hashes are change detection, not signatures or hostile-host attestation.

Two small shared interfaces changed: `LeanProof` exposes its closed model-only
module and constructible obligation records; the existing bound checker accepts
a trusted generator/proof selection and additional identity paths. Neither
change weakens the default 0.0.3 policy. Its full workflow and real CLI still
pass with six audits and 23 controls.

## Artifacts and next boundary

`.artifacts/report.json` contains outcomes, input/source identities, obligations,
native observations, counterexamples, commands, and timings.
`bundle.json`, `translation.lean`, and `proof.lean` contain the generated data
and proofs. `environment.json` records the pinned Lean import/runtime identity.
`controls/` preserves the changed Swift fixtures, collections, rejected
translations, and independently proved counterexamples.

Standalone CLI results are saved separately. A translation-only verdict for
the wrong-result body is successful; its full-contract verdict is `UNPROVED`.
Do not treat earlier successful reports or leftover files as reusable proof
certificates. Check the exit code and current top-level status.

Timings are recorded separately for each Lean subprocess and the entire
experiment, including builds, environment hashing, mutation proofs, and native
replays. The final measured rerun took 79.810 seconds overall: 2.060 seconds for
the baseline correspondence/sample proof and 2.078 seconds for the complete
contract-transfer proof. These local warm-run observations are not a production
performance benchmark.

The next trust boundary worth investigating is the direct SIL/IR-to-Lean data
handoff, before increasing language coverage. This version adds no loops,
heap semantics, effects, generic dispatch, concurrency, macros, or platform
coverage beyond the existing experiment.
