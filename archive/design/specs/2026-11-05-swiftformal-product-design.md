# Design: SwiftFormal as a product (v0.1), validated on a production app's Rules

Date: 2026-11-05. Status: **decided under autopilot; user can veto any section.**
Supersedes the scope (not the engine work) of `2026-11-05-pure-swift-verifier-design.md`.

## 1. Evidence that changed the scope

Survey of the 314 `Rule` conformances in a production iOS app (13.7k lines):

| Fact | Count | Meaning |
|---|---|---|
| Use `switch` | 170 | finite case analysis dominates |
| Use `onEnum(of:)` (KMP sealed) | 94 | inputs are enums/sealed types |
| Use `.localized()` | 92 | outputs contain opaque strings |
| Compose other Rules | 151 | Rules call Rules |
| Mention `Int/Double` | 57 | numerics are the minority |
| Force unwrap, `try!`, `as!` | 0 | traps are rare (2 `fatalError`) |
| Import `SharedKt` | 262 | real inputs need the KMP framework |

Constraint: `SharedKt.xcframework` has only an `ios-arm64-simulator` slice. Real Rules run only inside the
app's simulator test target (`@testable import MyApp`). Any approach that re-implements Swift semantics
outside the compiler cannot even load most Rules.

## 2. Decision: hybrid, finite domains first

**Tier 1 (this release): exhaustive verification of the real compiled function.**
For a function `f: A -> B` with a finite input domain, run the real `f` on every input. For a finite domain
this is a *proof* with no translation gap: no SIL reader, no encoder, no modeled semantics. The only trust
is the compiler and the domain enumerator, and the enumerator's size is reported.

**Tier 2 (next): symbolic proofs for numeric domains** using the existing `SFSAT`/`SFBV`/`SFCheck`
engine, entered through the same `Domain` and property API (an `Int` range becomes a symbolic variable
instead of 2^64 values). Not shipped until a Rule in the corpus needs it; the corpus survey says few do.

Rejected: SIL/AST re-implementation as the primary path (cannot load KMP types, needs a semantics for
strings, enums with payloads, optionals, existentials, and arbitrary stdlib calls); Lean as the primary
path (slow, external).

## 3. Honest verdicts

Every check returns one of:

- `proved(count)`: domain fully enumerated, property held for all `count` inputs.
- `bounded(checked, reason)`: domain larger than the budget; a deterministic, stratified subset passed.
  Never reported as proved.
- `counterexample(input, detail)`: first failing input, replayable because it is the real input.

Strings are opaque: a domain may supply representative strings and is then reported as `bounded` unless
the Rule treats the string only as a pass-through (the property is stated over the other fields).

## 4. API

Three layers, each usable without the next. Type-driven design is the organising idea: the more a type rules
out, the smaller the domain and the fewer contracts a function needs.

**Layer 1: types name the input space (`Finite`).** `CaseIterable` types, `Bool` and `Optional<Finite>` need
no description. A refined type (`Percent`, `Cents`) lists only its valid values, so it replaces a `#requires`.
`@Finite` derives the domain of your own structs (product of properties) and enums (union of cases);
`@Values` narrows one property; `Domain.union` builds payload-enum domains by hand for foreign types.
`Table([...])` is an exhaustive golden table; `SwiftFormalTesting.prove` runs the verdict inside Swift Testing.

**Layer 2: declarative properties (module `SwiftFormal`, zero dependencies).**

```swift
let report = verify("SurfaceTextRule", { SurfaceTextRule(input: $0).execute() }, over: .allCases) {
    Deterministic()
    Matches(expectedTable)
    Image(within: allowedLabels)
}
#expect(report.isProved)
// pairs of Rules, collisions, equivalence:
verify("round trip", toDomain, over: .allCases) { RoundTrip(through: toPrivacy) }
let groups = partition(SurfaceTextRule.run, over: .allCases)   // which cases share one output
```

**Layer 3: contracts next to the code (module `SwiftFormalContracts`, adds swift-syntax).**

```swift
@Verify(over: .product(.int(0 ... 1_000), .int(-5 ... 105)))
func discounted(price: Int, percent: Int) -> Int {
    #requires(percent >= 0 && percent <= 100)
    #ensures { $0 >= 0 && $0 <= price }
    return price - price * percent / 100
}

@Test func discountContract() { #expect(verify_discounted().isProved) }
```

- `#requires` / `#ensures` are `Contract.requires` / `Contract.ensures` at runtime: an `assertionFailure` in
  debug builds (shift left: the broken call stops at the call site), nothing in release.
- `@Verify` generates `verify_<name>()`. It runs the real function over the domain; `#requires` narrows the
  walk (excluded inputs are reported, not counted as checked); a failed `#ensures` is a counterexample with
  the real input instead of a trap.
