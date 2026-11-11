# What scales, and what does not

Measured limits only; nothing here is a guess. Unless a row says otherwise: 2026-11-05, Apple silicon, Apple Swift
6.4, release build. How the counts are taken: [PERFORMANCE](PERFORMANCE.md).

## Scan and symbolic proofs: width and operators

Adders, comparisons and branches scale. Multiplication and division do not.

| Claim | Result | Source |
|---|---|---|
| 8-bit index kernel with two multiplications (gated example `cellIndex`) | decided in 0.02 s | [gate guide](guides/gate.md) |
| The same kernel, `Examples/Metrics` `cellIndex` | proved with 851 conflicts, 5 311 clauses | [PERFORMANCE](PERFORMANCE.md) |
| 16-bit discount (`proveSigned`) | about 40 s | [symbolic proofs guide](guides/prove.md) |
| 16-bit index kernel with two multiplications | undecided at 100 000 conflicts (5.1 s) | [gate guide](guides/gate.md) |
| The 32-bit version of the same kernel | undecided at 300 000 conflicts (27 s, release); over 34 minutes in a debug-built `sfverify` (the internal engine command) before it was stopped | [gate guide](guides/gate.md) |
| 32-bit `a &* b == b &* a` (`Examples/Metrics` `mulCommutes32`) | undecided at 20 000 conflicts: 20 930 variables, 70 566 clauses | [PERFORMANCE](PERFORMANCE.md) |
| A miter with 32-bit division or multiplication | does not finish in minutes, so the soundness zoo uses 5 to 8 bits | [soundness zoo](guides/soundness-zoo.md) |
| `-O` against `-Onone` equivalence of `Int32` div and rem | 405 s and still unknown before structural hashing; 0.4 s and proved after | [research notes](../archive/research/2026-11-05-triz-and-swift-semantics.md) |

What this means for you:

- **The conflict budget does not bound time.** A wide multiplier is slow per conflict (see the 32-bit row). Use a
  release-built `swiftformal`. An undecided function is never a pass: `swiftformal check --gate` warns, and fails with
  `--strict`.
- **Narrow the types.** A real range shrinks the multiplier. A 64-bit signed multiply of two 32-bit signed operands is
  proved in 0.006 s; unconstrained, it was unknown after 300 000 conflicts (about 270 s). In symbolic proofs
  (`SFProve`): `inputSignedBits`.
- **Abstract the multiplier for algebraic claims.** `strategy: .refiningMultipliers` proves, in about a millisecond,
  commutativity at 10, 12, 16 and 32 bits, associativity at 8, 16 and 32, and distributivity at 8 and 16; the exact
  strategy was unknown. Claims that need the real multiplier (`(a+1)² == a² + 2a + 1`) refine to the exact circuit and
  stay as hard. Scan does not use this strategy yet, so `mulCommutes32` stays undecided there.
- **Full-width variable × variable multiplication is not helped** by any of this. Commutativity at 8 bits with the
  exact circuit took about 5 s when last measured.

## Walk: the size of the domain

- A walk (`Prove`, `verify_<name>()`) enumerates the whole domain up to `Budget.maxEvaluations` (default
  **1 000 000** evaluations).
- Past that it takes a seeded sample (`Budget.seed`, default `0x5F0F_A117`), so a sampled run reproduces exactly. The
  verdict is then `bounded`, never `proved`. This is defined behaviour (`Sources/SwiftFormal/Report.swift`), not a
  timing.
- A larger domain is not slower per input; it is just not enumerated. To enumerate it, widen the budget, or narrow the
  domain (`@Values`, refined types).

## The proof cache

A hit costs one lookup instead of a solver run. It pays off only for proofs slower than about 1 ms (research notes,
2026-11-05). `ProofCacheTests.coldVersusWarm` prints cold, warm and re-check times for four small claims on every run.
They are not recorded here: the machine was loaded, and the test says so.

## Time of the toolchain around the prover

Scan compiles with the real `swiftc`, so a small target costs a compile plus the proof. The gated example took:

- 0.5 s with a release-built `sfverify`;
- 2.6 s through the build plugin (since removed) in a debug `swift build`;
- about 4.6 s through Xcode or Tuist (gate guide).

The six kernels of `Examples/Metrics` compile and verify in about 2 s; 1.5 s of it is the solver, mostly
`mulCommutes32` up to its budget.

Larger Scan runs: a generated module of 8 192 functions
([PERFORMANCE](PERFORMANCE.md#wall-time-benchmarks-reported-never-compared)) and a 20-package app
([PERFORMANCE](PERFORMANCE.md#scanning-a-multi-package-app)). Coverage of real packages:
[research notes](../archive/research/2026-11-05-triz-and-swift-semantics.md) §6g.

## Not yet measured

- Domain sizes between 10⁶ and the sample: no time per input recorded.
- A comparison against another solver.
