# ``SFProve``

Prove a claim about every value of a fixed-width integer, with a SAT solver and an independent proof checker.

## Overview

This module is **Prove**, the second of three tools. It comes with `SwiftFormalTesting`, which re-exports it: `import SwiftFormalTesting` in a test target gives every symbol below. Where Walk (the `SwiftFormal` module) runs your function on a list of inputs, Prove covers *all* values of 8 to 64-bit integers at once. In inspector words: there are too many rooms to walk (2^64), so the structural engineer proves it from the plans.

``proveSigned(widths:conflictBudget:requires:claim:)`` lets you write the body with ``SymbolicInt`` and ``SymbolicBool``, which use Swift's own operators and record where real Swift would trap: overflow, divide by zero, `Int.min / -1`, a narrowing conversion that does not fit. Width conversions (``SymbolicInt/init(_:width:)``, ``SymbolicInt/init(truncatingIfNeeded:width:)``, ``SymbolicInt/init(zeroExtending:width:)``), `min`, `max` and `==` on ``SymbolicBool`` read like the Swift they model. Two proofs run, "it never traps" and "the claim holds", and the verdict says which one failed.

Every `proved` is accepted only after a separate proof checker agrees with the solver's proof. A solver that wrongly claims "no solution" is caught there, and the call throws instead of returning a verdict.

Is `price - price * percent / 100` always between 0 and `price`, for every 16-bit price up to 300 and percent up to 100? The answer is ``SymbolicVerdict/proved``:

```swift
let verdict = try proveSigned(
    widths: [16, 16],
    requires: { $0[0] >= 0 && $0[0] <= 300 && $0[1] >= 0 && $0[1] <= 100 }
) { v in
    let result = v[0] - v[0] * v[1] / 100
    return result >= 0 && result <= v[0]
}
```

This takes about 25 seconds in a debug build. Adders, comparisons and branches are fast; multiplication and division get slow quickly, and a proof that does not finish within its conflict budget is ``SymbolicVerdict/unknown`` (or ``ProofVerdict/unknown``). It never guesses.

### What you still trust

Prove checks the copy of the body that you wrote with ``SymbolicInt``, not your compiled function. It trusts the compiler, and the encoding of Swift's integer rules into formulas. That encoding is compared with real Swift execution in the package's tests, but it is not proved correct. The repository's `docs/TRUST.md` has the full list. To read your compiled function instead, use **Scan** (`sfverify`).

## Topics

### Proving claims about signed integers

- ``proveSigned(widths:conflictBudget:requires:claim:)``
- ``SymbolicVerdict``
- ``SymbolicInt``
- ``SymbolicBool``
- ``SymbolicContext``

### Proving claims about circuits

- ``prove(inputWidths:inputSignedBits:conflictBudget:strategy:proofFormat:claim:)``
- ``ProofVerdict``
- ``ProofStrategy``
- ``ProofFormat``
- ``ProveError``
