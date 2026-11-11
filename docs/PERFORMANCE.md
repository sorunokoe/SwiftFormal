# Performance

How the prover's cost is measured, and how to read the numbers. What scales and what does not: [SCALING](SCALING.md).

## What is measured, and why it is not time

Wall time on a shared machine is noisy, so no check compares it. The solver is deterministic, so the **work it does is
an exact count**:

| Count | Source | Meaning |
|---|---|---|
| `solverConflicts` | `SolveStats.conflicts` (`SFSAT`) | Conflicts of the CDCL search: how hard the formula was. With a refinement strategy, the sum over all rounds. |
| `cnfVariables` | `SolveStats.variables` | Variables of the formula given to the solver. |
| `cnfClauses` | `CNFBuilder.cnf` | Original clauses (not learned) of the whole formula the encoder built. The solver gets only the goal's cone (`CNFCone`). |

- `sfverify --json --stats` (`sfverify` is the internal engine command, built from a checkout) adds the three counts to each function that reaches the solver
  ([the JSON report](guides/scan.md#the-json-report---json-schema-version-1)). Without `--stats` the keys are absent.
- Budget ran out: `conflicts = budget + 1`, verdict `undecided`.
- The counts depend on the solver, the encoder and the semantics, not on the machine. A change there must show its
  effect in them.

## The baseline

[`Examples/Metrics`](../Examples/Metrics/Kernels.swift) has six fixed kernels. `Scripts/metrics.py` runs
`sfverify --stats` on them (conflict budget 20 000) and compares with `Scripts/baseline/metrics.json`:

```
python3 Scripts/metrics.py              # compare; exit 1 on a regression
python3 Scripts/metrics.py --record     # re-record the baseline
python3 Scripts/metrics.py --out FILE   # also write what was measured
```

| Rule | Limit |
|---|---|
| Verdict (`status`) | identical |
| `solverConflicts`, `cnfClauses` | at most +10 percent over the baseline (a decrease passes) |
| `cnfVariables`, wall time | recorded or printed, never compared |

A failure names the function and both numbers. The script also validates the JSON against
[`docs/schemas/scan-report.schema.json`](schemas/scan-report.schema.json), with and without `--stats`.
The safety net runs it (about 3 s once `sfverify` is built).

Recorded 2026-11-05 (Apple M4 Pro, Apple Swift 6.4, release `sfverify`):

| Kernel | Verdict | Conflicts | Variables | Clauses |
|---|---|---:|---:|---:|
| `adder` (8-bit add, contract) | contractHolds | 0 | 54 | 128 |
| `clamp` (branches, contract) | contractHolds | 389 | 269 | 809 |
| `discount` (8-bit multiply, divide by 100) | contractHolds | 1 822 | 1 337 | 4 307 |
| `popcount8` (bit tricks, no loop) | contractHolds | 13 | 50 | 143 |
| `cellIndex` (8-bit index with two multiplications) | contractHolds | 851 | 1 619 | 5 311 |
| `mulCommutes32` (32-bit `a &* b == b &* a`) | undecided | 20 001 | 20 930 | 70 566 |

`mulCommutes32` is undecided **on purpose**: if a solver change decides it, the check fails and someone re-records.
`popcount8` has no loop because loops are outside the supported subset.

## When the check fails

1. **Verdict changed:** a real behaviour change. Find out why first (`Scripts/check-golden.sh` should fail too if it
   touches the gated example).
2. **Conflicts or clauses grew over 10 percent:** proofs got more expensive. Fix it, or, if worth it (for example a
   more precise encoding), run `--record` in the same commit and say why in the message.
3. **Conflicts fell:** nothing fails. Record it, so the next regression is measured against it.

## Wall-time benchmarks (reported, never compared)

[`Benchmarks/`](../Benchmarks) is a separate package (users never fetch it). It times the walk behind `Prove` and the
one behind `verify_<name>()` (package functions, reached with `@testable import`), `Contract.requires`, grouping
outputs and three symbolic proofs (`SFProve`'s `proveSigned` and `prove`). `swift run -c release -Xswiftc -enable-testing -Xlinker -rpath -Xlinker "$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks" --package-path Benchmarks benchmarks`
prints the best of five (the rpath finds the Testing.framework that SwiftFormalTesting links); `--only <text>` and
`--repeat <n>` narrow it. Nothing fails on these numbers.

All results: Apple M4 Pro, Apple Swift 6.4.

**2026-11-06**, best of 3, loaded machine (`SampleSequenceTests` checks that walks visit the same inputs as before):

| Workload | Before | After |
|---|---:|---:|
| `runWalk` (behind `Prove`), 1 000 000 inputs, no properties | 157 ms | 19 ms |
| `runWalk` (behind `Prove`), 1 000 000 inputs, two properties | 221 ms | 54 ms |
| `runWalk` (behind `Prove`), 1 000 000 inputs of a 3-field product | 195 ms | 28 ms |
| `runWalk` (behind `Prove`), 1 000 000 sampled inputs | 137 ms | 19 ms |
| `@Verify` walk (`verify_<name>`), 100 000 inputs | 30 ms | 8 ms |
| `Contract.requires`, 1 000 000 calls | 10.6 ms | 1.8 ms |
| `runPartition`, 100 000 inputs into 20 000 outputs | 41.2 s | 15 ms |
| `proveSigned` (`SFProve`), 16-bit discount | 69 ms | 66 ms |
| `prove` (`SFProve`), 32-bit `a*b == b*a` to 20 000 conflicts | 1.15 s | 1.08 s |

**2026-11-07**, best of 3, loaded machine:

| Workload | Before | After |
|---|---:|---:|
| `runWalk` (behind `Prove`), 1 000 000 inputs, no properties | 18.3 ms | 4.9 ms |
| `runWalk` (behind `Prove`), a union of 2 000 parts | 354 ms | 3.6 ms |
| `runWalk` (behind `Prove`), 200 000 inputs of a 1 µs function, `parallelism: .threads(14)` | 211 ms (serial) | 46 ms |
| `runPartition`, 100 000 inputs | 14.4 ms | 4.0 ms |
| `runWalk` (behind `Prove`) over a 3-field product | 13.0 ms | 7.9 ms |
| `runWalk` (behind `Prove`) over a struct mapped from a product | 13.8 ms | 7.6 ms |

The same day, release `sfverify` and `swiftformal`, before and after run alternately, best of 3, same reports. The
`check` rows use a slightly later "before".

| Run | Before | After |
|---|---:|---:|
| `sfverify` on one file (`Examples/GatedPackage/Sources/Kernels`) | 0.55 s | 0.19 s |
| `sfverify --budget 1000 Examples/Metrics/*.swift` | 0.71 s | 0.25 s |
| `sfverify --package Examples/GatedPackage --target Kernels --build` | 3.71 s | 3.21 s |
| `sfverify --package . --target SFSIL --build` (links 6 targets) | 29.8 s | 7.7 s |
| `sfverify` on a generated module of 8 192 functions | 52.4 s | 7.7 s |
| `swiftformal check` on `Examples/Walk`, warm | 5.8 s | 4.7 s |
| `swiftformal check` on `Examples/Walk`, cold (no `.build`) | 39.7 s | 25.5 s |

**2026-11-08**, quiet machine, best of 3 to 5, same reports. `21cb1a8` is main before this work; `main` is main with
its own recheck fix (1eaa769).

| Run | 21cb1a8 | main | After |
|---|---:|---:|---:|
| `sfverify` on one file (`Examples/GatedPackage/Sources/Kernels`) | 0.48 s | 0.40 s | 0.25 s |
| `sfverify --budget 1000 Examples/Metrics/*.swift` | 0.90 s | 0.52 s | 0.32 s |
| `sfverify --package Examples/GatedPackage --target Kernels --build` | 3.0 s | 3.3 s | 3.1 s |
| `sfverify --package . --target SFSIL --build` | 210 s | 15.8 s | 8.4 s |
| `sfverify` on a generated module of 8 192 functions | 148 s | 20.2 s | 12.3 s |
| `swiftformal check` on `Examples/Walk`, warm | 7.9 s | 6.5 s | 6.5 s |
| `SILText.prepare`, 4 096 functions (scaling harness) | 0.97 s | | 0.38 s |
| `SILModule(text:)`, 4 096 functions (scaling harness) | 0.47 s | | 0.10 s |
| `Matches(table:)` with 8 192 rows (scaling harness) | about 9 s | | 3 ms |

At `-Onone`, Scan now compiles and verifies two configurations (debug and `-assert-config Release`): about twice the
work of 2026-11-07. The second compile runs alongside the first.

**2026-11-08, follow-ups** (against main after the work above, same reports):

| Run | Before | After |
|---|---:|---:|
| `sfverify` on one file (compiler answers kept on disk) | 0.28 s | 0.17 s |
| `sfverify` on a generated module of 8 192 functions (recheck rendered on several threads) | 13.2 s | 10.6 s |
| `sfverify --package . --target SFSIL --build` (same) | 10.3 s | 8.6 s |
| `swiftformal check` on `Examples/Walk`, warm (one build with the tests) | 7.2 s | 4.6 s |
| `swiftformal check --gate` of two targets after a `swift build` (one package build) | 4.6 s | 3.5 s |

## Scanning a multi-package app

2026-11-08, a production iOS app: 20 SwiftPM packages, SwiftUI and TCA, Apple Swift 6.4, `sfverify --build --json`,
`-Onone`, cold builds. Wall times include the SwiftPM build. Scan then built in `.build/sfverify`; it now uses the
package's own `.build` (maybe already warm), but each leaf package still builds its own dependencies.

| How | First target | Each further target | Disk |
|---|---:|---:|---:|
| Each leaf package on its own (`--package Features/X`) | 110 to 140 s | 110 to 140 s (the dependencies are built again) | about 2 GB per package, 37 GB for 19 |
| Through the umbrella package (`--package App/Packages --target X`) | 69 s (with the first feature target) | 19 to 24 s | 2.1 GB in all |

Same verdicts both ways (checked on four targets). Proving is not the cost: verifying all 19 targets took 5 s in
total; compiling to SIL took about 53 s per target cold, 6 to 7 s warm. Recipe: [Scan guide](guides/scan.md).

### With the proof cache

2026-11-08, same app: `swiftformal check` with four `--scan` modules and the walk tests, release binaries, debug and
release configurations. Shared machine (load 9 to 66), so seconds vary by tens of percent. Per-function verdicts were
identical to the run without the cache every time.

| Run | Wall | AppCore | AppUICore | AppFeature | AppSettings | Answers from the cache |
|---|---:|---:|---:|---:|---:|---:|
| Without the cache (before) | 118 s | 3 s | 12 s | 51 s | 27 s | — |
| Cold (empty cache) | 122 s | 8 s | 23 s | 44 s | 24 s | 0, 2596 stored |
| Warm (no change) | 101 s | 3 s | 13 s | 38 s | 23 s | 2596 of 2707 |
| After a one-line edit in AppFeature | 141 s | 3 s | 12 s | 77 s | 24 s | 2594; 2 solved again |

- Keys took 0.04 to 0.57 s per module.
- The 111 answers not from the cache are never stored (`undecided`, unsupported).
- The cache saves solving, not compiling. Compiling and linking to SIL runs every time: about 94 % of a warm module.

`swiftformal check --gate` skips a passing target whose stamp still matches ([Scan guide](guides/scan.md)). On
AppFeature (the app's only target with promises), release binaries, load 12 to 22:

| Run | Wall |
|---|---:|
| Empty cache, already built | 13.5 s |
| Unchanged | 4.1 to 4.5 s (the null `swift build` alone takes 3.5 s) |
| After a one-line edit | 13.4 s (12 answers from the proof cache) |

### One-file SIL and parallel modules (measured, not shipped)

2026-11-09, AppFeature (116 files), the frontend command `check` runs, shared machine:

| Step | Time |
|---|---:|
| Whole-module `-emit-sil` (46 MB of SIL) | 4.1 to 4.3 s |
| The same, with one `-primary-file` (0.47 MB) | 0.35 s |
| Type-checking alone | 2.6 s |
| Warm `sfverify --at`: SIL for 2 configurations and 4 dependencies (summed, run in parallel) / parse / prove | 11.9 / 3.0 / 1.7 s; 13.4 s wall |
| Null `swift build` (always needed) | 3.3 s |

A one-file fast path would win at most 2.5 to 3×, and it is **not sound**. Primary-file SIL is a different
compilation: 11 of its 80 bodies differ from the whole-module ones. It also lacks other files' bodies, deinits, witness
tables (3 against 587) and globals, which Scan needs for module-wide facts such as "no deinit runs code". Details:
`archive/design/plans/2026-11-08-dx-and-speed.md`, section "Phase 3".

The four `--scan` modules as four concurrent processes: 28.8 and 26.5 s warm, against 55.5 and 65.8 s one after
another; identical verdicts on 2,994 functions; 0.25 to 0.69 GB peak memory per module. This now runs in one process
(next section).

### Packages scanned at the same time (`check --jobs`)

2026-11-09, same command and app (four `--scan` packages, each with its own `.build`, plus the walk tests). Release
binary, warm builds, warm proof cache, shared 14-core machine (load 5 to 7), runs alternated:

| `--jobs` | Runs | Wall | Peak memory (resident) |
|---|---|---:|---:|
| 1 (one target at a time, as before) | 1st and 4th | 54.9 s, 59.0 s | 0.71 GB, 0.72 GB |
| default (4 here: one per package) | 2nd and 3rd | 34.5 s, 34.7 s | 0.87 GB, 0.88 GB |

- The scans end with the longest module (AppFeature, 14 s). The walks (19 s) are now most of what is left.
- Identical verdicts on all 2,994 functions. `--xcode` output byte-identical.
- `--json` byte-identical except two fields that also differ between two `--jobs 1` runs:
  `modules[].proofCache.keySeconds` (a time) and the compiler's `@opened("<UUID>")` archetype names in the `detail` of
  10 unsupported functions.
- Cold proof cache (first run with a new binary), default `--jobs`: 50.1 s.

## Scaling curves (reported, never compared)

A benchmark at one size cannot show that a step grows faster than its input. `Scripts/scaling.sh <out-dir>` times each
engine step at sizes 16, 32, ... up to 2^20 (`SCALING_MAX_POW=N` caps it), with
[swift-collections-benchmark](https://github.com/apple/swift-collections-benchmark). It draws one log-log chart per
group (`Domain`, `runWalk`, `CNFBuilder`, `LRAT`, `SIL`) and writes each task's slope to `slopes.txt` (1 is linear;
`SUPER` marks a slope above 1.25). `Scripts/scaling.sh <out-dir> <old results.json>` also runs `results compare`
between two runs.

The first runs found five steps that grew faster than their input (contract matching, `Domain.union`,
`SILModule.symbol`, `Property.table`, proof-cache keys) and a false counterexample in `Property.injective`.

- **Developer-only.** The target exists only when `SWIFTFORMAL_BENCH` is set (like `SWIFTFORMAL_DOCS`), because it
  uses the engines' `package` declarations. The benchmark library needs macOS 15, so the platform floor is raised only
  under that variable. `Scripts/check-portability.py` checks that nobody else fetches it. The script builds into
  `.build/scaling` and restores `Package.resolved`.
- **By hand, report only.** `SCALING_MAX_POW=14 Scripts/scaling.sh <out-dir>` (13 minutes on an M4 Pro) warns for each
  slope that rose by more than 0.25 against `Scripts/baseline/scaling-slopes.json`. After an intended change, record
  that file from a run with the same setting.

## Profiling

- **Quick look:** `sample <pid> 3 -file out.txt`. Release products keep a `.dSYM`, so lines resolve.
- **Cost per component:** start a release `sfverify` in the background, wait past the compile, sample (attaching at
  process start can give an empty sample), then sum with `Scripts/sample-inclusive.py`:
  `sfverify k8192.swift > /dev/null & sleep 2.5; sample $! 4 -file out.txt; Scripts/sample-inclusive.py out.txt
  proveExactly SILEncoder.run LRATChecker Solver. 'cone()'`.
  On the 8,192-function module (2026-11-09), of the time in `proveExactly`: 50 % encoding, 36 % checking (almost all
  `LRATChecker.verify` loading the whole formula, line 103), 4 % solving.
- **`xctrace` with a timeout** (macOS has no `timeout`):
  `perl -e 'alarm 90; exec @ARGV' xcrun xctrace record --template 'Time Profiler' --time-limit 5s --launch -- <binary> ...`.
  CPU Counters works too (`xctrace export` reads its tables). Processor Trace needs the terminal in System Settings >
  Privacy & Security > Developer Tools.
- **Is a generic call specialized?** `nm -u <caller>.o | swift demangle`. An undefined generic symbol (`runWalk<A, B>`)
  means the unspecialized body runs. Public generic entry points are unspecialized in users' modules unless
  `@inlinable`, so keep their per-input state in non-generic storage (`ContiguousArray<Bool>`, not an array of a
  generic struct).
- **Span only as a local** (`array.mutableSpan` inside a function). A Span type in a signature, stored property or
  generic argument links `libswiftCompatibilitySpan.dylib`, which macOS 13 to 15 lack. `Scripts/check-portability.py`
  checks the command-line tools.

## Not measured here

- Test suite timings: [`Scripts/baseline/timings.md`](../Scripts/baseline/timings.md) (wall-clock observations).
- Cold and warm proof-cache timings: printed by `ProofCacheTests.coldVersusWarm` (release, noisy), not recorded.
