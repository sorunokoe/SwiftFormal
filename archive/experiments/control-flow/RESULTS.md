# SwiftFormal 0.0.7: ordinary control flow and branch growth

## Question

Which ordinary Swift control-flow forms work under the same discount contract,
and where does checking time grow when branches share a continuation?

```bash
python3 -B experiments/control-flow/run.py
```

For a bounded rerun, use repeatable `--case NAME` arguments and a separate
`--output PATH`. Selected batches always include the original baseline.
Their reports list the requested/scheduled cases and set `matrix_complete`
to false; a successful selected batch is not advertised as a complete matrix.
Every selected proof is checked again. This is case selection, not a proof cache.

The experiment reuses the existing Swift readers, exporters, independent Lean
reader, reference instruction semantics, and strict proof checker. It fixes
one proof-rendering defect exposed by repeated conditions, without changing
the model, contract, instruction semantics, or acceptance policy. There is
no caching or additional solver. Tool requirements remain those in the root README.

## Recorded outcome

The completed 13-case inventory contains **nine full SIL contract proofs,
two rejected seeded defects, and two unsupported source forms**. All 1,122
native/IR comparisons across the eleven supported cases agree. Neither seeded
defect was counted as an infrastructure control or a historical application bug.

All five ordinary cases passed all four proof stages. The seeded cases passed
translation and decoding but failed their actual return-value obligations:

| Case | Full result | Lean seconds | Bound-check seconds |
|---|---|---:|---:|
| Original | `SIL CONTRACT PROVED` | 111.565 | 159.373 |
| Strict `guard` | `SIL CONTRACT PROVED` | 62.274 | 65.704 |
| Early return | `SIL CONTRACT PROVED` | 81.522 | 90.363 |
| Joined `if` expression | `SIL CONTRACT PROVED` | 84.662 | 97.572 |
| Reused expression | `SIL CONTRACT PROVED` | 139.864 | 144.697 |
| Wrong guard return, retry | `UNPROVED`: `return_0` | 74.325 | 79.142 |
| Wrong joined return | `UNPROVED`: `return_0`, `return_2` | 171.958 | 183.018 |

The full-stage limit applies to the Lean subprocess, not total bound-check
time; the 183.018-second bound check did not exceed its Lean-process limit.
Times are individual observations, not performance rankings of Swift syntax.

## Source variants

All inputs are freshly compiled Swift. The original compiler-bridge fixture
is unchanged; `cases.py` replaces only its exact selected function and preserves
the other functions. No SIL is rewritten or supplied as a substitute compiler
artifact.

The ordinary cases are the original body, a strict-comparison `guard`, an
inverted early return, an `if` expression whose branches join into a local
result, and a calculated value reused in a comparison and a return.

The `guard` uses `discount < subtotal`. Equality returns zero, as required by
the unchanged rule; no inputs are excluded. The reused-expression case checks
the clamp before subtracting, retaining the original overflow behavior outside
the contract domain as well.

Two seeded variants compute or could compute the correct result but return
`subtotal` when it is below 50. One is based on the guard, the other on the
joined expression. The distinguishing input `(10, 3)` must return `7`;
both mutants return `10`. These are seeded defects, not historical bugs found
in application code.

The source probes also retain two common forms outside the supported profile:

| Source form | Observed unsupported SIL |
|---|---|
| `guard subtotal >= discount` | `builtin "cmp_sge_Int64"` |
| Declare `let result: Int64`, then assign in each branch | `alloc_stack [var_decl] $Int64` |

Deferred initialization introduces real stack-memory operations, not merely
debug metadata. The experiment does not ignore them. An initialized `if`
expression can express a joined result using the supported value-based
instructions, but that does not establish support for deferred initialization.

## Frozen promise

The exact existing contract checksum is:

```text
afffc343970ceb49c1b0d1917cab677ba3cc47ca8add17785d76ae588d3abd4b
```

For every nonnegative `Int64` pair, the function must return exact clamped
subtraction without a modeled arithmetic trap. Correspondence still covers
every signed `Int64` pair, including traps. Contracts concern actual returns,
not the names of local variables.

Each supported case also has 51 extracted input/boundary observations compared
with both native builds. Ordinary and growth cases must retain the original
observations; mutants must agree with their own faithfully extracted behavior.
This is sampled agreement, separate from the all-input proof.

## Deliberate branch-growth fixture

The four fixtures contain 1, 2, 4, or 8 **additional** branch-and-join diamonds
before the original clamp. Both sides forward the same discount value.
They are structural stress cases, not claims about typical business code.

The condition is deliberately repeated. This isolates continuation expansion
from the number of distinct comparisons and stays within the current distinct-
predicate limit. All compiler-generated branches must survive extraction;
the runner checks the resulting IR conditional count.

