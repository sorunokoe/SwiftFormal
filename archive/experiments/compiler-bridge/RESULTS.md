# Compiler bridge experiment results

**Version:** 0.0.1, 3 November 2026.
**Decision:** continue, narrowly, with canonical `-Onone` SIL.
**Evidence kind:** compiler inspection and finite executable observations.
No Swift implementation proofs, translator, contract macros, or stable API
were implemented in this version.

## Question and hypothesis

Can a compiler-resolved representation expose enough meaning to attempt a tiny
Swift verifier without a compiler fork?

Hypothesis: after mandatory compiler lowering, scalar operations will expose
machine arithmetic and traps while retaining useful source locations. Raw SIL
may retain opaque calls; optimized SIL may obscure the original structure.

## Configuration and exact commands

Observed configuration:

| Item | Value |
|---|---|
| Compiler | Apple Swift 6.4, `swiftlang-6.4.0.34.1`, Clang `2100.3.34.1` |
| Host/default target | `arm64-apple-macosx27.0.0` |
| macOS SDK | 27.0, selected through `xcrun --sdk macosx` |
| Python | 3.14.8 |
| Fixture module | `BridgeFixture` |
| Language source | `Fixture.swift` and `main.swift`, hashed in each report |
| Version control | This workspace was not a Git repository; no repository, tag, or release was created |

Reproduce:

```bash
python3 experiments/compiler-bridge/collect.py
python3 -B -m unittest discover -s experiments/compiler-bridge -p 'test_*.py' -v
swift test --package-path prototype --quiet
```

The collector records the resolved executable/SDK paths and complete argument
arrays in `.artifacts/report.json`. Its compiler operations are:

```text
swiftc -sdk SDK -parse-as-library -module-name BridgeFixture -g \
  -emit-silgen -Onone Fixture.swift -o silgen.sil
swiftc -sdk SDK -parse-as-library -module-name BridgeFixture -g \
  -emit-sil -Onone Fixture.swift -o sil-onone.sil
swiftc -sdk SDK -parse-as-library -module-name BridgeFixture -g \
  -emit-sil -O Fixture.swift -o sil-optimized.sil
swiftc -sdk SDK -g -Onone Fixture.swift main.swift -o oracle-debug
swiftc -sdk SDK -g -O Fixture.swift main.swift -o oracle-release
```

`SDK` in this display means the concrete path returned by `xcrun`, not a literal
argument. The JSON contains the directly runnable, fully resolved commands.

### First failure: SDK context was missing

Calling the absolute compiler path returned by `xcrun --find swiftc` initially
failed with:

```text
unable to load standard library for target 'arm64-apple-macosx27.0.0'
```

`xcrun swiftc -### ...` showed that invocation through `xcrun` supplied the SDK
path. Passing that same path explicitly to the absolute compiler fixed the
failure without changing source, target, or optimization level.

**Learning:** compiler path and version are not the complete build context.
Record and pass the SDK explicitly. Do not solve extraction failures by silently
switching compiler or deployment target.

## Observed executable behavior

All rows below were observed in both `-Onone` and `-O`.
Let `max = 9223372036854775807` and `min = -9223372036854775808`.

| Operation | Inputs | Observed result |
|---|---|---|
| clamped discount | `0, 1` | `0` |
| clamped discount | `100, 20` | `80` |
| clamped discount | `max, 0` | `max` |
| clamped discount | `max, max` | `0` |
| raw discount | `0, 1` | `-1`, incorrect for the intended clamped rule |
| always zero | `100, 20` | `0`, incorrect for the intended exact result 80 |
| checked increment | `0` | `1` |
| wrapping increment | `max` | `min` |
| custom subtraction | `Amount(10), Amount(3)` | `42`, not integer subtraction |
| effectful discount | `100, 20` | Prints `effect`, then `80` |
| checked increment | `max` | `SIGTRAP` |
| raw discount | `min, 1` | `SIGTRAP` |
| clamped discount | `max, -1` | `SIGTRAP` |

Total: 26 observations, 20 returned outputs and six expected trap signals.
The last clamped case is outside the proposed nonnegative-input contract; it
shows why that contract matters, not a counterexample within its domain.

The trap children returned signal 5 with empty captured diagnostics on this
host. Source inspection and each corresponding SIL `cond_fail` establish the
arithmetic-overflow path in these controlled fixtures. The signal alone does
not identify a cause; any arbitrary nonzero exit is rejected by the collector,
and even a trap signal must not be treated as a general proof of overflow.

