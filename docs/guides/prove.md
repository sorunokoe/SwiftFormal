# Prove: whole integer ranges (`SFProve`, preview)

`SFProve` proves claims over every value of 8 to 64-bit integers with a SAT solver. A "proved" is accepted only after
an independent proof checker agrees. This is a preview.

## How to use

`SFProve` proves claims over every value of 8 to 64-bit integers with a SAT solver. `import SwiftFormalTesting`
re-exports it (it is no product of its own). Write the body with `SymbolicInt` inside `proveSigned`. `SymbolicInt`
uses Swift's own operators and records where real Swift would trap (overflow, divide by zero, `Int.min / -1`):

```swift
import SwiftFormalTesting

// (a + b) / 2: finds the real overflow input, not just "may overflow".
proveSigned(widths: [32, 32]) { v in (v[0] + v[1]) / 2 <= Int(Int32.max) }   // .mayTrap([...])

proveSigned(widths: [16, 16], requires: { $0[0] >= 0 && $0[0] <= 300 && $0[1] >= 0 && $0[1] <= 100 }) { v in
    let result = v[0] - v[0] * v[1] / 100
    return result >= 0 && result <= v[0]
}                                                                              // .proved
```

Verdicts: `.proved`, `.mayTrap(inputs)`, `.claimFails(inputs)`, `.unknown`. Limits: you write the body again with
`SymbolicInt`; only signed integers and `Bool`; multiplication and division get slow quickly. Not connected to `Prove`
or `@Verify` yet.

## Writing the body: conversions, `min`/`max`, Boolean `==`

Write the body the way the Swift code reads. The inputs have the widths you ask for. Convert between widths as Swift
does:

| Swift | `SymbolicInt` | Traps |
|---|---|---|
| `Int(x)` for an `Int32` `x` (wider) | `SymbolicInt(x, width: 64)` | never (sign extension) |
| `Int32(x)` for an `Int` `x` (narrower) | `SymbolicInt(x, width: 32)` | where the value does not fit, like Swift |
| `Int32(truncatingIfNeeded: x)` | `SymbolicInt(truncatingIfNeeded: x, width: 32)` | never (keeps the low bits) |
| `Int(UInt32(bitPattern: x))` | `SymbolicInt(zeroExtending: x, width: 64)` | never (the new bits are zero) |
| `min(a, b)`, `max(a, 100)` | `min(a, b)`, `max(a, 100)` | never |
| `p == q`, `p != q` on `Bool` | `p == q`, `p != q` on `SymbolicBool` | never |

So an `Int32` field read into `Int` arithmetic is an `Int32` input, not a 64-bit input with a range `requires`:

```swift
proveSigned(widths: [32]) { v in
    let count = SymbolicInt(v[0], width: 64)      // Int(count)
    let capped = min(count * 2, count.literal(1_000))
    return capped <= 1_000
}                                                                              // .proved
```

Operands of `+`, `<`, `min` and the others must have the same width, as in Swift. Convert first.

## Run proof tests optimized

The SAT solver and the proof checker are much slower in a debug build: a 32-bit `%` or `/` proof took about 30 s in a
debug test build.

- Put such tests in a suite whose name ends in `SlowTests`.
- Run them with `swift test -c release`, or with this repository's `Scripts/test-lane.sh slow-dev` (a debug build with
  the engine modules optimized).
- Keep debug runs for adders, comparisons and narrow widths.

## Multiplication: `strategy: .refiningMultipliers`

For the circuit-level `prove(inputWidths:claim:)`, `strategy: .refiningMultipliers` abstracts each multiplication and
refines it only when the solver needs the exact product. Verdicts are the same as with the default `.exact`. Claims
that need only algebraic facts about products finish far faster.

## Limits

- You write the body again with `SymbolicInt`. Nothing reads your compiled function yet.
- Only signed integers and `Bool`.
- Adders, comparisons and branches are fast. Multiplication and division get slow quickly: a 16-bit discount takes
  about 40 s; the same at 32 bits did not finish in minutes.
- Not connected to `verify`, `@Verify` or `Domain` yet.
