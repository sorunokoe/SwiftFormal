# Scalar extraction experiment results

**Version:** 0.0.2, 3 November 2026.
**Decision:** continue to one carefully bounded proof experiment.
**Evidence:** typed extraction, interpreted execution, finite native comparisons,
and rejection controls. No `PROVED` result exists in this version.

## Question

Can we mechanically read the selected canonical SIL bodies and reproduce their
returned values and arithmetic traps without substituting a handwritten
discount implementation?

**Observed answer: yes for four selected functions on this pinned configuration.**
This is evidence for the translation connection, not a soundness theorem.

## Run and inspect

From the workspace root:

```bash
python3 experiments/scalar-extraction/run.py
```

The command runs the Python bootstrap regression and Swift package tests, builds
`scalar-probe`, regenerates 0.0.1 compiler artifacts into its own output
directory, and executes the comparisons and controls. It does not change
`compiler-bridge/` sources, its existing artifacts, or `prototype/`.

For the short package-only loop:

```bash
swift test --package-path experiments/scalar-extraction --quiet
```

The installed Swift formatter was also applied and checked using four-space
indentation:

```bash
xcrun swift-format lint --strict --recursive \
  --configuration '{"indentation":{"spaces":4}}' \
  experiments/scalar-extraction/Package.swift \
  experiments/scalar-extraction/Sources \
  experiments/scalar-extraction/Tests
```

The observed extraction configuration is Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, Clang `2100.3.34.1`), macOS SDK 27.0,
`arm64-apple-macosx27.0.0`, canonical `-emit-sil -Onone -g`.
The SwiftPM tool has a macOS 14 minimum; no iOS or Linux integration was tested.

## What is implemented

| File | Responsibility |
|---|---|
| `Sources/ScalarExtraction/IR.swift` | Typed SSA values, blocks, instructions, source locations, and distinct result/trap outcomes |
| `Sources/ScalarExtraction/SILReader.swift` | Selected-body parsing, type/definition checks, dominance, branch arguments, acyclic control flow, and checked-arithmetic pattern validation |
| `Sources/ScalarExtraction/Interpreter.swift` | Evaluates that IR without copying the fixture's business logic |
| `Sources/ScalarExtraction/CollectedSIL.swift` | Rejects unrecognized collection configuration and stale source/artifact identities |
| `Sources/ScalarProbe/main.swift` | Thin JSON CLI over the same library |
| `run.py` | Reproducible compiler/native comparison and controls |

The additional collection adapter makes the source/configuration boundary
explicit instead of hiding it in the interpreter. CryptoKit is used only for
local SHA-256 identities; there are no downloaded library dependencies.

The parser selects an exact compiler symbol, not a friendly function-name
comment. It does not parse the entire standard library. Unknown instructions
in the selected body cannot silently disappear.

## Observed coverage

Instruction counts include retained `debug_value` instructions, which do not
affect execution.

| Selected function | Result | Blocks | Instructions | Input cases |
|---|---|---|---|---|
| clamped discount | Extracted | 4 | 19 | 81 |
| raw discount | Extracted | 1 | 11 | 81 |
| always zero | Extracted | 1 | 5 | 81 |
| checked increment | Extracted | 1 | 10 | 39 |
| wrapping increment | Unsupported: unrecognized checked-arithmetic pattern | - | - | - |
| effectful discount | Unsupported: `Builtin.Word` during allocation setup | - | - | - |
| custom subtraction | Unsupported: `Amount` parameters | - | - | - |

The effectful function is rejected before reaching its `print` call. This is
not a completed effect analysis; calls are independently outside the grammar.

The baseline uses all combinations of
`min`, `min + 1`, `-1`, `0`, `1`, `max - 1`, and `max`, plus 32 seeded random
cases per supported function (`0x5F002`). Inputs are recorded as decimal strings
so JSON consumers do not round 64-bit integers.

**282 function/input cases; 564 comparisons against native `-Onone` and `-O`
executables; zero observed disagreements.** Of those native executions, 76
trapped and 488 returned values. The two native builds are compared to the same
unoptimized IR; this is not proof of optimizer correctness.

These are curated fixtures, not representative Swift-language coverage.
Four supported functions out of seven must not be presented as general
coverage or a proof-completion rate.

## The important changed-source result

A controlled copy adds this branch before clamped discount's subtraction:

```swift
if subtotal < 50 {
    return subtotal
}
```

All 26 original collector observations still pass. But for `(10, 3)`:

| Body | Native output | Extracted/interpreted output |
|---|---|---|
| Original | 7 | 7 |
| Changed | 10 | 10 |

The changed body is freshly compiled and bound to a different collection
report. Both changed native builds return 10. Trying to combine the original
report with changed source is rejected.

**Learning:** fixed examples can miss a business-rule defect. Successful
extraction can accurately model that defect; it does not establish the intended
business rule. This is exactly the gap a later contract proof must close.

