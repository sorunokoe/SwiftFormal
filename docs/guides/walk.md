# Walk: check every input you listed (`Prove`)

Walk runs your real compiled function on every input of a domain and checks the rules you state. Verdicts:
`proved` (every input), `bounded` (a sample), `counterexample` (an input you can replay).
The `@Verify` quick start is in the [README](../../README.md).

## In a test

`Prove` is the one way to walk. `import SwiftFormalTesting`, then write what to call (`it:`), over which inputs
(`over:`), and one property per line, like SwiftUI views:

```swift
@Test func surfaceText() {
    Prove(it: { SurfaceTextRule(input: $0).execute() }, over: .allCases) {
        Deterministic()
        Matches(table: [.grass: "Grass", .sand: "Sand"])   // an input with no row is a counterexample
        Satisfies("never blank") { _, text in !text.isEmpty }
    }
}
```

Run the tests with `swift test`.

`Prove` runs the function on every input and records a test issue unless the verdict is `proved`. The `Report` is in
`.report`. Pass `allowBounded: true` to accept a sample.

| Write | It holds when |
|---|---|
| `Deterministic()` | a second call on the same input gives the same output |
| `Matches(table: [input: output, …])` | every input has its row and gets that output |
| `Matches(oracle)`, `Matches("name", oracle)` | the output equals `oracle(input)` (a plain statement of the rule, or the old version) |
| `Satisfies("name") { input, output in … }` | the predicate is true for every input |
| `Satisfies("name", when: { input in … }, then: { output in … })` | the output passes `then` whenever the input passes `when` |
| `Injective()` | different inputs never give the same output |
| `Injective(except: [(a, b), …])` | only the listed pairs give the same output, and each listed pair does (walked only) |
| `Outputs(within: […])`, `Outputs(exactly: […])` | outputs stay in the set; with `exactly`, every member is also reached |
| `NeverOutputs("", "TBD")`, `NeverOutputs("name", where: { input, output in … })` | no input gives a listed output, or one the predicate flags (walked only) |
| `RoundTrip(through: inverse)` | `inverse(output) == input` |
| `Agrees(with: other)`, `Agrees("name", with: other)` | the output equals `other(input)`: a sibling rule, or the one a refactor replaces |
| `Agrees(with: other, where: { output, otherOutput in … })` | the relation holds between the two outputs (walked only) |

- Types come from `it:` and `over:`. A wrong type is a compile error. If `Input: Finite`, you can leave out `over:`.
- To reuse a property, conform it to `PropertyConvertible`.
- SwiftLint's `multiple_closures_with_trailing_closure` warns on this shape (as on SwiftUI's `Button(action:) { … }`).
  Turn it off for test targets.
