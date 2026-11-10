# Candidates for self-verification

Task Q.1 of the open-source readiness plan. Read-only inventory of pure functions with small inputs, each with the property that is checked, and the tier that checks it. The tests are in this folder; nothing here changes production code.

Tiers: **Walk** = `Prove` over a complete `Domain` (the real function runs, the oracle is plain Swift). **Prove** = `prove` with the independent checker (`SFCheck`) accepting the proof. **Scan** = `sfverify` over the module's sources, reported in [docs/guides/dogfooding.md](../../docs/guides/dogfooding.md).

| Path | Function | Property (the spec) | Tier | Test |
|---|---|---|---|---|
| `Sources/SwiftFormal/Domain.swift` | `Domain.int(_:)` | lists exactly `Array(lo...hi)` for every small range; saturates `count` for huge ranges | Walk | `DomainSelfTests` |
| `Sources/SwiftFormal/Domain.swift` | `product`, `union`, `optional`, `arrays(of:maxLength:)` | count is the product / sum / `n+1` / `1+k+…+kⁿ`; every element appears exactly once | Walk | `DomainSelfTests` |
| `Sources/SwiftFormal/Domain.swift` | `filter`, `evenlySpaced` | agrees with `Array.filter`; keeps first and last; never claims completeness after dropping values | Walk | `DomainSelfTests` |
| `Sources/SwiftFormal/Verify.swift` | `runWalk` | a sample is never `proved`; one bad input in a complete domain is found; a seeded sampled run reproduces | Walk | `DomainSelfTests` |
| `Sources/SFCNF/CNF.swift` | `CNF.isSatisfied(by:)` | equals the hand-written Boolean formula on every assignment | Walk | `GateSelfTests` |
| `Sources/SFBV/CNFBuilder.swift` | `and`, `or`, `xor`, `mux`, `not`, `constant` | the clauses (decided by the solver, not by folding) are Swift's `&&`, `\|\|`, `!=`, `?:`; constants round-trip | Walk | `GateSelfTests` |
| `Sources/SFBV/BitVec.swift`, `BitVecOps.swift` | `add`, `sub`, `mul`, comparisons, overflow flags | equal Swift's `&+ &- &*`, `< <= ==` (signed and unsigned) and `addingReportingOverflow` for all 65,536 pairs of 8-bit values | Walk | `BitVectorSelfTests` |
| `Sources/SFBV/BitVecOps.swift` | shifts, `negate`, `unsignedDivide`, `signedDivide` | equal Swift's `<< >>`, `0 &- x`, `/`, `%` for all 8-bit operands (`Int8.min / -1` excluded: it traps in Swift); out-of-range shift amounts are flagged | Walk | `BitVectorSelfTests` |
| `Sources/SFBV/BitVec*.swift` | the same operations at 64 bits | equal Swift's operators on seeded samples that include the boundary values | Walk (sampled) | `SampledCircuitSelfSlowTests` |
| `Sources/SFBV/BitVec.swift` | `add`, `sub`, `negate`, comparisons at 32 bits | commutative, associative, carry-save identity, `a - b == a + ~b + 1`, `-a == ~a + 1`, comparison trichotomy, `slt` = `ult` on sign-flipped values | Prove | `ProofSelfTests` |
| `Sources/SFBV/BitVecOps.swift` | `unsignedDivide` at 8 bits | `(a / b) * b + a % b == a` and `a % b < b` | Prove | `ProofSelfTests` |
| `Sources/SFSAT/Solver.swift` | `internalLit`, `externalLit` (private) | round trip for every literal of a real formula | not testable directly (private); `sfverify` finds the one input outside the contract, see the dogfooding guide | Scan |
| `Sources/SFCheck`, `Sources/SFSAT` | `LRATChecker`, `Solver` | not here: the solver is compared with a brute-force enumerator in `Tests/SoundnessZooTests` | — | `DifferentialTests` |

Not candidates: anything with strings, classes, closures, floating point or dictionaries (`sfverify` reports them `unsupported`, so only Walk applies) and anything that calls the compiler (that is the oracle lane).
