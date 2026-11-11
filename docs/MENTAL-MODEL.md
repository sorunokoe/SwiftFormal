# The mental model: SwiftFormal is a building inspector for your functions

SwiftFormal inspects your *real* function like an inspector inspects a *real* building, then tells you honestly what
you get: a certificate, a spot-check note, or a crack report with the room number.
[GLOSSARY.md](GLOSSARY.md) lists every word in plain terms.

## The analogy, word by word

| Inspector world | SwiftFormal word | Where it lives |
|---|---|---|
| The building (not the blueprint) | the real compiled function | your code |
| The building code (rules) | the promise: `@Verify` with `#requires` and `#ensures` | `SwiftFormal` |
| An engineer checks every room from the plans, without walking in | **Scan**, "the logic": `swiftformal check` reads the compiler's SIL | the `swiftformal` command |
| A second, independent engineer countersigns | the independent proof checker | `SFCheck` |
| Where the plans cannot be read: the inspector walks every room | **Walk**: `Prove(it:over:)` in a test, `verify_<name>()` from `@Verify` | `SwiftFormalTesting`, `SwiftFormal` |
| The floor plan: every room to walk | `Domain` | `SwiftFormal` |
| **Certificate** (every room checked) | `proved` | the report |
| **Spot-check note** (only some rooms) | `bounded` (a sample, or out of budget) | the report |
| **Crack with a room number** (replayable) | `counterexample` | the report |
| The inspector declines to sign what they cannot inspect | `unchecked`, `unsupported`, `undecided` (fail closed, never guess) | the report |
| Occupancy permit: no permit, no move-in | the **gate**, `swiftformal check --gate` | the `swiftformal` command |
| Permit on file, reused only if nothing changed | proof cache | `SFSIL/ProofCache` |
| "Does the code catch a deliberately bad building?" | spec audit (`swiftformal check --mutate`) | `SpecAudit` |
| A structural calculation for one beam, by hand | **symbolic proofs** (preview): `proveSigned` on a `SymbolicInt` copy | `SFProve` |
| The inspector's stated limits | the **trust ledger**: compiler, the domain you described | `docs/TRUST.md` |

## Three engines, one set of answers

`swiftformal check` asks Scan first, then runs the walks linked to each function: a walk covers code Scan cannot read,
and can state a promise Scan does not check (a table, injectivity). Walks of functions Scan already showed broken are
skipped. Each function then gets one answer: `proved`, `counterexample`, `bounded` or `unchecked`.

| Engine | Question it answers | Its own verdicts |
|---|---|---|
| **Scan** `swiftformal check` | "Can this function trap, and does its `@Verify` promise hold, for every input?" | safe / mayTrap / contractHolds / contractFails / undecided / unsupported |
| **Walk** `Prove(it:over:)`, `verify_<name>()` | "Does this rule hold for every input I listed?" | proved / bounded / counterexample |
| **Symbolic proofs** `SFProve` (preview) | "Does it hold for *all* values of these integer widths?" | proved / mayTrap / claimFails / unknown |

Rule for every doc and error message: **name the engine, then the answer, then the evidence.**

```
                    your real Swift function
                              |
         +--------------------+---------------------+
         |                    |                     |
       SCAN                 WALK              SYMBOLIC PROOFS
  (swiftformal check)  (Prove(it:over:),      (proveSigned,
                        verify_<name>())        preview)
  reads compiler SIL,  runs the function      SAT solver on
  every input          on every input         bit-vectors, for
                       you listed             all integer values
         |                    |                     |
         v                    v                     v
  safe / contractHolds  proved                proved
  mayTrap / contractFails  bounded            mayTrap / claimFails
  undecided             counterexample        unknown
  unsupported (declined)
```

| Engine | Strength | Cost |
|---|---|---|
| Scan | reads the compiler's output; every input; no spec needed to find traps | understands a part of Swift, says `unsupported` for the rest |
| Walk | runs the function itself, no model of Swift | needs a finite list of inputs |
| Symbolic proofs | covers whole integer ranges | works on a copy of the body that you write |

## What the certificate does *not* cover

Outside a `proved`:

- **The compiler.** Scan reads, and Walk runs, what the compiler produced. If the compiler is wrong, SwiftFormal does
  not know. Scan results are stated for one pinned compiler version.
- **The `Domain` you wrote.** A walk's `proved` means "every input in the domain". It says nothing about inputs the
  domain leaves out. Neither engine checks inputs a too-strong `#requires` excludes. The report prints the domain size.
- **Strings in a walk.** A domain can list some strings, not all of them. A walk over strings is reported as `bounded`,
  unless the function only passes the string through and the property is about the other fields.
- **Traps in a Walk.** A Swift trap (overflow, force unwrap) cannot be caught in-process: it stops the whole test run,
  and you see the run end, not a `counterexample`. On macOS and Linux, `await Prove(neverTraps:)` walks in a Swift
  Testing exit test: the test then fails with the input ([Walk guide](guides/walk.md#when-the-function-can-trap)). iOS
  has no exit tests. Use Scan to look for traps before walking.
- **Swift has no formal definition.** The SAT proof covers the encoded problem. Whether the encoding matches Swift's
  real behavior is tested against real Swift execution, not proved. See [TRUST.md](TRUST.md).

When SwiftFormal cannot inspect something, it says `unsupported` or `unknown` and stops. It does not guess.