- [Migrating from the pre-release names](#migrating-from-the-pre-release-names) lists the names that walked before.

### `bounded` verdicts and attachments

- An accepted `bounded` verdict is a warning: the test passes "with 1 warning". Needs Swift 6.3; with an older
  compiler it is silent.
- A report that is not a proof is attached to the test as text and as a JSON line (Swift 6.2 or newer).
  `swift test --attachments-path <folder>` saves them.

### Suite defaults

A suite (or one test) can set the budget and `allowBounded` for its calls, for example exhaustive on CI and sampled
locally (Swift 6.1 or newer). An argument written at the call wins:

```swift
@Suite(.swiftFormal(budget: Budget(maxEvaluations: 50_000), allowBounded: true))
struct PricingTests { ... }
```

### How `swiftformal check` links a test to a function

`swiftformal check` reads the function under test from the `it:` closure and runs the test, also when a promise on it
holds (a walk may promise more: a table, injectivity). A walk that covers only functions where logic already found a
failing input is not run; it is listed under "Seen, not run". The test's name is never used.

| In the test | Covers |
|---|---|
| `{ SurfaceTextRule(input: $0).execute() }` | `SurfaceTextRule.body`, when `execute()` is a protocol-extension method whose body is one member (`{ body }`) |
| `{ $0.label }`, `{ surface in surface.label }`, `\Surface.label` | `Surface.label` |
| `Prove(it: LanguageOption.init(from:))` | `init(from:)`, never `init(rawValue:)` |
| `{ Formatter.shared.text(for: $0) }` | `text(for:)`; if no scanned function has exactly these labels, one whose labels contain them in order (`text(for:style:)`), as Swift would pick it |
| `Prove("Surface.label", it: …)` | `Surface.label`: name the function when nothing can be read |
| `Prove("Formatter.text", …)` (no labels) | every `Formatter.text` |

- For `$0.label`, the test records its input type when it runs (`AppFeature.Surface` → `Surface`). A walk whose type
  has no scanned `label` is listed as not linked.
- Under that list, a `hint:` line names the member to write, or the `--scan <dir>:<Target>` that declares the type (or
  free function, or extension member such as `Double.withFormat`). It is found from the `Package.swift` files and
  sources under the given packages, without building. In `--json`: `scanHints`.
- Any other `execute()` body is not followed: name the member, `Prove("SurfaceTextRule.body", it: …)`.
- A subject that names only a type proves none of its members.

### Relational claims: proved for every input by logic

`swiftformal check` also gives `Injective()`, `RoundTrip(through:)`, `Agrees(with:)` and `Matches` of a walk to logic,
which decides them for every value of the input type, not only the walked ones. It runs the rule twice in one query: on
two inputs for `Injective`, or once followed by the inverse or the other rule. Each closure must be one chain of calls
on the input:

```swift
Prove("SeatRule.body", it: { SeatRule(input: $0).execute() }, over: .samples(seats)) {
    Injective()
    RoundTrip(through: { SeatBack(input: $0).execute() })
    Agrees(with: { legacySeatCode($0) })
}
```

`f($0)`, `T.f(x: $0)`, `T(input: $0).m()`, `$0.p`, `\.p`, a named parameter and a `try` are read; an inverse may end
in `!`. A value is passed where an `Optional` of it is taken.

- **Proved:** the property's line says "for every input, by logic" (with its assumptions, such as a call with no
  body), and so does `total`: logic first proves the rule returns normally on every input. When every property of the
  walk is proved this way, so is the walk.
- **Counterexample:** when the walk's domain is a sample (`.samples`, `.boundaries`, a generated domain) and passed,
  the property fails with the input logic found, marked "found by logic, outside the walked inputs". A complete
  domain, even one too big to walk (`.int(0...n)`), states a precondition logic does not know, so its walk's verdict
  stands. A precondition in the function itself is a `#requires`.
