# Known issues

Problems found while testing, with the reason and the status today. None changes a verdict.

**Ordering rule:** a real soundness bug (a wrong `proved`) is listed first, and its test is marked `withKnownIssue`.
Today there is none: the soundness zoo, the differential and metamorphic SAT tests and the fuzzing found no wrong
verdict. Numbers never change, so older references stay valid.

## 1. `Solver.internalLit` overflows on out-of-contract literals (low, input validation)

- **Symptom:** in `Sources/SFSAT/Solver.swift`, `static func internalLit(_ lit: Int32) -> Int` traps for
  `lit = Int32.min` (negation), and for literals above about 2³⁰ (`2 * (lit - 1)` in 32-bit arithmetic). Found by
  Scan (`sfverify`, the internal engine command) on the `SFSAT` target ([dogfooding](guides/dogfooding.md)).
- **Workaround:** none needed. DIMACS variable numbers are bounded by the formula and `CNFBuilder` allocates from 1, so
  no package path reaches this range. A trap is a crash, never a wrong answer.
- **Status:** open. Options: `precondition(lit != 0)` with a clear message, or widen the arithmetic to `Int`.

## 2. Scan and macros defined in your own packages (tool limitation, mostly fixed)

- **Symptom:** a macro defined in a package does not compile in the maintainers' loose-file mode
  (`sfverify file.swift`): `plugin for module '…' not found`, and nothing is proved.
- **Works:** toolchain and SDK macros without `--build` (`@TaskLocal`, `@Observable`, `#Predicate`, Swift Testing's
  `@Test` and `#expect` in a loose file). Package macros with `--build` and in `swiftformal check`, because Scan reuses
  SwiftPM's exact flags (measured on tests using `@Verify` and `@Test`, 158 functions).
- **Workaround:** `swiftformal check --scan <dir>:<target>`, `--build-log` or `--gate`. They build with SwiftPM or read
  the build's log, so the macro is loaded ([Gate guide](guides/gate.md)).
- **Status:** mostly fixed. The build plugin that came before `swiftformal check --gate` had the same limit
  (PackagePlugin gives a build-tool plugin no way to find a built macro), which is why it was removed.

## 3. Fixed: the SIL and LLVM readers trapped on a repeated basic-block label

- **Symptom (was):** two blocks with the same label (`bb1:` twice, or two `t:` lines) stopped the process instead of
  giving an `invalid` error: `Dictionary(uniqueKeysWithValues:)` built the block index before the check meant to
  throw. The SIL encoder had the same bug. It mattered for the next pinned compiler, whose
  `debug_value … transform { bbN: … }` nests block labels.
- **Status:** fixed. Both readers throw `duplicate block <label>`. `ParserFuzzTests` no longer skips such inputs, and
  `aRepeatedBlockLabelIsATypedError` checks both readers.

## 4. A generated app check was not repeatable: `ProfileEditRule` (open, found by `sfgen`)

- **Symptom:** in a second full run of the 392 checks generated for a production iOS app, 283 of the first 284 matched
  their lock. `ProfileEditRule` reported `CHANGED` on unchanged code. Which field varies is unknown: the lock and the
  was/now line keep only a prefix. Usual causes: a clock, a random value, an unordered collection.
- **Workaround:** mask the varying part or make the Rule deterministic.
- **Status:** open. The last 108 Rules of that pass were not run, so more such Rules may exist. `sfgen` writes no lock
  any more, so a second run no longer compares with the first. The generated `Deterministic()` check calls each input
  twice in one run: it catches output that differs between two calls, not output that differs only between runs.

## 5. A test host died silently once and the run hung (open, cause unknown)

- **Symptom:** an earlier second-pass attempt lost the test host in `BagDetailsRule` after 70 Rules, with no crash
  report. That Rule alone passes in 9.3 s (peak footprint about 637 MB), so it looks like a flake. Not reproduced.
- **Workaround:** a known cause of the same symptom is a Kotlin exception: it ends the process, Swift Testing restarts
  the host, and the run looks hung. Look for the last `SFGEN-BEGIN` with no result line.
- **Status:** open, cause unknown.

## 6. Scan reads other modules only from your own packages (partly fixed, Scan limitation)

- **Symptom:** SDK modules (Foundation, SwiftUI) and remote packages (checked out under `.build`) are not read, so
  their types, conformances and functions are `unsupported`. `sfverify` on loose files links nothing.
  A type name declared twice (in two files, two linked modules, or also by an imported module or the standard library)
  is refused as `ambiguous type`: SIL prints a type without its module, and Scan never guesses.
