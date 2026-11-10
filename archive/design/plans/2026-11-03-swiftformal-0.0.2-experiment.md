# SwiftFormal 0.0.2 Experiment Plan

**Status:** implemented as experimental 0.0.2. See
[results and limitations](../../../archive/experiments/scalar-extraction/RESULTS.md).

**Goal:** Test whether a small typed extractor preserves the returned values
and traps of the scalar bodies inspected in 0.0.1. This is not yet the
five-function proof milestone or a stable public API.

**Architecture:** Consume canonical `-Onone` SIL from the same pinned compiler
configuration. Parse a rejecting-by-default subset into typed SSA blocks, then
interpret that representation and compare it with compiled Swift. Keep this
logic in one focused SwiftPM package with a thin command-line consumer.

**Tech stack:** Swift, SwiftPM, Swift Testing, and the existing compiler collector.
No new external dependencies, Lean backend, macros, or AI requirement.

## Inputs already supported by evidence

Use the 0.0.1 `Fixture.swift`, `sil-onone.sil`, and native executables.
The candidate functions are clamped discount, raw discount, always zero, and
checked increment. The other three functions are rejection controls.

The initial signature is `(Int64...) -> Int64`, with builtin one-bit values
inside branches. Do not declare support for arbitrary Swift `Bool` functions,
new comparison operators, or a different compiler stage before adding fixtures
that expose their actual lowering.

Pin the compiler version, SDK/target, and flags from the collection report.
Regenerate artifacts from current source before interpreting them. A missing
report, non-passed collection, changed source/artifact digest, duplicate symbol,
unknown toolchain, or missing target body must fail.

## Small package boundary and file responsibilities

Create `experiments/scalar-extraction/Package.swift` with:

- `Sources/ScalarExtraction/IR.swift`: typed values, SSA value identities,
  block parameters, source locations, and supported instructions.
- `Sources/ScalarExtraction/SILReader.swift`: selected function extraction and
  strict validation of the observed syntax.
- `Sources/ScalarExtraction/Interpreter.swift`: deterministic evaluation with
  distinct returned-value and arithmetic-trap outcomes.
- `Sources/ScalarProbe/main.swift`: a thin CLI over the same library.
- `Tests/ScalarExtractionTests/`: parser rejection, arithmetic/control-flow,
  and real compiler-to-interpreter comparisons.

The implementation also adds `CollectedSIL.swift` for source/configuration
binding, `run.py` for native comparison, and a Python bootstrap regression.
The CLI consumes the same library; no separate interpreter copy was introduced.

## Interpretation contract

The subset must retain, rather than guess, all of:

| Construct | Required meaning / rejection boundary |
|---|---|
| `Int64`, `Builtin.Int64` | Signed 64-bit value and its wrapper; reject other widths/types initially |
| `Builtin.Int1` | Exactly one bit; interpret the observed `0` and `-1` literals consistently |
| `integer_literal` | Validate type and range, not just parse digits |
| `struct_extract`, `struct` | Only the observed `Int64._value` wrapper operations |
| `cmp_slt_Int64` | Signed comparison in the actual operand order |
| `sadd_with_overflow_Int64`, `ssub_with_overflow_Int64` | Preserve partial value and overflow result; establish the semantics of the flag operand before accepting it |
| `tuple_extract` | Typed tuple index; reject invalid indices or mismatched values |
| `cond_fail` | A true condition yields a modeled trap |
| `cond_br`, `br` | Exact successors and block arguments, including the merged return value |
| `return` | The resolved SSA value, not the contract's expected expression |
| `debug_value`, `loc`, `scope` | Non-executing metadata retained for diagnostics, not proof evidence |

Validate definitions/uses, block-argument types, terminators, target existence,
and an acyclic reachable graph. Reject unknown executable instructions and
calls; do not recover by dropping a line.

Initially accept only the observed checked-arithmetic lowering patterns.
Wrapping increment must be rejected explicitly, despite sharing a builtin
name with checked increment. Modeling a builtin as immediately trapping is not
equivalent to computing its partial value and separately executing `cond_fail`;
either preserve that distinction or validate a lowering pattern for which
collapsing them is justified.

## Execution sequence and evidence gates

- [x] Add a parser test for one actual clamped-discount body, plus rejection of
  an unknown instruction and a missing/ill-typed block argument. Observe failure
  before implementing the typed reader.
- [x] Interpret straight-line zero, increment, and subtraction. Compare `0`,
  `1`, `-1`, `Int64.min`, and `Int64.max` cases against the native executables;
  keep trapping executions in child processes.
- [x] Add clamped discount's four-block graph. Compare `(0, 1) -> 0`,
  `(100, 20) -> 80`, `(max, 0) -> max`, and `(max, -1) -> trap`.
- [x] Challenge the whole compiler-to-interpreter connection with changed
  bodies, unchanged sample expectations, unknown calls, wrapping arithmetic, and altered
  artifact/source identities. None may silently become the old interpretation.
  A formal contract parser remains deferred to the proof experiment.
- [x] Record operation coverage, returned-value agreement, trap agreement,
  rejection results, and stage timings. Count all exclusions and failures.

For successful native comparisons, assert both output value and outcome class.
Do not encode native traps as arbitrary integer sentinels. A tool error or
interpreter error is not an arithmetic trap.

## Acceptance and stop condition

Continue only if all four candidate bodies are extracted mechanically, all
declared comparisons agree with compiled Swift, all rejection controls fail
explicitly, and source/configuration binding is checked.

If this requires general heap/call modeling or broad SIL support, narrow the
accepted grammar or stop. Do not expand the language merely to turn examples
green, and do not call finite interpreter agreement a formal equivalence proof.

The completed report must distinguish:

```text
EXTRACTED / RETURNED / ARITHMETIC TRAP
UNSUPPORTED / INVALID ARTIFACT / TOOL ERROR
```

There is no `PROVED` result in this experiment.

## Later proof experiment, not part of 0.0.2

Once extraction has evidence, the next plan can generate Lean statements from
this actual IR, define precise checked-integer semantics, and prove the IR's
verification rules. Start with the clamped-discount contract and safety
obligations, then grow toward the five-function milestone.

That version must include a strict contract representation, a checked
precondition witness, all reachable arithmetic safety obligations, an
expected-theorem manifest, transitive axiom auditing, and source/configuration
identity checks. False or missing proofs, `sorryAx`, stale results, unknown
operations, and checker failure must never produce `PROVED`.

API syntax and the architecture remain replaceable. The evidence boundary does
not: model proofs, sampled agreement, and source-linked implementation claims
must remain separate.