- The domain comes from `Finite` parameter types, or from `over:` for integers and other open types.
- Limits in v0.1: free functions and static methods, not `async`, no `inout`.

Other facts:

- `Domain<Value>`: `allCases`, `of`, `samples`, `bool`, `int(range)`, `optional`, `arrays(of:maxLength:)`,
  `product` (2 to 4), `map`, `filter` (eager, at most 10M).
- Budget: default 1,000,000 evaluations; a larger domain is sampled with a fixed seed and the verdict is
  `bounded`.
- Closures, not a `Rule` dependency: SwiftFormal stays independent of AppMapping.
- Swift Testing: `verify` returns a `Report` with `isProved`, `hasNoCounterexample`, `counterexamples`; no
  dependency on a test framework.
- Trailing-closure gotcha: parameters that are closures (`assuming`, `requires`) come after `properties`
  so the property builder keeps the trailing closure.

## 5. Properties that matter for the app's Rules

1. **Total and deterministic**: no throw, same output twice.
2. **Exact table** (characterization): the whole mapping is stated once; enum additions force an update.
3. **Round-trip / inverse pairs**: `PrivacyType <-> DomainVisibility` and similar.
4. **Injectivity / collisions**: which inputs collapse to one output (report, not always an error).
5. **Output-set coverage**: every presentation value is reachable; no dead outputs.
6. **Equivalence**: old vs new Rule during refactors, over the whole domain.
7. **Predicate implication**: for example "invalid password never yields a `.valid` field state".

## 5a. Trap handling

Swift traps cannot be caught in-process on iOS. v0.1 documents this: a trap aborts the test run and the
last-attempted input is written to a breadcrumb (`Domain` iteration index is deterministic, so the failing
input is re-derivable). A fork-isolated runner is possible on macOS only and is out of scope for v0.1.

## 6. Validation plan on the app

1. Unit tests in SwiftFormal for every domain and property, including mutated properties that must fail.
2. A validation suite for real Rules (`validation/`, kept outside the public repository), run via `xcodebuild test` in the
   `MyAppTests` target, covering at least: all enum->enum Rules, `.localized()` Rules, inverse pairs, and
   validation Rules. Reported as a coverage table: Rules attempted / proved / bounded / skipped (reason).
3. Mutation sanity check: apply a deliberate bug to a copy of a Rule; the SwiftFormal check must fail where
   the existing example-based test passes (reproduces the 0.0.2 lesson on real code).
4. Compare against the app's existing Rule tests: report cases the example tests miss.

Success: >= 60% of the 314 Rules receive a `proved` verdict on at least one non-trivial property; at least
one real inconsistency or untested case found; no false `proved` in the mutation check.

### Result (first run)

- 43 of 133 enum-input Rules run: 48 reports, all `proved` (exhaustive), no crashes. The harness is a
  standalone Tuist target, not the full app; it links a stale SharedKt build, so results hold for that build.
- Mutation check passed: a deliberate bug became a `counterexample` (RoundTrip) and a new collision.
- Found: output collisions (e.g. 15 of 38 `ActivityType` cases give `""`) and 23 of 43 Rules with no example
  test (name-matching heuristic). No localization leaks.
- **Missed the 60% target.** 74 Rules take structs or sealed Kotlin classes and need hand-written `Domain`s.
  Most package enums are not `CaseIterable`. These are the main adoption costs, and the next work.

## 7. Package layout

Existing `SFCNF/SFSAT/SFCheck/SFBV/SFProve` are kept untouched. New:

| Target | Purpose | Depends on |
|---|---|---|
| `SwiftFormal` | Domain, Property, verify, Contract, Finite, Report | none |
| `SwiftFormalMacros` | `@Verify`, `#requires`, `#ensures` compiler plugin | swift-syntax (600..<700) |
| `SwiftFormalContracts` | Macro declarations, re-exports `SwiftFormal` | SwiftFormal, SwiftFormalMacros |

Products: `SwiftFormal` (core), `SwiftFormalContracts` (macros), `SFProve` (Tier 2 backend). Only apps that
use macros pay for the swift-syntax build.

## 8. Non-goals (v0.1)

Symbolic execution, a Swift semantics, strings theory, concurrency, a Rule discovery plugin (planned for
v0.2 once the manual corpus run shows which shapes recur).

Roadmap after v0.1: Rule discovery generator; counterexample replay snippets; instance-method and `async`
`@Verify`; refined payload types so sealed-class Rules reach `proved`; `Injective(except:)` for known
collisions; Tier 2 numeric domains through `SFProve`.