- **Workaround:** use `swiftformal check` or `check --gate` (maintainers: `sfverify --build`): they link the SIL of
  your package's imported targets and of local path dependencies. Rename one of two same-named types.
- **Status:** partly fixed. Not a verdict bug: Scan says `unsupported` with the reason.

## 7. Scan knows string identities and literal texts, not the contents of other strings (by design, for now)

- **Read:** `==` and `isEmpty` on every string. On ASCII literal texts: `count`, `+`, `<`, `hasPrefix`, `hasSuffix`,
  `lowercased()`, `uppercased()`. `s.lowercased()` is the lowercased literal whenever `s` is that literal, also when the
  literal comes later (`switch input?.lowercased() { case "home": … }` with a contract about `input == "home"`). An
  integer's text (`"\(n)"`, `String(n)`, `String(describing: n)`, `n.description`) equals a literal exactly when the
  literal is `n` in decimal (`"\(n)" == "18"` only for 18; never `"F"`, `"007"`, `"-0"` or `""`). A `String` raw-value
  enum's `init(rawValue:)` (`_findStringSwitchCase`) and `==` (`Kind(rawValue: s) == .iron`).
- **Also read (issue 21):** an interpolation with ASCII literal parts equals a literal only where the parts line up
  (`"-\(n)" == "-0"` exactly when `n == 0`); localized texts are an unknown function of their key; `String(format:)`
  with a literal format.
- **Symptom:** `undecided` when a result needs: the length or order of an unknown string; equality of two unknown
  strings, also after `lowercased()`; non-ASCII case conversion (`"É".lowercased()`); two unknown parts next to each
  other (`"\(a)\(b)"`); a non-ASCII raw-value case (`"é"`); `==` on an `@objc` enum.
- **Workaround:** none. Such a result is `undecided` with the names of the calls, never `safe`. A counterexample is
  shown only when it fails whatever those calls return.
- **Status:** by design for now. Not done: a model of string contents, more facts about results (such as an upper
  bound on `count`).

## 8. Scan knows an array's count, and the elements of the literals your code builds (by design, for now)

- **Read:** in a `-Onone` build an array is its count. The elements of an array literal your code builds
  (`[Row(…), Row(…)]`, up to 64 elements) are known while it is unchanged, also after it is returned or stored in a
  struct: `a[i]`, `first` and `last` on it are exact.
- **Symptom:** a subscript write (`a[i] = x`, also in a callee) forgets the elements of that array and its copies. A
  count change (`append`, `remove…`, `+`) gives unknown elements. Otherwise `a[i]` checks the index exactly but returns
  an unknown element: `a[0] + 1` on an array parameter is `undecided`. `Array.==`, `contains` and `firstIndex(of:)` are
  unknown when both sides are non-empty (for your element types they also run `==` on unknown elements, so its traps
  are not hidden). `map`, `filter`, `compactMap`, `first(where:)`, `contains(where:)`, `allSatisfy` and
  `count(where:)` with a closure literal are read as issue 20 says; `for x in array`, `reduce` and other closure calls
  are `unsupported`. A `-O` build supports only constant tables.
- **Workaround:** none. A trap that depends on an element value is `undecided`, never `mayTrap` or `safe`.
- **Status:** by design for now. Not done: elements of non-literal or changed arrays, element values in iteration,
  arrays of classes or existentials.

## 9. Scan holds closures but runs only closure literals of the calling function (by design, for now)

- **Symptom:** a closure is an opaque value. Creating, storing, copying, passing or destroying one is read. Calling a
  closure that is not a literal of the calling function (`client.load()`, `validator(text)` with `validator` a
  parameter or a stored property) is `unsupported` ("closures and indirect calls").
- **Read:** `Optional.map` and `Optional.flatMap`, a helper of the module that calls its closure parameter
  (`apply(x) { $0 + 1 }`), and the `Array` calls of issue 20, each with a closure literal written in the same function
  (or a function named in its place) that cannot throw and captures only values (not a `var`): the closure's body
  runs, inlined with its traps.
- **`deinit`:** destroying an escaping closure (or an existential, a key path, an object) may run the `deinit` of any
  object it captured. A `deinit` that only releases, reads, branches and calls its superclass's runs no code when that
  superclass is a class of the read modules (its `deinit` is inspected too) or `NSObject`. A superclass of an SDK or
  binary framework has a `deinit` Scan has no body of, so it is assumed like one that runs code. One that traps,
  writes memory, or calls a function (other than the reviewed `NWPathMonitor.cancel()` and `Task.cancel()`) runs code.
  When some `deinit` of a read module runs code, a scan assumes it does not trap: "deinit of X does not trap", one per
  such class, in the function's `assumptions`. With `--no-opaque-calls` those values are refused. A non-escaping
  closure is never destroyed and is kept.