The measured compiler/exporter outputs show:

| Additional diamonds | IR conditionals, including clamp | IR instructions | Generated return obligations |
|---|---:|---:|---:|
| 1 | 2 | 26 | 4 |
| 2 | 3 | 33 | 8 |
| 4 | 5 | 47 | 32 |
| 8 | 9 | 75 | 512 |

These counts measure the current emitter, not the inherent difficulty of
the contract. The instruction graph grows linearly here; expanded return
obligations double for each additional diamond.

After the renderer repair, **all four growth cases passed all four stages**,
including the complete raw-SIL contract proof. The eight-diamond full check
audited 779 root theorems, not just the 771 roots of the isolated model check.

Generated sizes are UTF-8 bytes; the baseline has no additional diamond:

| Additional diamonds | Model expression | Model proof source | Full proof source | Full root obligations |
|---|---:|---:|---:|---:|
| 0 | 251 | 2,865 | 483,583 | 14 |
| 1 | 512 | 4,746 | 495,916 | 17 |
| 2 | 1,070 | 8,840 | 505,979 | 23 |
| 4 | 4,778 | 36,808 | 545,967 | 59 |
| 8 | 94,490 | 741,776 | 1,274,919 | 779 |

Each timing cell below is **Lean / total bound-check seconds**. Stages are
checked separately and must not be added to estimate a full check:

| Additional diamonds | Model | Translation | Decoding | Full |
|---|---:|---:|---:|---:|
| 0 | 18.439 / 27.491 | 15.088 / 19.341 | 32.845 / 37.781 | 111.565 / 159.373 |
| 1 | 16.192 / 32.973 | 10.885 / 14.600 | 32.062 / 42.865 | 98.760 / 102.197 |
| 2 | 2.064 / 3.867 | 2.653 / 4.515 | 30.574 / 33.204 | 131.881 / 135.853 |
| 4 | 2.710 / 5.439 | 3.230 / 5.688 | 33.536 / 37.492 | 98.800 / 103.242 |
| 8 | 4.993 / 7.693 | 4.290 / 6.499 | 38.941 / 50.321 | 103.379 / 115.350 |

Raw SIL grows from 80,419 bytes / 158 certified chunks at baseline to 89,327
bytes / 175 chunks at eight diamonds. Its growth is modest relative to the
expanded model and proof source. Full checking remains expensive, but these
noisy times do not establish an exponential checking-time curve.

## A proof-generator defect found and fixed

The first complete measurement run decoded and translated every growth case
successfully, but their business proofs failed with `` `simp` made no progress ``.
The strict gate correctly left these cases unproved.

The emitter's recursive `simp only` step simplified repeated conditions deeper
in the model. Its generated proof then tried to simplify those conditions
again, after they had already disappeared. This was a proof-script defect,
not a bad Swift result or a resource limit.

The repair changes the three conditional proof steps in
`../lean-proof/Sources/LeanProof/LeanEmitter.swift` to single `rw` steps using
the same existing `ite_eq_left`/`ite_eq_right` lemmas. Nested conditionals remain
available for their own generated proof steps. Nothing is admitted, no warning
is suppressed, and no return or safety obligation is removed.

`test_renderer.py` compiles a real one-diamond Swift fixture and invokes the
existing bound checker. It failed before the repair and passed afterward.
An isolated eight-diamond model also passed all 771 root audits with the
repaired proof strategy, while a seeded wrong return still failed.
The first renderer, failing source/verdict, and before/after checks are
preserved under `.artifacts/renderer-reproduction/`.

The affected Swift package tests and the real compiled regression pass:

```bash
swift test --package-path experiments/lean-proof
swift test --package-path experiments/translation-validation
python3 -B -m unittest discover -s experiments/control-flow -p 'test_*.py' -v
```

The complete 0.0.3 and 0.0.4 workflows were also rerun after the repair.
Their six/ten root audits and 23/18 controls pass, including seeded overflow,
unauthorized-proof, and mistranslation controls; 0.0.4 retains 306 native
agreements. The changed Swift file passes strict formatting with four-space
indentation. The readers, reference interpreter and checker policy were not
changed.

The remaining-case batch also passed all six Python tests, including the real
compiled regression and the case-selection regression. The complete 0.0.5 and
0.0.6 workflows were not rerun after this renderer change; their earlier reports
remain historical. The new cases exercise their reused full bound-checking path.

## Four separately checked stages

| Stage | Existing checker | What its successful verdict establishes | Lean process limit |
|---|---|---|---:|
| `model` | 0.0.3 | Generated model satisfies the business contract | 60 s |
| `translation` | 0.0.4, translation-only | Independent IR execution agrees with that model for all signed inputs | 60 s |
| `decoding` | 0.0.5, handoff-only | Complete raw SIL independently decodes to the exported IR | 180 s |
| `full` | 0.0.5, full proof | Contract and no-trap guarantee transferred to independently decoded SIL | 180 s |

