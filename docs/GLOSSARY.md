# Glossary

Plain words, one sentence each. For the big picture, read [MENTAL-MODEL.md](MENTAL-MODEL.md).


**bit-vector**: a fixed-width integer (8, 16, 32 or 64 bits) as a row of true/false values; this is how the SAT solver sees numbers.

**bounded**: the check held for everything it looked at, but it looked at a sample or ran out of budget: not a proof.

**budget**: how much work a check may do (inputs walked, or solver conflicts) before it stops and says so.

**build log** (`--build-log`): the log of a build that already ran (`swift build -v`, `xcodebuild`, or Xcode's activity logs). `swiftformal check --build-log <file> --target <name>` reads the target's compile command from it, so an app target without a `Package.swift` can be checked (and gated with `--gate`).

**contract**: a rule next to a function: `#requires` for what callers must give, `#ensures` for what it must return.

**contract checks**: the `if` statements `@Verify` writes into the body from the contract; compiled only where `DEBUG` is defined, unless `@Verify(checks: .always)` (`ContractChecks`).

**contract in place**: a contract written inside the function or computed property it describes, with `@Verify`, `#requires` and `#ensures`, instead of separate `f_requires` / `f_ensures` functions; `@Verify` writes those functions for Scan. It is the only contract Scan reads.

**ignored contract**: a hand-written `f_requires` / `f_ensures` next to `f`. Scan does not read it (only the contract `@Verify` writes counts); the report names it in `ignoredContracts`, and `f`'s verdict is about traps only.

**counterexample**: a real input that makes the check fail; you can run it again on the real function.

**Domain**: the list (or description) of inputs a Walk goes through; `proved` always means "for this domain".

**exit test**: a Swift Testing test whose body runs in a child process (`#expect(processExitsWith:)`), so a trap ends only that process; Walk uses it to name the input a function traps on (`Prove(neverTraps:)`, macOS and Linux only).

**every failure**: a walk that keeps checking every property after its first failing input and lists every failing input (`reporting: .everyFailure`), for an audit of data.

**fail closed**: when SwiftFormal is unsure, it reports an error or `unsupported`, never a pass.

**foreign object**: a reference to an Objective-C (or Kotlin/Native) object; Scan holds and passes it, and treats what its methods return as unknown values.

**gate**: `swiftformal check --gate`, the build step that makes the build fail unless every `@Verify` promise is proved.

**independent checker**: separate code (`SFCheck`) that re-checks the solver's proof and shares no code with the solver.

**known issue**: a failure a test expects and keeps on purpose (`knownIssue:`, `KnownFailure`, Swift Testing's `withKnownIssue`); the test passes while it fails and fails once it is fixed, and it is never a proof.

**LRAT / RUP proof**: a step-by-step record that the SAT solver's "no solution" answer is correct, small enough for the independent checker to follow.

**plumbing**: code that wires an app together instead of computing (property wrappers, dependency injection, a view's `body`); Scan counts such `unsupported` functions apart, in `summary.plumbing`.

**proof cache**: a stored `proved` result, reused only when the function, its callees, the compiler and the settings are all unchanged.

**Property**: one statement about a function's result that Walk checks on every input, such as "never blank" or "matches this table".

**Prove**: the second tool: a SAT solver shows a claim holds for all values of integers of a given width (`SFProve`).

**`Prove(…)`** (the walk in a test): the one way to walk, from `SwiftFormalTesting`: `Prove(it: f, over: domain) { properties }`, `Prove(it: step, over: .sessions(…))`, `await Prove(neverTraps: Walk.self)`. Not the same as the tool **Prove**.

**proved**: the claim holds for every input in the domain (Walk), or every value of the stated integer widths (Prove), and the evidence says how it was checked.

**SAT**: the question "is there any true/false assignment that satisfies these constraints?", answered by a solver.

**Scan**: the third tool: `swiftformal check` reads the compiler's SIL and tells you whether a function can trap and whether its plain-Swift contract holds.

**session**: a start state and a sequence of actions sent to it; `Domain.sessions(from:actions:upTo:)` is every session up to a length, and `Prove(it: step, over: .sessions(…))` runs each one and checks each state (`Always`) and each step (`EachStep`).

**SIL**: Swift Intermediate Language, the compiler's readable form of your code; Scan reads it.

**spec audit**: a check of the contract itself: it makes small deliberate mistakes in the function and tells you if the contract misses them (for Scan: `swiftformal check --mutate`; see weak contract).

**subject**: the function a walk checks (`"Type.member"`, `"Type.=="`). `swiftformal check` links the walk to that function only; a subject that names only a type proves none of its members.

**trap**: a crash Swift inserts on purpose, for example on integer overflow, divide by zero or a force unwrap of `nil`.

**unknown**: the solver could not decide within the budget; not a pass and not a failure.

**unsupported**: the function uses something SwiftFormal does not model, so it declines to judge instead of guessing.

**verdict**: the answer a check gives: `proved`, `bounded`, `counterexample`, `unknown`, or for Scan `safe`, `mayTrap`, `contractHolds`, `contractFails`, `undecided`, `unsupported`.

**Walk**: the first tool: `Prove` (in a test) and `verify_<name>()` (written by `@Verify`) run the real function on every input of a domain and check the properties.

**weak contract**: a contract that also holds for an edited copy of the function that ends differently (`swiftformal check --mutate` shows the edit and an input), so it would not catch that mistake.
