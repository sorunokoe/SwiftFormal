# ``SwiftFormalTesting``

Walk a function over every input inside a Swift Testing test, with `Prove`.

## Overview

This module adds the one way to walk in a test on top of `SwiftFormal`. It needs the `Testing` framework, so it is a separate library: depend on it only from test targets. In app code, write the promise in the function with `@Verify`, `#requires` and `#ensures` instead.

``Prove`` runs the real function on every input of a domain, checks what must hold, and records a test issue unless every property is proved. Every form reads the same: what to call (`it:`), over which inputs (`over:`), and what must hold, written like SwiftUI views. A `bounded` verdict fails the test unless you pass `allowBounded: true`, because "nothing found in the sample" is not a proof; an accepted `bounded` verdict is a warning, and a report that is not a proof is attached to the test. The `.swiftFormal(budget:allowBounded:)` trait sets the defaults for a suite.

In inspector words, this is the part that makes the inspection a required step before the building opens: a failing report fails the build.

```swift
@Test func everySpeedHasItsLabel() {
    Prove(it: { label(for: $0) }, over: .allCases) {
        Deterministic()
        Matches(table: [.standard: "Standard (3-5 days)", .express: "Express (1-2 days)", .overnight: "Overnight"])
        Satisfies("never blank") { _, text in !text.isEmpty }
    }
}
```

A reducer or a model walks every sequence of actions: `Prove(it: { reducer.reduce(into: &$0, action: $1) }, over: .sessions(from: State(), actions: actions, upTo: 4)) { Always("…") { … } }`. A function that may trap walks in a child process: `await Prove(neverTraps: Walk.self)`, with the function and its inputs in an ``ExitTestWalk`` type.

The same import brings the symbolic integer proofs of `SFProve` (`proveSigned(widths:requires:_:)`, `SymbolicInt`), which this module re-exports, so a test target needs this one product.

## Topics

### Walking a function

- ``Prove``
- ``KnownFailure``
- ``FailureReporting``

### Sessions of a reducer or a model

- ``Session``
- ``SessionRun``
- ``Always``
- ``EachStep``

### Checking that a function cannot trap

On macOS and Linux the walk runs in a Swift Testing exit test, so a trap fails the test with its input instead of ending the run. Elsewhere (iOS) nothing is walked and the report is `bounded`.

- ``ExitTestWalk``

### Domains from tables

- ``NamedValue``

### Defaults for a suite

- ``WalkDefaults``
- ``WalkDefaultsTrait``
