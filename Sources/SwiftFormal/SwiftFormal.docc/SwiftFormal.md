# ``SwiftFormal``

Write a promise next to a function, and get an honest answer for every input.

## Overview

This is the library for app code. Mark a function `@Verify` and write its promise inside it: `#requires` says what
the inputs must be, `#ensures` what the result must be (`$0` is the result). A computed property takes its promise in
the getter.

```swift
@Verify(over: .product(.int(0...1_000), .int(0...100)))
public func discounted(price: Int, percent: Int) -> Int {
    #requires(price >= 0 && price <= 1_000_000 && percent >= 0 && percent <= 100)
    #ensures { $0 >= 0 && $0 <= price }
    return price - price * percent / 100
}
```

Scan (`swiftformal check`, or `swiftformal check --gate` as a build step) proves for every input that the function
cannot trap and keeps its promise. `over:` is optional: it lists the inputs, a ``Domain``, of a walk that `@Verify`
writes for your tests, `verify_discounted()`:

```swift
@Test func discountStaysInRange() {
    #expect(verify_discounted().isProved)
}
```

Walk runs the real function on every input of the domain, so there is no model of Swift between you and the answer.
It returns a ``Report`` with one ``Verdict`` per property:

| Verdict | Meaning |
|---|---|
| ``Verdict/proved(checked:)`` | Every input of a complete domain was checked. |
| ``Verdict/bounded(checked:reason:)`` | It held for everything checked, but the domain is a sample or exceeded the budget. |
| ``Verdict/counterexample(_:)`` | It failed, and the input is a real input you can replay. |

A walk's `proved` means "for every input in the domain you described". If the domain leaves out an input that
matters, it says nothing about it. A Swift trap (overflow, force unwrap) cannot be caught in-process; it stops the
whole run. The repository's `docs/TRUST.md` lists everything that is not covered.

To walk a function in a test with your own properties (a table, `Deterministic()`, every session of a reducer), use
`Prove` from `SwiftFormalTesting`. That library also brings symbolic proofs over whole integer ranges (`SFProve`, a
preview).

## Topics

### Writing contracts in place

- ``Verify()``
- ``Verify(over:)``
- ``Verify(checks:)``
- ``Verify(over:checks:)``
- ``ContractChecks``
- ``requires(_:)``
- ``ensures(_:)``
- ``Finite()``
- ``Values(_:)``

### Describing inputs

- ``Domain``
- ``Finite``
- ``Pairwise``
- ``SplitMix64``

### Stating properties

- ``Property``
- ``PropertyBuilder``
- ``Contract``

### Budgets

- ``Budget``

### Reading verdicts

- ``Report``
- ``PropertyResult``
- ``Verdict``
- ``Counterexample``