The first successful persistent collection took 2.941 seconds wall time,
including compiler discovery, compilation, and child executions. Another
collector was running against an independent temporary output directory at the
same time. **This is an uncontrolled observation, not a benchmark or latency
guarantee.** Every run records its own timings.

## Operation inventory and source mapping

These symbols are observations of this exact compiler/module configuration,
not stable public identifiers. In the table, append each suffix to
`$s13BridgeFixture` to obtain the complete mangled symbol.

| Function / symbol suffix | Canonical signature | Blocks | Meaning in `sil-onone.sil` |
|---|---|---|---|
| clamped / `15clampedDiscountys5Int64VAD_ADtF` | `(Int64, Int64) -> Int64` | 4 | Signed comparison, conditional branch, zero or checked subtraction, block argument merge, return |
| raw / `11rawDiscountys5Int64VAD_ADtF` | `(Int64, Int64) -> Int64` | 1 | Checked subtraction and `cond_fail` |
| zero / `10alwaysZeroys5Int64VAD_ADtF` | `(Int64, Int64) -> Int64` | 1 | Literal zero, `Int64` construction, return |
| increment / `9incrementys5Int64VADF` | `(Int64) -> Int64` | 1 | Checked addition by one and `cond_fail` |
| wrapping / `17wrappingIncrementys5Int64VADF` | `(Int64) -> Int64` | 1 | Addition by one with the overflow result discarded |
| effectful / `17effectfulDiscountys5Int64VAD_ADtF` | `(Int64, Int64) -> Int64` | 1 | Array/string setup, `print`, releases, call to clamped discount |
| custom / `14customSubtractys5Int64VAA6AmountV_AFtF` | `(Amount, Amount) -> Int64` | 1 | Resolved `Amount.-` call, then field extraction |

For the scalar candidates, the relevant instruction set is:

```text
debug_value
integer_literal
struct_extract
struct
builtin
tuple_extract
cond_fail
cond_br
br
return
```

This is an inventory, not an implemented parser or permission to accept every
possible operand/type combination of those instructions.

### Branch and trap information survive

In `sil-onone.sil`, clamped discount compares the subtotal bits to the discount
bits with `cmp_slt_Int64`, then branches. Its subtraction block includes:

```text
%14 = builtin "ssub_with_overflow_Int64"(%11, %12, %13) : $(Builtin.Int64, Builtin.Int1)
%15 = tuple_extract %14, 0
%16 = tuple_extract %14, 1
cond_fail %16, "arithmetic overflow"
```

Source metadata on these instructions points to `Fixture.swift:5:21`, the
subtraction operator. `sil_scope` associates the function with
`Fixture.swift:1:13`. The branch has its own source location at line 2.
The real artifact retains these locations; they are omitted above for clarity.

The four basic blocks distinguish the two return paths and the merged return
value. A later extractor must preserve branch arguments and SSA value identity;
matching an operation name alone is insufficient.

### Checked and wrapping arithmetic share a builtin

Checked increment has:

```text
%4 = integer_literal $Builtin.Int1, -1
%5 = builtin "sadd_with_overflow_Int64"(%3, %2, %4) : $(Builtin.Int64, Builtin.Int1)
%6 = tuple_extract %5, 0
%7 = tuple_extract %5, 1
cond_fail %7, "arithmetic overflow"
```

Wrapping increment has:

```text
%4 = integer_literal $Builtin.Int1, 0
%5 = builtin "sadd_with_overflow_Int64"(%2, %3, %4) : $(Builtin.Int64, Builtin.Int1)
%6 = tuple_extract %5, 0
```

The flag operand and the use of the overflow result differ. The extractor must
model the actual data flow and trap behavior. Version 0.0.1 does not establish
general semantics for every builtin flag combination.

### Calls retain their identity before optional optimization

Raw SIL resolves ordinary subtraction to
`$ss5Int64V1soiyA2B_ABtFZ`, but only declares that function's body.
Canonical SIL lowers the scalar fixture's operation to the builtin and trap.

The custom operator instead resolves to
`$s13BridgeFixture6AmountV1soiyA2C_ACtFZ`. In canonical unoptimized SIL the call is
still explicit. Its implementation constructs the constant 42. It must not be
mistaken for integer subtraction.

Effectful discount contains an actual `print` call to
`$ss5print_9separator10terminatoryypd_S2StF`, plus allocations and releases.
These are concrete reasons to exclude it from an initial pure-scalar extractor.
No framework or heap semantics need to be invented to handle this fixture:
report it as unsupported in that future extractor.

