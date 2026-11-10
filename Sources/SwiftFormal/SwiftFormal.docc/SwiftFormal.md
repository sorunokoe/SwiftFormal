# ``SwiftFormal``

Check your real function over every input you list, and get an honest verdict.

## Overview

SwiftFormal inspects your *real* function the way a building inspector inspects a *real* building: it walks every room, and then tells you honestly whether you get a certificate, a spot-check note, or a crack report with the room number.

This module is **Walk**, the first of three tools. You describe the inputs with a ``Domain`` (the floor plan: every room), state what must hold with ``Property`` values (the building code), and walk it: with `@Verify` on the function, whose `verify_<name>()` walks the inputs, or in a test with `Prove` from `SwiftFormalTesting`. The function itself runs on every input, so there is no model of Swift between you and the answer.

| Verdict | In inspector words | Meaning |
|---|---|---|
| ``Verdict/proved(checked:)`` | the certificate | Every input of a complete domain was checked. |
| ``Verdict/bounded(checked:reason:)`` | the spot-check note | It held for everything checked, but the domain is a sample or exceeded the budget. |
| ``Verdict/counterexample(_:)`` | the crack report | It failed, and the input is a real input you can replay. |

Here the function is `label(for:)` and its input is the enum `Speed`, which is `CaseIterable`. The test is in a Swift Testing test file and uses `Prove` from `SwiftFormalTesting`, the one way to walk in a test.

```swift
@Test func everySpeedHasItsLabel() {
    Prove(it: { label(for: $0) }, over: .allCases) {
        Deterministic()
        Matches(table: [
            .standard: "Standard (3-5 days)",
            .express: "Express (1-2 days)",
            .overnight: "Overnight",
        ])
        Satisfies("never blank") { _, text in !text.isEmpty }
    }
}
```

A `proved` here means "for every input in the domain you described". If the domain leaves out an input that matters, the certificate says nothing about it. A Swift trap (overflow, force unwrap) cannot be caught in-process; it stops the whole run. The repository's `docs/TRUST.md` lists everything this module does not cover.

The same import has the contract macros. Write the promise inside the function with `#requires` and `#ensures`;
``Verify()`` turns it into checks that Scan (`swiftformal check`) proves for every input:

```swift
@Verify
func label(for speed: Speed) -> String {
    #ensures { !$0.isEmpty }
    speed == .overnight ? "Overnight" : "Standard"
}
```

The other two tools are in other modules: **Prove** (`SFProve`, which `SwiftFormalTesting` re-exports) covers whole integer ranges with a SAT solver, and **Scan** (`swiftformal check`) reads compiler output to ask whether a function can trap.

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
