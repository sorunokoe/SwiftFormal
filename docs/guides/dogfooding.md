# Dogfooding: the package verifies itself

Scan, Walk and symbolic proofs (`SFProve`) are run on this package's own code. This page records what was tried, what
worked and what did not. It is not a claim of full coverage: most of the package is outside the subset the tools can reason about.

## Scan on the package's own sources

Command: `sfverify --package . --target <T> --build` (the internal tool; today: `swiftformal check --scan .:<T>`).
This is an early measurement, when Scan decided only integer and Boolean functions without classes, closures, arrays
or strings. Scan reads more today; the table is not re-run. The engine modules are mostly types, arrays and classes.

| Target | Functions | Decided | Not in the subset |
|---|---|---|---|
| SFCNF | 6 | 0 | all (arrays, the `CNF` type) |
| SFBV | 74 | 4 safe (`GateKey`) | 70 (`BV`, `CNFBuilder`, ...) |
| SFCheck | 56 | 0 | all |
| SFSAT | 134 | 10 safe, 1 may trap | 123 |
| SFProve | 138 | 7 safe | 131 |
| SFSIL | mostly unsupported | | |
| SwiftFormal | none: `sfverify` could not compile the target | | the `@TaskLocal` macro plugin (`SwiftMacros`) is not found when sfverify invokes `swiftc` directly |

The `SwiftFormal` row was a tool limitation, not a result about `SwiftFormal`. Toolchain macros such as `@TaskLocal`
now compile with `--build`: see `docs/KNOWN-ISSUES.md` (item 2).

### What Scan found

One possible trap: `Solver.internalLit(_:)` in `Sources/SFSAT/Solver.swift`
(`lit > 0 ? 2 * (lit - 1) : 2 * (-lit - 1) + 1`).

- Counterexample: `lit = Int32.min` (negation overflows). The arithmetic also overflows for `lit` above about 2³⁰.
- **Not** a verdict-soundness bug: DIMACS variable numbers cannot be that large, and `CNFBuilder` allocates variables
  from 1 and cannot reach them.
- It is an input-validation issue in a package-internal function. Recorded in `docs/KNOWN-ISSUES.md` (item 1). The
  engine was not changed.

### What did not work

- Almost everything in the engine modules is `unsupported`. Scan is for small arithmetic functions; these modules are
  data structures. This is expected, and it is why Walk and symbolic proofs are used on the circuits instead.
- `internalLit` and `externalLit` are `private`, so no test can call them. Scan could check them only because it reads
  the source.

## Walk on the package's own domains and circuits

`Tests/SelfVerificationTests` runs `Prove` on the package's code, with plain Swift as the oracle:

- **`Domain`**: `int`, `product`, `union`, `optional`, `arrays`, `filter` and `evenlySpaced` list exactly what `Array`
  and `ClosedRange` say. A sample is never `proved`. One bad input in a complete domain is found. A seeded sampled
  run reproduces.
- **CNF gates** (`and`, `or`, `xor`, `mux`, `not`): decided by the SAT solver (not by constant folding) and compared
  with `&&`, `||`, `!=` and `?:`.
- **Bit-vector circuits** against Swift's `UInt8` / `Int8` operators for **all 65,536 operand pairs**: `&+ &- &*`,
  signed and unsigned comparisons, shifts, negation, division and remainder, and the six overflow flags against
  `addingReportingOverflow` and friends. Several seconds each in debug, so they are in `BitVectorSelfSlowTests` (slow
  lane).

All candidates and their properties: `Tests/SelfVerificationTests/CANDIDATES.md`.

## Symbolic proofs on identities of the circuits

`SFProve.prove` accepts UNSAT only after the independent checker (`SFCheck`) accepts the proof. So each `.proved`
below was also checked by a second implementation.

- **32 bits:** commutativity and associativity of `+`; `a + b == (a ^ b) + ((a & b) << 1)`; `a - b == a + ~b + 1`;
  `-a == ~a + 1`; `ult(a, b) == !ule(b, a)`; `slt` equals `ult` on sign-flipped operands; unsigned-add overflow means
  the wrapped sum is smaller than an operand.
- **8 bits:** `(a / b) * b + a % b == a` and `a % b < b`.
- **64 bits, sampled** (`SampledCircuitSelfSlowTests`): the same circuits against Swift's operators on values from
  three fixed seeds, including `0`, `1`, `UInt64.max`, `Int64.min` and `Int64.max`. A failure prints the seed, the
  sample number and both operands.

Limit: multiplier proofs are slow at wide widths (see `docs/TRUST.md`). So multiplication identities are exhaustive at
8 bits and sampled at 64.
