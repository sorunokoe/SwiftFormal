# The soundness zoo, differential tests and fuzzing

These tests hunt for the worst bug: a false "proved". All are deterministic: random inputs come from a fixed seed,
printed on failure.

| What | Where | Lane | Rule |
|---|---|---|---|
| Zoo for Walk and symbolic proofs (`prove`, `proveSigned`) | `Tests/SoundnessZooTests/ZooTests.swift` | fast | A wrong claim is never proved; every counterexample fails again when replayed on plain Swift; true controls are proved. |
| Zoo for Scan | `Tests/SFOracleTests/ScanZooTests.swift` | oracle | A wrong function is never `safe`; every `mayTrap` input traps in the compiled function; every `safe` function survives a sweep of edge inputs; a hand-written `_requires` / `_ensures`, even a false one, is never read as a contract (`contractNotRead`, `ScanZooContractEntries.swift`). |
| SAT solver against brute force | `Tests/SoundnessZooTests/SATDifferentialTests.swift` | fast | Same SAT/UNSAT answer as exhaustive enumeration; every model satisfies the formula; every UNSAT proof passes the RUP and LRAT checkers. |
| Metamorphic SAT | same file | fast | Clause permutation, variable renaming, polarity flip and clause duplication never change the answer. |
| Parser and checker fuzz | `Tests/SoundnessZooTests/ParserFuzzTests.swift` | fast | Truncated and mutated SIL, LLVM IR and LRAT text give a result or a typed error (no crash, no hang); a checker never accepts a proof of a satisfiable formula. |

The fast ones take well under a second at the default seed count.

Floating point in the Scan zoo: `x - x` is `+0.0`, a negative number times zero is `-0.0`, half the smallest
subnormal rounds to zero, a subnormal doubled and halved is itself, NaN is unequal to itself, `inf - inf` is NaN,
overflow gives an infinity. `(x * 0).bitPattern` is never `safe`: the hardware NaN payload is left open by the model.
`SILFloatArithmeticTests` (slow lane) compares the floating-point circuits bit for bit with the hardware.

## Adding a case

A soundness report becomes a zoo case first, then a fix. Add a `walk(...)`, `signed(...)` or `bits(...)` entry to
`Zoo` with its `Truth`:

- `.falseClaim`: wrong; the tool must refute it with an input that replays.
- `.trueClaim`: right; the tool must prove it.
- `.falseClaimBeyondBudget` / `.trueClaimBeyondBudget`: the budget may stop the tool first. Giving up is fine, a wrong
  verdict is not.

Keep each case under about 2 s in debug. Division or multiplication at 32 bits does not finish in minutes, so use 5
to 8 bits (see `ZooTests.swift`). A case that cannot be fast goes in a suite named `*SlowTests`.

## Running more of it

- `SF_DIFFERENTIAL_SEEDS` (default 200): random formulas for the SAT tests.
- `SF_FUZZ_ROUNDS` (default 150): mutations per fixture.
- `SF_SEED=<seed>`: reruns one failing formula (differential and metamorphic SAT tests).

Before a release:

```sh
SF_DIFFERENTIAL_SEEDS=100000 SF_FUZZ_ROUNDS=20000 swift test --filter 'SATDifferentialTests|SATMetamorphicTests|ParserFuzzTests|ProofCheckerFuzzTests'
```

## What it has found

No wrong verdict. One crash on malformed input (a repeated LLVM block label): [KNOWN-ISSUES.md](../KNOWN-ISSUES.md),
item 3.

Mutation testing is not set up: it needs a tool that is not an installed dependency.