- **Workaround:** none. A closure's body is never assumed; a function that depends on it is not read. What such a
  `deinit` does besides trapping (a global it writes) is not modelled.
- **Status:** by design for now. Not done: calling unknown closures (needs an honest rule for "the closure might
  trap"), a closure chosen at run time (`flag ? f : g`), key-path closures (`map(\.value)`), a finer `deinit` rule per
  captured type.

## 10. Scan reads TCA state getters but not setters (by design, for now)

- **Symptom:** a TCA `@ObservableState` struct's getters, initializers, `_x` storage, `_$id` and computed properties are
  read. Its setters and `_modify` accessors call `ObservationStateRegistrar.mutate`, which takes closures
  (`_$isIdentityEqual`, and a generated one that runs the value's `==`), so they are `unsupported`. So are key paths
  that capture values (`\.items[i]`, CasePaths with `indices`) or name another module's property (`\String.count`).
- **Workaround:** none. A function is read only when every call in it is a reviewed TCA call or code Scan reads.
- **Status:** by design for now. Not done: setters (need a rule for running the value's `==` behind `mutate`), other
  TCA types (`Store`, `Shared`, `StackState`).

## 11. Scan holds existentials but does not open them (by design, for now)

- **Symptom:** an `any P` value (`any AnalyticsManager`, `any Error`, `any P & Q`) is opaque. Storing, copying,
  passing or destroying one is read. Opening one to call a requirement (`tracker.track(event)`), casting it (`as?`,
  `as!`) or boxing a value into one (`let t: any P = Named()`) is `unsupported`. Existentials are refused in a build
  where some `deinit` of a read module runs code, because destroying one destroys the value inside. `Any`,
  `AnyObject` and existential metatypes (`any P.Type`) are `unsupported`. A thrown `any Error` is held, not opened;
  throwing calls into the standard library and `rethrows` closures are `unsupported`.
- **Workaround:** none. What is inside is never assumed; a function that depends on it is not read.
- **Status:** by design for now. Not done: calling a requirement (needs the set of conforming types, or an honest rule
  for "the witness might trap"), boxing, casts, reading a thrown error.

## 12. Scan reads `static let` values, not global variables (partly fixed, Scan limitation)

- **Symptom:** a `static let` or global `let` of a type Scan reads (`Self.inputHelper`, `Limits.bounds`) is read as
  the value its one-time initializer stores; an initializer that traps makes every read trap. Still `unsupported`: a
  `static var` or global `var`, a global read while its own initializer runs, an initializer with a loop, and a global
  initialized another way (a constant table in a `-O` build is read separately).
- **Workaround:** none. A mutable global is not read at all. A `let` global is stored only by its initializer, which
  runs once, before any read returns.
- **Symptom (also):** a function that reads the same `static let` twice in one expression
  (`x > Limits.maxValue ? Limits.maxValue : x`: `other: address_to_pointer`) is `unsupported`; reading it once, or into
  a local first, is read.
- **Status:** partly fixed. Not done: global and static `var`s (need a model of state shared between functions).

## 13. Objective-C objects: every call returns its own value (by design, for now)

- **Symptom:** an Objective-C or Kotlin object is a reference whose getters return any value of their type, a fresh
  one at each call. So `x.index >= 0 && x.index < 3 ? a[Int(x.index)] : 0` is `mayTrap` with three different values
  of `x.index`, though a Kotlin `val` returns the same value every time.
- **Workaround:** none needed for soundness: a fresh value per call covers every value the real object can return, so
  `safe` stays sound. The report lists what each call returned (`foreignResults`) and says the values come from
  foreign code.
- **Also:** subclassing and conformance are asked of the compiler, one probe line per (foreign type, supertype) pair.
  On a production app (220 types × 15 supertypes) compile time did not change measurably (45.5 s, then 44.8 s). Types
  renamed with `NS_SWIFT_NAME` are read by their Swift name. A generic Objective-C class (`KotlinArray<T>`) is not
  read.
- **Status:** by design for now. Not done: one getter value per object (stable `val`s), creating objects, casts.
  Kotlin enums and sealed classes, `onEnum(of:)` and `==` (`isEqual:`) are read (issue 19).

## 14. Scan holds Foundation values but reads only a few calls on them (by design, for now)

- **Read:** `UUID`, `URL`, `Locale`, `Date` and SwiftUI's `Color` are opaque identities. Holding, copying, passing,
  storing (in a struct, enum or `Optional`) and destroying one is read, and so are `==`, `hash(into:)`, `hashValue`,
  `description`, `UUID()`, `UUID(uuidString:)`, `uuidString`, `URL(string:)`, `absoluteString`, `Locale.current`,
  `Locale(identifier:)`, `identifier`, `Date()`, `Date.now`, `Date(timeIntervalSince1970:)`, `timeIntervalSince1970`,
  `Date.<`, `Color.opacity(_:)` and the standard colours. So a state with `let id: UUID` has its accessors and
  synthesized `==` and `hash(into:)` read.
- **Known values:** a `UUID` equals another exactly when it is the same value. A copy of a `URL` or `Locale` equals
  itself; two others are of unknown equality. `Color.==` is unknown; a `Date` is its `Double` (issue 22).
  Getters such as `uuidString` give the same unknown result for the same value. Every value a call makes is unknown:
  two `UUID()` calls are neither proved equal nor different, and `URL(string:)` may or may not be nil.
- **Symptom:** any other call (`url.path`, `url.host`, formatters, `Color(red:green:blue:)`) is an assumed call
  (issue 22), or `unsupported` with `--no-opaque-calls`, with the list of calls that are read. A name spelled
  with its module (`Foundation.UUID`, which SIL prints when a read module declares its own `UUID`) is not read.
- **Workaround:** none. A trap that depends on an unknown result is `undecided`, never `mayTrap` or `safe`; a call not
  in the list is not read.
- **Status:** by design for now. Not done: what URL components, `Calendar` and formatting compute, `Color`
  initializers (assumed calls, issue 22).

## 15. `swiftformal check` does not run a walk where logic already found a failing input (by design)

- **Symptom:** every walk linked to a scanned function runs, also where a contract holds (a walk may state another
  promise: a table, injectivity). A walk whose functions all have a failing input from logic (`contractFails`) is not
  run: the function is already broken. It is listed under "Seen, not run" (`notRunWalks`, kind `logicFoundFailure`)
  with that reason, so what the walk itself promises is not checked until the function is fixed.
- **Workaround:** none needed: the function's verdict is already "broken, with the input"; nothing it covers is
  shown as proved or passed.
- **Status:** by design. Not done: running such walks anyway (a cost for a function that already fails the run).

## 16. Planted-bug shapes logic cannot catch yet (by design, for now)

- **Symptom:** four mappers of the [planted-bug suite](TESTING.md#the-planted-bug-suite) are not read by logic, so
  their bugs are caught only by a walk. `PlantedBugScanTests` marks each with `withKnownIssue`.
  - Shape 3, parse of format for one locale: `Locale.decimalSeparator` is an assumed call (issue 22), but
    `String.split` and `Character(_:)` are `unsupported` (issue 7).
  - Shape 5, "-0" from `String(format: "%.0f", x)`: `undecided`, since what `%f` prints is not modelled (issue 21);
    the fixed one is `unsupported` (`Double.rounded()`). Shape 5's `"-\(n)"` is caught.
  - Shape 13, two cases with different keys: `undecided`, never proved, since different keys may have the same text
    (issue 21). A walk over the real catalogue checks it.
  - Shape 10, a forgotten subclass of a sealed hierarchy: a class instance is `unsupported`, so `as?` casts and
    `onEnum(of:)` are not read.
- **Workaround:** none needed: none of them is `safe` or `contractHolds`; `noBuggyMapperIsEverAPass` checks it.
- **Status:** by design for now. Not done: a model of string contents and of formatting. When Scan learns one, its known
  issue fails the test: turn it into a plain expectation and update this entry.

## 17. Protocol-extension forwarders are followed only when they are exact (by design)

- **Symptom:** a rule written as `struct X: Rule { var body: … }` and called as `X(input: v).execute()`, with `extension
  Rule { func execute() -> Output { body } }`, is read in both engines. Scan follows the call into `X.body`, taking
  `Output` from the conformance's witness table. `swiftformal check` links a walk `Prove(it: { X(input: $0).execute() },
  …)` to `X.body` when the closure's whole body is `X(…).execute()`, `execute()` has no parameters and sits in an
  unconstrained `extension Rule`, its body is only `body`, `self.body` or a call of one requirement, and `Rule`,
  `execute` and `X` are each declared once in the sources the tests can see (the test files, the scanned targets and
  what they import).
- **Not followed:** a conforming type that is generic (`Box<T>: Rule`), a nested associated type
  (`Self.Output.Element`), an associated type two conformances disagree on, a forwarder with any other body or with
  parameters, a constrained extension, a rule built in a variable first (`let r = X(…); return r.execute()`), and types
  or protocols declared only in a binary framework. `check` also keeps every subject when the tests or the targets they
  reach import a module it does not read (a remote dependency in `.build/checkouts`, a path dependency outside the
  `--tests`/`--scan` roots; only the toolchain's, the common SDK modules and SwiftFormal's are exempt), when an
  Objective-C header it reads mentions the member, or when a file's comments and string or regex literals cannot be told
  apart (an unclosed one, unbalanced braces): such a file is unknown, not empty. Declarations added by macros are not
  seen.
- **Workaround:** none needed: Scan leaves such a call `unsupported` with its reason; `check` keeps the subject the
  closure names (`Rule.execute`), lists the walk as not linked, and its hint says which member to name (`Prove("X.body",
  it: …)`).
- **Status:** by design. Not done: generic conformances (they need the conformance's own substitutions) and forwarders
  with parameters (`execute(with: y)`).

## 18. Generated domains for binary frameworks (by design)

- **Symptom:** `sfgen domains` ([Generate](guides/generate.md#domains-for-a-binary-framework)) marks a domain
  `exhaustive` from the framework's declarations, which a binary does not let it check. An exhaustive domain
  assumes that:
  - an initializer stores each argument as the property of the same name, so the product of the fields' domains is
    every value the class can hold;
  - the class has no other state: a settable property or a method that may change it, declared by the class or by
    any superclass (the sealed base included), makes the domain `bounded`, and so does a superclass the graph does
    not describe. `NSObject` counts as stateless: its settable properties (accessibility, key-value coding) are not
    the value a mapper reads;
  - an enum has only the cases the graph declares: its domain is complete only when `allCases`, as the walk finds
    it, holds that many distinct values. A case that carries values or is unavailable, or a C enum (which may hold
    raw values outside its cases), makes it `bounded`;
  - a sealed hierarchy has only the subclasses its `onEnum(of:)` enum lists. A Swift subclass of an open sealed base
    is not covered, and an open class that is not sealed is skipped, because it may be abstract.
- **Also:** `CaseIterable.domain` is a sample (`bounded`), because a hand-written `allCases` may leave values out;
  `Finite` and `Domain.allCases` are claims, by the type's author or at the call site, that the list is complete.
  A Kotlin initializer that validates its arguments (`require`) can stop a walk on a boundary sample. A domain
  larger than 1,024 combinations is walked pairwise and is `bounded`.
- **Workaround:** none needed: every sampled field makes the domain `bounded`, so no walk over it says
  `proved`; the generated `switch` over each sealed hierarchy and enum stops compiling when a case is added or
  removed.
- **Status:** by design. Not done: generic types, recursive types, protocols without `onEnum(of:)` and classes without a
  public initializer are skipped with a reason in the manifest.

## 19. Types from binary frameworks: calls with no body are assumptions (by design)

- **Symptom:** in a framework shipped as a binary (Kotlin through SKIE, closed-source Swift or Objective-C), Scan reads
  enums from the compiler's case lists, and every call with no body (`onEnum(of:)`, `ordinal`, `name`, the
  Objective-C bridging calls, Objective-C methods, `==` through `isEqual:`) returns any value of its type, a fresh one
  each time, and is assumed not to trap. Each such call is listed in the function's `assumptions`
  ([TRUST](TRUST.md#scan-swiftformal-check-and-the-build-gate---gate)).
- **So:** a SKIE enum that round-trips through Objective-C (`Surface(obj._bridgeToObjectiveC())`) is any case, not
  the same one; two calls of a Kotlin `val` may differ; `isEqual:` may give either answer even for the same object.
  Such code can be `contractFails` with a counterexample the real framework never produces: the counterexample names
  what each call returned (`onEnum(of:) returned .sand`), so it can be judged. A proof is never wrong for these
  reasons; what it takes on trust is that the calls return.
- **Not read:** a non-frozen enum of a module built with library evolution whose payload is address-only (the
  compiler shows no payload type), a call that returns through memory (a generic or resilient result), takes a
  closure, an existential or a type of a read package, and a call into a module whose source is also read.
- **Status:** by design. Not done: reading SKIE's generated Swift (it ships in the binary) to prove the round trip and
  the bridging calls instead of assuming them.

## 20. Closures over arrays: unrolled up to a bound (by design, for now)

- **Symptom:** `map`, `filter`, `compactMap`, `first(where:)`, `contains(where:)`, `allSatisfy` and `count(where:)` with
  a closure literal (issue 9) run the closure on each element in order, the searches stopping at the first match.
  With a known count (a literal, up to 64 elements, or a count built of constants) this is exact, and `map` makes a
  literal whose elements are the closure's results. An array of unknown length is run on its first 8 elements; being
  longer is never a counterexample and never a proof. A claim whose `#requires` bounds the length (`xs.count == 18`,
  at most 64) is then solved again over 64 elements, and its proof holds for every input. Otherwise the claim is
  solved assuming at most 8 elements: a proof there is `undecided` with the category `bounded` ("bounded (n ≤ 8)",
  `bounded` in the JSON with the calls, `summary.bounded`), never `safe` or `contractHolds`, and never cached. A
  counterexample there is real. Outside a scan (`SILVerifier` alone) such a call is `unsupported` ("an array of
  unknown length").
- **Still unknown:** the elements of an array that is not a literal, and of the results of `filter` and `compactMap`
  (their count is exact), so a claim that needs them is `undecided`. `sfverify --modular` does not prove a `bounded`
  function again.
- **Not read:** `reduce`, `forEach`, `sorted(by:)`, `firstIndex(where:)` and other closure-taking calls; key-path
  closures (`map(\.value)`); a closure that can throw, captures a `var`, or is generic (a closure passed on to a
  generic helper). An array whose elements may hold a closure, an existential or an object is read as issue 9 says:
  with an assumption per `deinit` that runs code, or refused with `--no-opaque-calls`; its elements are still not
  read when they are objects.
- **Workaround:** none needed: a proof for every input needs every length the claim allows to be run; for the
  rest the bound is printed, and the planted-bug suite (shape 12) checks that an array of unknown length is never a
  pass.
- **Status:** by design for now. Not done: an abstraction per element (a loop invariant for these calls), so that a
  proof holds for every length without a `#requires`.
- **Not read: SwiftUI `Binding<…>`** (of an array or not): a binding reads and writes through closures the view
  gave it (`Binding(get:set:)`), which may be code of the read modules, so its `wrappedValue` cannot be a call with
  no body (`SILOpaqueCalls.swift`); holding one without reading it would gain little, since view code reads it.

## 21. Text: localization keys, `String(format:)` and interpolations (by design)

- **Symptom:** Scan reads which localization key a function picks. `NSLocalizedString(key, tableName:, bundle:, value:,
  comment:)` and `String(localized:table:bundle:locale:comment:)` are an uninterpreted function of everything but
  the comment: the same key gives the same text, so two cases that pick the same key are `contractFails`. A body-less
  `localized…` call of your own module (an extension in a binary framework, `"key".localized()`) is the same
  function of its arguments. Each function that uses one lists the assumption that localization is deterministic
  (the same key, table, bundle and locale give the same text during one call).
- **Never proved:** that two different keys have different texts. A catalogue may give both the same text, so such a
  contract is `undecided`; a counterexample that needs two keys' texts to be equal is not shown (the honesty check
  looks for one that fails whatever the texts are). This holds for an app's own body-less `localized…` call too:
  its text is not a value the counterexample names.
- **Format arguments:** `[any CVarArg]` holds any value, and a type of your module that conforms to `CVarArg` (every
  `NSObject` does) could run your code when it is printed or destroyed. An array literal whose elements are each
  boxed from a known type (`init_existential_addr`) is read: its values destroy without your code, and a body-less
  call (`"key".localized([n, name])`) may take it when every value is a standard number or a `String`. An
  `any CVarArg` that comes from elsewhere is `unsupported`.
- **`String(format:)`:** a literal format is read conversion by conversion. `%d` and `%i` print the decimal text
  of a signed integer only when the length modifier matches it: none for `Int32` or narrower, `l`, `ll`, `q`, `z`,
  `j` or `t` for `Int` and `Int64`; `%d` of an `Int` prints its decimal text only when the value fits in an `Int32`.
  Any other length is any text: `%hd` of 70000 is "4464", `%hhd` of 300 is "44", and `%ld` of `Int32(-1)` or `%lld`
  of `Int8(-1)` is "4294967295". A plain `%@` prints the string and `%%` a percent sign. Other number conversions
  (`%u`, `%x`, `%f`) print a non-empty text Scan does not know; `%c`, `%C`, a `%@` with flags or a width, and any
  conversion with a precision may print nothing (`%c` of 0, `%.0d` and `%.0x` of 0 are ""), so they are any text,
  the empty one included. Reading more arguments than given, a number as `%@`, a Swift value as `%s` or a `Double`
  as `%Lf` is `mayTrap`. Not read: a format that is not a literal (an assumption, or `unsupported` with
  `--no-opaque-calls`) and `%*d`.
- **Interpolations:** a text built from ASCII literal parts and unknown parts is matched part by part against each
  literal of the code: it equals one only where the literal parts line up, which is sound because an ASCII
  character never combines with its neighbour. Two unknown parts next to each other are not split, and a text with
  more than 16 parts, or more than 32 ways to line up with one literal, gets no facts (`undecided`). `hasPrefix` is
  known for a text that starts with a literal part.
- **Catalogues:** what a key's text is in each language is not proved; `swiftformal strings` checks the catalogues
  (missing languages, format arguments, untranslated keys) without a solver
  ([Scan](guides/scan.md#localization-catalogues-swiftformal-strings)).

## 22. Foundation values: dates, decimals, and calls that are assumed (by design, for now)

- **Symptom:** a `Date` is the `Double` it wraps (`timeIntervalSinceReferenceDate`). `Date(timeIntervalSince1970:)`,
  `timeIntervalSince1970`, `timeIntervalSinceReferenceDate`, `addingTimeInterval`, `addTimeInterval`, `+`, `-`, `+=`,
  `-=`, `Date(timeInterval:since:)`, `timeIntervalSince(_:)`, `distantPast`, `distantFuture`, `==`, `<`, `>`, `<=` and
  `>=` are Foundation's IEEE operations, checked against Foundation bit for bit (`SILFoundationValueTests`). `Date()`
  and `Date.now` are unknown dates. `Decimal`, `Calendar`, `TimeZone`, `DateComponents`, `URLComponents`,
  `CharacterSet` and SwiftUI's `Image` and `Font` are held like `URL` (issue 14): stored, passed, equal to a copy of
  themselves, nothing more (`Image` and `Font` are refused, like `Color`, while some deinit of the read modules runs
  code). Any call on these types that is not read returns any value of its type, changes its `inout` arguments to any
  value and is assumed not to trap; each is listed in `assumptions` (issue 19), and a failure that needs a particular
  result is `undecided`, not `contractFails`. With `--no-opaque-calls` they are `unsupported`.
- **Not read:** `Decimal` arithmetic (`+`, `-`, `*`, `/`, `add(_:)`, `rounded`, …) is `unsupported` with "Decimal
  arithmetic": it is decimal floating point with its own rounding, and reading it as `Double` would prove what is false
  (`1 / 3 * 3` is 1 in `Double`). A call that takes a closure, an existential, a generic, an `async` or `throws`
  signature, a collection, a type of a read package, or an enum Scan does not read (`Calendar.Component`,
  `Calendar.MatchingPolicy`) is `unsupported`: it could run the app's code or its argument is not readable. So
  `calendar.date(byAdding:value:to:)` is `unsupported`. `Data` is not held: a `Data` can carry a deallocator closure.
- **Workaround:** none needed: a `Calendar` or `TimeZone` is never taken for the device's or any other; what it
  computes is any value. The assumptions are those of issue 19: the call returns. `Locale`, `URL`, `Calendar` and
  `TimeZone` may be bridged Objective-C objects; their calls are still listed as assumptions.
- **Status:** by design for now. Not done: a model of `Calendar` with a pinned time zone, of `Decimal` arithmetic, of
  `Data`, and SwiftUI's `UnitPoint`; `Color` stays refused while a deinit runs code. Walks are unchanged: no sampled
  domain for these types.

## 23. Relational claims of walks, proved by logic (by design, for now)

- **Symptom:** `swiftformal check` gives a walk's `Injective()`, `RoundTrip(through:)`, `Agrees(with:)` and `Matches`
  to logic when each closure is one chain of calls on the input (`RelationalWalks.swift` reads them from the test
  sources as text; [Walk](guides/walk.md#relational-claims-proved-for-every-input-by-logic)). Logic runs the rule
  twice in one query (self-composition) and decides the claim for every value of the input type
  (`RelationalProofs.swift`): proved, a counterexample, or unknown, which leaves the walk's verdict as it was.
- **Only after the rule returns normally:** the claim is decided only when logic first proves that every chain
  returns normally on every valid input; a rule that may trap leaves the claim unknown. The assumptions of either
  query are listed with the proof, and a counterexample that rests on one, or on a result an Objective-C call
  returns, is not kept.
- **Equality:** the derived `==`, leaf by leaf. A compared type that holds a floating-point value (`-0.0 == 0.0` and
  `nan != nan`, where the walk compares with `==` and hashes) or has a hand-written `==` is not read, nor is an
  array, set, dictionary or opaque value other than `String`. A test target that declares any `==`, or a function or
  type of the name a closure calls (the walk may call that one), has none of its walks read.
- **Text:** compared by Scan's text identity (issue 21): `Injective` over literal texts is decided, over localized
  text it stays unknown, since two keys may have the same text.
- **A counterexample fails a walk only over a sample:** a walk that passed over `.samples`, `.boundaries` or a generated
  domain ("the domain is a sample") fails with logic's input, marked "found by logic, outside the walked inputs". A
  complete domain (`.of`, `.int(0...n)`, `.allCases`) states a precondition logic does not know, even when it is too big
  to walk, so a counterexample there is dropped. A precondition logic should know is a `#requires` on the function: then
  the rule may trap outside it, and the claim is unknown.
- **Only over the walk's own type, in the walk's own file:** a closure `{ $0.code }` names no type, so logic reads
  whichever scanned `code` there is. A proof or a counterexample is laid over a walk only when the type the rule's
  first step takes, read from its full demangled name (`RelationalInputType.swift`), is the walk's input type exactly:
  the module-qualified name and every `Optional` (a rule over `T?` says nothing about a walk over `T`). A type logic
  cannot name exactly (generic, private or local, an Objective-C type spelled another way) leaves the walk's verdict.
  Results are matched to the walk by the file's full path and line; a scan that read the rule but could not decide it
  cancels a proof from another scan, while one in which no function matches says nothing.
- **Not read:** a closure with a captured value, a second argument, more than one statement, `await`, a closure in a
  loop over rules, a method with arguments on a built value, a stored property's getter the compiler did not emit,
  and code built with optimization (a memberwise `init` the compiler did not emit is taken as storing its one
  property only at `-Onone`). A walk at a line where two properties have the same name is not changed.
- **Walked only:** `Agrees(with:where:)`, `Injective(except:)` and `NeverOutputs`. They are new walk properties
  (`MapperSpecs.swift`); logic for them is not done.
- **Counts:** the per-function summary of `check` still counts a walk proved by logic under the walked inputs (it
  counts only fewer proofs). Relational results are not in the proof cache: they are decided again on every run.
- **Status:** by design for now. Spec quality not done: that every `#ensures` branch can be reached, and a walk-level
  mutation check (change one output: the walk must fail). Each needs a solver query per branch or per mutant over every
  walked function; the vacuity check of `SpecAudit.swift` stays the only one.

## 24. `@Verify` reads types from the source only (by design)

- **Symptom:** a macro sees syntax, not types. Whether a parameter is `Finite` decides whether `@Verify` writes a
  `verify_<name>()` walk; `@Verify` judges it from the spelling. `String`, `Int`, `Double`, `Date`, `URL`, arrays,
  dictionaries, tuples, closures, optionals of these, `inout` and variadic parameters are surely not `Finite`: no walk.
  Any other name (your own types) gets a walk through `Domain.ofParameterType`, which the compiler resolves to the
  type's `Finite` domain when it has one, and otherwise to an empty sample. So `@Verify` on a function over a type
  of yours that is not `Finite` still has a `verify_<name>()`; it checks nothing and is `bounded`, never `proved`. A
  standard type made `Finite` by your own extension (`extension Int16: Finite`) gets no walk without `over:`.
- **`@Verify get`:** on a property with a setter, `@Verify` goes on the `get` (the compiler does not let a body macro
  on such a `var`). A macro on an accessor cannot add declarations next to the property, so there is no
  `name_requires()` / `name_ensures(_:)`: Scan sees the contract only as the checks in the getter, in a build that
  defines `DEBUG`, where a `#requires` is a trap, not an assumption. A warning says so. Functions written by hand are
  not read either, so such a contract is not proved: move the code into a property without a setter, or a function.
- **Workaround:** none needed: none of this can make anything `proved`: a walk with nothing in it is `bounded`, and
  Scan proves only the peers that exist.
