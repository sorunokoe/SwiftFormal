# Development log before the first public release (0.1.0)

Frozen history; not maintained.

## [Unreleased]

### One front door: `swiftformal check`

- **Breaking: three products.** `SwiftFormal` (app code), `SwiftFormalTesting` (tests) and the `swiftformal`
  executable. Removed: `SwiftFormalContracts` (use `SwiftFormal`; its module and its tests are gone, the tests now run
  in `SwiftFormalTests`), `SFProve` (use `SwiftFormalTesting`, which re-exports it: `import SwiftFormalTesting` gives
  `proveSigned`, `prove`, `SymbolicInt`; `Examples/Prove` is now a test), `SFVerifyKit`, `sfverify`, `sfgen`,
  `SFGenKit`, and the plugins `SwiftFormalGate` (it could not build `@Verify` code, K12: use `swiftformal check
  --gate`) and `SwiftFormalScan` (use `swiftformal check --scan`). `sfverify` and `sfgen` remain executable targets
  of the checkout for the maintainers' scripts (`swift build --product sfverify`), which no package that depends on
  SwiftFormal can name. `swiftformal doctor` reads a package's `Package.swift` as text and names each removed product
  or plugin it still uses with what to use instead, and checks that `swiftformal` itself is a release build (it
  checked `sfverify`). The release artifact bundle now holds `swiftformal` (was `sfverify` for the gate plugin).
  `Benchmarks/` runs with an rpath to Testing.framework, since SFProve comes with SwiftFormalTesting.
- **Breaking: `swiftformal` has three commands: `check`, `doctor` and `lsp`.** `swiftformal verify`, `swiftformal
  scan` and `swiftformal gen` were removed; each now exits 2 with what to run instead: `swiftformal check --gate` for
  `verify`; `swiftformal check --scan <dir>:<target>` (with `--format json|xcode|sarif|github`, `--emit-tests`,
  `--at`, `--symbol`, `--mutate`) for `scan`; `Prove(it: …, over: …)` in a test for `gen`. Not reachable from
  `swiftformal` any more (they were `sfverify` and `sfgen` options): `--confirm` (running the emitted playback tests),
  `--cross-check llvm`, `--modular`, `--unwind`, `--config`, `--paranoid`, `--stats`, `--show-unsupported`, scanning
  loose files without a package, and the Rule generator (`sfgen symbols|generate|prune`).
- **`swiftformal check --gate`** is the build-time check that `swiftformal verify` was: the same `@Verify` promises,
  diagnostics, stamps, proof cache and exit codes (0 no error, 1 an error or a target that could not be built, 2 a
  usage error). `--strict` there means what it meant for `verify` (warnings become errors). New: `--build-log <file>
  --target <name>` reads an app target's compile command from the log of a build that ran (`xcodebuild … | tee
  build.log`, or Xcode's activity logs), builds nothing and keeps no stamps. Options of `check` that do not apply
  (`--scan`, `--tests`, `--at`, `--json`, …) are a usage error with `--gate`, not ignored.
- **`swiftformal check --build-log <file> --target <name>`** proves every function of a target that a build already
  compiled (an Xcode or Tuist app target), as `sfverify --build-log` did, with `--scratch-path` and `--cache-dir`; it
  combines with `--scan` and `--tests`.
- **`swiftformal check --format sarif|github`** prints the findings of `--format xcode` as SARIF 2.1.0 or GitHub
  Actions annotations; the exit code is the same in every format.
- **`swiftformal check --emit-tests <dir>`** writes `<Module>ScanPlaybackTests.swift` for each `--scan` target, one
  Swift Testing test per counterexample (as `sfverify --emit-tests`).

### One way to walk: `Prove`

- **Breaking: `Prove` is the one way to walk in a test, and `@Verify` in app code.** Every other entry point left the
  public API. The names a 0.1.0 user may have written are unavailable declarations: the code no longer compiles, and
  the error names what to write instead.

  | Removed | Write instead |
  |---|---|
  | `expectProved(subject, f, over: d) { … }`, `prove(subject, f, over: d)` | `Prove(it: f, over: d) { … }` |
  | `expectProved(subject, f) { … }`, `prove(subject, f)` (a `Finite` input) | `Prove(it: f) { … }` |
  | `expectProved(report)` | `Prove(it: f, over: d) { … }`: it walks and records in one call |
  | `expectProved(subject, from: s, actions: a, upTo: n, step: step) { … }` | `Prove(it: step, over: .sessions(from: s, actions: a, upTo: n)) { … }` |
  | `await expectNoTrap(subject, Walk.self)`, `walkInExitTest(…)` | `await Prove(neverTraps: Walk.self)` |
  | `verify(subject, f, over: d) { … }`, `verify(subject, f)` (SwiftFormal) | `Prove(it: f, over: d) { … }` in a test, or `@Verify` on the function |
  | `verifyContracts(…)` | `@Verify` with `#requires` / `#ensures` (it writes `verify_<name>()`) |
  | `partition(f, over: d)` | `Prove(it: f, over: d) { Matches(table: …) }` (say what each output must be) |
  | `lockBehavior`, `expectLocked`, `describeOutput` | `Prove` with `Matches(table:)` or `Satisfies`; `String(describing:)` |
  | `Table(…)`, `Image(equals:)`, `Image(within:)` | `Matches(table:)`, `Outputs(exactly:)`, `Outputs(within:)` |

  Moved to `package` access, with no replacement of their own: `TrapWalk`, `WalkStep`, `AloneCall`,
  `callAloneInExitTest`, `LockOutcome`, `LockChange`, `Partition`, `Checked`, and the walk on several threads
  (`verify(…, parallelism:)`, `Parallelism`; it was never released). The code `@Verify` writes now calls
  `SwiftFormal._verifyContracts`, public only because that code compiles in the app's module and hidden from the
  documentation. `Benchmarks/` reaches the package functions with `@testable import` and runs with
  `-Xswiftc -enable-testing`. `OneWayToWalkSlowTests` builds a package that depends on SwiftFormal as an app does:
  every `Prove` form and `@Verify` compile there, every removed name fails with its message, and every hidden name is
  not found.
- **`swiftformal check` reads only `Prove(`.** `expectProved(`, `expectNoTrap(`, `walkInExitTest(` and `partition(`
  are not read any more (they do not compile), so the "Seen, not run" section, the `notRunWalks` key of `--json` and
  `WalkCheck.kind` are gone, and the progress line no longer counts "not run" walks. The hints that suggested a walk
  name `Prove`.
- **`Prove` has a form for every walk, all written like the plain one.** Sessions are a domain:
  `Prove(it: { reducer.reduce(into: &$0, action: $1) }, over: .sessions(from: State(), actions: actions, upTo: 4)) {
  Always("…") { … } }`, with `Domain.sessions(from:actions:upTo:)` from one start state or from a `Domain` of them;
  the `it:` closure is the step, and it takes `reporting: .everyFailure` too. No trap: `await Prove(neverTraps:
  SelectedTab.self)` runs the walk of the `ExitTestWalk` type in a child process, as before. Its `report` holds what
  `swiftformal check` reads: a trap is one failed property, "never traps", with the input. Where exit tests do not exist
  (iOS), nothing is walked and the report is `bounded` with nothing checked, never `proved`. A leading subject string
  (`Prove("Type.member", …)`) is optional on every form; without one the report uses the test's name, and a trap check the walk type's
  `call` (`SelectedTab.call traps for input 2`).
- **`swiftformal check` reads the function from every form.** From the `it:` closure as before; in a session step `$0`
  is the state (the walk's record names the state's type, so `{ $0.send($1) }` links `State.send(_:)`); a call on a name
  the test sources create with one type links that type's member (`let reducer = TabsReducer()` and
  `{ _ = reducer.reduce(into: &$0, action: $1) }` link `TabsReducer.reduce(into:action:)`; a written type alone,
  `let reducer: Base` or a parameter, is only the static type and links nothing); `Prove(neverTraps: Walk.self)`
  is read from the body of the type's `call`. Each reading fails closed: a name declared with two types or bound
  without a written type (a closure parameter, `for … in`, `case let`), a parameter of the closure other than the
  first, or a walk type whose name is declared twice (whatever it conforms to) links nothing, and the walk is listed as unlinked until it has a subject.
- **`Prove` follows the suite defaults.** It used `Budget.default` and `allowBounded: false` whatever the
  `.swiftFormal(budget:allowBounded:)` trait said; every `Prove` form now reads `WalkDefaults`, as the other walks did.
  An argument written at the call still wins.
- **`sfgen` writes `Prove`, and no behaviour lock.** The generated file now checks each Rule with
  `Prove(name, it: …, over: domain) { Deterministic() }`, which is public, so it compiles in the app's test target
  (`GeneratedTestsSlowTests` builds it in a package that depends on SwiftFormal as an app does). It no longer writes or
  reads `__SFLocks__` files, and its `SFGEN` result line has no `locked`/`CHANGED` column; delete old lock folders.
  Outputs are still compared as text with object addresses and UUIDs masked, by a helper in the generated file.

### Only `@Verify`: a contract is written in place (breaking)

- **Breaking: Scan reads only the contract `@Verify` writes.** A contract is `@Verify` with `#requires` and `#ensures`
  in the function's body. The `f_requires` / `f_ensures` peers the macro writes are recognised by where the compiler
  puts them (the macro's expansion buffer, `@__swiftmacro_…6VerifyfMp_.swift`, in the debug info). A hand-written
  `f_requires(…)` / `f_ensures(…)` next to `f` is no longer read by `sfverify`, `swiftformal check`, `swiftformal
  verify`, the gate or the editor. It is not dropped silently: the function's report has the new JSON key
  `ignoredContracts` (in the schema), the text report says `contract not read: … write the contract in place with
  @Verify, #requires and #ensures`, `swiftformal check` and the editor show a warning, and `swiftformal verify` and the
  gate an error. The function's verdict is then about traps only (`safe`, `mayTrap`, …), never `contractHolds` or
  `contractFails`; the hand-written function is scanned as ordinary code. Fix: move the conditions into the body as
  `#requires(…)` and `#ensures { … }` under `@Verify`.
- **Breaking: `// sf:verify` is no longer read.** `@Verify` (with or without `#requires` / `#ensures`) is the one way
  to ask for a proof. Each `// sf:verify` comment is an error in `sfverify --gate`, the SwiftFormalGate plugin and
  `swiftformal verify` (`` `// sf:verify` is no longer read: mark the function @Verify instead ``), a warning in the
  editor, and a failing `swiftformal doctor` check; it selects nothing. The editor's "Gate the build on this proof
  (// sf:verify)" action is gone; "Add a contract" writes `@Verify`, `#requires` and `#ensures`.
- **Breaking: the gate proves the `@Verify` functions.** `sfverify --gate` gates every function or computed property
  marked `@Verify`, and every function with a contract (read or not), instead of `// sf:verify` functions. A file that
  uses `@Verify` needs the built macro, so run the gate with `--package . --target T --build --gate`, or use
  `swiftformal verify`. The SwiftFormalGate plugin compiles a target without the built macro (K12), so on a target
  that uses `@Verify` it fails closed, and on one without proves nothing: `swiftformal doctor` says so for each target
  that applies it. `Examples/GatedPackage` now uses `@Verify` and no plugin; `Scripts/check-examples.sh` gates it with
  `--build`. `Gate.check` takes the `@Verify` promises (`promises:`) instead of markers and contract names, and
  `Promise.Kind` has no `marker` case.
- **A trap in the body `@Verify` rewrites** is reported by the gate at the function, not in the macro's buffer (which
  no editor can open), as `swiftformal verify` already did.
- **A peer `@Verify` wrote that Scan cannot pair is reported.** Before, such a peer was macro code and left out of the
  report without a word; now it is listed (as `macro` code), and `swiftformal verify` and the gate fail: it checks
  nothing.
- **Changed exit code of plain `sfverify`.** A false hand-written `f_ensures` used to be `contractFails` (exit 1); it
  is not read now, so the function is `safe` and `sfverify` exits 0. A CI job that runs plain `sfverify` and relies on
  that exit code passes where it failed: `--xcode`, `--format sarif` and `--format github` print a warning for each
  contract not read (SARIF rule `contractNotRead`), and the text report and `swiftformal check` say it, but only
  `swiftformal verify` and `sfverify --gate` fail on it. Hand-written contract functions are now counted as ordinary
  functions in the summary (`total`, `safe`, coverage).
- **Lost: a proved contract on a property with a setter.** `@Verify` on its `get` writes no peers, and hand-written
  ones are no longer read, so Scan sees such a contract only as the checks in the getter. Move the code into a
  property without a setter, or a function, to have it proved.
- **Hints:** an `undecided` function's hint says to add a `#requires` that bounds the inputs (was an `f_requires`).
  `sfverify --help`, `swiftformal --help`, `swiftformal verify --help` and `swiftformal doctor --help` describe only
  `@Verify` (the CLI contract was recorded; no exit code changed).
- **Proof cache:** `ScanClaimVersion` is 3, so no answer stored before is reused.

### One import, contracts written in place

- **`import SwiftFormal` is the one import.** `@Verify`, `#requires`, `#ensures`, `@Finite`, `@Values` and
  `ContractChecks` moved from `SwiftFormalContracts` into `SwiftFormal`, which now depends on the `SwiftFormalMacros`
  compiler plugin (built with swift-syntax, run by the compiler, never linked into an app). The code the macros write
  names `SwiftFormal.…`, never `SwiftFormalContracts`. **Deprecated:** the `SwiftFormalContracts` product and module;
  it only re-exports `SwiftFormal`, so 0.1.0 code (`import SwiftFormalContracts`) still builds. Swift cannot mark a
  module deprecated, so the compiler does not warn; change the import and the product to `SwiftFormal`. The editor's
  "Add a contract" action now adds `import SwiftFormal`, and only when the file imports neither module.
  `--disable-default-traits` still leaves out sfgen's reader, but no longer swift-syntax as a whole: the macro needs it.
- **No SwiftUI name clashes.** An app file imports SwiftUI (and Foundation, Combine, Observation, UIKit) next to
  `import SwiftFormal`. Of every public top-level name of `SwiftFormal`, only two are also declared there: `Table`
  (SwiftUI) and `Image` (SwiftUICore). `Table` in a type position, such as `extension Table`, was "ambiguous for type
  lookup". **Renamed:** the property `Table([...])` is now `Matches(table: [...])` (same check, same report name
  "matches table"). **Moved:** the deprecated `Table` type and `Image(equals:)` / `Image(within:)` functions are now in
  `SwiftFormalTesting` only, still deprecated, so 0.1.0 test code that imports it still builds. A type of the app's
  own module with a SwiftFormal name (`Report`, `Domain`, `Budget`, `Property`, …) shadows SwiftFormal's, and the
  code `@Verify` writes names `SwiftFormal.Report` and the like, so those names stay. The new test target
  `SwiftFormalAppImportTests` is such an app file, built with the strict settings.
