# 0.0.3: checking a source-derived Lean model

## Question and result

Can we generate a model from the actual extracted `clampedDiscount` body,
prove its fixed contract, and reject incomplete or stale evidence?

**Yes, within the explicitly trusted translation boundary.** The generated
baseline passes Lean with six complete theorem audits. All 23 negative controls
behave as expected, including two incorrect Swift bodies that pass the original
0.0.1 sample suite.

This is a learning snapshot, not a stable verification library or a published
package release. There are no macros, arbitrary contract expressions, AI-written
proofs, proof cache, or additional supported Swift features.

## Reproduce

From the workspace root:

```bash
python3 -B experiments/lean-proof/run.py
```

Observed configuration:

- Apple Swift 6.4, `swiftlang-6.4.0.34.1`, arm64, macOS SDK 27.0.
- Lean 4.35.0, revision `eb6cafb7290e8bd5f2937522d8d804f58f02bafc`.
- Python 3.14.8; the scripts require Python 3.11 or later.

Other compiler/SDK/target and Lean configurations are rejected. Dependencies
are the installed tools and the local `ScalarExtraction` package; nothing is
downloaded by this experiment.

`--output PATH` selects an output directory. `--lean PATH` selects the initial
Lean executable or shim; the checker resolves and verifies the installed
toolchain, then invokes its concrete binary. Each output directory is
single-writer.

To recheck a stored bundle without rebuilding the fixtures:

```bash
binary_path=$(swift build --package-path experiments/lean-proof --show-bin-path)
python3 -B experiments/lean-proof/check.py \
  --emitter "$binary_path/proof-emitter" \
  --collection experiments/lean-proof/.artifacts/bridge/report.json \
  --fixtures experiments/compiler-bridge \
  --contract experiments/lean-proof/contract.json \
  --bundle experiments/lean-proof/.artifacts/bundle.json \
  --output experiments/lean-proof/.artifacts/verdict.json
```

Run the full experiment first to build the emitter and create these artifacts.
The standalone checker regenerates the proof from current bound inputs; it does
not trust the previous verdict.

## Exact contract

The only accepted preset is the one in `contract.json`, for the exact compiler
symbol `$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF`.

Both arguments range from zero through `9223372036854775807`, inclusive.
The postcondition is independently defined as:

```text
if discount <= subtotal:
    result = subtotal - discount
else:
    result = 0
```

The model must return that value, not an arithmetic trap, for **every** input in
the domain. Nothing is claimed for negative arguments.

A separate theorem proves that the supplied witness `(0, 0)` satisfies the
precondition. This prevents an empty approved domain from passing vacuously.
An attempted `False` precondition is rejected as an unsupported contract preset;
there is no general satisfiability checker. A negative witness is accepted as
an `Int64` value by the decoder but fails its Lean theorem.

## What runs under the hood

```text
real Swift fixture
  -> canonical -Onone -g SIL
  -> existing validated scalar SSA/control-flow representation
  -> symbolic execution tree
  -> Lean implementation, per-path obligations, composition proofs
  -> Lean kernel checking and exact theorem/axiom audit
  -> MODEL PROVED, only while input and tool identities remain unchanged
```

`LeanProof` consumes the same `SILReader` and `CollectedSIL` used by the 0.0.2
CLI. That package now exposes its validated IR read-only across the package
boundary; the parser and interpreter were not copied or behaviorally changed.
`proof-emitter` is the real executable consumer of the proof library.

The emitter traverses blocks, substitutes actual SSA operands and block
arguments, and retains both conditional branches. It does not recognize the
business implementation by function name. The contract selects the target and
the independent expected result, not the generated implementation.

Integers are represented by mathematical Lean `Int` values. Every accepted
checked addition/subtraction introduces an explicit signed-64 range guard and
an arithmetic-trap outcome. This relies on the reader's immediate lowering
pattern: result projection, overflow projection, then `cond_fail`, with no
intervening observation of the partial result. Even an unused arithmetic result
must retain its safety obligation.

The baseline inventory is:

| Theorem | Meaning |
|---|---|
| `preconditionWitness` | The approved input domain is inhabited |
| `return_0` | The clamp-to-zero return satisfies the postcondition |
| `safety_0` | The subtraction cannot overflow on its path |
| `return_1` | The subtraction return satisfies the postcondition |
| `totalCorrectness` | Every allowed input returns the exact expected result |
| `noTrap` | Every allowed input avoids the modeled trap |

All names are in `SwiftFormalV003`. Obligations retain their statement and,
where available, SIL line and Swift source location. Proofs use fixed `decide`,
`simp`, and `omega` tactics, with structural composition over the actual tree.

## Acceptance, not merely a successful process exit

The checker compares the complete supplied bundle against fresh emitter output,
including the model, Lean source, theorem statements, inventory, contract hash,
and collection binding. Altered generated Lean is not an authoring interface.
It is rejected before execution, even if its edit would be harmless.

The verified source is passed to Lean through stdin in a fresh empty working
directory. Inherited `LEAN_*` settings are removed. Invocation uses
`--json --stdin -t 0`; the zero trust level also type-checks imported modules.

Acceptance requires a successful process exit, no warning/error diagnostics or
unexpected stderr, parseable audit records, and exactly one audit for every
expected theorem. Unknown information records, duplicate/missing audits, and an
empty inventory fail closed.