- **Not read** (the walk's verdict stands): a closure that captures a value or takes a second argument, a loop of
  rules, a compared type with a floating-point value (`-0.0 == 0.0`, `nan != nan`) or a hand-written `==`, a type
  logic does not read, a rule that may trap, and every walk of a test target that declares a `==`, function or type
  with a name the closure calls. `Injective` over localized text stays undecided: two keys may have the same text.
- A result is used only when the rule takes exactly the walk's input type (module and `Optional`s included):
  `{ $0.code }` over `Seat` is never proved by another type's `code`. Limits:
  [KNOWN-ISSUES](../KNOWN-ISSUES.md#23-relational-claims-of-walks-proved-by-logic-by-design-for-now).

### Tests in the app's own style

A walk is one call in a plain `@Test`: no step enums, session structs, outcome structs or run functions.

**Sessions.** `.sessions(from:actions:upTo:)` is the domain of every sequence of up to `upTo` actions from a start
state; `Prove(it: step, over: .sessions(...))` sends each action and checks the properties after every step. For a TCA
reducer the step is `{ reducer.reduce(into: &$0, action: $1) }`; effects are not run, so a server's answer is an
action of its own. Build the actions' domain with `Domain.union`, one part per case.

```swift
private let reducer = EventDetailsStore()
private let tabActions = Domain<EventDetailsStore.Action>.union(
    Domain.of(allKinds).map(EventDetailsStore.Action.changeKind),
    Domain.int(0...2).map(EventDetailsStore.Action.tabSelected),
    .of([.viewRanking, .retry]))

@Test("every sequence of up to 4 tab events keeps the selected tab on screen")
func selectedTabNeverOutOfRange() {
    Prove(it: { reducer.reduce(into: &$0, action: $1) },
          over: .sessions(from: EventDetailsStore.State(), actions: tabActions, upTo: 4)) {
        Always("the selected tab is on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
    }
}
// FAILED the selected tab is on screen for input changeKind(.multiStage) → tabSelected(2) → changeKind(.single):
//        fails after action 3 (changeKind(.single))
```

| Write | It holds when |
|---|---|
| `Always("name") { state in … }` | the start state and the state after every action pass |
| `EachStep("name") { before, action, after in … }` | every action of every session passes, seen with the states around it |
| `Satisfies("name") { session, run in … }` | the whole session passes (`run.states`, `run.finalState`) |

- Sessions are walked shortest first, so the failing one is a shortest one, printed without module names.
- `from:` also takes a `Domain` of start states; the failing session then starts with `from <state>:`.
- `n` actions and `upTo: k` are `1 + n + … + n^k` sessions; the budget applies as for any walk.
- A step that cannot happen in some state (a tap on a tab that is not shown) returns early.
- `swiftformal check` links `reducer.reduce(into:action:)` to `EventDetailsStore.reduce(into:action:)` when the test
  sources create `reducer` with that one type; `{ $0.send($1) }` links `send(_:)` of the recorded state type. A name
  created with two types, declared with a written type only (`let reducer: Base`, a parameter), or bound another way (a
  closure parameter, `for … in`, `case let`) links nothing: write the subject first,
  `Prove("Store.reduce(into:action:)", it: …, over: …)`.

**Known issues.** Pass `knownIssue:` instead of wrapping the call in `withKnownIssue { … }`. The test passes while the
walk fails, and fails once it passes. Name the failing inputs to keep it strict: `KnownFailure("…", inputs: [21, 22])`
or `failingInputs: ["zh-Hant: item_moved_to_archive"]`; a failure on any other input is an ordinary failure.
`swiftformal check` reads it as it reads `withKnownIssue`.

**Every failing input.** `reporting: .everyFailure` walks the whole domain (within the budget) and lists every failing
input of every property; `Prove(...).failures` holds them all. With a known issue that names its inputs, a named input
that no longer fails is a failure too:

```swift
@Test("every key in every language takes the same format arguments as English")
func everyFormatMismatch() {
    Prove(it: { $0.key.localized(locale: $0.language) }, over: allKeysInAllLanguages, reporting: .everyFailure,
          knownIssue: KnownFailure("zh-Hant takes %1$d %2$d", failingInputs: ["zh-Hant: item_moved_to_archive"])) {
        Satisfies("the same format arguments as English") { input, shown in !formatMismatch(input, shown) }
    }
}
```

**Domains from tables.** `Domain.named([...])` takes literal rows with a name each, so a failing input prints as its
name:

```swift
private let servers: Domain<NamedValue<ValuesData>> = .named([
    "metric default": ValuesData(altitude: 0, temperature: 25, altitudeUnit: .meters, temperatureUnit: .celsius),
    "cold day": ValuesData(altitude: 120, temperature: -5, altitudeUnit: .meters, temperatureUnit: .celsius),
])
```

Also built in: `.allCases`, `.int(0...10)`, `.of([...])`, `.optional(d)`, `.arrays(of: d, maxLength: n)`,
`.product(a, b, c)` (up to four, then `map` to a struct) and `.union(a, b, c)`. A part not of the domain's type yet is
written in full: `Domain.int(0...2).map(Action.tabSelected)`.

**Copies of app code.** A package test cannot import the app target, so a walk over a copy of an app function names
something no scan has: start its subject with a word that is no type (`"copy of BoundLabelRule"`), so
`swiftformal check` lists it as not linked.

## Domains

A `Finite` type that cannot hold invalid values needs no `#requires`.

- Every `CaseIterable` type has a domain (`over: Surface.domain`), but it is a sample: a hand-written `allCases` may
  leave values out, so walks over it say `bounded`. To prove, claim the list complete: `extension Surface: Finite {}`
  (which also lets you leave out `over:`), or `over: .allCases` where the compiler wrote `allCases`.
- For your own structs and enums, `@Finite` writes the domain from the stored properties or cases. `@Values`
  narrows one property:

  ```swift
  @Finite struct Order {
      @Values(.int(0 ... 3)) var quantity: Int
      var express: Bool
  }
  @Finite enum Plan { case free, paid(Bool) }
  ```

- Foreign types (Kotlin sealed classes, types from other packages) cannot be derived. List their values once:
  `Domain.of([...])`, or `Domain.union([...])` for payload cases, or generate them (below).
- Any sampled part makes the verdict `bounded`.
- `Domain` is `@unchecked Sendable`, so a domain can be a global `let` under Swift 6. Build domains from pure values.

### Types from binary frameworks

For a binary framework (Kotlin Multiplatform through SKIE, or any closed-source framework), `sfgen domains` (an
internal tool, not part of the `swiftformal` command) writes the domains from the framework's symbol graph
([Generate](generate.md#domains-for-a-binary-framework)): a sealed hierarchy
is the union of its subclasses, a Kotlin `object` its `shared` singleton, a data class is built through its
initializer from its fields' domains. Add the file to your test target:

```swift
// Generated: extension Domain where Value == Reward { static var reward: Self { … } }
@Test func rewardText() { Prove(it: rewardText, over: .reward) { Satisfies("never empty") { !$1.isEmpty } } }
```

- A domain built only from finite fields is exhaustive, and a walk over it can prove.
- An enum's domain is complete only when its `allCases` lists each case the symbol graph declares; the generated code
  checks that when the walk runs. Otherwise it is a sample.
- `Int`, `Double`, `String` and array fields are sampled at their boundaries (0, ±1, min, max, NaN, "", a non-ASCII
  string): `bounded`, never `proved`. Each generated domain says which in its doc comment.

## `@Verify`: the same promise, also proved by Scan

Write the promise in place, inside the function or computed property, with `import SwiftFormal`. `@Verify` turns
`#requires` and `#ensures` into checks in the body, and adds:

- `verify_<name>()`: walks the domain you gave.
- `<name>_requires` and `<name>_ensures`: `swiftformal check` proves them on the compiled function for **every** input
  ([Scan guide](scan.md)). A walk over `0 ... 1_000` can pass while a promise breaks at `Int.min`; Scan finds that
  input. You never write these two yourself.

This is the only promise Scan reads. A hand-written `<name>_requires` / `<name>_ensures` is not read, and Scan,
`swiftformal check --gate` and the editor say so ("contract not read: … write the contract in place with @Verify,
#requires and #ensures").

**`mutating` methods:** `#ensures` also gets `self` from before the call, last: `#ensures { result, old in … }`, or
`#ensures { old in … }` if it returns nothing. There is no `verify_<name>()` (a walk would need values of `self`).
Scan proves it for every `self`.

### On a computed property

`@Verify` on a computed property applies to its getter. Write the getter's code after the promise; one expression
needs no `return`:

```swift
struct Rule {
    var title: String

    @Verify
    var body: String {
        #requires(!title.isEmpty)
        #ensures { result in result.hasPrefix(title) }
        title + "."
    }
}
```

Scan pairs `body_requires()` and `body_ensures(_:)` with `Rule.body.getter`. `static` properties and properties in
enums and extensions work the same way. A property with a setter takes `@Verify` on the `get`, not the `var`; there
Scan sees the contract only as the checks in the getter, and a warning says so. To have it proved, move the code into
a property without a setter or a function.

### When there is nothing to walk

`@Verify` writes no `verify_<name>()`, only the checks and the promise Scan proves, for:

- a computed property, and a function without parameters;
- a `mutating` method;
- a function without `over:` whose parameter is surely not `Finite`: `String`, `Int`, `Double`, `Date`, `URL`, an
  array, a dictionary, a tuple, a closure, an optional of one of these, an `inout` or a variadic parameter.

So `@Verify func greeting(for name: String) -> String { … }` needs no `over:`. Give `over:` when you also want a walk.
A parameter of your own type is walked over its domain when it is `Finite` (`Domain.ofParameterType`); otherwise that
walk checks nothing and is `bounded`. A function with an `inout` parameter gets no `<name>_ensures` (return the new
value instead). Past four parameters, `@Verify` builds the domain from nested pairs; `Domain.product` takes up to six.

### What a release build keeps

The checks in the body (and the copy of `self` that `#ensures { result, old in … }` reads) are inside `#if DEBUG`.
Without `DEBUG`, the body runs as you wrote it. SwiftPM and Xcode's default Debug configuration
(`SWIFT_ACTIVE_COMPILATION_CONDITIONS`) define `DEBUG`; a custom configuration may not.

| | Debug (`DEBUG` defined) | Release (no `DEBUG`) |
|---|---|---|
| Checks in the body, copy of `self` | yes: a broken promise stops at `assertionFailure` | no |
| `verify_<name>()` | walks and checks each `#ensures` | the same: it checks them itself |
| `<name>_requires`, `<name>_ensures` (what Scan proves) | yes | yes |

So `swift test -c release` finds the same broken promises as a debug run, and Scan proves the same promise at
`-Onone` and with `-O`.

`@Verify(checks: .always)` (or `@Verify(over: …, checks: .always)`) keeps the checks in every build. A failing check
calls `assertionFailure`, which stops only a build that keeps assertions (`-Onone`): use it for a configuration that
keeps assertions without defining `DEBUG`.

### Adding `@Verify` to existing code

- Only lines are added. A body of one expression still works without `return` after the `#requires` and `#ensures`
  lines (`switch key { case "a": "A" … }`, `if … { .a } else { .b }`, `x * 2`).
- SwiftLint: a `// swiftlint:disable:next` right above `func` now disables the `@Verify` line instead, and SwiftLint
  reports `superfluous_disable_command` plus the old violation (`cyclomatic_complexity` and other function rules are
  reported on the `func` line). Put the comment between the attributes and `func`, or use
  `// swiftlint:disable:this` at the end of the `func` line. Any attribute (`@discardableResult`) does the same.

  ```swift
  @Verify(over: .of(imageKeys))
  // swiftlint:disable:next cyclomatic_complexity
  func imageName(for key: String?) -> String? {
  ```

## When the function can trap

A Swift trap (overflow, force unwrap, `precondition`) cannot be caught: in a plain `Prove` it ends the whole test run.
`await Prove(neverTraps: Walk.self)` walks the function in a Swift Testing exit test, so a trap ends only that child
process, and the test fails with the input, confirmed by calling the function alone on it in a second child. The
function and its inputs are an `internal` type at file scope (the child finds it by name; for a `private` or local
type the walk says it cannot):

```swift
enum BoundLabel: ExitTestWalk {
    static let inputs: Domain<Double> = .of([0, 15, -5, 54, -10, 36.4, 9.2e17, 1e18, .infinity, -.infinity, .nan])
    static func call(_ input: Double) -> String { BoundLabelRule(input: input).formattedBound }
}

@Test("bound label: no Double the type can hold traps")
func boundLabelTraps() async {
    await Prove(neverTraps: BoundLabel.self,
                knownIssue: "Int((abs(x) * 10).rounded()) traps for |x| ≥ 9.3e17, ±infinity and NaN")
}
// BoundLabel.call traps for input 1e+18 (step 7, SIGTRAP: … Fatal error: Double value cannot be converted
// to Int because the result would be greater than Int.max); confirmed: it traps when called alone
```

- It takes the same `budget:`, `allowBounded:`, `knownIssue:` and `sourceLocation:`; suite defaults reach the child.
  After a trap, its `report` has one failed property, "never traps", with the input.
- `swiftformal check` reads the function from the body of `call` (`BoundLabelRule.formattedBound` above) and runs the
  walk like any other. After a trap it is never `proved` or `bounded`. A type declared twice in the test sources, or a
  `call` whose first call cannot be read, links nothing: write the subject first,
  `Prove("Rule.member", neverTraps: …)`.
- The child writes its step from a signal handler (`write(2)`) and dies of the same signal; the parent maps the step
  back to the input. A trap inside a property is reported as "trapped while checking", not blamed on the function.
- About 0.11 s for 65,536 inputs with the confirmation, 0.07 s for a clean walk (debug build, macOS 13 target).
- **Not on iOS:** Swift Testing has no exit tests there (and they need Swift 6.3). No `#if` is needed: the walk checks
  nothing, records a warning, and its report is `bounded`.

## Recipes

**List every failing input.** A walk stops at a property's first counterexample. For a data audit (every translation
key in every language, every row of a table), pass `reporting: .everyFailure` ([above](#tests-in-the-apps-own-style)).

**Say where the inputs come from.** `TabKind.allCases[selectedTabIndex]` in a computed property traps for indices the
UI never sends. Scan reports one (`selectedTabIndex = Int.min`), and `swiftformal check` reports the getter broken,
whatever its walk says. Two fixes:

- Better: make the bad value impossible (send the enum case instead of an `Int`, or check the index).
- Or state the assumption in the getter, so Scan proves the rest:

  ```swift
  @Verify
  var selectedTab: TabKind {
      #requires(TabKind.allCases.indices.contains(selectedTabIndex))
      return TabKind.allCases[selectedTabIndex]
  }
  ```

  A `#requires` is a promise you make, checked only in debug builds.

## Products

| Product | Contents |
|---|---|
| `SwiftFormal` | app code: the core and the `@Verify` macros (the macro plugin uses swift-syntax and is never linked into an app) |
| `SwiftFormalTesting` | tests: `Prove`, needs the Testing module; re-exports symbolic proofs (`SFProve`, [guide](prove.md)) |
| `swiftformal` | the command: `check`, `doctor`, `lsp`, `strings` |

Validated on 314 real `Rule` types of a real iOS app (the raw data is not public).
Design and limits: `archive/design/specs/2026-11-05-swiftformal-product-design.md`.

## Migrating from the pre-release names

Each of these names is an unavailable declaration now: code that uses it does not compile, and the error says what to
write instead.

| Before 0.1.0 | Write instead |
|---|---|
| `expectProved(subject, f, over: d) { … }`, `prove(subject, f, over: d)` | `Prove(it: f, over: d) { … }` |
| `expectProved(subject, f) { … }`, `prove(subject, f)` | `Prove(it: f) { … }` (a `Finite` input) |
| `expectProved(report)` | `Prove(it: f, over: d) { … }`: it walks and records in one call |
| `expectProved(subject, from: s, actions: a, upTo: n, step: step) { … }` | `Prove(it: step, over: .sessions(from: s, actions: a, upTo: n)) { … }` |
| `await expectNoTrap(subject, Walk.self)`, `walkInExitTest(…)` | `await Prove(neverTraps: Walk.self)` |
| `verify(subject, f, over: d) { … }`, `verify(subject, f)` | `Prove(it: f, over: d) { … }` in a test, or `@Verify` on the function |
| `verifyContracts(…)` | `@Verify` with `#requires` and `#ensures`; it writes `verify_<name>()` |
| `partition(f, over: d)` | `Prove(it: f, over: d) { Matches(table: …) }`: say what each output must be |
| `lockBehavior`, `expectLocked` | `Prove(it: f, over: d) { Matches(table: …) }` or `Satisfies` |
| `describeOutput(x)` | `String(describing: x)` |
| `Table([…])`, `Image(equals:)`, `Image(within:)` | `Matches(table: […])`, `Outputs(exactly:)`, `Outputs(within:)` |