## Arithmetic semantics and rejection boundary

The reader accepts signed 64-bit literals and values, one-bit conditions,
`Int64` wrapping/unwrapping, signed less-than, checked addition/subtraction,
tuple projections, explicit traps, branches, block arguments, and returns.
Only the observed parameter/debug metadata forms are supported.

Addition/subtraction produce a partial value and an overflow bit. The interpreter
does not trap at the builtin itself. It executes the separate `cond_fail`.
The reader requires the observed flag literal and local projection/trap pattern;
removing the trap or using the wrapping pattern is unsupported.

The inspected open-source compiler lowering consumes the two arithmetic
operands and discards the third flag before calling LLVM's overflow intrinsic:
[GenBuiltin.cpp, pinned reference](https://github.com/swiftlang/swift/blob/4bbf48a5b8207f839349bb9badb475538cbef2a1/lib/IRGen/GenBuiltin.cpp#L526-L545).
This supports the separation between tuple production and trapping. That
open-source revision is not asserted to be the exact Apple compiler source
revision; the installed configuration is additionally exercised by the native
comparisons.

Interpretation uses Swift's `addingReportingOverflow` and
`subtractingReportingOverflow`. The compiler and standard-library arithmetic
remain shared trusted dependencies; these comparisons are not an independent
verification of their implementation.

## Controls and failure behavior

The 15 integration controls cover the three unsupported functions, changed-body
behavior, stale source, missing/failed/running/malformed collection reports,
unknown compiler/SDK, wrong source hashes, changed flags, and changed artifact
bytes.

Eight Swift test functions, including parameterized cases, exercise actual
branch results and trap locations, invalid SSA uses and dominance, mismatched
branch arguments, duplicate values/blocks/bodies, missing targets, misplaced
terminators, unsupported operations/calls, invalid literals, cyclic flow, and
missing overflow checks. The first reader tests failed on the unimplemented
reader before passing with the implementation.

A separate Python regression exposed a bootstrap bug: a missing `VERSION`
could leave an old `passed` report behind. The runner now writes `running`
before reading version/source data, then records `failed` on that error.
The regression was observed failing before the fix and passing afterward.

The collection adapter checks source and artifact hashes, the expected file
inventory, collector identity, compiler/SDK/target, successful exact compiler
commands, and input stability through interpretation. The runner checks its
own implementation, probe binary, and baseline artifacts again before success.

**These are unsigned local records, not tamper-proof attestations.** Hashes
detect stale/mismatched files; they do not prove that the compiler was correct
or that an intentionally forged report is authentic.

## CLI protocol and persistent evidence

After running the experiment, this invokes the same library through its real
consumer with the generated request file:

```bash
swift run --package-path experiments/scalar-extraction scalar-probe \
  experiments/scalar-extraction/.artifacts/bridge/report.json \
  experiments/compiler-bridge \
  experiments/scalar-extraction/.artifacts/requests/baseline.json
```

Requests are arrays of `{"symbol": "...", "inputs": [["100", "20"]]}`.
Results include the report/SIL hashes, per-function extraction status,
instruction counts, returned decimal values, and trap source locations.

Exit 0 means every requested body was extracted; exit 2 means at least one is
unsupported; exit 1 means invalid evidence/input; exit 3 means a tool error.
The baseline batch intentionally exits 2 for its three rejection controls.
The experiment runner treats those expected rejections separately from success
on supported functions.

Evidence under `.artifacts/`:

| Path | Contents |
|---|---|
| `report.json` | Overall status, source/probe identities, configuration, commands/timings, comparisons, and controls |
| `probe.json` | Baseline typed-extraction/interpreter response |
| `requests/` | Exact JSON inputs used by each CLI call |
| `bridge/` | Fresh original-source compiler artifacts and collection report |
| `changed-fixtures/`, `changed-bridge/` | Controlled changed source and its separate compiler evidence |

Use a separate `--output PATH` for each concurrent run. The output directory is
single-writer. Failed runs are not reusable successes. Old generated files
alone do not establish a passed run.

Timings are recorded separately for the test/build commands, compiler
collection, CLI process, and native child processes. No controlled cold/warm
benchmark or performance promise is claimed.

## Continue, narrow, or stop

**Continue with one contract and one extracted function.** A suitable 0.0.3
question is whether Lean can check the exact clamped-discount result and
absence of modeled arithmetic traps for all nonnegative `Int64` inputs.

Before implementing that version, define the contract format and precondition
witness, IR semantics, complete obligation inventory, generated theorem
identities, strict theorem/axiom audit, and configuration binding. Reject false,
missing, or `sorry`-dependent proofs without relabeling them as confirmed
counterexamples.

Do not add macros, wider Swift support, caching, or AI proof generation to solve
that question. APIs and architecture remain replaceable. The distinction
between sampled agreement and an actual checked theorem does not.