- **`@Verify` on computed properties.** `@Verify var body: String { #requires(…); #ensures { result in … }; … }`
  checks the contract in the getter, as in a function (debug builds by default, implicit return kept), and writes
  `body_requires()` / `body_ensures(_:)` next to the property, which Scan pairs with the getter and proves: instance and
  `static` properties, in structs, enums and extensions. A property with a setter takes `@Verify` on its `get`, which
  adds the checks but cannot add peers: a warning says Scan then sees the contract only as those checks. `@Verify` on
  a property whose braces hold accessors (`{ get { … } }`) is a compiler error ("'body' macro cannot be attached to
  property"); the macro adds what to write instead.
- **`@Verify` without a walk.** With nothing to walk, `@Verify` writes no `verify_<name>()`, only the contract Scan
  proves: a computed property, a function without parameters (was "needs at least one parameter to range over"), a
  `mutating` method (as before), and a function without `over:` whose parameter is surely not `Finite` (`String`,
  `Int`, `Double`, `Date`, an array, a tuple, a closure, `inout`, variadic; was "type 'X' has no member 'domain'"). A
  parameter type the macro cannot judge from the source (a type of yours) takes the new `Domain.ofParameterType(_:)`:
  the type's domain when it is `Finite`; otherwise an empty sample, so that walk compiles and is `bounded`, never
  `proved`. `over:` with nothing to range over is an error at the domain. `inout`, variadic and `some` parameters are
  rejected only when `over:` asks for a walk. A function with an `inout` parameter gets `_requires` (with `inout`, the
  form Scan pairs) and no `_ensures`, with a warning that Scan checks no `#ensures` there.
- **Fixed: `@Verify` on a function of five or more parameters did not compile** ("cannot convert value of type
  '((String?, String, String?, Bool, …)) -> …' to expected argument type '((String?, B, String?, Bool)) throws ->
  …'"): the type domain was a flat five-way product, which does not exist. Past four parameters it is now nested pairs
  mapped back to the flat tuple, as `@Finite` builds a struct. **Added:** `Domain.product` of five and six domains,
  for `@Verify(over:)`. Tested from zero to six parameters, with labels, defaults and `inout`.
- **`swiftformal verify` checks `@Verify` getters.** A `@Verify var name` (or `@Verify get`) is a promise of the
  property `name`, so the build scans its getter; 0.1.0 found no `func` after the attribute and left it out (a file
  with only getter contracts said "no promises"). The "only a test can check it" hint names `verify_<name>()` only
  where `@Verify` writes one.
- **Fixed: `--mutate` edited the checks `@Verify` writes.** Survivors such as "it returns true instead" or "the
  cases .some and .none are swapped" were edits of an `#ensures` closure or a `#requires` condition, which change the
  contract, not the function. The mutation pass now leaves alone every value whose only use is a branch into
  `Contract.requiresFailed` / `ensuresFailed` (with the blocks of an `&&` in the condition, the `!`, and the call of
  an `#ensures` closure, which it then does not enter, also in a `mutating` method where it captures `self`), at
  `-Onone` and after `-O` inlined the closures. The body closure and `return __sf_result` are still edited. Verdicts
  never change.

### Both lines of work together

- The mapper verification work below fits the new shape above: `swiftformal verify` became
  `swiftformal check --gate`, which takes `--no-opaque-calls` (so do `check --build-log` and `sfverify --gate`);
  `swiftformal strings` stays as a fourth command and `sfgen domains` stays. The walk blocks `Agrees(with:)`,
  `Injective(except:)` and `NeverOutputs` and the relational proofs in `check` work with `Prove(it:over:)`.
- The planted-bug fixtures and the scan tests write their contracts as `@Verify` peers (`#sourceLocation` markers),
  because a hand-written `f_requires` / `f_ensures` is no longer read. Their expectations are unchanged.
- Proof cache: SIL semantics version 37 and Scan claim version 6. Both lines had bumped them (36/5 and 26/3), and
  the merged semantics differ from either, so old entries are dropped.
- `Scripts/baseline/cli.txt` is re-recorded: the usage texts now list `--no-opaque-calls` under `check` and the
  `strings` command.

### Mapper verification: mapped correctly

- `swiftformal check` proves a walk's `Injective()`, `RoundTrip(through:)`, `Agrees(with:)` and `Matches` for every
  value of the input type with logic, when each closure is one chain of calls on the input (`T(input: $0).execute()`,
  `f($0)`, `$0.code`): the rule runs twice in one query. A proof shows "for every input, by logic" with its
  assumptions; over a sampled domain, a counterexample fails the walk with the pair logic found ("found by logic,
  outside the walked inputs"); anything logic does not read leaves the walk's verdict as it was. Floating-point
  values, a hand-written `==` and localized text are not decided ([KNOWN-ISSUES](../docs/KNOWN-ISSUES.md) 23,
  [Walk](../docs/guides/walk.md#relational-claims-proved-for-every-input-by-logic)).
- New walk properties: `Agrees(with:)` (also `where:` a relation), `Injective(except: [(a, b)])` for the merges a
  mapper is meant to make, and `NeverOutputs` for outputs that must never appear (an empty text, a raw key).
- Planted-bug shape 15 (mapped correctly). The proof cache is unchanged (semantics 32, claim 5): relational results
  are not cached.

### Mapper verification: text

- Scan proves which localization key a function picks. `NSLocalizedString`, `String(localized:)` and a body-less
  `localized…` call are an unknown text of their key, the same for the same key: two cases that pick the same key
  are `contractFails`, and different keys are never taken to have different texts (`undecided`). The function lists
  the assumption that localization is deterministic ([KNOWN-ISSUES](../docs/KNOWN-ISSUES.md) 21).
- `String(format:)` with a literal format is read: `%d` prints the decimal text and `%@` the string, and a format
  that reads more arguments than it is given, or a number as `%@`, is `mayTrap`. An array literal of standard
  numbers and strings may be passed to a body-less call (`"key".localized([n])`).
- An interpolation with ASCII literal parts equals a literal only where the parts line up (`"-\(n)" == "-0"` exactly
  when `n == 0`), and starts with its first literal part (`hasPrefix`).
- `swiftformal strings <path> [--sources <dir>]`: checks `.xcstrings`, `.strings` and `.stringsdict` catalogues
  without a build or a solver: a key missing in a language, format arguments that differ in count or type across
  languages, a key shown as its own text, and literal keys in the sources that no catalogue has
  ([Scan](../docs/guides/scan.md#localization-catalogues-swiftformal-strings)). The usage text lists it, so the
  recorded CLI contract of `swiftformal --help` and of usage errors changed.
- Planted-bug shape 13 (text); shape 5's `"-\(n)"` is now caught by logic. Proof-cache semantics version 31, Scan
  claim version 4: earlier cache entries are misses.
- Fixed: `String(format:)` no longer proves a decimal text for a length modifier that does not match the argument
  (`%hd` of 70000 is "4464", `%ld` of `Int32(-1)` is "4294967295"), nor a non-empty text for `%c`, a `%@` with a
  width, or a conversion with a precision (`%c` of 0 and `%.0d` of 0 are ""); `%Lf` of a `Double` is `mayTrap`.
  Proof-cache semantics version 34.

### Mapper verification: honesty

The tool never says "proved" or "passed" for what it did not check, and each reason it gives is what happened.

- `swiftformal check`: a contract that holds no longer stands in for a walk. Every walk linked to a scanned function
  runs, also where logic proved the function's `ensures`, because a walk may state another promise (a table,
  injectivity); a failing walk there now fails the run, where it was skipped before. The function is "proved by
  logic" only when its walks proved their promises too. A walk is skipped only where logic already found a failing
  input in every function it covers; it is then listed as not run (`notRunWalks`, kind `logicFoundFailure`), with
  that reason. The help text says the same.
- Scan: a `_requires`/`_ensures` that logic cannot read, or that is named after a function but does not pair with
  it (an `inout` parameter, other parameters), is no longer dropped. The function is `unsupported` with the category
  `contract not read` and the reason, and counts as not proved in the summary, the JSON and the exit code. If the
  function traps for an input its `requires` allows, it is `contractFails` with that input, whatever the unread
  `ensures` says.

### Mapper verification: binary types (walks)

- Every `CaseIterable` type has a walk domain with no `Finite` conformance, `over: T.domain`. It is a sample, so
  walks over it are `bounded`: a hand-written `allCases` may leave values out. `Finite` or `over: .allCases` claims
  the list complete.
- `sfgen domains` writes walk domains for the types of a binary framework (a Kotlin Multiplatform framework through
  SKIE, or any closed-source framework) from its symbol graph: sealed hierarchies, Kotlin `object`s and classes built
  through their initializers. A domain with a sampled field (`Int`, `Double`, `String`, arrays), or a class with state
  it or any superclass can change, is `bounded`, never `proved`. An enum's domain checks `allCases` against the
  cases in the graph when the walk runs, and is a sample when they differ; a manifest lists each type's status and why a type was skipped. `sfgen symbols --access-level internal`
  extracts SKIE's sealed enums ([Generate](../docs/guides/generate.md#domains-for-a-binary-framework),
  [KNOWN-ISSUES](../docs/KNOWN-ISSUES.md) 18).
- Planted-bug shapes 9 (a wrong arm over an imported `CaseIterable` enum) and 10 (a forgotten subclass of a sealed
  hierarchy, over a generated domain). Walks catch both; Scan catches shape 9 and leaves shape 10 `unsupported`.

### Mapper verification: regression gate

- Planted-bug suite (`Tests/SwiftFormalTestingTests/PlantedBugs/`, `PlantedBugWalkTests`, `PlantedBugScanTests`):
  eight small mappers, each with a bug of a kind found in a real iOS app's rules and its fix. Logic catches 6 of the
  8 shapes and walks catch 6 of 8; every shape is caught by one or the other. The fixed mappers prove. The shapes
  logic cannot read yet (a locale's decimal separator and `String.split`, `"-\(n)"`, `String(format:)`) are known
  issues, never a pass ([TESTING](../docs/TESTING.md#the-planted-bug-suite), [KNOWN-ISSUES](../docs/KNOWN-ISSUES.md) 16).

### Mapper verification: forms

- **Rules called through `execute()`** (`extension Rule { func execute() -> Output { body } }`). Scan reads
  `X(input: v).execute()` as `X.body`: the associated type `Output` comes from the conformance's witness table (two
  tables that disagree, nested associated types and generic conformances stay `unsupported`). A contract on a rule that
  calls another rule through `execute()` is proved, and a bug in the inner `body` breaks it. The proof cache's semantics
  version is 27.
- **Walks over `X(input: $0).execute()`** are linked to `X.body`, not to `Rule.execute()`, when `execute()` is a
  one-line forwarder to a requirement of the protocol and `X`, the protocol and the method are each declared once in the
  sources the tests can see (Known issue 17). Before, such a walk was "not run" and the hint named the wrong
  `--scan`; now an unlinked walk on a scanned type gets a hint naming the member: `Prove("X.body", it: …)`. On a
  95-function app sample, walks run went from 0 to 7 of 19 and unlinked walks from 18 to 3.
- **`==` on a `String`-backed enum in `#requires` / `#ensures`** is read (a contract that holds and one that fails, end
  to end).
- **An unsupported result names the field that blocks it**, for every type Scan refuses (also classes, generic types
  and indirect enums, and functions with a source place): the hint starts
  `blocked by field 'model.player.photo' of type CharacterSet.` (or `parameter 'p'`, `self`, `the result`), and the
  check's Unchecked list shows it.

### Mapper verification: binary types (logic)

Scan proves mapper logic over the types of a framework it has no SIL bodies of (a Kotlin Multiplatform framework
through SKIE, a closed-source Swift or Objective-C framework); before, every such function was `unsupported: type X`.

- **Enums from the compiler.** The cases of an enum a binary module declares come from a probe `switch` the compiler
  checks; it is closed only when the compiler says a client's `switch` needs no `@unknown default` (`@frozen`, or a
  module built without library evolution). An open enum has one more case, "unknown", so `@unknown default` is
  reachable. Payload types come from the probe's SIL. A class the API notes rename (`__DomainSurface`) is read by its
  Swift name.
- **Calls with no body are assumptions.** `onEnum(of:)`, getters such as SKIE's `ordinal`, the bridging calls,
  `Double(truncating:)`, Objective-C methods and `==` of Objective-C objects (`isEqual:`, which was `unsupported`)
  return any value of their type, a fresh one per call, and are assumed not to trap. Each is listed per function:
  `assumptions` in the JSON (schema: an optional key), `assumes:` in text, a `note:` in `swiftformal check --gate`. A
  proof holds for every value they may return; see [TRUST](../docs/TRUST.md) for what it takes on trust.
- **`--no-opaque-calls`** (`sfverify`, `swiftformal check`, also with `--gate` and `--build-log`) refuses every call with no body. It
  is not the default: Objective-C getters already returned any value before this change (issue 13), and the existing
  verdicts on Objective-C code keep holding, now with their assumptions listed. The recorded CLI contract
  (`Scripts/baseline/cli.txt`) changes only because the usage texts list the new flag.
- **Assumptions are transitive.** A proof that uses a callee's lists the callee's assumptions too: inlined (as
  before), and now also when the callee's proved contract stands for its code (`--modular`), which listed them only
  on the callee. The proof cache stores and replays the whole set.
- **Summaries count them.** `sfverify` text: `Proved safe (cannot trap for any input): N (k with assumptions)` and
  `Contracts: N hold (k with assumptions)`; JSON `summary.withAssumptions` (schema: an optional key, omitted when
  0). `swiftformal check`: `cannot trap for any input, assuming 2 calls with no body` per function, in its
  diagnostics `(logic, assuming 2 calls with no body)`, the per-function total `(… by contract; k assuming calls
  with no body)`, and `assumptions` per entry in its JSON. `swiftformal check --gate`: `N of M promises proved by logic (k
  assuming calls with no body), …`. No new outcome: verdicts are the same, only their wording changes, and only
  where a proof assumes something; the golden verdicts (`Scripts/baseline/golden-sfverify.json`) have no
  assumptions and do not change.
- **Where the call goes.** A call into a module compiled from source by the same build but not scanned (a sibling
  SwiftPM target, a framework target of the app) says `no body: not scanned (module M)` with the hint to scan it,
  not "binary module"; `no body available (module M)` when the file the compiler loaded does not say. Read from
  that file's path (`BinaryTypeCheck.origin(of:)`); verdicts do not depend on it.
- Planted-bug shape 11 (types of a binary module): logic catches it. Proof cache semantics version 29 (entries keep
  their assumptions, with the new wording). On the spike corpus (`BinaryProbe`, rules over a prebuilt Kotlin framework) 6 of 6 rules prove,
  0 before.

### Mapper verification: Foundation values

Scan reads mappers whose types hold library values beyond `UUID`, `URL`, `Locale`, `Date` and `Color`, and reads
`Date` arithmetic; before, such a function was `unsupported: type X` or `unsupported: no body`.

- **Dates are their `Double`.** `Date(timeIntervalSince1970:)`, `timeIntervalSince1970`,
  `timeIntervalSinceReferenceDate`, `addingTimeInterval`, `+`, `-`, `+=`, `-=`, `addTimeInterval`,
  `Date(timeInterval:since:)`, `timeIntervalSince(_:)`, `distantPast`, `distantFuture`, `==`, `<`, `>`, `<=`, `>=`
  are Foundation's IEEE operations (checked against Foundation, bit for bit). `Date.==` was unknown; a NaN date is now
  a counterexample to `d == d`. A date in a counterexample prints as `Date(timeIntervalSinceReferenceDate: …)`.
- **More values are held.** `Decimal`, `Calendar`, `TimeZone`, `DateComponents`, `URLComponents`, `CharacterSet`, and
  SwiftUI's `Image` and `Font`: a struct that stores one is read, and a copy equals itself.
- **Other calls on these types are assumptions.** With the default `OpaqueCallMode.all`, a call on one of these types
  (or on `UUID`, `URL`, `Locale`, `Date`, `Color`) that is not read returns any value and is assumed not to trap, listed
  in `assumptions` like a binary module's (KNOWN-ISSUES 22). A call that takes a closure, an existential, a generic or a
  value that could run the app's code is still `unsupported`; so is every such call with `--no-opaque-calls`.
- **`Decimal` arithmetic is `unsupported`** ("Decimal arithmetic"), never read as `Double`.
- **Faster debug solving.** The SAT solver's propagation no longer copies every watch list per literal in a debug
  build (a `self` copy made the list shared); release builds were not affected.
- Planted-bug shape 14 (Foundation values: two `UUID`s swapped, rounding at a tie, `-0.0`, NaN through a guard, a due
  date one day early, `Decimal` division): logic catches all but `Decimal`, which is `unsupported`. Shape 3 now stops
  at `String.split` instead of `Locale.decimalSeparator`. Proof cache semantics version 33.

### Mapper verification: closures and collections

Scan runs closure literals: the ones given to helpers of the module and to the `Array` calls rules use to build and
search rows. Before, every such function was `unsupported` ("closures and indirect calls" or "try_apply of …").

- **Closure literals.** A closure literal of the calling function (or a function named in its place) that cannot
  throw and captures only values runs, inlined with its traps, where a helper of the module calls its closure
  parameter (`apply(x) { $0 + 1 }`, the trailing-closure style of rules), as `Optional.map`/`flatMap` already did.
- **Arrays.** `map`, `filter`, `compactMap`, `first(where:)`, `contains(where:)`, `allSatisfy` and `count(where:)`
  with such a closure run it on each element, in order, the searches stopping at the first match. Exact for an
  array of known count (a literal; `map` of a literal gives a literal of the results); for a claim whose `#requires`
  bounds the count to at most 64, exact for every input.
- **Unknown length is never a proof.** Otherwise the claim is solved for arrays of at most 8 elements. A
  counterexample there is real; a proof is the new category `bounded` ("bounded (n ≤ 8): proved only for arrays of
  at most 8 elements, not for every input"): status `undecided`, never `safe` or `contractHolds`, with `bounded` (the
  calls, e.g. `filter over Array<Int8> (n ≤ 8)`) per function in the JSON and text, and `summary.bounded` (schema:
  optional keys). It is not cached. Outside a scan, such a call is `unsupported` ("an array of unknown length"). See
  [known issue 20](../docs/KNOWN-ISSUES.md#20-closures-over-arrays-unrolled-up-to-a-bound-by-design-for-now).
- **`--modular`** says which contracts a proof used: "used the contract of X" in text (was "by the proved contracts of X"); `usesContracts` in the JSON as before. It
  stays opt-in; see `docs/guides/scan.md`.
- Planted-bug shape 12 (closures over rows: a dropped row, an off-by-one in `first(where:)`, a `filter` keeping the
  wrong rows, `Optional.map` returning the wrong arm, an unbounded count): logic catches each, and never passes the
  unbounded one. Proof cache semantics version 30, claim version 3.
- **Deinits.** A `deinit` that only calls its Objective-C superclass's `-dealloc` (an `NSObject` subclass) no longer
  counts as running code. When some `deinit` of the read modules does run code, destroying an escaping closure, an
  existential, a key path, an object or an array, dictionary or set of objects is no longer refused in a scan: the
  verdict lists "deinit of X does not trap" for each such class X (with `--no-opaque-calls` it is refused, and the
  reason names X). Arrays, dictionaries and sets of objects are read when no `deinit` runs code (their elements are
  still not). What a `deinit` does besides trapping (a global it writes) is not modelled. Planted-bug shape 12b.
  Proof cache semantics version 31.
- **Deinits: superclasses outside the read modules are assumptions.** A `deinit` calling its superclass's was
  accepted whatever the superclass; one in an SDK or binary framework (or any Objective-C base class but `NSObject`)
  was never inspected, so releasing a subclass ran its code with nothing listed. Now only a superclass of the read
  modules (inspected) or `NSObject` runs no code; any other is listed as "deinit of S does not trap" (refused with
  `--no-opaque-calls`). Proof cache semantics version 36.

### Toolchain floor for consumers: Swift 6.1 (was 6.0)

- `Package.swift` is now `swift-tools-version: 6.1`, because it declares a package trait (H6). A package that depends
  on SwiftFormal needs Swift 6.1 or newer to resolve it; nothing else changes for it. The trait `Generator`, on by
  default, builds swift-syntax for `sfgen`'s source reader (`SourceIndexer`). With `--disable-default-traits` the
  package builds without swift-syntax: a cold debug build of everything took 35.9 s of user CPU instead of 94.7 s
  (15.4 s instead of 24.9 s wall), and `sfgen generate` then says it needs the trait. Products cannot depend on a
  trait, so `sfgen` and `SFGenKit` stay listed; `RuleInfo` moved to its own file. The `slow-dev` test lane passes
  `--disable-default-traits` (its own scratch path); CI and the other lanes keep the default, so `sfgen` and
  `SFGenKitTests` are still built and run there.

### Added

- Walks in an app's own test style (`SwiftFormalTesting`), without harness types (app study round 7: the walks written for
  an iOS app needed step enums, session structs, outcome structs and run functions). All additive:
  - Session walks: `expectProved("Store.body", from: State(), actions: actions, upTo: 4, step: { _ =
    reducer.reduce(into: &$0, action: $1) }) { Always("…") { state in … } }` walks every sequence of up to `upTo`
    actions and checks every state (`Always`), every step (`EachStep { before, action, after in … }`) or the whole
    session (`Satisfies` over `Session` and `SessionRun`). `from:` takes one start state or a `Domain` of them. A
    failing session prints as its actions, shortest first, without module names: `changeKind(.multiRound) →
    tabSelected(2) → changeKind(.single)`.
  - The trap check in one call: `await expectNoTrap("Type.member", Walk.self)`, with `Walk` an `internal` type
    conforming to `ExitTestWalk` (`static var inputs`, `static func call(_:)`). It runs the walk and the confirmation
    in exit tests the library declares (the child finds the type by its mangled name), so a test writes no
    `#expect(processExitsWith:)` and no `#if`; where exit tests do not exist it walks nothing and records a warning.
    Suite defaults reach the child. A private or function-local type is refused with the reason.
  - `knownIssue:` on `expectProved`, `Prove`, the session walk and `expectNoTrap` replaces `withKnownIssue { … }`
    around a walk: a string, or `KnownFailure("…", inputs: […])` / `failingInputs:` to fail on any other input.
  - `reporting: .everyFailure` on `expectProved` and `Prove` lists every failing input of every property in the
    issue (`Prove.failures` holds them), instead of `partition` and a loop of prints. With a known issue that names
    its inputs, a named input that no longer fails is a failure too. The walk lives in a new core file,
    `Sources/SwiftFormal/EveryCounterexample.swift` (`package`), because a property's observer is internal there.
  - `Domain.union(a, b, c)` (variadic) for an enum with payloads, and `Domain.named([...])` for literal rows printed
    by their names (`NamedValue`, members read through it).
  - `swiftformal check` finds `expectNoTrap("…"` walks, runs them and links them by subject: the test process writes
    the record, the child's verdict after a clean walk or a failure of `never traps` with the input after a trap. They
    are no longer under "Seen, not run" (`walkInExitTest` walks still are). It also reads the subject of an
    `expectProved(` or `expectNoTrap(` call from the next line, where `swift format` puts a long call's arguments;
    such walks were not found before. The CLI help says so (`cli.txt` recorded).
- `Examples/Verify`: the README's `@Verify` quick start as a package. `Scripts/check-examples.sh` runs its test
  and `swiftformal verify` on it, so the quick start must prove.
- `swiftformal check --jobs <n>` scans the `--scan` targets of up to n packages at the same time (default: half the
  cores, at most one per 2 GiB of memory). Targets of one package still run one after another (one SwiftPM `.build`),
  and packages built with different compilers are not proved at the same time. The report, `--json`, `--xcode` and the
  exit code are those of `--jobs 1`, the previous behaviour; stderr progress comes in `--scan` order. One line more on
  stderr says how many packages run at once. Without `xcrun`, packages are scanned one at a time.
- `swiftformal check --xcode` and `swiftformal lsp` show the walk outcomes `conflict` and `typeWalkFailed`: a
  failing walk over a whole type is one error at the walk (a note when the test marks it as a known issue), never a
  ✓; weak contracts (`--mutate`) are notes. Scan proof-cache entries written before semantics 26 or with claim
  version 1 are not reused.
- `swiftformal check --json` names the package of each module and verdict (`package`, as given to `--scan`), so two
  packages with targets of the same name are told apart. Additive: `schemaVersion` stays 1.
- `AGENTS.md` and an agent skill (DX plan Phase 5). [AGENTS.md](../AGENTS.md) is for AI agents that change SwiftFormal:
  the module map, the change loop, the checks and the soundness rules, with links to CONTRIBUTING and the docs.
  [`skills/swiftformal`](../skills/swiftformal/SKILL.md) is for agents writing code in an app that uses SwiftFormal:
  check the changed function with `swiftformal check --at <file>:<line> --json`, read `outcome`, then fix the code or
  add a contract or a walk; what each outcome means, and that `bounded`, `unchecked`, `undecided`, `unsupported` and
  `stale` never mean proved. `reference.md` lists every field of `check --json`. The README says how to install the
  skill. No MCP server.
- `swiftformal lsp`, a language server beside sourcekit-lsp (DX plan Phase 4, [editor guide](../docs/guides/editor.md)):
  on save it runs `swiftformal check --json` as a child process (killed with its whole process tree when a newer
  save supersedes it) and shows each verdict as a code lens (`✓ proved (debug, release asserts)`, `✓ cannot crash`,
  `✓ walked 12/12 (complete domain)`, `✗ counterexample`, `? unchecked: <reason>`, `⚠ stale`), a diagnostic with the
  document version, a hover, and code actions (replay a counterexample as a Swift Testing test, add a contract, a
  `Prove(it:over:)` skeleton), with `$/progress` while it runs. Every check records a generation and the hashes of
  its inputs; an edit or a reported file change turns the verdicts of its package and of the packages that read it
  stale at once, and a verdict is shown as proved only while its file has the text that was checked. Configuration:
  `swiftformal.json` or the client's settings (`checkOn`, `scan`, `tests`, `walks`, `budget`). New library target
  `SFLanguageServer`. `Editors/vscode` is a VS Code extension that starts it and shows the verdicts in the Test
  Explorer (from a `swiftformal/results` notification); the guide has a Neovim snippet. `check`, `verify` and
  `sfverify` are unchanged.
- A proof cache for Scan (plan items D4, S5, X6): `swiftformal check`, `swiftformal verify` and `sfverify --package`
  keep each checked answer in `<package>/.build/swiftformal/proofs` and reuse it while nothing it depends on changed.
  The key hashes the function's code and everything it can reach (callees, its paired `_requires`/`_ensures` and
  theirs, the witnesses its `witness_method`s and the encoder's comparing, hashing and printing lookups can call),
  the module's types, tables, globals and flags, the claim's declarations, the budget class, the build (compiler,
  SDK, target, frontend arguments, optimization, assert configuration, linked dependencies) and the tool itself (a
  new Scan-claim version and the UUIDs of the loaded images that hold the encoder, semantics, prover and Scan, read
  from memory; no UUID, no cache). Only an `LRATChecker`-checked proof and a counterexample that
  replayed are kept; a kept counterexample is replayed again before use, and caller-exclusivity, spec-shape checks,
  configuration merging, `--llvm-check` and `--paranoid` run as without the cache. Entries are read only from a
  directory of yours that no one else can change (nor any directory above it), as regular files of yours opened with
  `O_NOFOLLOW` and checked with `fstat` on the descriptor; anything else, or any I/O error, means proving as before. Loop proofs,
  `--modular` retries and `--gate` are not cached. New flags `--proof-cache <dir>` (relative to the current
  directory) and `--no-proof-cache`;
  `--cache-dir` keeps its meaning. The text report says how many answers came from the cache, and the scan JSON has
  a `proofCache` object and per-function `fromCache` (schema updated; `check --json` has `proofCache` per module).
  On a production iOS app, four modules: cold 122 s (base 118 s), warm 101 s with 2,596 of 2,707 claims from the cache, and a
  one-line edit proves 2 claims again; compiling and linking dominate what is left.
- `swiftformal check --xcode` (or `--format xcode`): the verdicts as compiler-format lines,
  `<file>:<line>:<col>: error|warning|note: [swiftformal] …`, for Xcode, VS Code's `$swiftc` matcher and CI logs. An
  `error` is exactly what fails the run (a broken contract, a walk's failing input, a walk that did not report; a trap
  only with `--strict`). A counterexample says it is concrete, with `note:` lines for the result, the replay call or
  the walk's `swift test --filter`, and the failing property; `undecided` says there is no proof and no
  counterexample, with its fix; an unsupported function notes the construct and the calls that lead there
  (`--show-unchecked`). The text and JSON output are unchanged. `sfverify --xcode`, the gate and `swiftformal verify`
  print through the same renderer.
- `--at <file>:<line>` and `--symbol <name>` for `sfverify` and `swiftformal check`: verify exactly one function, the
  innermost one whose body, declaration, attributes or doc comment hold that line, or the one with that name as
  reports print it (`Score.clamp(_:)`; `Type.member` with the same argument labels also matches). Several that fit, a
  contract function (`f_ensures`), or none is an error with exit 2, never "nothing to prove". The module is still
  compiled whole and every other function is kept as inventory, so contracts pair and walks link exactly as without
  a selector; only the other functions' proofs are skipped, and `check` runs only the walks linked to the selected
  function. A function the compiler writes at its type (a memberwise or inherited init) covers only the type's own
  line: a blank or comment line in a type is no function's. `--at` picks only in the files a module is compiled from
  (not where a `#sourceLocation` points); the selected function is verified in every assert configuration, and a
  module where nothing is selected is compiled once, its `configurations` naming only that build. The scan JSON has a
  `selection` object then (schema updated). Not with `--gate` or `--only`; `swiftformal verify` has no selector.
- `swiftformal check --json` keeps what each verdict holds under, additively (schemaVersion stays 1): a `modules`
  array with each module's optimization, assert `configurations`, `compiler`, `pinned`, `warnings` and `selection`,
  and per entry `category`, `detail`, `hint`, `at`, `calledFrom`, `moreTraps`, `proofScope` and `origin`, each absent
  when unset. `proofScope: "partialCorrectness"` (also in the scan JSON and its schema) marks a loop proof: it holds
  for every run that ends.
- `sfverify --emit-tests` (and `--confirm`) replays traps in methods, getters, static methods and initializers of
  structs and enums, not only free functions over scalars (app study round 6, L19: the app's one real trap was the getter
  `TabsStore.State.selectedTab`). `self` and the arguments are written as Swift: a struct through its
  memberwise initializer as the compiler printed it (a TCA `@ObservableState` property `x` stored as `_x` behind an
  init accessor is passed as `x:`; the macro's `_$observationRegistrar` keeps its initial value; this shape is
  tested on a hand-written fixture, not yet on the app), enum cases with payloads, optionals, numbers by their declared type
  (a `UInt8` of 200 is `200`), `Bool` and strings (stand-ins for texts that are none of the code's literals); a
  mutating method runs on a copy. A property the replay cannot write (an array, a `UUID`) is left to its default, and
  a `let` with an initial value to it, only when a proof (checked like every other) shows the function traps whatever
  they hold. The counterexample's `replay` is set for these members too (text report, SARIF, gate notes), and a new
  JSON field `noReplay` (additive; schema updated) says why a method has none: a private type, no memberwise
  initializer, a trap that may depend on a property a test cannot set, a broken contract of a method. `--confirm`
  checked on a fixture with a getter, a mutating method, an enum payload, a string and a static method: every test
  reproduces natively. The `--emit-tests` help line says so (CLI contract re-recorded for that text only).
- Prove: `SymbolicInt` converts between widths as Swift does: `SymbolicInt(x, width:)` (like `Int(x)` / `Int32(x)`:
  sign extension when wider, a recorded trap where a narrower value does not fit), `SymbolicInt(truncatingIfNeeded:
  x, width:)` and `SymbolicInt(zeroExtending: x, width:)` (like `Int(UInt32(bitPattern: x))`), never trapping.
  `min(_:_:)` and `max(_:_:)` take two `SymbolicInt`s or a `SymbolicInt` and an `Int`, and `SymbolicBool` has `==`
  and `!=`. Each is compared with native Swift on every 8-bit value (and every 16-bit value for narrowing). The prove
  guide shows them and advises running proof tests optimized (a 32-bit `%` proof took about 30 s in a debug test
  build). App study round 6 (L22) had modelled an `Int32` input as a 64-bit one with a range `requires`, and `min` with
  `then(_:else:)`.
- Scan reads `Optional.map` and `Optional.flatMap` with a closure literal of the same function (the most common shape
  in the app study's rules, `input.value.map { … }`, was `unsupported` as "closures"): the closure's body is inlined
  and runs, with its traps, exactly when the optional holds a value. The closure must not throw and may capture values
  but not a `var`. A non-escaping closure is no longer refused in a build where some `deinit` runs code: it is never
  destroyed (app study round 6, L11).
- Scan knows the elements of an array literal the code builds (up to 64 elements), while it is unchanged: `a[i]`,
  `first` and `last` on it are exact, also after it is returned, stored in a struct and passed to an `ensures`
  (`UnitDefaults.defaultUnits()`'s contract on its six rows was `undecided`). Each literal gets a count circuit of
  its own and its stored elements are recorded under it; a write through the subscript forgets them for every copy,
  and any count change makes a new array with unknown elements (KNOWN-ISSUES 8; app study round 6, L6: the
  `defaultUnits()` and `defaultTemperatureUnits()` contracts of AppSettings went from `undecided` to `holds`).
- Scan reads `static let` values and global `let`s of any readable type: the addressor's one-time initializer is
  encoded once per query and every read gets the value it stores (`Self.inputHelper` of a struct type made
  `ValuesState.changeAltitude(_:)` unsupported with "instruction: pointer_to_address"). An initializer
  that traps makes every read trap. `static var`, global `var`, and a global read during its own initialization stay
  `unsupported` (KNOWN-ISSUES 12; app study round 6, L13: no "pointer_to_address" is left in the three targets, 39
  functions before; `changeAltitude(_:)` now stops at `String.filter`).
- Scan reads `CGFloat` as the `Double` it wraps on 64-bit Apple platforms (it blocked 126 functions of a production iOS app
  as "type CGFloat"). Arithmetic, comparisons, conversions (`CGFloat(x)`, `Double(c)`, `CGFloat(n)` of an integer,
  `Float(c)`), `abs`, `min`, `max`, `magnitude` and `rounded()` use the exact float circuits, and a counterexample
  shows `CGFloat(1.5)`. The package-type compile probe must confirm that the bare name is CoreFoundation's `CGFloat`
  and that its `native` is a `Double` for the target; a module that declares its own `CGFloat` makes the name
  ambiguous, as before (app study round 6: "type CGFloat" no longer appears in AppSettings, AppUICore and
  AppFeature, 67 functions before; 18 stay unsupported behind `@ScaledMetric`/`@State` wrappers).
- Scan reads `==`, `!=` and `~=` on an enum with raw values (`enum Kind: String`), which `-Onone` code writes with
  the generic builtin `getEnumTag` and which made the function `unsupported` ("generic builtin getEnumTag"). The tag
  is the case index in declaration order, which is what logic keeps, for an enum without payload cases; an `@objc`
  enum (raw values in memory) and an enum with payloads stay `unsupported`. So `self == .us`, `result == .saved` and
  `Kind(rawValue: s) == .iron` are exact, in code and in contracts (app study round 6, L4: the 20 functions of
  AppSettings and AppFeature that stopped at "generic builtin getEnumTag" are read).
- The scan guide has a recipe for Kotlin Multiplatform and Tuist apps: build the app target for the simulator against
  a headers-only Kotlin framework (no Gradle, `ARCHS=arm64` when the framework has only an arm64 Swift module), let
  the final link fail, then `sfverify --build-log <DerivedData> --target <App> --scratch-path <DerivedData>
  --cache-dir <dir>`. KNOWN-ISSUES 13 says why functions over Kotlin types stay `unsupported` (app study round 6).
- `swiftformal check` says which `--scan` would link a walk it did not run: under "Not run", a `hint:` line names
  the `--scan <dir>:<Target>` whose sources declare the type, free function or extension member the walk's subject
  names (read from the `Package.swift` files and sources under the packages given, no build; targets already scanned
  are skipped), or gives a general hint; `scanHints` in `--json` (additive). On the app's FormalVerificationTests with
  AppFeature and AppEvents scanned it names AppCore for 8 walks, AppSettings for 2 and
  AppUICore for 1, in under a second (app study round 6).
- Scan counts plumbing apart from logic: `summary.plumbing` (JSON, omitted when 0) is the number of `unsupported`
  hand-written functions that stop at a property wrapper or injection type (`Injected<…>`, `Dependency<…>`,
  `Environment<…>`, `State<…>`, `Binding<…>`, `Store<…>`, Factory's `Container`, …), are the `body` of a view or
  reducer, or are a TCA `@ObservableState` setter; the text report adds "N of them plumbing (property wrappers,
  dependency injection, view bodies)". No verdict and no coverage number changes. On the app's main target: 579
  of 3,334 unsupported functions (app study round 6).
- Scan computes floating-point arithmetic (plan item R6-3). `+`, `-`, `*` and `/` on `Double`, `Float` and `Float16`
  are exact IEEE 754 (round to nearest even, subnormals, signed zeros, overflow to infinity, `x / 0` an infinity), and
  so are `rounded()` and `rounded(_:)` with every `FloatingPointRoundingRule` (now a readable enum, like
  `FloatingPointSign`), `Int(x)`, `Double(n)`, `Double(Float)`, `Float(Double)`, and the calls `-Onone` code makes for
  `abs`, `magnitude`, `bitPattern`, `Double(bitPattern:)` and `min`/`max` on floating point (summaries, pinned). Only
  the sign and payload of a NaN result are left open, so a trap that depends on them is `undecided`. The app's
  `Int((abs(x) * 10.0).rounded())` was `unsupported` and is now `may trap` with an input that traps natively
  (`--emit-tests --confirm` replays it; a NaN input other than `Double.nan` is replayed with its bits), its guarded
  forms (`isFinite` and `|x| < 1000`) are `safe`, and `x * 2.0 > x` is refuted. `squareRoot()`,
  `truncatingRemainder` and fused multiply-add still give unknown results; `CGFloat` stays unsupported. Semantics
  version 21.
- Scan reads more about text (Scan semantics 23). A `String` raw-value enum's `init(rawValue:)` is read: the compiler's
  `_findStringSwitchCase(cases:string:)` is summarized with the case texts of the call, so these initializers are no
  longer `unsupported` (143 functions of the app's packages stopped there; on four of those targets all 78 are now
  `safe`). `lowercased()` and `uppercased()` of a
  string Scan does not know are the converted literal whenever the string is one of the code's ASCII literals, also one
  met later, so `switch input?.lowercased() { case "home": .app … }` meets `input != "home" || result == .app`.
  The text of an integer (interpolation, `String(n)`, `String(describing: n)`, `n.description`) is its decimal form:
  `"\(n)" == "18"` exactly when `n == 18`, never `"F"`, `"007"` or `"-0"`, so a rule that prints `"F"` or a number
  is checked exactly, and a broken one is refuted with its input. Two unknown strings, a non-ASCII case conversion
  and text mixing literals with numbers stay unknown (`undecided`, never `safe`).
- Scan reads `UUID`, `URL`, `Locale`, `Date` and SwiftUI `Color` as opaque identities. One such stored property used to
  make every accessor and the synthesized `==` and `hash(into:)` of its struct `unsupported` (`type UUID`, `type URL`,
  `type Color` were the top reasons on a 19-target SwiftUI/TCA app). Holding, copying, storing and destroying them is
  read, and so are `==`, hashing, `description` and a short list of calls (`UUID()`, `uuidString`, `URL(string:)`,
  `absoluteString`, `Locale.current`, `identifier`, `Date()`, `timeIntervalSince1970`, the standard colours, ...); any
  other call on them stays `unsupported`, and the reason lists what is read. A `UUID` equals another exactly when it is
  the same value, a copy of a `URL` or `Locale` equals itself, and `Date.==` and `Color.==` are unknown (a NaN date is
  not equal to itself); values a call makes are unknown, so two `UUID()` calls are neither equal nor different. A
  contract such as `id_ensures(_ result: UUID) -> Bool { result == id }` is proved (contracts now pair with functions
  whose parameters or result are address-only), and counterexamples show stand-ins (`id: <UUID 1>`). A name is used
  only after the compiler probe confirms it means Foundation's or SwiftUI's type and no read module declares it. On
  the app's `AppEvents` (862 functions): 340 → 369 `safe`, and `type URL` (110), `type Color` (65),
  `type UUID` (10) and `type Locale` (9) are gone from the `unsupported` reasons. Semantics version 24.
- `sfverify --mutate` and `swiftformal check --mutate`: is a proved contract strong enough? Each contract that holds
  (with an `ensures`, on a function without loops) is checked again on up to 16 small edits of its function, made in
  the SIL without recompiling: skip a call that changes `self`, drop a write to a field of `self`, return a parameter
  or a constant instead, negate a branch, swap two cases of a `switch`, change an operator or a constant. An edit that still satisfies the contract
  and changes the outcome on some input meeting `requires` marks the contract weak, with the edit, its position and
  that input (`weak: the contract still holds when the call to State.show(_:) is skipped`). Edits proved to behave
  like the function are not reported; a difference that depends on unmodelled results (`String(_:)`) is reported as
  `may differ`. The app's `discardEdit` contract, which said nothing about the loaded case, is the motivating case. No
  verdict, exit code or output changes without the flag. JSON: `weakContract` per function and
  `summary.weakContracts`, both optional (schema version stays 1).
- `--cross-check llvm` reads app code (round 6, item 6). The IR reader follows `-Onone` stack memory byte by byte, reads
  `switch`, `insertvalue`/`extractvalue`, pointers as opaque values and the reference-counting runtime, and a new
  bridge ties SIL's view of a signature to the IR's through Swift's memory layout: structs passed in pieces or by
  reference, `sret` results, enums without payloads, `Optional` (of integers, enums, `Bool`, strings, closures and
  arrays), multi-payload enums with a tag byte, strings and closures as two words. On the AppFeature app target the
  cross-check went from 9 `agrees` and 867 `unread` to 218 `agrees`, 658 `unread`, no `disagrees`. Each `unread` now
  says why in the new JSON field `crossCheckReason` (schema: additive). Still `unread`: results written through an
  address (`inout`, setters, `@out`), existentials, enums that keep their tag in spare bits, calls into the standard
  library. What an `agrees` rests on is in `docs/TRUST.md`.
- Loops that the invariant proof cannot decide get two more tries (plan item L3). A function with one loop and no
  `ensures` is proved by 2-induction when it can be: loops whose exit test comes after the body (`repeat { i += 1 }
  while i < 100 && i < n`) are now `safe`. Otherwise Scan unrolls the loops for up to 8 loop-header visits (`sfverify
  --unwind N`, `0` turns it off) looking for an input that traps: such a trap is real and is reported as `may trap`
  with the input, where it was `undecided` (a loop that overflows on its third iteration is refuted with its `n`).
  None found within the bound proves nothing and stays `undecided`.
- Scan reads Objective-C objects as opaque references (plan item R6-1), which is what a Kotlin Multiplatform app's
  Swift code holds: a class or protocol the compiler imports from Objective-C can be held, passed, stored in a struct,
  released and compared with `===`, and a getter, setter or method of it returns any value of its declared type
  (nullability from the header; `String` bridged from `NSString`). `struct R { let input: GKTDomainX; var body: Int {
  Int(input.count) } }` is `safe`; `[1, 2, 3][Int(input.index)]` is `may trap`, and the counterexample says what the
  foreign object returned (`input.index returned -2147483648`; `foreignResults` in the JSON, no replay). Assumed
  (TRUST.md): foreign code returns normally, calls back into none of your code, and releasing a foreign object runs no
  code of yours that traps. A type a class of your modules subclasses or conforms to, member names your modules
  implement for Objective-C, creating objects, casts, blocks, printing and `==` (`isEqual:`: Kotlin enums, sealed and
  data classes) stay `unsupported` with the reason. `AnyObject` values are now read the same way (held, passed,
  `===`), in a build where no `deinit` of your modules runs code. Semantics version 22 (21 is the floating-point arithmetic).
- Scan reads simple classes (plan item L5): a `final class` with no superclass, no protocol conformance and stored
  properties Scan reads is read as those properties, with one reference per object. A function that creates such
  objects, calls their methods and returns them can be `safe` (`let c = Counter(); c.count = n; c.bump()` is refuted
  with `n = 127`), and an initializer or function that returns its parameter returns the same object. A function
  that takes an object, a method's `self` included, is never `safe`: each property access is checked at run time
  against other open accesses, and a caller may hold one, so a proof there is `undecided` ("exclusivity"); a trap is
  still `may trap`. Every other way to get a second reference is `unsupported`. `@Observable` and `ObservableObject`
  classes stay `unsupported`. Semantics version 20.
- `Table([...])` and `Property.table(_:)` for `Hashable` inputs find each input's row by hashing: a table of 8,192 rows is checked in 3 ms instead of about 9 s, with the same report (the first row of a repeated input counts, as before).
- `sfverify --modular`: what is `undecided`, or refused as a call chain deeper than Scan inlines, is proved again with
  the contract of each callee proved in the same run standing for its code (assume-guarantee): the call must satisfy
  `g_requires`, its result is any value satisfying `g_ensures`. Only proofs are kept, and they list the contracts used
  (`usesContracts`); every other verdict is the inlined one. A 12-deep chain of contracted functions, refused
  without it, is proved; a weak callee contract, a caller that really traps and a call that breaks `requires` stay
  unproved. See [Contracts at call sites](../docs/guides/scan.md).
- Contributors: the oracle lane checks the SIL reader's inferred value types against the compiler's own
  (`-Xllvm -sil-print-types`, `OperandTypeOracleTests`; 529 values on the examples and a fixture, 0 mismatches).
- Scan reads `Dictionary` and `Set` values (plan item L2). Like arrays, only their count is modelled: `count` and
  `isEmpty` are exact, a lookup in an empty dictionary is `nil`, and `subscript` set, `updateValue`, `removeValue`,
  `Set.insert`, `Set.remove`, `contains`, `removeAll`, `==`, literals, `Dictionary()`, `Set()` and
  `Dictionary(uniqueKeysWithValues:)` of an array change the count by exactly what their results say. Hashing and
  comparing keys runs your types' `hash(into:)` and `==`. Two equal keys in a dictionary literal or in
  `uniqueKeysWithValues:` trap: found exactly when the keys are integers, `Bool`s or values of your types computed
  in the function (`[x: 1, 0: 2]` is refuted with `x = 0`), `undecided` otherwise; inserting a key of your own type
  next to another is `undecided`, since its `hash(into:)` and `==` may disagree. Other members (`keys`, `values`,
  iteration, `subscript(_:default:)`, `merge`, `filter`, ...) stay `unsupported`. Semantics version 16.
- Scan reads `for-in` loops at `-Onone` (plan item L4): over `a..<b` and `a...b` of any standard integer type, an
  array, `enumerated()` and `indices` of an array, and `stride(from:to:by:)`/`stride(from:through:by:)` over `Int`.
  The compiler turns them into generic `makeIterator()`/`next()` calls into the standard library; these now have
  exact summaries written from its 6.4 source, including its traps (`lowerBound <= upperBound`, a zero stride, a
  checked `+ 1`) and its care at the top of a `ClosedRange` and at the end of `Int` in a stride. The loop then goes
  through the `while`-loop proof, with the iterator's well-formedness as a checked candidate invariant: a loop that
  cannot trap is `safe` (termination not proved), one that may trap is `undecided`. Array elements stay unknown.
  Other sequences (strings, dictionaries, your own `Sequence` types) stay `unsupported`. Semantics version 19.
- Scan reads calls to your own generic functions (plan item L7). At `-Onone` the compiler does not specialize, so
  `clamp(x, 0, 9)` calls `clamp<T: Comparable>` with `T = Int8`; Scan now reads that body at `Int8`, at each call,
  and resolves `witness_method` for the concrete type through your module's witness tables (protocol extension
  defaults included) or, for `==`, `<`, `<=`, `>`, `>=` of a standard integer type, as the exact comparison. A trap
  in the generic body or in the witness it calls is found through the call. The generic function itself is still
  `unsupported`: it is never proved "for all T". Refused, with the reason: conditional conformances (and every
  conformance of a generic type), existential, class or non-concrete substitutions, associated types (`T.Element`),
  generic witnesses, other standard-library protocols (`BinaryInteger` arithmetic, `ExpressibleByIntegerLiteral`), a
  type parameter named like a declared type, and generic functions of the standard library. Semantics version 17.
- `sfverify --cross-check llvm`: each proved function is compared with the meaning of its LLVM IR, read by the
  second, separately written encoder (`SFLLVM`); the report says `agrees`, `disagrees`, `unread` or `undecided`
  (`crossCheck` in the JSON). `--cross-check llvm-strict` keeps only the proofs both encoders agree on.
- Scan reads functions with `while` and `repeat` loops. Each loop is cut at its header, where the values it changes
  are unknown and the values from before it stay exact; a proof then holds for every run that ends (termination is
  not proved, and the report says so). A loop it cannot prove this way is `undecided`, not `mayTrap`. Loops inside
  a called function and `for-in` loops stay `unsupported`. Semantics version 15.
- Scan reads throwing functions: `throw` (with `any Error` or a typed error), `try`, `try?` and `do`/`catch` between
  your functions. Throwing is not a trap: a function that throws on bad input and cannot trap is `safe`, and its
  `_ensures` is checked on normal returns only. A trap behind a `try` is found through it (`(try? parse(x)) ?? 0`).
  Throwing calls into the standard library, `rethrows` closures and `inout` arguments of a throwing call stay
  `unsupported`. Semantics version 14.
- Scan reads `hashValue` (the getters Swift synthesizes, and any call to it): it runs the type's own `hash(into:)`,
  so a trap there is found and a safe one proved. They were `unsupported` ("generic call to `_hashValue`").
- A release process for a prebuilt `sfverify` (U14): `Scripts/release-artifactbundle.sh <version>` builds a universal
  release `sfverify` as a SwiftPM artifact bundle (`info.json`, the binary, `LICENSE`) with its SHA-256, checks that it
  links only system libraries and that the build is path-independent (two folders, same SHA-256: verified), and
  `.github/workflows/release.yml` runs it on version tags, rebuilds in a second folder and compares, and keeps the zip
  as a workflow artifact (nothing is published). Not yet wired into `Package.swift`: a binary target needs a published
  URL, so it would break every build before the first release. A gate with the prebuilt tool took 1.2 s instead of
  3.8 s with the debug one. See [RELEASING](../docs/RELEASING.md#the-prebuilt-swiftformal) and the
  [Gate guide](../docs/guides/gate.md).
- An oracle-lane test (K8) compares Scan's import discovery with the compiler's dependency scanner
  (`swiftc -scan-dependencies`) on every import spelling (`public`/`internal`/`package import`, `@preconcurrency`,
  `@_implementationOnly`, `import class M.T`). It fails when an import is missed, the class of bug that made Scan
  ignore attributed imports (C1).
- Scan for Xcode and Tuist app targets (K6): `sfverify --build-log` also reads `xcodebuild` output, an
  `.xcactivitylog` (Xcode's own gzip-compressed log) or a DerivedData folder (its newest activity log that compiled the
  module), and takes the target's exact compiler flags from it. With DerivedData, the modules the target imports from
  the same build are linked. See the [Scan guide](../docs/guides/scan.md#xcode-and-tuist-app-targets---build-log-on-xcodes-logs).
- `swift package scan [--target T] [-- sfverify options]` (K5): a second plugin product, `SwiftFormalScan`, that
  scans a target on the package's own build. It builds the target with a verbose log and hands the log to
  `sfverify --build-log`, so there is no second build tree (`--build` keeps one in `.build/sfverify`). New `sfverify`
  options `--build-log <file>`, `--scratch-path <dir>` (also for `--build`) and `--cache-dir <dir>`. On a build that
  compiled nothing, the command saved for the same build description is used; without one the scan stops and says
  which file to touch. See the [Scan guide](../docs/guides/scan.md#on-your-own-build---build-log). CLI contract:
  help text and three new rows.
- Scan reads floating point (`Double`, `Float`). A value is its IEEE 754 bit pattern: comparisons, `isNaN`,
  `isFinite` and the other classifications, sign operations and bit casts are exact, and so is the check that
  `Int(x)` fits, so a conversion that can trap is found with a real input (`toInt(-2.68e154)`) and a guarded one is
  proved. Arithmetic and rounding give unknown results: a trap that depends on one is `undecided`. Floating-point
  functions were all `unsupported`. Semantics version 12.
- Scan reads bit counting and byte order (`leadingZeroBitCount`, `trailingZeroBitCount`, `nonzeroBitCount`,
  `byteSwapped`), `assumeNonNegative` and the plain integer casts the compiler emits (`trunc`, `zext`, `sext`); they were
  `unsupported`. Each is checked against Swift's own API and the compiler's builtin in the tests. Semantics version 18.
- Concrete playback for Scan (U5): `sfverify --emit-tests <dir>` writes one Swift Testing test per counterexample of
  a free function over integers and `Bool` (an exit test `#expect(processExitsWith: .failure) { _ = f(args) }` for a
  trap, `#expect(!f_ensures(args, f(args)))` for a broken postcondition), which passes while the counterexample
  reproduces. `--confirm` (opt-in; it builds and runs your code) runs them in a scratch package and sets
  `counterexample.confirmed`; a counterexample that does not reproduce natively makes the function an
  `internalError` (a model/compiler disagreement). New optional JSON keys `ensuresCall` and `confirmed`; schema
  updated. CLI contract: rows for the new flags.
- `swiftformal doctor [--package <dir>]` (U9): checks the compiler against the pin, a debug-built `sfverify`, exit-test
  availability (Swift 6.3 or newer, not iOS) and, in a package, the gate wiring (plugin applied, `// sf:verify`
  markers, imports the gate cannot compile, a stamp copied into a resource bundle). Each problem comes with a fix;
  exit 0 when all checks pass, 1 otherwise. CLI contract: new `swiftformal` rows (help and usage errors only, since a
  real run depends on the machine).
- `sfverify --format sarif` (SARIF 2.1.0, for GitHub code scanning and SARIF viewers) and `--format github` (GitHub
  Actions `::error`/`::warning` annotations), printed from the same findings as `--xcode` (U8). `--format text|json|xcode`
  are the existing outputs. See [Scan](../docs/guides/scan.md#in-ci-sarif-and-github-annotations). CLI contract: new rows
  for `--format`, and the help text.
- Scan explains `unsupported` and `undecided` (U7). An unsupported function gets `at` (where the construct is, from
  the instruction's debug info), `calledFrom` (the calls that lead there when it is in a callee, as the compiler's
  "called from here" notes) and `hint` (what to change), in the JSON, in `--show-unsupported` and, with
  `--xcode --show-unsupported`, as `note:` lines. An undecided function gets `category` `budget` or `unmodelled
  results` and a `hint`; the summary says `Undecided: N` split by reason instead of filing every one under
  "Undecided (budget)". The gate's messages for these carry the same notes. Additive JSON keys; schema updated.
  The `--show-unsupported` help text says so (CLI contract re-recorded for the help rows only).
- `verify(_:_:over:budget:parallelism:properties:assuming:)`: the function is evaluated on several threads (`.threads(8)`), with the same report as the serial `verify`. For functions of a microsecond or more: 200,000 inputs of a 1 µs function take 46 ms on 14 cores instead of 211 ms. The function must be `@Sendable`. See the [Walk guide](../docs/guides/walk.md).
- Contributors: the mutation lane, `Scripts/mutation-lane.py` (nightly): 14 mutants of S0, the encoder's trap and
  undefined-behaviour plumbing and the literal parser must each be killed by their tests (fastest first, stopping at
  the first failure); sources are restored after each mutant, also on Ctrl-C. 14 of 14 killed in about 5 minutes
  (debug). It found one gap: a `cond_fail` that can never fire before `unreachable` was not covered by a test
  (`SILFailureBlockTests` now does). `--check` runs in the safety net.
- Contributors: the compiler-corpus lane, `Scripts/corpus-lane.py` (nightly): Scan on the 730 `.swift` tests of the
  pinned compiler's `test/SIL` and `test/SILOptimizer`, fetched by commit SHA, against `Scripts/baseline/corpus.json`.
  It fails on a crash, a hang, a new `INVALID SIL` on compiler output, or a verdict flip. First run: 370 files compile,
  4,385 functions (1,108 safe, 73 may trap, 1 undecided, 3,203 unsupported), 0 crashes; 10 functions in 4 files are
  still `INVALID SIL` (destroyed noncopyable values, several `@out` results, `copy_addr` between types) and are listed
  as known.
- Contributors: `Scripts/check-summary-pin.py` pins the standard-library code behind every Scan summary: the probe
  `tools/summary-probe/probe.swift` is compiled with `-O` and the bodies linked by the performance linker are
  hashed (43 summarized functions with a body, 128 bodies in their call closures; 9 pinned by their declaration)
  into `Scripts/baseline/stdlib-summaries.json`, keyed to compiler, SDK and target. Runs in the safety net and nightly;
  `--update` dumps the changed code for review.
- Contributors: the SIL parser fuzzer also damages 9 seeds of real `-emit-sil -Onone` output, made from this
  repository's `Examples/` by `Scripts/make-fuzz-seeds.py` (2 hand-written seeds before); about 4 s in the fast lane.
- Contributors: the oracle lane checks S0 against the compiler's constant folder (`S0FolderOracleTests`): every
  builtin, casts included, at 8, 16, 32 and 64 bits on literal operands; folded values must equal S0's, and the folder
  must diagnose a case exactly when S0 calls it undefined. 17,124 sampled cases by default, 60,924 with
  `SF_FOLDER_ORACLE=full` (nightly); 0 mismatches on the pinned compiler.
- Scan checks the `[_semantics "…"]` tags the compiler prints on each summarized standard-library call against the
  tags its summary row expects; any other tag refuses the call (`unsupported`, never a new behaviour). The oracle lane
  checks the table against `tools/summary-probe/probe.swift`, which calls every summarized function.
- `sfverify --paranoid`: the compiler also verifies its own SIL after every pass (`-sil-verify-all`; compiles take
  40 to 75 % longer). It checks the compiler, not sfverify's reader.
- `partition(_:over:limit:)` for `Hashable` outputs: the same groups in the same order, found by hashing (100 000 inputs with 20 000 outputs: seconds become milliseconds).
- Contributors: `Scripts/test-lane.sh slow-dev` runs the slow lane in a debug build with the engine modules optimized (about 40 s of tests instead of 10+ minutes); `Scripts/check-cli.py` (the command-line contract) and `Scripts/check-portability.py` (no `unsafeFlags` for consumers, no CLI linking `libswiftCompatibilitySpan.dylib`) run in the safety net and CI.
- `swiftformal check`: one command, logic first. It proves every `--scan` target with Scan, then runs only the walks
  (`expectProved("Type.member…", …)`) that cover a function logic did not prove, and merges both into one verdict per
  function. `swiftformal scan` and `swiftformal gen` forward to `sfverify` and `sfgen`.
- `swiftformal verify`: the build-time check. It proves every `@Verify`, `// sf:verify` and `_requires`/`_ensures`
  promise in a package, in the package's own `.build`, and prints `file:line:col` errors (broken, with the input)
  and warnings (not proved by logic, so only a test can check it). From an Xcode Run Script phase, ⌘B fails on a broken
  promise; CI runs the same command. Targets that have not changed are skipped. See the [Gate guide](../docs/guides/gate.md).
- `@Verify` on `mutating` methods: each `#ensures` closure also gets `self` from before the call
  (`#ensures { result, old in … }`, or `#ensures { old in … }` for a method that returns nothing). It writes
  `<name>_ensures(…, old: Self)` for Scan, which proves the contract for every `self`. Such a method has no walk.
- `Prove(it:over:) { … }` in `SwiftFormalTesting`: a walk written like a SwiftUI view. The properties are types,
  one per line, with their types inferred from `it:` and `over:`: `Deterministic()`, `Table([...])`, `Matches(oracle)`,
  `Satisfies("name") { input, output in … }`, `Injective()`, `Outputs(within:)`, `Outputs(exactly:)`,
  `RoundTrip(through:)`. Conform to `PropertyConvertible` to name your own. `swiftformal check` links the walk to the
  function its `it:` closure calls (`{ SurfaceTextRule(input: $0).execute() }` → `SurfaceTextRule.execute`). See the
  [Walk guide](../docs/guides/walk.md).
- `swiftformal check` links a walk over a member of its input without a subject string: `{ $0.label }`,
  `{ surface in surface.label }`, `\Surface.label`. The test records its input type in the walk log (`inputType`), and `check`
  links the walk to `Surface.label` with it. A walk that does not report covers every `label` it might, so it shows as
  missing; a type with no scanned `label` is listed as not linked.
- Scan reads text. Each ASCII string literal is a known string and every other string is equal only to itself, so
  `==`, `isEmpty` are exact on every string and `count`, `+`, `+=`, `<`, `hasPrefix`, `hasSuffix`, `lowercased()`,
  `uppercased()` are exact on the texts of your code. Contracts about text are proved or broken instead of
  `undecided`, and counterexamples show the text: `surface = .rough`, `returns: ""`; strings that are none of the code's
  literals appear as `"a"`, `"b"`, …, and the `replay:` call reproduces the failure. Non-ASCII literals, and the length
  or order of strings that are not literals, stay unknown.
- `expectProved` appends one JSON line per call to the file named by `SWIFTFORMAL_WALK_LOG`, when it is set.
- Walk survives a trap on macOS and Linux: `walkInExitTest` runs a walk inside a Swift Testing exit test
  (`#expect(processExitsWith: .failure, observing: [\.standardErrorContent])`). A trap ends only the child, which writes
  the step it was on from a signal handler; `TrapWalk` maps the step back to the input (enumerated or sampled), and
  `callAloneInExitTest` confirms it by calling the function alone on that input. Outcomes: walked, trapped on an input,
  trapped while checking (a property or `#requires`), input unknown, unexpected exit; only a clean walk can pass, and
  none is `proved` or `bounded`. About 0.1 s for 65,536 inputs with the confirmation. Not on iOS (no exit tests there):
  the API is compiled out, as it is with a compiler older than Swift 6.3 (exit tests and their capture lists). New:
  `walkInExitTest`, `callAloneInExitTest`, `TrapWalk`, `WalkStep`, `AloneCall`.
- Swift Testing at the macOS 13 floor: `expectProved` with `allowBounded: true` records a `bounded` verdict as a
  warning-severity issue (it was silent), and attaches a report that is not a proof as text and as its JSON line. The
  `.swiftFormal(budget:allowBounded:)` trait (`WalkDefaultsTrait`) sets the default budget and `allowBounded` for a
  suite or a test, through the task-local `WalkDefaults`; an argument written at the call wins. Warnings need Swift 6.3,
  attachments 6.2 and the trait 6.1; an older compiler keeps the old behaviour (silent bounded, no attachments).
- Scan understands more of Swift, so it proves more real functions:
  - enums (with and without payloads), `Optional`, `switch` and `if case` over them;
  - `String` and `Hasher` values: logic follows them through the code but does not know their contents. Standard
    library calls on them (`==`, `isEmpty`, `count`, `hash(into:)`, `description` and others in
    `Sources/SFSIL/SILSummaries.swift`) are assumed not to trap and to return an unknown result;
  - `inout` parameters, and arguments and results passed by address (`@in`, `@out`);
  - calls of your own code through a protocol witness (`description`, `hash(into:)`), and generic standard library
    calls whose type is known;
  - `min(_:_:)` and `max(_:_:)` on standard integers, exactly;
  - ranges of standard integers: `Range`, `ClosedRange`, `PartialRangeFrom`, `PartialRangeThrough` and
    `PartialRangeUpTo` values, `contains`, `~=` (so `switch` cases such as `case 10...hi:` and `case ..<0:`), `isEmpty`
    and `Array.indices`, exactly. Before, any range made a function unsupported, so the idiomatic bounds check
    `a.indices.contains(i) ? a[i] : x` could not be proved while `i >= 0 && i < a.count ? a[i] : x` could. A range
    parameter is known to have `lowerBound <= upperBound`. The category "for-in over ranges and sequences" is now
    "for-in loops" (loops are still not read) and "ranges of non-integer bounds";
  - arrays, in `-Onone` builds: literals, `allCases`, `count`, `isEmpty`, `a[i]` (read and write), `first`, `last`,
    `append`, `+`, `+=`, `insert(_:at:)`, `remove(at:)`, `removeLast()`, `popLast()`, `removeAll()`,
    `Array(repeating:count:)`, `contains`, `firstIndex(of:)` and `==`. Logic knows the count exactly, so an index out of
    range or `removeLast()` on an empty array is found with a concrete input, and a guarded `a[i]` is proved. It does not
    know the elements: a trap that depends on an element value is `undecided`. Arrays of classes are refused (destroying
    them may run your code); arrays of closures and existentials follow the closure rule below. `for x in array`, `map` and `filter` are not read yet;
  - closures as values: a struct with a closure field (`var validator: (String) -> [String]`, `var onTap: (() -> Void)?`,
    a TCA-style client) can be created, read, copied, passed and changed, so its getters, setters, initializers and the
    functions that use it are read. Logic never runs a closure: calling one stays `unsupported`. Destroying a closure
    may run the `deinit` of something it captured, so closures are refused in a build where a `deinit` of a read
    module traps, writes memory, or calls a function (other than a few reviewed ones such as `Task.cancel()`);
  - The Composable Architecture's `@ObservableState` (TCA 1.26): the getters of a state struct, its initializers, its
    `_x` storage, `_$id`, `_$willModify()` and the computed properties built on them. A key path without captured values
    (`\.count`) is an opaque value. SIL prints `ObservationStateRegistrar` without its module, so before using it Scan
    asks the compiler to confirm that, with your imports, the name means TCA's type and nothing else. State setters
    (`mutate`, which runs your `==` through closures) are still `unsupported`;
  - existentials as values: a struct with an `any P` field (`let tracker: any AnalyticsManager`) can be created, read,
    copied, passed and changed, and `any P` parameters and results are read. Logic never looks inside one: calling a
    requirement (`tracker.track(…)`), casting it (`as?`) and boxing a concrete value into one stay `unsupported`.
    Existentials follow the closure rule for `deinit`s. `Any`, `AnyObject` and throwing functions are not read yet;
  - your generic structs and enums used at a concrete type (`LoadingState<Int>`), and enum cases with one labeled
    payload (`case failed(code: Int)`);
  - other modules of the same build. `sfverify --build` and `swiftformal check` compile the SIL of every imported
    target of your package or of a local path dependency (not SDK modules, not remote packages) and link it in, so
    their types, conformances and function bodies are known. Only the scanned target's functions are reported.
- Scan never reports a bug that depends on a value it does not know. When a trap happens only for some results of an
  unknown call (for example only when two strings are equal), the verdict is `undecided` and the detail names the calls.
  A trap that happens whatever those calls return is still `mayTrap`.
- Scan proves contracts, not only "cannot trap". It checks them on the compiled function for every input:
  - `@Verify` writes `<name>_requires` and `<name>_ensures` next to your function and compiles `#requires` and `#ensures` into plain
    checks in the body, so the contract you walk over a domain is also proved by `sfverify` and `swiftformal check --scan` for all inputs.
    A broken contract comes with a concrete input;
  - contracts for `mutating` methods: `<name>_ensures(…, old: Self) -> Bool`, where `self` is the value after the call and `old` the value before;
  - contracts for computed properties: `<name>_requires()` and `<name>_ensures(_ result:)` pair with the getter;
  - logic knows a string is equal to itself, so "this text did not change" can be proved; equality of two different strings stays unknown.
  `swiftformal check` reports them as "proved (N contracts hold, M cannot crash)".
- `sfgen generate --max-inputs N` (default 500): the most inputs one generated check runs per Rule. The generated check prints `SFGEN-BEGIN` before it builds the domain, so a crash names its Rule. See the [Generate guide](../docs/guides/generate.md).

### Changed

- The README is rewritten short: what SwiftFormal is, why you need it, how it works, a four-step quick start
  with `@Verify` and `swiftformal verify`, and where it fits. The details stay in the guides.
- `swiftformal verify`'s stamps cover everything a check reads: a target that passed is skipped only while its
  files and arguments, every module, header and macro plugin they name, the local modules it links (and theirs), the
  manifests, the compiler, SDK, tool (image UUIDs) and flags are unchanged; the old stamp hashed the target's own
  files only and missed a dependency that started to trap. The stamp is checked after the null build that plans the
  target, written only if nothing changed while the check ran, and read and written like proof cache entries.
  `--force` checks every target; `--no-proof-cache` neither reads nor writes stamps. Review fixes: the target is
  hashed before its promises are read, and they are read from the bytes hashed (a promise saved between the two was
  left out of a check that was then stamped); a file's `stat` (inode, size, times in ns) must not change while the
  check runs, so an edit undone during it is not stamped; and the stamp hashes every file the compiler said it read
  (`-emit-dependencies-path`), so a C header no argument names (`#include "../limits.h"`) is a change (stamp format
  2; older stamps are ignored). A file is read into memory and hashed between its two `stat`s (it was mapped, so a
  write in place after the second one could reach the digest).
- Planning a local module a target links (`swiftformal verify`, `swiftformal check` and `sfverify --package
  --build`) no longer runs a `swift build` of that module when the target's build compiled nothing: its
  command comes from Swift Build's plan of the target's build description (`task-store.msgpack`), byte for byte the
  command its own build would use. The command saved by the module's own build carried that build's description, so
  it never matched after the target's build, and each module was built again, about 3 s each, on every run. On
  a production app's AppFeature (six local modules) an unchanged `swiftformal verify` takes 4 s instead of 21–52 s, an edit
  15 s instead of 74 s, and the full `check` 54 s instead of 75 s, with the same verdicts. A plan that cannot be read,
  or with two different commands for a module, gives no command and the module is built as before. The plan is read
  only for the build the run has just run itself, while no build with another description has run in `.build` since,
  and a module's command only from a plan that holds the target's exact command; `sfverify --build-log` never reads it
  (the log may come from another build: Xcode's, a release build, another platform). Stamps are kept
  per tool, so two builds of swiftformal on one package no longer overwrite each other's.
- `sfverify --xcode` prints column 1, not 0, for a finding whose location has no column, as the gate and `swiftformal
  verify` already did.
- `@Verify` compiles the checks it writes into the body only where `DEBUG` is defined (app study round 6, L23): the
  `#requires` and `#ensures` checks and the copy of `self` that a `mutating` method's `#ensures { result, old in … }`
  reads are inside `#if DEBUG`, so a release build runs the function as written. Before, a release build made the
  copy and ran every check, and only the `assertionFailure` was gone. What stays in every configuration:
  `<name>_requires` and `<name>_ensures` (Scan's verdicts, at `-Onone` and `-O`, are unchanged; a broken contract
  scanned without `DEBUG` reads `ensures is false: …_ensures …` instead of `ensures failed: …`) and `verify_<name>()`,
  which now checks each `#ensures` on the result itself: without that, a walk in a release test build would have
  reported a broken contract as proved. `@Verify(checks: .always)` and `@Verify(over:checks:)` keep the checks in every
  build (new `ContractChecks`: `.debugOnly`, the default, and `.always`); any other `checks:` expression is a
  compile error, because the macro reads the choice from the source.
- `@Verify` accepts a body of one expression after `#requires` lines without `return` (app study round 6, L21), as it
  already did after `#ensures`: `switch`, `if` and plain expressions are the function's value. The walk guide says
  where a `// swiftlint:disable:next` goes once an attribute stands above `func` (between the attribute and `func`):
  SwiftLint reads the source, so the macro cannot move it.
- Contributors: the SIL reader's functions throw `SILError` and nothing else (`throws(SILError)`, plan item H9), from
  `SILModule(text:)` and `SILModule.function` down to each instruction; the parser fuzz test now checks it at compile
  time. Internal API only (ADR 0007: no typed throws in the public API).
- Contributors: the encoder's 1,200-line `SILEncoder.run` is now `FunctionRun` (plan item H1): one object per
  encoded function holding its values, cells and events, with one exhaustive `switch` over `Instruction` in
  `execute` and a method per instruction in the file of its family (`SILRunValues`, `SILRunMemory`, `SILRunArrays`,
  `SILRunCalls`, `SILRunSummaries`). Formulas are byte-identical: a new test pins the CNF of 2,488 fixture functions
  (every SIL suite's fixtures, an Objective-C one and one for arms no fixture reached) next to the earlier hash tests.
- Scan parses each SIL function once per module instead of about four times (the verifier, the loop planner, the
  closure walk and the counterexample replay each parsed it again; plan item S7). On 2,014 generated functions:
  verify 0.83 s to 0.62 s, CPU 11.6 s to 8.7 s (release, best of 3 each). A change to the module, such as linking
  another, starts a fresh cache.
- Scan no longer encodes a function without loops a second time to look for loops (next-level plan item R2): on the
  generated module of 8,192 functions, CPU 53.6 s to 50.0 s, with the same report.
- The SAT solver gets only the clauses the claim depends on (next-level plan item S1): most of what the encoder builds
  for a function (results, flags and branches the claim never reads) no longer reaches the solver. The solver's proof
  is renumbered and its model completed for the whole formula, and both are checked against the whole formula as
  before, so `SFCheck` and the trust base are unchanged. On the generated module of 8,192 functions: CPU 50.0 s to
  36.8 s, wall 8.4 s to 7.5 s, with the same report, solver conflicts included. `cnfClauses` still counts the whole
  formula. `Examples/Metrics` at the default budget: 108.5 s to 77.2 s.
- A formula the solver already answered in this run, at a cost of 2,000 conflicts or more (or by running out of
  budget), is not solved again (next-level plan item S3): an `undecided` function no longer spends its budget a second
  time when the release build is checked. The formula must be equal clause for clause, with the same inputs and
  budget, and the answer is the one solving again would give. `Examples/Metrics` at the default budget: 77.2 s to
  38.7 s, with the same report.
- The proof checker (`SFCheck`) reads a clause of the formula when the proof first names it, instead of storing every
  clause first (next-level plan item S2): checking costs what the proof needs, not the size of the formula. It accepts
  and rejects the same proofs with the same errors, except that an invalid literal in a clause the proof never names
  is no longer an error (a proof of part of a formula proves all of it). `SFCheck` grows from 282 to 289 lines (see
  `docs/TRUST.md`). On the generated module of 8,192 functions: CPU 37.6 s to 32.9 s, with the same report.
- `sfverify` at `-Onone` compiles the `-assert-config Release` build while it verifies the debug one, links each imported target once for both, and asks the compiler about type names once per run: `Examples/Metrics` takes 0.32 s instead of 0.52 s, a generated module of 8,192 functions 12.3 s instead of 20.2 s. `SFVerify.run`'s `linking:` closure may now be called from another thread, one call at a time.
- Deciding which functions read differently in the release build renders the functions on several threads first: the 8,192-function module takes 10.6 s instead of 13.2 s, `--package . --target SFSIL --build` 8.6 s instead of 10.3 s, with the same report.
- `swiftformal check` builds the package once with its tests (`swift build --build-tests`) when the walks are in a scanned package, plans the scan from that build, and runs the walks without building: two SwiftPM runs instead of three, `Examples/Walk` warm 4.6 s instead of 7.2 s, with the same report. Tests of another package still build while the scan runs.
- `swiftformal verify` with two or more targets to check, in a package built before, builds the package once (`swift build`) and plans every target from that build: one null build instead of one per target (two targets: 3.5 s instead of 4.6 s after a `swift build`). On a fresh checkout it still builds each target alone.
- `sfverify` keeps what the compiler and `xcrun` say about themselves (`-print-target-info`, the SDK version and path) in `<cache>/toolchains`, next to the module cache, keyed by the compiler file's identity, the selected Xcode and `DEVELOPER_DIR`, `SDKROOT` and `TOOLCHAINS`: one file takes 0.17 s instead of 0.28 s. A changed compiler or environment is asked again.
- `@Verify` on a `mutating` method no longer copies `self` before the body when every `#ensures` names the value before the call `_` (`{ count, _ in … }`): nothing could read the copy, and when the body changes an array or other stored value in place the copy made it copy that storage on every call. `_ensures` keeps its `old: Self` parameter.
- Reading the compiler's SIL output searches the module's bodies (for deinits that run code, issue reporters, `willThrow`) by bytes first: `SILModule(text:)` on 4,096 functions takes 0.10 s instead of 0.47 s, with the same answers.
- `sfverify` reads source positions and contract-failure calls in the SIL by bytes: preparing the SIL of 4,096 functions takes 0.38 s instead of 0.97 s, with the same report.
- The Gate guide and KNOWN-ISSUES #2 state the limit of the Build Gate with macros defined in a package, `@Verify`
  included (K12): such a gated target fails closed, because no PackagePlugin API gives a build-tool plugin the path of
  a built macro; `swift package scan` or `sfverify --build --gate` cover those targets.
- The build gate (K11) adds `note:` lines that lead to the code involved: the gated declaration with the inputs when
  the error sits elsewhere (a trap in a callee), the `f_ensures` function of a broken postcondition with the failing
  call (`bump_ensures(255, bump(255)) is false`), and the declaration of a callee that traps without a position of
  its own. A `// sf:verify` marker that no function follows is reported by the plugin while the build is planned
  (`swift build` fails before any compiler run), and `sfverify --gate` no longer compiles a target whose only marker
  is such a one.
- Contributors: a strict-memory-safety lane (`Scripts/strict-memory-safety.sh`, nightly) builds everything with
  `-strict-memory-safety` and ratchets the warnings per file (`Scripts/baseline/quality.json`): 33 today, from 39. The
  mechanical sites were rewritten without pointers or C variadic calls, with the same output (digests, the `Time:` line).
- `swiftformal check` reads the walks' results from Swift Testing's event stream (`swift test
  --event-stream-output-path … --event-stream-version 6.4 --attachments-path …`, Swift 6.3 or newer): each
  `expectProved` attaches its JSON line (proofs too, only while the check runs, via `SWIFTFORMAL_WALK_EVENTS`), and a
  known issue comes from the issue's `isKnown` instead of the console text. The `SWIFTFORMAL_WALK_LOG` side file stays
  the fallback when there is no stream. The check says which one it read.
- Mangled names in reports are made readable in-process, with the compiler toolchain's `libswiftDemangle`, instead of
  by starting `swift-demangle` (3,100 symbols: 2.9 ms instead of 20 ms, the same text for every one). The tool next to
  the scan's `swiftc` stays the fallback when the library is missing.
- Every Scan compile (`sfverify`, `--build`, the gate, `swiftformal check`) uses one module cache per compiler, named
  after its version line, instead of SwiftPM's cache in each scratch path. A scan with a new scratch path or a fresh
  checkout no longer builds Foundation's module again: `sfverify --build` of a Foundation target in an empty
  `.build` spent 19.5 s compiling, now 1.6 s (27.5 s to 10.9 s in all). The directory is `--module-cache <dir>`, else
  `SFVERIFY_MODULE_CACHE`, else `~/Library/Caches/sfverify`, else the temporary directory (where the gate plugin's
  sandbox lets it write); the gate plugin passes `SFVERIFY_MODULE_CACHE` on.
- Scan finds its compiler with one `swiftc -print-target-info` (version for the pin, target triple, resource
  directory) instead of `swiftc -version`; `SWIFT_EXEC` is honoured, and without `xcrun` (Linux) the first `swiftc` on
  `PATH` is used. A `TOOLCHAINS` that names no installed toolchain, which `xcrun` ignores silently, is reported, and
  `swiftformal doctor` shows where the compiler is and how it was picked. `sfverify --package` without `--build`
  compiles for the package's macOS deployment target instead of the host's. See
  [Which compiler Scan runs](../docs/guides/compilers.md#which-compiler-scan-runs).
- A function that can trap in several places is reported with each place and an input that reaches it
  (`moreTraps` in the JSON, `also:` lines in the text; up to 4 more, one extra solve each, only when no summarized
  standard-library call is involved). It used to show the first one the solver happened to find.
- A trap inside a function your code calls is reported where it happens: `in inc(_:): traps: arithmetic overflow`
  at the callee's line (also through protocol witnesses, such as a `description` or `hash(into:)`), instead of
  "calls …, which traps" at the call. Trap sites are typed inside Scan rather than strings parsed back.
- The compiler pin is enforced. Nothing checked it before: Scan ran whatever `xcrun swiftc` found, and with `--build`
  it could use a different compiler from the one SwiftPM built with. Scan now resolves one compiler (the one in the
  SwiftPM log with `--build`, else `xcrun`), uses it for every compile, and names it in the report (`compiler`,
  `pinned`, optional JSON keys). The Build Gate fails on a compiler that is not pinned; `sfverify` and `swiftformal
  check` print a warning. `Scripts/pin-upgrade.sh OLD NEW` checks a new compiler's SIL printer against the reader
  before it is pinned ([guide](../docs/guides/pin-upgrade.md)).
- Scan checks a debug and a release build by default (`sfverify --config debug|release|both`, default `both`). A
  `safe` from a `-Onone` scan did not carry to the release build: a release build removes `assert`, and the side
  effects of its condition with it (`assert(a.popLast() != nil)`), so code proved safe could trap in release. Functions
  whose code differs under `-assert-config Release` are verified again; the JSON report says which builds it covers
  (`configurations`, an optional key).
- `Deterministic()`, `Matches`, `Table`, `Injective`, `RoundTrip` and `Satisfies` are types now (they were deprecated
  functions returning `Property`). Inside a property builder nothing changes. A value annotated as `Property<…>`
  needs `.property` or the `Property.` factory. `Image(equals:)` and `Image(within:)` stay deprecated, renamed to
  `Outputs(exactly:)` and `Outputs(within:)` (`Image` would clash with SwiftUI).
- Scan builds in the package's own `.build` instead of a second full build in `.build/sfverify` (often 1–2 GB). After
  `swift build --build-tests`, a scan recompiles nothing, and the tests recompile nothing after a scan. Its own files
  are in `.build/swiftformal` (compile commands in `args/<Module>.args`, the build log, a module cache).
- `swiftformal check` no longer lists every function logic proved cannot trap: on four targets of a real app that was
  about 2,000 lines (mostly accessors) before the walks and the summary. The logic section lists broken functions and
  contracts, then one line with the number of functions that cannot trap; `--show-proved` lists them. `--json` is
  unchanged. `swiftformal scan`/`gen` name the build command for the configuration they run in when the tool next to
  them is missing (`swift build -c release --product sfverify`).
- Scan counts code a macro wrote as compiler-generated (`summary.compilerGenerated`), not as functions written by
  hand: the `#Preview` registry (`static $s…PreviewRegistryfMu_.fileID.getter` was reported as a "safe" function)
  and the members, peers and extensions that macros such as `@Observable` and TCA's `@ObservableState` add
  (`shouldNotifyObservers`, `_count` storage, `_$willModify()`). Accessors a macro writes for a property the user
  declared (`count.getter` under `@Observable`) are still reported. `total`, `safe` and `unsupported` drop by those
  functions; no verdict changes. A type with a macro-made name is filed under "macro-generated types" in
  `unsupportedByCategory` instead of under its mangled name.
- Scan matches `_requires` and `_ensures` functions by name instead of scanning every function for each one: on a generated module of 4,096 functions the verify step takes 0.66 s instead of 10.3 s, with the same verdicts.
- `sfverify` starts the compiler and other tools without polling for their exit (about 65 ms per process), reads the SIL from the compiler's output instead of a temporary file, and asks `xcrun` for the SDK and compiler paths once per run: scanning one file takes 0.23 s instead of 0.53 s.
- `sfverify` reads the compiler's SIL output by bytes instead of with Foundation's character search: preparing the SIL of 4,096 functions takes 0.58 s instead of 2.0 s, and a generated module of 8,192 functions is scanned in 7.5 s instead of 10.4 s, with the same report.
- `sfverify --build` and `swiftformal check` read the compile command of each linked local target from the scanned target's build instead of building each one again, and compile the linked targets of one dependency level at the same time: `sfverify --package . --target SFSIL --build` takes 7.6 s instead of 26.3 s, with the same verdicts.
- `swiftformal check` builds the tests while the scan runs, then runs the walks without building again (Examples/Walk, warm: 5.9 -> 4.5 s). When no walk is needed the build is stopped; when it fails, `swift test` builds and reports the error as before. The build's output is in `.build/swiftformal/test-build.out`.
- `partition`, `Domain.map`, `Domain.product` and the domain subscript are `@inlinable`, so your test module specializes them for your types (release): `partition` of 100 000 inputs 14.4 -> 4.0 ms; `verify` over a 3-field product 13.0 -> 7.9 ms, over a struct mapped from a product 13.8 -> 7.6 ms. Their bodies are now part of the package's interface.
- The SAT solver's inner loop uses bounds-checked spans instead of unsafe buffer pointers: the same search step for step (identical LRAT logs on 45 formulas, exact solver counts unchanged) at the same speed, and no `Unsafe` API left in `Sources` (ratchet 7 -> 0).
- `@Verify` on a `mutating` method is an error that points to the Scan contract (`<name>_ensures(…, old: Self)`):
  a walk cannot call a `mutating` method.
- `sfverify --budget` must be a positive number (0 and negative values were accepted and made every function that needs one solver conflict `undecided`); exit code 2 as for other usage errors. Options that take a value also accept `--option=value`. Flags that have no effect in the combination given (`--stats` without `--json`, `--stamp` or `--time-limit` without `--gate`, `--only` with `--gate`, `--xcode` with `--json`) print a warning on stderr; stdout and exit codes are unchanged.
- `@Verify` reports generic, variadic, `inout` and opaque `some` parameters at the parameter, with what to do instead, instead of an error inside the expansion.
- Faster, with the same verdicts and the same sampled inputs (pinned by `SampleSequenceTests`): `verify` over a large domain does no per-input work over its property list; `Contract.requires` checks its condition before reading the recorder; `verifyContracts` binds one recorder per walk instead of one per input; `@Finite` builds 2 to 4 fields with one flat product; behaviour-lock masking skips text that cannot hold an address or a UUID.
- The SAT solver merges its LRAT hint chains instead of sorting them, with byte-identical proofs; about 5% less solver time.
- `sfverify --build` passes the toolchain's and the platform's macro plugin paths to the frontend, so targets that use
  `@Observable` or other Apple macros compile instead of failing with "external macro implementation type could not be found".
- `Domain.combinations` builds at most 4,096 rows. A pairwise cover of fields with hundreds of values each took minutes to build in a debug build. When the table of pairs would exceed 4 million entries it uses a deterministic spread in which every value of every field appears. `Pairwise.rows(levels:)` is unchanged.
- `sfgen` gives `kotlinx.datetime.LocalDate` only valid dates: its Kotlin initializer throws, and a Kotlin exception ends the process.
- A failed `#ensures` (`Contract.ensures`) in Walk shows the value the function returned: `violated: 0 <= result <= price
  (result: -1)`, shortened to 300 characters like inputs. The debug-build `assertionFailure` outside a walk says it too.

### Fixed

- `swiftformal check` no longer proves functions a walk never calls (app study round 7). A walk whose subject names only
  a type (`"EventDetailsStore"`, `"Store without overlay"`) made every member of the type, and of its nested
  types, `provedByWalk`: a getter that traps was reported proved. Such a walk is still run and its failure is still
  reported (`typeWalkFailed`), but it proves no member: a member it alone covers is `cannotTrap` or `unchecked`, and
  the text report says so under the walk. An operator subject links to the operator: `"LoadingState.=="` covers
  `static LoadingState.== infix(_:_:)`, not `LoadingState.load()`, and a scanned `<` (`static Rank.< infix(_:_:)`) is
  keyed `Rank.<` instead of losing its operator to the generic-parameter rule. `swiftformal lsp` weighs the walks the
  same way. Name the member a walk calls: `"Store.body"` for a reducer.
- `swiftformal verify`'s warning for a promise only a test can check suggested `#expect(verify_x().proved)`, which
  does not compile. It now says `#expect(verify_x().isProved)`.
- Scan semantics version 26: the fix that keeps a literal array's known count from reaching another array (an array
  made with `repeating:count:` from its count) changed verdicts without a version bump, so a proof cached at version 25
  by a build before the fix could still be reused. Version 26 invalidates such cache entries.
- A counterexample prints a `Double` or `Float` stored in a struct as a number (`self = HB(input: 5.78960446186581e+76)`),
  not as its bit pattern (`5755600323779493888`), and an unsigned field as unsigned: the field's declared type is taken
  from the module's printed declaration, also inside an `Optional`. The replay line already printed the number (app study round 6,
  the app's `BoundLabelRule`).
- A contract no longer hides a trap. When an `f_ensures` reads what logic does not model (an array element, string
  contents) the contract was `undecided`, "can fail only for some results of Array.subscript", even when the function
  traps whatever those calls return (`allCases[index]` with any `index`). Scan now proves the function again without
  the ensures, the `requires` kept: a trap found that way is reported as the contract's failure (`contractFails`, the
  verdict a contracted function that traps already gets), with its input, and the detail says the ensures alone is
  undecided. A trap that depends on an unmodelled value stays `undecided` (app study round 6, L5).
- A contract is paired with its function when a type in it is passed indirectly (it holds a `URL`, a `UUID`, a
  SwiftUI `Color` or another type whose layout a different module owns) or the result is a tuple. Such a contract was
  dropped: the function said `hasContract: false`, the `_ensures` was listed as a function of its own, and `swiftformal
  verify` failed the build with "… checks nothing: no loadingState in the same type takes the parameters it expects".
  The function now has `hasContract: true` and its own verdict (`unsupported — type URL` when Scan cannot read the
  type); the text report counts "N not checked" next to the contracts that hold and fail, `--show-unsupported` adds
  "its contract is not checked", and `verify` gives a warning with the real reason ("logic cannot read it yet (type
  URL …); its contract is not checked") instead of the error. A contract over a tuple of integers is now checked
  (app study round 6, L7 and L9).
- `swiftformal verify` gives the reason Scan gave for an undecided function. It said "logic could not decide it within
  the budget" for every one, also when the answer depends on results logic does not model (`String(stringInterpolation:)`),
  where a larger budget does not help. It now says "logic could not decide it: can fail only for some results of …"
  for those, keeps "within the budget" for the budget, and adds the fix hint of each (app study round 6, L8).
- A type Scan cannot read (`URL`, `UUID`, `Locale`, SwiftUI's `Color`, a type of a binary framework) gets a hint that
  fits: "Scan cannot read URL: no module it reads declares its layout (…); keep it out of what this function reads,
  or check the logic around it with a walk (`expectProved`)", where every such type got "pass the fields the
  arithmetic needs", also where no arithmetic is involved. When the type is a stored field inside `self` or a parameter, the new
  `typePath` (JSON, additive) names it, through stored properties, enum payloads, tuples and optionals:
  `self.tabs.style: Color`. The hint starts with "Color sits at self.tabs.style.", `--show-unsupported` adds a
  `where:` line, and `swiftformal verify` adds ", at self.tabs.style: Color" to its reason (app study round 6, L10 and L3).
- `swiftformal check` no longer calls a function proved because a walk proved it. A walk proves only the inputs it
  lists, so a getter logic left `undecided` and a walk over indices 0…1 was "proved by walking a whole domain", next to
  "proved by logic for every input", although logic could not exclude a trap outside 0…1. The line is now "proved
  over the walked inputs only", each walk says "proved over its N inputs (not every input)", and the usage text and
  README say so. The JSON outcome stays `provedByWalk` (documented as the walk's inputs) (app study round 6, L5).
- `swiftformal check` blames a failing walk only on the function it names (app study round 6, L18). A walk over a whole
  type ("CustomStore without overlay") that fails no longer marks each member broken: they get the new
  outcome `typeWalkFailed` ("in a type whose walk failed", neither broken nor proved by that walk), and a failure there
  that is not a known issue still fails the run. A known-issue walk that names a function other walks prove no longer
  overrides them: the new outcome `conflict` ("walks disagree (a known issue)") shows both; a failure that is not a known
  issue still beats any proof. JSON: two new outcome values and `wholeType` on a walk result (additive).
- `swiftformal check` lists the walks it does not run instead of dropping them: `walkInExitTest(…)` calls (with the
  scanned function the subject names) and SwiftFormal's `partition(…)` appear under "Seen, not run" with the reason,
  count in "running N of M (…; K not run: exit-test walk or partition)", and are `notRunWalks` in `--json` (additive);
  `WalkCheck.kind` says which (app study round 6, L17). They are still not run: an exit-test walk's result comes from a child
  process that `check` does not read yet.
- `sfverify --build-log <DerivedData>` after an incremental Xcode build no longer leaves out the dependencies that build
  did not recompile, silently. It linked only the modules compiled in the newest log that compiled the target, so on
  the app's main target a 45 s incremental build gave 2 contracts holding where the clean build's log gave 7, `generics` 15
  instead of 2, exit 0 and no warning. A local module the chosen log has no command for now takes its command from the
  newest other activity log of the same folder that compiled it, if that one has the same `-target` and `-sdk`;
  otherwise (and with a single log file) the scan's warnings say "module X could not be linked … no compile command
  for X in this build log" with the reason (app study round 6, L1).
- `docs/TRUST.md` now lists the multiplication lemmas of `prove(strategy: .refiningMultipliers)` as trusted: the
  checker reads them as part of the formula and does not prove them. Contributors: the proof cache (not yet used by
  any tool) has no default directory any more; its default was the shared temporary directory, where anyone could
  write a `.proved`.
- The formula Scan builds for a function is the same in every run. Where several paths join, the stack cells were
  merged in dictionary order, which Swift changes from one process to the next, so the variable numbering (not the
  verdict) could differ between two runs of the same scan. Found by the CNF hashes now taken of every feature.
- An imported module of the same build that Scan could not link is no longer silent. The report's `warnings` (JSON,
  and stderr with the text report) name the module and its first compiler error, and an `unsupported` function that
  stopped at a type declared there (or a call into it) gets the hint "<Type> is declared in <Module>, which could not
  be linked", where it said "Scan reads integers, Bool, and structs…", wrong advice for a plain struct. Verdicts are
  unchanged; the JSON only gains warning lines (app study round 6, bug B).
- The fix hint for `abs(x)` on a `Double`, `Float` or `CGFloat` no longer suggests `x.magnitude`, which Scan does not
  read either: it suggests `x < 0 ? -x : x`, which it reads. Integer `abs` keeps its hint (app study round 6, bug D).
- `sfverify --build`/`--build-log` and `swiftformal check` no longer print "warning: data race detected: @MainActor
  function at sfverify/main.swift:… was not called on the main thread". The closure that finds the imported modules
  to link was written in top-level code, so it was isolated to the main actor, and the linker calls it from its own
  threads; it is now `@Sendable` and copies the values it reads (app study round 6, bug C). On AppFeature: 6 such
  warnings before, none after, the same verdicts.
- Scan compiles SwiftUI code for an iOS, tvOS, watchOS or visionOS simulator. A simulator platform ships no macro
  plugins, and the iOS 27 SDK makes `@State` and `#Preview` macros, so every SwiftUI module of an app built for the
  simulator failed with "plugin for module 'SwiftUIMacros' not found". Scan now takes the plugins from the device
  platform (`iPhoneSimulator.platform` → `iPhoneOS.platform`) when the simulator has none, as the `swiftc` driver
  does (app study round 6, bug A).
- `swiftformal check` no longer counts a walk for an overload it never ran. Walks were linked by `Type.member` alone,
  so `Prove(it: LanguageOption.init(from:))` also marked `init(rawValue:)` as proved by a walk. Argument labels now
  count, read from the reference or the call (`text(for: $0)` → `text(for:)`); a call that leaves out defaulted
  arguments still links to the function it calls. A subject string without labels covers every overload, as before.
- Scan in both build configurations (the default) no longer spends minutes on one core in a module with many
  protocol conformances. Deciding which functions read differently in the release build rebuilt the text of every
  witness and callee for each function; each function's text is now made once per build and compared once. The
  answers are the same.
- `sfverify --build` and `swiftformal check` no longer scan with a garbled compile command. `swift build -v` runs tasks
  in parallel, and another task's output (actool's `/* com.apple.actool.compilation-results */`, codesign's
  "replacing existing signature") could land in the middle of the target's compile command in the log, also with
  `-j 1`. The scan then failed with "invalid value … in '-load-plugin-executable'", and the broken command was saved
  and reused by every later scan. A command is now used and saved only when it is whole (its module, its sources, every
  plugin an existing `path#module`, no foreign text); otherwise the module's other task lines, which carry the same
  driver arguments, are used, and a scan that finds no whole command says so. Found on a real app.
- The README's build line for `swiftformal check` built only `sfgen` (SwiftPM builds only the last `--product` of a
  command), so a new user had no `swiftformal`. It now builds `swiftformal`, which is all `check` needs, and says how to
  build `sfverify` and `sfgen` for `scan` and `gen`. The Scan guide has a recipe for apps made of many packages (scan
  through one package that depends on all of them; measured in `docs/PERFORMANCE.md`), and the Walk guide two recipes:
  listing every failing input with `partition`, and stating where inputs come from with a `_requires` on a getter.
- Scan no longer drops functions whose mangled name shortens the module name. The Swift mangler replaces a word that
  already appeared in the symbol, so a module named `AppStepByStep` (`$s09AppStepByB0…`) reported
  "0 functions written by hand", and an extension in one module of another module's type (`extension
  TemperatureUnitType` from `AppCore` inside `AppSettings`, or a constrained `extension LoadingState<X>`)
  was missing from the report, so a contract on it was never checked (`--gate` failed with "matched no compiled
  function"). Scan now asks `xcrun swift-demangle` which module declares such a function. If it cannot run, or if no
  function of the module is found at all, the report says so in a new optional `warnings` key (also printed on stderr)
  instead of staying silent. Found on a production iOS app (app study round 5).
- `Property.injective()` on a sampled walk no longer reports an input colliding with itself ("1793597 and 1793597 both give 3587194"): sampling draws with replacement. An earlier input that is provably the same value (equal by `Equatable`, or a tuple or struct whose stored parts are all equal) is skipped; anything else is still reported.
- `sfverify --json` reports each function's `seconds`; it was always `0`.
- `swiftformal check` runs walks whose `@Test` (or `@Suite`) attribute is on the same line as the declaration (`@Test func everySpeedHasItsLabel()`, as in `Examples/Walk`), and walks of a `--tests` package given by a relative path. Both were reported as "did not report".
- `sfverify --build` could prove code with stale compiler flags (K3). On a null build SwiftPM prints no compile
  command, so `--build` reused the one it saved last, even when the target had since been recompiled with other
  settings outside sfverify (measured on `Examples/GatedPackage`: a `.define` added and built with `swift build` in the
  same scratch path, then `--build` scanned without it). The saved command now carries Swift Build's build-description
  id (`XCBuildData/prior-build-descriptions.txt`) and is reused only for that same description; otherwise the target
  is rebuilt. With the native build system the command is read from `debug.yaml`, so a null build no longer deletes
  and rebuilds the target. Both are internal formats: when either cannot be read, `--build` rebuilds the target as
  before. A command saved by an older sfverify has no id and is rebuilt once.
- Scan could report a contract as holding when it did not, on a method that returns its own type
  (`func grown(_ by: Int8) -> Bag` with `grown_ensures(_ by: Int8, _ r: Bag)`): the result and `self` were passed to
  `ensures` swapped. They are now passed in the documented order: parameters, result, `self`.
- Scan counted `static` stored properties as fields of the instance (SIL marks them `@_hasStorage` too). It failed
  safe ("struct operands do not match"), so those types were `unsupported` and counterexamples showed extra fields.
- The `@Verify` example in the documentation (`discounted`) did not hold: `price = Int.min`, or a price big enough to
  overflow `price * percent`, broke it. Scan found it. The example now requires `price >= 0 && price <= 1_000_000`.
- Scan could prove a function safe that traps when it printed a value of your type without a `description` of its own
  (`"\(outer)"`): Swift then prints each stored field, enum payload and tuple element, running their `description`s.
  Logic now runs them too, and refuses a type with a custom `Mirror`. Printing a generic type that conforms to
  `CustomStringConvertible` (`extension Box: CustomStringConvertible`) skipped its `description`; it is now refused.
- `@Verify` with `#ensures` on a `throws(E)` function compiles; it failed with "'any Error' cannot be converted".
- `@Verify` no longer produces "immutable value was never used" warnings in your code when `#requires` reads only some parameters.
- `verifyContracts` with a property that calls the function again (`Property.deterministic()`) reports a failing `ensures` as a counterexample; it stopped a debug build with `assertionFailure`.
- `Domain.evenlySpaced` no longer overflows on a domain near `Int.max`.
- Scan could prove a function safe that traps, when two types with the same name were in scope (two `private struct
  Row` in two files, or a type of yours named like one from an imported module or the standard library). SIL prints
  types without their file or module, and Scan used whichever declaration it read last. A type name declared more
  than once, or also declared by an imported module, is now refused as "ambiguous type". The imported modules are
  checked by asking the compiler about each name.
- Imports with an access level or an attribute (`public import Core`, `package import Core`, `@preconcurrency import
  Core`) were ignored: those modules were neither linked nor part of the "ambiguous type" check above, which reopened
  that false proof for them. Every spelling of an import is now read.
- Scan now reads functions declared in an extension of a type from another module (`extension Double { func f() }`).
  Their mangled name starts with the outside type, not the module, so they were silently left out.
- Scan proved functions safe that trap (found by reading the Swift 6.4 compiler and standard library; each one
  reproduced natively, now in `ScanKnownTrapTests` with the printing case above):
  - the default `hash(into:)` of a `RawRepresentable` type ran its `rawValue` getter but did not hash the raw value,
    so a trapping `hash(into:)` of the raw value was missed;
  - `DefaultStringInterpolation(literalCapacity:interpolationCount:)` was assumed never to trap; its capacity
    arithmetic is checked and its allocation can fail;
  - a `~Copyable` struct with a `deinit` was read as a plain struct and its `deinit` never ran; such types (and types
    that contain one) are now refused;
  - array counts computed by `Array(repeating:count:)`, `+`, `+=`, `append` and `insert` had no upper bound, so a
    count the allocation cannot hold was accepted. A count of 2^48 or more is now a trap (the allocation fails).
- `Hasher()` and `Hasher.finalize()` are read (they never trap), so functions that hash a value themselves are no
  longer `unsupported`.
- The SIL and LLVM readers stopped the process on a repeated block label instead of reporting invalid SIL
  (KNOWN-ISSUES 3).
- The proof cache key now includes the standard library summary table, so fixing a summary invalidates the cached
  proofs that relied on it. Encoder semantics version 9.
- The README's install line (`swift build -c release --product swiftformal --product sfverify --product sfgen`) built
  only `sfgen`: `swift build` takes one `--product`, uses the last one given, and exits 0. The README now has one line
  per tool. `Scripts/check-readme-install.py` fails on a `swift build` line with more than one `--product` (safety net,
  CI `links`), and `Scripts/check-examples.sh` runs the README's install lines verbatim and checks each tool was built.
- `docs/TRUST.md` said a second, separately written encoder "is not built". It is: `SFLLVM` encodes the LLVM IR of
  the same compilation, and the nightly oracle lane proves it agrees with the SIL encoding on a fixed set of 26 integer
  functions. `sfverify` does not use it, so no Scan verdict is cross-checked; an opt-in `sfverify --cross-check llvm` is
  decided and not built ([ADR 0008](../docs/decisions/0008-sfllvm-status.md)).
- `docs/TRUST.md` now says which standard library the Scan summaries cover: the SDK's (Swift 6.4). At `-Onone` a
  summarized call runs the OS's `libswiftCore`, which on macOS 13 and iOS 16 is Swift 5.7's; on such an OS the
  summarized calls' trap behaviour was not reviewed and a verdict does not cover it.
- Code from macro expansions (`@Observable`, your own macros) and from files SwiftPM generates is reported with an
  `origin` (`macro`, `build`) and no longer counted as written by hand: a two-function `@Observable` target reported
  15 functions and 20% coverage. The summary counts it under `generatedCode`.
- `sfverify` on a loose file that imports Swift Testing (`import Testing`, `@Test`, `#expect`) failed with "no such
  module"; Scan now passes the toolchain's Swift Testing macros and the platform's developer modules, as SwiftPM
  does. KNOWN-ISSUES 2 is rewritten: only macros defined in your own packages need `--build`.
- A mistyped `--target` was reported as `INVALID SIL` or `COMPILER FAILED`; it now names the target and lists the
  package's targets. A compile that fails with "no such module" without `--build` suggests `--build`.
- `sfverify --build` and `swiftformal check` failed on a cold build when a linked target had its package's name (`Foo`
  in package `Foo`): rebuilding one target deleted Swift Build's folder for the whole package. Only the target's own
  folders are removed now, and a compile flag naming a build-only file is dropped.
- The Build Gate gave every gated target a resource bundle and a `Bundle.module` accessor (its stamp file was taken
  for a resource), which Scan then counted as two unsupported functions. The stamp is now a comment-only
  `<Module>.sfgate.swift`.
- Real compiler output that Scan does not model (a generic builtin such as `builtin "sizeof"<T>()`, a function with
  several `@out` results) was reported as `INVALID SIL`, which reads as a bug in the tool; it is now `unsupported`.
- The coverage table filed most dictionaries (`[K : V]`) under "arrays", and arrays of existentials under
  "existentials"; each is now under its own category.
- `sfverify --build` with a relative package path no longer puts the scratch directory inside itself
  (`Foundation/Core/Foundation/Core/.build/sfverify`).
- A saved compile command whose file list no longer exists is not reused. The target is built again instead of failing
  with "error opening input file".

## [0.1.0] - Unreleased

The first release. Not tagged: the owner decides when. The license (Apache-2.0) and the copyright holder are pending the owner's confirmation ([docs/RELEASING.md](../docs/RELEASING.md)).

### Added

- **Three tools with one vocabulary** ([ADR 0002](../docs/decisions/0002-one-vocabulary-three-tools.md), [mental model](../docs/MENTAL-MODEL.md)):
  - **Walk** (`SwiftFormal`, `SwiftFormalTesting`, `SwiftFormalContracts`): runs your real function over every input of a finite domain. Verdicts: `proved`, `bounded`, `counterexample`.
  - **Prove** (`SFProve`): proves a claim for all values of given integer widths with a SAT solver, accepted only after an independent proof checker agrees. Verdicts: `proved`, `counterexample`, `unknown` (`ProofVerdict`).
  - **Scan** (`sfverify`, the `SwiftFormalGate` build plugin): reads the compiler's own SIL and proves a function cannot trap, or checks a plain-Swift contract. Verdicts: `safe`, `mayTrap`, `contractHolds`, `contractFails`, `undecided`, `unsupported`.
  - `unsupported` and `unknown` always mean that SwiftFormal declined to answer. They are never a pass.
- `sfverify --json --stats` adds the solver's deterministic counts (`solverConflicts`, `cnfVariables`, `cnfClauses`) to every function that reaches the solver. The JSON report carries `schemaVersion` (currently `1`) and has a schema in [docs/schemas](../docs/schemas/scan-report.schema.json). Without `--stats` the JSON is unchanged. Inside the package, `SolveStats` (in `SFSAT`) carries the same numbers; it is `package` and not API.
- `prove(inputWidths:…strategy:claim:)` takes a `ProofStrategy`: `.exact` or `.refiningMultipliers`.
- Documentation: [README](../README.md), [mental model](../docs/MENTAL-MODEL.md), [glossary](../docs/GLOSSARY.md), [what you have to trust](../docs/TRUST.md), [architecture](../docs/ARCHITECTURE.md), [what scales](../docs/SCALING.md), [performance](../docs/PERFORMANCE.md), [testing](../docs/TESTING.md), guides in [docs/guides](../docs/guides), [known issues](../docs/KNOWN-ISSUES.md), decision records in [docs/decisions](../docs/decisions), a DocC catalog for each front-door module, and the runnable [Examples](../Examples) that the README snippets are copied from.
- Tests and checks: tests split per module, three lanes (fast, slow, oracle: [ADR 0004](../docs/decisions/0004-test-lanes.md)), the soundness zoo with differential, metamorphic and fuzz tests ([guide](../docs/guides/soundness-zoo.md)), self-verification of the package, golden verdicts, a deterministic prover-cost baseline, API diff against the `baseline-pre-oss` tag, link and snippet checks, layering and doc-coverage checks, swift-format, SwiftLint and quality ratchets, and CI and nightly workflows.
- Community files: `LICENSE`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue forms (bug, soundness, feature), a pull request template, and the [soundness policy](../docs/decisions/0006-soundness-policy.md): a false `proved` is a P0 bug.

### Changed (breaking compared with the pre-release baseline)

Renames. The old name is gone unless the table says it stays as a deprecated alias.

| Old | New | Old name |
|---|---|---|
| `SFProve.Verdict` | `ProofVerdict` | removed (an alias would clash with `SwiftFormal.Verdict`) |
| `SFVerifyKit.Report` | `ScanReport` | removed |
| `SFVerifyKit.Counterexample` | `ScanCounterexample` | removed |
| `SFVerifyKit.Status` | `ScanStatus` | removed |
| `prove(...)` in `SwiftFormalTesting` | `expectProved(...)` | deprecated alias; removed in 0.2 |
| `Deterministic()` | `Property.deterministic()` | deprecated alias; removed in 0.2 |
| `Matches(_:)` | `Property.matches(_:)` | deprecated alias; removed in 0.2 |
| `Table(_:)` | `Property.table(_:)` | deprecated alias; removed in 0.2 |
| `Injective()` | `Property.injective()` | deprecated alias; removed in 0.2 |
| `Image(equals:)`, `Image(within:)` | `Property.image(equals:)`, `Property.image(within:)` | deprecated alias; removed in 0.2 |
| `RoundTrip(through:)` | `Property.roundTrip(through:)` | deprecated alias; removed in 0.2 |
| `Satisfies(...)` | `Property.satisfies(...)` | deprecated alias; removed in 0.2 |
| `proveRefining`, `proveMaybeRefining`, `proveRefiningDetailed` (public, `SFProve`) | `prove(inputWidths:…strategy: .refiningMultipliers…)` | now `package`, not public |

The previous `prove(inputWidths:…claim:)` signature in `SFProve` still compiles (it is a disfavored overload of the new one). Inside a builder with several properties, write the type (`Property.deterministic()`): Swift reads a line that starts with `.` as a continuation of the previous line ([ADR 0005](../docs/decisions/0005-api-naming.md)). The names that deliberately stay are listed in the same ADR.

Package access ([ADR 0003](../docs/decisions/0003-package-access-for-engines.md)). Engine modules are no longer public API; only the front doors are covered by semantic versioning. Public declarations per module, baseline to now:

| Module | Public before | Public now |
|---|---:|---:|
| `SFCNF` | 7 | 1 |
| `SFSAT` | 10 | 0 |
| `SFCheck` | 12 | 0 |
| `SFBV` | 56 | 52 |
| `SFSemantics` | 15 | 0 |
| `SFSIL` | 190 | 1 |
| `SFLLVM` | 26 | 0 |
| `SFProve` | 69 | 42 |
| `SwiftFormalMacros` | 11 | 0 |
| `SFVerifyKit`, `SFGenKit`, `SwiftFormal` | 111, 93, 99 | 110, 93, 99 |

- `Property.Observer`, `Property.Evaluate` and `Property.custom(_:makeObserver:)` are now `@_spi(Extending)`. `Property.perInput` is the supported way to write a property.
- Strict compiler settings (`ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`) on every library and executable module, so importing `SFProve` no longer re-exports `SFBV`, `SFCNF` or `SFSAT` except where its public signatures use them ([ADR 0007](../docs/decisions/0007-type-driven-audit.md)).

### Fixed

- `Budget.maxEvaluations` stays positive after creation.
- `Results.values` (`SFVerifyKit`) reads under its lock.
- `ProofCache.Entry.verdict` is an enum, not a `String`; the JSON on disk is the same.

No wrong verdict was found by the soundness zoo, the differential and metamorphic SAT tests, or the fuzzing. Problems that are not fixed are in [docs/KNOWN-ISSUES.md](../docs/KNOWN-ISSUES.md).

### Known issues

See [docs/KNOWN-ISSUES.md](../docs/KNOWN-ISSUES.md): three, none changes a verdict, and none is a soundness bug.

[Unreleased]: #unreleased
[0.1.0]: #010---unreleased