The model-only and translation bundles must contain the same model. Every
stage uses the unchanged contract, exact theorem inventories and existing
axiom policy. A successful partial stage is never promoted to a full proof.

Each stage records the exact Lean input hash, Lean subprocess wall time,
total bound-check wall time, and their difference. Bound checks include
regeneration and identity checks. Decoding time includes certificate proposal,
elaboration and kernel checking, not just parser execution. The full proof
repeats work from other stages, so these times are not additive.

Build/environment setup, compiler collection, both exporters, composition,
and generated source sizes are recorded separately. The recorded post-fix
measurements span an interrupted run, a targeted retry, and a remaining-case
batch. They are wall-clock observations, not controlled cold/warm or CPU
benchmarks.

The interrupted run hit the existing 180-second limit on the seeded guard's
full check. A retry of that exact bundle, without increasing the limit, finished
in 79.142 seconds and failed at `SwiftFormalV003.return_0`. The original timeout
is retained alongside the retry; the first run's report remains `failed`.
This variation rules out treating a single time comparison as a reliable
speedup or slowdown.

Only a real subprocess timeout becomes `LIMIT`. Missing tools and malformed
evidence remain errors. A growth case without a successful full proof is
`UNKNOWN`, even if native samples or partial proofs pass. `UNPROVED` alone
does not establish that the Swift function is incorrect.

Ordinary cases require all four stages to pass. Seeded cases require successful
translation and decoding, and model/full failures specifically at return-value
obligations. Their concrete bad native outputs distinguish a real seeded
contract violation from an infrastructure failure.

## Evidence and boundaries

The output directory contains `report.json`, `run.log` when run through the
recorded shell command, and the pinned `environment.json`. Each case has its
fixture sources, native compiler collection, generated bundles, and exact
Lean sources and measured verdicts for applicable stages. Unsupported forms
keep their fresh compiler artifacts and precise exporter rejection reasons.

All checks use the existing bound verification paths. The runner rechecks
source and exporter identities, saved bundles, compiler collections, fixture
sources, native binaries, SIL artifacts, and the Lean environment before
marking the experiment complete. A new report starts as `running`; only
completion of all scheduled checks can mark it `passed`. The separate
`matrix_complete` field identifies whether all cases were scheduled.

`passed` describes completion of the experiment's checks, not verification of
an `UNKNOWN` or `UNSUPPORTED` case. Use `--output PATH` for a separate
single-writer run.

The recorded inventory is `.artifacts/measurement-summary.json`. It points to
the exact report and case directory for each result, without rewriting failed
runs or treating an earlier passed flag as a build gate:

| Evidence | Role |
|---|---|
| `report.json` | Interrupted post-fix run; supplies guard, early-return, joined and reused measurements |
| `wrong-guard-return/recovered-report.json` | Same-limit full retry plus completed native comparisons; original timeout retained separately |
| `remaining/report.json` | Successful selected batch: original baseline, joined mutant, four growth cases and two unsupported forms |
| `renderer-reproduction/before-report.json` | Earlier pre-fix results; not used as successful post-fix evidence |

The final inventory audit regenerated every supported bundle, compared current
sources/artifacts and Lean environment identities, reapplied the existing
theorem/axiom policy to recorded Lean output, and checked native command
results against the observations. It did not rerun Lean or introduce proof-cache
acceptance. Only the case-selection driver and its test changed between the
post-fix measurement batches; all proof-core sources stayed unchanged.
The repeated original case is counted once, from the remaining-case batch.

The Swift compiler, the chosen SIL grammar/reference semantics, artifact
binding and checking infrastructure remain assumptions. This is still one
fixed contract and a narrow instruction profile, not general Swift verification.
There is no new library API or protected AI contract-approval mechanism.

## Decision for the next experiment

**Preserve shared blocks in the generated model and proof structure.** From
four to eight diamonds, the IR grows from 47 to 75 instructions, but return
obligations grow from 32 to 512 and model-proof source from 36,808 to 741,776
bytes. The renderer repair restores valid proofs; it does not remove this
structural expansion.

For 0.0.8, keep the same contract, independent decoding, correspondence checks
and negative controls, then rerun this corpus with a block-preserving
representation. Measure source size and checking stages again; enforce an
explicit generation budget before trying larger inputs. Sharing should reduce
artificial duplication, not be advertised as a general linear-time proof solver.
Caching unchanged results would not solve first-check expansion. A larger DSL,
new solver or custom numeric types are not justified by these measurements.
