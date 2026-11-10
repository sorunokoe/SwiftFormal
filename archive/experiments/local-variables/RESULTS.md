# SwiftFormal 0.0.6: a local variable must not break verification

## Question and result

Can an ordinary local `let` preserve the existing all-input guarantee without
weakening the contract, bypassing independent decoding, or hiding a wrong return?

**Yes, for the selected discount function and observed compiler profile.**
The original body and the local-variable refactor both receive
`SIL CONTRACT PROVED`. A deliberately wrong return still translates faithfully
but fails its return-value obligation.

```bash
python3 -B experiments/local-variables/run.py
```

Observed with the pinned Swift, SDK, Python, and Lean tools in the root README:

```text
SwiftFormal 0.0.6 local-variable experiment: PASS
Original and local refactor: SIL CONTRACT PROVED under the same frozen contract.
Wrong return: SIL TRANSLATION VALIDATED, business contract UNPROVED.
306 native comparisons agree; 5 reader theorem audits; 2 evidence controls.
```

## Small implementation change

The reproduced compiler output contained:

```text
debug_value %18, let, name "result", loc "Fixture.swift":5:9, scope 5
```

Both readers previously required `argno`, which describes a function parameter,
not this local. The new grammar recognizes the same `let` debug form with or
without that argument number. Location/scope suffixes still pass through their
existing strict parsers. Unknown instructions and suffixes are not stripped.

The production changes are confined to:

- `../scalar-extraction/Sources/ScalarExtraction/SILReader.swift`
- `../sil-validation/Sources/SILReader.lean`

The Swift reader still validates the referenced SSA value, including definition
and dominance. The independent Lean reader keeps the debug instruction as an
explicit no-op in the decoded program; its structural checks do not replace
the Swift SSA/type validator. The instruction count and execution fuel account
for the additional instruction.

Reference instruction semantics, symbolic model generation, the contract,
axiom policy, source binding, and certificate composition are unchanged.
The experiment uses the existing exporter and 0.0.5 checker directly. Generated
bundles and theorem namespaces retain their upstream versions rather than
pretending that a new proof engine was introduced.

This does not enable arbitrary debug syntax, mutable `var` storage, or every
possible local expression. The end-to-end profile still requires supported
instructions, types, names, and control flow.

## Same promise, actual returns

The runner fixes the existing contract bytes to SHA-256:

```text
afffc343970ceb49c1b0d1917cab677ba3cc47ca8add17785d76ae588d3abd4b
```

For every pair of nonnegative `Int64` inputs, the decoded program must return
`subtotal - discount` when the discount fits, otherwise zero, without a
modeled arithmetic trap. Correspondence between the decoded instructions
and symbolic model still covers all signed `Int64` pairs, including traps.

The original fixture is left untouched. The runner creates and freshly compiles
three complete fixture sets, changing only the selected return region:

| Variant | Selected return region | Outcome |
|---|---|---|
| `original` | `return subtotal - discount` | Contract proved, 14 required root audits |
| `local-result` | `let result = subtotal - discount; return result` | Same contract proved, 14 required root audits |
| `wrong-return` | Compute `result`, but return `subtotal` when `subtotal < 50` | Translation proved; contract rejected at `SwiftFormalV003.return_1` |

The first clamp branch is retained in all three variants. The distinguishing
input `(10, 3)` returns `7`, `7`, and `10`, respectively, in both native builds.
The local named `result` contains the correct subtraction in the buggy body,
but the proof follows the actual return instruction.

All three variants pass the older collector's 26 observations. The new runner
also compares each extracted program's 51 boundary/input samples with both
native builds: 306 agreements in total, including traps. Native agreement
is a separate observation, not the all-input proof and not evidence that the
buggy program satisfies its contract.

The frozen checksum guards this experiment against changing its input contract.
It is not a protected human-approval system: someone able to change the runner
or contract implementation could change what is approved. AI repair governance
and caller-precondition composition remain future work.

## Regression cases and controls

Before the reader changes, the new Swift tests reproduced `UNSUPPORTED` for
local metadata. In Lean, parameter metadata still checked while the two new
local-decoding equalities failed. After the changes, all these cases pass
under the existing strict proof audit.

Four new Swift Testing tests cover 14 cases: local/parameter metadata, preserved
results and overflow behavior, an actual return different from the named local,
seven unsupported forms, and undefined/non-dominating debug operands.