Only `propext`, `Classical.choice`, and `Quot.sound` are allowed axioms.
The witness uses none; the other baseline proofs use subsets of that allowlist.
This is **not** an axiom-free proof claim. `sorryAx`, arbitrary new assumptions,
and native-evaluation trust axioms are rejected.

Source/collection/contract identities are checked again after Lean. The emitter
binary, checker script, and supplied bundle are checked for changes as well.
The full experiment additionally checks its implementation/test source inventory
at completion.

The environment fingerprint records the concrete Lean binary, version/revision,
flags, allowed axioms, all 2,374 discovered transitive imports, their `.olean`,
`.olean.private`, and `.ir` files, and the selected macOS Lean runtime libraries.
There are 7,127 fingerprinted files, totaling 2,155,531,928 bytes in this install.
Their hashes are checked again before accepting a proof and at experiment end.

These hashes detect ordinary stale/changed inputs. They are not signatures,
remote attestation, or protection against an adversary controlling the checker,
its initial toolchain, or the operating system. System libraries, Python, and
the rest of the host are still trusted; this is not a fully closed reproducible
OS/toolchain environment.

Reports start as `running`/`RUNNING` before version and tool reads. Failures
cannot reuse an earlier successful report as the current result. Always check
the process exit and top-level report status; leftover files and previous
`MODEL PROVED` verdicts are not reusable proof certificates.

## Evidence and negative controls

The changed-body controls insert a branch after the original upper clamp:

```swift
if subtotal < 50 {
    return subtotal // wrong-result variant
}
```

The overflow variant instead returns
`discount + 9223372036854775807`. Both still pass all 26 observations of the
original collector. At `(10, 3)`, both native optimization modes independently
reproduce the defect:

| Body | Native observation | Lean result |
|---|---|---|
| Original | Returns `7` | All six obligations checked |
| Wrong result | Returns `10` | `return_1` fails |
| Overflow | `SIGTRAP` | `safety_0` and `return_1` fail |

A failed proof search alone is not a counterexample. The replay supplies the
separate concrete evidence above.

The 23 integration controls cover:

| Controls | Count | Expected outcome |
|---|---:|---|
| Changed bodies: stale bundle, stale source, fresh failing proof for each variant | 6 | `INVALID EVIDENCE`, `INVALID ARTIFACT`, or `UNPROVED` |
| Missing bundle; altered model/proof/statement; missing theorem/source; empty inventory | 7 | `MISSING PROOF` or `INVALID EVIDENCE` |
| False precondition, weakened contract, changed witness, failed witness | 4 | `INVALID CONTRACT`, `INVALID EVIDENCE`, or `UNPROVED` |
| Unknown compiler configuration | 1 | `INVALID ARTIFACT` |
| Real Lean: `sorry`, foreign axiom, native evaluation, missing theorem audit | 4 | Exit zero, but `UNPROVED` |
| Missing Lean after a previously successful verdict | 1 | Nonzero exit and `TOOL ERROR` |

The real native-evaluation test in this Lean version reports
`claim._native.native_decide.ax_1_1`, which the allowlist rejects. Unit tests also
reject the `Lean.ofReduceBool` spelling; these are distinct observations.
The fixed negative Lean snippets exercise the low-level audit only, not an
arbitrary-source production execution endpoint.

Seven Python test functions and three Swift test functions pass. They cover
the policy, binding-before-execution, bootstrap failure, changed-body emission,
contract rejection, and unused checked arithmetic. A focused red/green test also
closed an error-path bug: a failed emitter cannot choose a successful verdict
by putting `MODEL PROVED` in its error payload.

The affected 0.0.2 consumer still reports 564 agreeing native comparisons,
including 76 traps, and 15 controls. The four compiler-bridge tests and three
prototype tests also pass. Original compiler fixtures and prototype code remain
unchanged.

## Artifacts and performance

| Artifact | Contents |
|---|---|
| `.artifacts/report.json` | Overall status, source identities, proof result, obligations, controls, commands, diagnostics, and timings |
| `.artifacts/bundle.json` | Bound emitter output used for acceptance |
| `.artifacts/Generated.lean` | Human-readable generated proof; the checker executes the matching bundle source |
| `.artifacts/environment.json` | Lean import/runtime identity inventory |
| `.artifacts/bridge/` | Original compiler collection and native executables |
| `.artifacts/controls/` | Mutated fixtures, collections, bundles, proofs, and failure evidence |
| `.artifacts/verdict.json` | Standalone recheck result, when that command is run |

One measured rerun took 52.775 seconds for the complete experiment and 1.713
seconds for the baseline Lean proof subprocess. The larger total includes
builds/tests, import discovery and hashing, recompilation, repeated checks, and
negative controls. These are local warm-run observations, not a performance
benchmark or a claimed production latency.

## Remaining boundary and next decision

Lean checks the theorem about the emitted model. It does not prove that the
Swift compiler preserves source semantics, that SIL was parsed correctly, or
that the symbolic emitter faithfully represents every accepted IR program.
The checks and mutation evidence reduce mistakes in those components but do
not turn them into verified translations.

The next useful experiment is to reduce that gap: start a small Lean-checked
correspondence between the accepted IR semantics and emitted model. Keep the
same tiny contract and arithmetic/branch subset before expanding the Swift
surface. There is no claim yet for loops, heap state, concurrency, effects,
generic dispatch, wider platforms, or production Swift applications.
