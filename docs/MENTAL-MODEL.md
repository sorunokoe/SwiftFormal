# The mental model: SwiftFormal is a building inspector for your functions

SwiftFormal inspects your *real* function like an inspector inspects a *real* building, then tells you honestly what
you get: a certificate, a spot-check note, or a crack report with the room number.
[GLOSSARY.md](GLOSSARY.md) lists every word in plain terms.

## The analogy, word by word

| Inspector world | SwiftFormal word | Where it lives |
|---|---|---|
| The building (not the blueprint) | the real compiled function | your code |
| The floor plan: every room | `Domain` | `SwiftFormal` |
| The building code (rules) | `Property`, `Contract` (`#requires`, `#ensures`) | `SwiftFormal` |
| Inspector walks every room | `Prove(it:over:)`: **Walk** (Tier 1) | `SwiftFormalTesting` |
| **Certificate** (all rooms visited) | `proved` | `Verdict` |
| **Spot-check note** (only some rooms) | `bounded` (sample or over budget) | `Verdict` |
| **Crack with a room number** (replayable) | `counterexample` | `Verdict` |
| Too many rooms (2^64): an engineer proves it from the plans | **Prove** (Tier 2): SAT solver on bit-vectors | `SFProve` |
| A second, independent engineer countersigns | the independent proof checker | `SFCheck` |
| "Could anything collapse?", no code book needed | **Scan** (`swiftformal check`): can this function trap? | the `swiftformal` command |
| The inspector declines to sign what they cannot inspect | `unsupported` (fail closed, never guess) | reports |
| Occupancy permit: no permit, no move-in | the **Build Gate**, `swiftformal check --gate` | the `swiftformal` command |
| Permit on file, reused only if nothing changed | proof cache | `SFSIL/ProofCache` |
| "Does the code catch a deliberately bad building?" | spec audit (mutants) | `SpecAudit` |
| The inspector's stated limits | the **trust ledger**: compiler, the domain you described | `docs/TRUST.md` |

## Three tools, one verdict vocabulary

| Tool | Question it answers | Verdict words | Evidence line (planned, not printed yet) |
|---|---|---|---|
| **Walk** `Prove` | "Does this rule hold for every input I listed?" | proved / bounded / counterexample | `walked 1,001 of 1,001 inputs of the real function` |
| **Prove** `SFProve` | "Does it hold for *all* values of these integer widths?" | proved / counterexample / unknown | `SAT proof, accepted by the independent LRAT checker` |
| **Scan** `swiftformal check` | "Can this function trap, and does its plain-Swift contract hold?" | safe / mayTrap / contractHolds / contractFails / undecided / unsupported | `read from compiler SIL (swiftc 6.4), proof checked` |

Rule for every doc and error message: **name the tool (Walk, Prove, Scan), then the verdict, then the evidence.**

```
                 your real Swift function
                           |
      +--------------------+---------------------+
      |                    |                     |
    WALK                 PROVE                 SCAN
(Prove(it:over:),    (proveSigned,         (swiftformal check,
   Tier 1)              Tier 2)               Tier 3)
 runs the function    SAT solver on         reads compiler SIL,
 on every input       bit-vectors, for      asks "can it trap?"
 you listed           all integer values
      |                    |                     |
      v                    v                     v
 proved                proved                safe / contractHolds
 bounded               counterexample        mayTrap / contractFails
 counterexample        unknown               undecided
                                             unsupported (declined)
```

| Tool | Strength | Cost |
|---|---|---|
| Walk | runs the function itself, no model of Swift | needs a finite list of inputs |
| Prove | covers whole integer ranges | works on a symbolic copy of the body that you write |
| Scan | reads the compiler's output, no spec to write | understands a small part of Swift, says `unsupported` for the rest |

## What the certificate does *not* cover

Outside a `proved`:

- **The compiler.** Walk runs, and Scan reads, what the compiler produced. If the compiler is wrong, SwiftFormal does
  not know. Scan results are stated for one pinned compiler version.
- **The `Domain` you wrote.** `proved` means "every input in the domain". It says nothing about inputs the domain
  leaves out, or that a too-strong `#requires` excludes. The report prints the domain size.
- **Strings.** A domain can list some strings, not all of them. A domain with strings is reported as `bounded`,
  unless the function only passes the string through and the property is about the other fields.
- **Traps in a Walk.** A Swift trap (overflow, force unwrap) cannot be caught in-process: it stops the whole test run,
  and you see the run end, not a `counterexample`. On macOS and Linux, `await Prove(neverTraps:)` walks in a Swift
  Testing exit test: the test then fails with the input ([Walk guide](guides/walk.md#when-the-function-can-trap)). iOS
  has no exit tests. Use Scan to look for traps before walking.
- **Swift has no formal definition.** The SAT proof covers the encoded problem. Whether the encoding matches Swift's
  real behavior is tested against real Swift execution, not proved. See [TRUST.md](TRUST.md).

When SwiftFormal cannot inspect something, it says `unsupported` or `unknown` and stops. It does not guess.