Five Lean root theorems cover parameter metadata, local metadata, located local
metadata, the actual returned operand, and rejection of seven unsupported forms.
Those forms include `var`, an unquoted name, an unknown suffix, incomplete or
repeated `argno`, an extra return on the same line, and an unknown instruction
after otherwise valid local metadata.

Two end-to-end evidence controls reject, before invoking Lean:

- The original function's bundle supplied for the refactored source/collection.
- A local-refactor bundle with its independent-decoding audit removed.

Two Python tests additionally check stale-success invalidation on setup failure
and rejection of missing/ambiguous fixture mutation targets.

The buggy return is a **seeded business defect**. Parser and evidence controls
are infrastructure checks, not counts of real application bugs discovered.

The complete earlier workflows were rerun with the updated readers:

```bash
python3 -B experiments/scalar-extraction/run.py
python3 -B experiments/lean-proof/run.py
python3 -B experiments/translation-validation/run.py
python3 -B experiments/sil-validation/run.py
```

All passed: 0.0.2 retains 564 native agreements and 15 controls; 0.0.3 retains
six root audits and 23 controls; 0.0.4 retains ten root audits, 306 native
agreements, and 18 controls; 0.0.5 retains fourteen root audits and 42 controls.
Their current source snapshots match their regenerated reports. The changed
Swift files also pass `swift format lint --strict` with the existing four-space
indentation (`--configuration '{"indentation":{"spaces":4}}'`).

## Measurements

One local run, not a controlled performance benchmark:

| Variant | IR instructions | Raw SIL bytes | Certified chunks | Bound contract check, seconds |
|---|---:|---:|---:|---:|
| Original | 19 | 80,419 | 158 | 70.698 |
| Local result | 20 | 80,632 | 158 | 122.977 |
| Wrong return | 25 | 82,175 | 161 | 102.330, rejected |

Generated full-proof sources contain 483,604, 484,564, and 494,184 bytes,
respectively. The complete experiment took 441.602 seconds, including builds,
collections, reader checks, the separate buggy-body translation proof,
contract checks, native comparisons, and binding controls.

Bound checks include regeneration and identity checks, not only Lean execution.
The extra local metadata is small, but its observed proof-check time is higher.
This run does not isolate the cause or establish a repeatable slowdown.
No caching, branch-scaling benchmark, or speed improvement is claimed.

## Evidence and checking

The runner saves `report.json`, the pinned `environment.json`, and the exact
kernel-checked `reader-tests.lean`. Each variant directory contains its fixture
sources, fresh compiler collection and binaries, bundle, all three generated
Lean sources, and contract verdict. The buggy variant also has a successful
translation verdict. The report records commands, source hashes, native
comparisons, diagnostics, and timings.

The checker regenerates each bundle before and after checking and binds the
compiler collection, raw bytes, contract, exporter, both proof layers, reader,
proposer, and Lean environment. The runner additionally rechecks its source
snapshot, saved bundles, and native executable identities. A new run replaces
an old report with `running` before setup; failure cannot leave an old success
marked current. Output directories are single-writer.

Standalone checking uses the existing CLI:

```bash
EMITTER="$(swift build --package-path experiments/translation-validation --show-bin-path)/translation-emitter"
python3 -B experiments/sil-validation/verify.py \
  --emitter "$EMITTER" \
  --collection experiments/local-variables/.artifacts/local-result/bridge/report.json \
  --fixtures experiments/local-variables/.artifacts/local-result/fixtures \
  --contract experiments/lean-proof/contract.json \
  --bundle experiments/local-variables/.artifacts/local-result/bundle.json \
  --output experiments/local-variables/.artifacts/local-result/cli-verdict.json
```

This command was also run independently and returned `SIL CONTRACT PROVED`.

## Limits and next decision

This remains one function and one fixed contract under explicit assumptions:
the Swift compiler, the chosen SIL grammar/reference semantics, artifact
binding, Lean's kernel/foundations, and the host/checking infrastructure.
Neither reader nor the compiler has been verified for every possible input.
Successful native samples do not prove native-code refinement.

Next, apply the same frozen-contract approach to `guard`, early returns,
shared joins, and reused expressions. Measure branch/model/proof growth before
choosing sharing-aware generation or certificate caching. Normal tests stay;
Lean remains a development-time dependency, not an iOS runtime dependency.