## Chosen extraction representation and why

Choose **canonical SIL emitted with `-emit-sil -Onone -g`** for the next
experiment, tied to the observed toolchain.

It is the earliest of the three inspected representations where the selected
scalar functions expose all arithmetic and trap behavior without opaque callee
bodies. It also preserves direct source locations and explicit custom/effectful
calls.

Do not infer that every `Int64` function, compiler version, or platform lowers
this way. The next experiment must check types, operands, control flow, and a
strict supported instruction set, rejecting unknown input.

## Evidence against using the alternatives

| Representation | Observed size | Evidence |
|---|---|---|
| Raw SIL | 343 lines / 24,158 bytes | Smaller file, but scalar arithmetic remains in external declarations; wrapping addition also has generic calls and stack operations |
| Canonical `-Onone` | 1,061 lines / 80,419 bytes | Larger module because library bodies are emitted, but the selected scalar function bodies are simple and explicit |
| Canonical `-O` | 597 lines / 43,109 bytes | Scalar traps remain in these fixtures, but custom subtraction folds to constant 42 and the effectful function gains inlined scopes/control flow |

File size alone would pick the wrong stage. A future extractor should select the
requested function's body and dependency closure, not attempt to model every
unrelated standard-library definition in the file.

Optimized SIL may become useful later, particularly for checking the release
configuration. Here it adds source-mapping and transformation complexity without
solving a missing requirement. Agreement on these examples does not prove
equivalence between debug and release builds.

## Negative controls

The collector has four automated integration tests, using actual compiler
invocations rather than a mocked compiler:

1. The original fixtures produce three nonempty SIL artifacts and all 26
   expected observations with matching source hashes.
2. A nonexistent compiler fails and replaces a previous `passed` report with
   `failed`.
3. Replacing only clamped discount's final subtraction with `return 0` makes the
   `100, 20 -> 80` observation fail. The changed canonical body also loses its
   subtraction instruction.
4. Replacing checked increment's maximum-input trap with an ordinary `exit(1)`
   is rejected; nonzero exit is not sufficient evidence of a trap.

Mutations run on temporary copies of the two fixture files, not on the original
prototype or shared working sources. The test checks that the original fixture
remains unchanged. This safely automates the plan's mutate/observe/restore step.

The first two tests were observed failing before the collector existed. The
real integration run then exposed the missing-SDK failure before the fix.
All four tests subsequently passed. Existing prototype tests and its Lean model
demonstration also passed; their evidence is separate from this experiment.

## Trusted dependencies and unsupported constructs

This version trusts the compiler and OS to produce/run the fixtures, and the
collector/oracle expectations to describe the intended observations. It does
not prove the compiler, extract a formal model, or discharge any proof obligation.

Future extraction initially excludes custom types, unknown calls, effects,
wrapping arithmetic, heap operations, loops, recursion, async code, and unsupported
flags or toolchain configurations. Any future proof must still name its
compiler/translation assumptions and precise input domain.

This is a macOS host experiment. There is no iOS build, Linux validation,
production app integration, or claim that the compiler's SIL format is stable.
An artifact hash is an identity check, not a correctness proof.

## Continue, narrow, or stop

**Continue, narrowly.** The six required distinctions in the first-milestone
plan have concrete evidence: branches, actual return expressions, checked vs
wrapping arithmetic, custom operator identity, effects, and optimization/source
mapping differences.

The next question is not "can we support all Swift?" It is:

> Can a small, rejecting-by-default extractor interpret these particular
> canonical scalar bodies with the same returned values and traps as the native
> executables?

See the [0.0.2 experiment plan](../design/plans/2026-11-03-swiftformal-0.0.2-experiment.md).
The larger five-function proof milestone is split into smaller learning versions.
No parser, proof backend, macros, or library packaging is claimed complete here.

## Deviations from the original script sketch

- Explicit SDK propagation, required by the observed compiler failure.
- A single atomic `report.json` containing metadata, commands, observations,
  status, and errors instead of separate potentially stale metadata/output files.
- `-g` on executable builds too, so debugger inspection remains possible.
- Output/compiler/fixture arguments to make controlled experiments reproducible.
- Automated temporary-copy negative controls instead of editing shared sources.

The experiment remains a standalone, independently runnable directory. A SwiftPM
package would not answer the compiler-format question more directly, so package
scaffolding is deferred to the implementation that consumes the findings.
