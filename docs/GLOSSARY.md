# Glossary

Plain words, one sentence each. For the big picture, read [MENTAL-MODEL.md](MENTAL-MODEL.md).


**bit-vector**: a fixed-width integer (8, 16, 32 or 64 bits) as a row of true/false values; this is how the SAT solver sees numbers.

**bounded**: the check held for everything it looked at, but it looked at a sample or ran out of budget: not a proof.

**budget**: how much work a check may do (inputs walked, or solver conflicts) before it stops and says so.

**build log** (`--build-log`): the log of a build that already ran (`swift build -v`, `xcodebuild`, or Xcode's activity logs). `swiftformal check --build-log <file> --target <name>` reads the target's compile command from it, so an app target without a `Package.swift` can be checked (and gated with `--gate`).

**contract**: the technical word for a **promise**: `#requires` for what callers must give, `#ensures` for what the function must return, inside a `@Verify` function.

**contract checks**: the `if` statements `@Verify` writes into the body from the contract; compiled only where `DEBUG` is defined, unless `@Verify(checks: .always)` (`ContractChecks`).

**contract in place**: a contract written inside the function or computed property it describes, with `@Verify`, `#requires` and `#ensures`, instead of separate `f_requires` / `f_ensures` functions; `@Verify` writes those functions for Scan. It is the only contract Scan reads.

**ignored contract**: a hand-written `f_requires` / `f_ensures` next to `f`. Scan does not read it (only the contract `@Verify` writes counts); the report names it in `ignoredContracts`, and `f`'s verdict is about traps only.

**counterexample**: a real input that makes the check fail; you can run it again on the real function.

**Domain**: the list (or description) of inputs a Walk goes through; `proved` always means "for this domain".

**engine**: one of the three ways SwiftFormal checks code: **Scan** (the logic), **Walk**, and **symbolic proofs** (`SFProve`). `swiftformal check` runs Scan first, then only the walks Scan still needs.

**exit test**: a Swift Testing test whose body runs in a child process (`#expect(processExitsWith:)`), so a trap ends only that process; Walk uses it to name the input a function traps on (`Prove(neverTraps:)`, macOS and Linux only).

**every failure**: a walk that keeps checking every property after its first failing input and lists every failing input (`reporting: .everyFailure`), for an audit of data.

**fail closed**: when SwiftFormal is unsure, it reports an error or `unsupported`, never a pass.

**foreign object**: a reference to an Objective-C (or Kotlin/Native) object; Scan holds and passes it, and treats what its methods return as unknown values.

**gate**: `swiftformal check --gate`, the build step that makes the build fail unless every `@Verify` promise is proved.

**independent checker**: separate code (`SFCheck`) that re-checks the solver's proof and shares no code with the solver.

**known issue**: a failure a test expects and keeps on purpose (`knownIssue:`, `KnownFailure`, Swift Testing's `withKnownIssue`); the test passes while it fails and fails once it is fixed, and it is never a proof.

**logic**: the README's word for **Scan**: proving from what the compiler made of the code, for every input, without running it.

**LRAT / RUP proof**: a step-by-step record that the SAT solver's "no solution" answer is correct, small enough for the independent checker to follow.

**plumbing**: code that wires an app together instead of computing (property wrappers, dependency injection, a view's `body`); Scan counts such `unsupported` functions apart, in `summary.plumbing`.

**promise**: what a function must do, written inside it with `@Verify`, `#requires` and `#ensures`; see contract.

**proof cache**: a stored `proved` result, reused only when the function, its callees, the compiler and the settings are all unchanged.

**Property**: one statement about a function's result that Walk checks on every input, such as "never blank" or "matches this table".

**`Prove(…)`** (the walk in a test): the one way to walk, from `SwiftFormalTesting`: `Prove(it: f, over: domain) { properties }`, `Prove(it: step, over: .sessions(…))`, `await Prove(neverTraps: W.self)`. `Prove` always means this test API; the SAT engine is called **symbolic proofs**.

**proved**: the claim holds for every input in the domain (Walk), or every value of the stated integer widths (symbolic proofs), or every input at all (Scan), and the evidence says how it was checked.

**SAT**: the question "is there any true/false assignment that satisfies these constraints?", answered by a solver.

**Scan**: the first engine, "the logic": `swiftformal check` reads the compiler's SIL and proves, for every input, that a function cannot trap and that its `@Verify` promise holds. `SFCheck` confirms each proof.

**session**: a start state and a sequence of actions sent to it; `Domain.sessions(from:actions:upTo:)` is every session up to a length, and `Prove(it: step, over: .sessions(…))` runs each one and checks each state (`Always`) and each step (`EachStep`).

**SIL**: Swift Intermediate Language, the compiler's readable form of your code; Scan reads it.

**spec audit**: a check of the contract itself: it makes small deliberate mistakes in the function and tells you if the contract misses them (for Scan: `swiftformal check --mutate`; see weak contract).

**symbolic proofs**: the third engine, a preview (`SFProve`, `proveSigned` from `SwiftFormalTesting`): a SAT solver shows a claim holds for every value of integers of given widths, on a copy of the body written with `SymbolicInt`. Its verdicts: `proved`, `mayTrap`, `claimFails`, `unknown`.

**subject**: the function a walk checks (`"Type.member"`, `"Type.=="`). `swiftformal check` links the walk to that function only; a subject that names only a type proves none of its members.

**trap**: a crash Swift inserts on purpose, for example on integer overflow, divide by zero or a force unwrap of `nil`.

**unknown**: the solver could not decide within the budget; not a pass and not a failure.

**unchecked**: no engine says anything about the function: Scan could not read it and no walk names it. Not a pass; `--show-unchecked` lists them.

**unsupported**: the function uses something SwiftFormal does not model, so it declines to judge instead of guessing.

**verdict**: the answer a check gives. Per function in `swiftformal check`: `proved`, `counterexample`, `bounded`, `unchecked`. Scan: `safe`, `mayTrap`, `contractHolds`, `contractFails`, `undecided`, `unsupported`. Walk: `proved`, `bounded`, `counterexample`. Symbolic proofs: `proved`, `mayTrap`, `claimFails`, `unknown`.

**`@Verify`**: the macro from `SwiftFormal` that marks a function or computed property whose promise is checked. It writes `verify_<name>()` (a walk, when there are inputs to walk) and the `f_requires` / `f_ensures` functions Scan reads.

**Walk**: the second engine: `Prove` (in a test) and `verify_<name>()` (written by `@Verify`) run the real function on every input of a domain and check the properties.

**weak contract**: a contract that also holds for an edited copy of the function that ends differently (`swiftformal check --mutate` shows the edit and an input), so it would not catch that mistake.
