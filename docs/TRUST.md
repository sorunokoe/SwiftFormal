# What you have to trust

For each tool: what you must trust, what a second piece of code checks, what is only tested, and the limits. Read it
with [MENTAL-MODEL.md](MENTAL-MODEL.md). If this page and the code disagree, the page is wrong: please open an issue.

## Summary

| Tool | Trusted | Checked independently | Tested, not proved |
|---|---|---|---|
| Walk (`Prove`) | Compiler, your `Domain`, the enumerator | Counterexamples replay on the real function | Domain builders |
| Prove (`SFProve`) | Compiler, bit-blaster, your `SymbolicInt` copy, multiplication lemmas | Every `proved`, by `SFCheck` | Encoding and lemmas against real execution |
| Scan and the Gate | Compiler pin, build arguments, SIL reader and semantics, contract pairing, proof cache and stamps, library summaries and models | Every `safe`/`contractHolds`, by `SFCheck`; counterexamples replay | Reader and encoder against the compiler and native runs; LLVM cross-check |
| Editor (`swiftformal lsp`) | Edit and file events; staleness by package | Shows `swiftformal check` results only | — |

## Walk (`Prove`)

- **Trusted:** the compiler (the function that runs is the one it built); your `Domain` (`proved` means "every input
  in that domain", nothing more); the enumerator (it reports the domain size, so you can compare it with what you
  expected).
- **Trusted in `swiftformal check`:** which function a walk counts for is read from the text of its subject. A walk
  counts only for the function its subject names (`"Type.member"`, or an operator, `"Type.=="`). A subject that names
  only a type proves none of its members; its failure is still reported.
- **Checked:** a `counterexample` is a real input to the real function. You can replay it.
- **Tested, not proved:** domain builders (`@Finite`, `.allCases`, products), by unit tests. Without `over:`,
  `@Verify` walks `Domain.ofParameterType`: the type's `Finite` domain, chosen by overload resolution, or an empty
  sample for a type that is not `Finite` (then `bounded`, never `proved`; `InPlaceVerifyTests`).
- **Limits:**
  - A trap (overflow, force unwrap) cannot be caught in-process: it stops the whole run.
  - On macOS and Linux with Swift 6.3 or newer, `Prove(neverTraps:)` runs the walk in a Swift Testing exit test. A
    trap ends only the child process and fails the test with its input (confirmed by calling the function alone on
    it). Such a walk is never `proved` or `bounded`. The child finds the walk by its mangled type name
    (`_typeByName`, trusted to find the same type in the same binary). iOS has no exit tests.
  - Strings are opaque: representative strings give `bounded`, not `proved`. So does a sampled or over-budget domain.

Walk has no model of Swift between you and the answer: the function itself runs.

## Prove (`SFProve`, preview)

- **Trusted:**
  - the compiler;
  - the bit-blaster (Swift's integer rules as bit-vector formulas). The proof shows the formulas are unsatisfiable,
    not that they mean what Swift means;
  - your copy of the body, written with `SymbolicInt`. Your compiled function is not read;
  - with `strategy: .refiningMultipliers`, the lemmas `Sources/SFProve/Refine.swift` adds (`addLemmas`,
    `linkPrefixes`, `linkDistributivity`), each a fact about multiplication modulo 2^w. `SFCheck` takes them as part of
    the formula, so a false lemma could make a false claim `proved`.
- **Checked:** every `proved` needs `SFCheck` to accept the solver's proof. `SFCheck` does not import the solver or the
  bit-blaster. In one process, a formula met again, equal clause for clause, reuses the accepted answer (only when it
  took 2,000 conflicts or more).
- **Tested, not proved:** operators against real Swift (exhaustive at 4 and 8 bits, sampled above); the lemmas against
  the exact multiplier (`lemmasHoldForTheRealMultiplier`: every input at 1 to 3 bits, samples at 4 and 6 bits).
- **Limits:** signed integers (8 to 64 bits) and `Bool` only. Multiplication and division are slow: the 16-bit
  discount example takes about 40 s; at 32 bits it did not finish in minutes. A run that does not finish is `unknown`.
  Not connected to `Prove`, `@Verify` or `Domain` yet.

## Scan (`swiftformal check`) and the Build Gate (`--gate`)

Scan models Swift and library code itself, so its list is the longest.

### Checked independently

- The SAT proof behind each `safe` or `contractHolds`, by `SFCheck`.
- A `mayTrap` or `contractFails` has a concrete input and a replay call you can run.
- A counterexample from the proof cache is encoded again and dropped if it no longer fails.

### Trusted: compiler and build

- The compiler, and that it prints SIL the way the reader expects.
- One pinned compiler (today `Apple Swift version 6.4`). Scan uses one compiler for everything (with `--build`, the
  `swiftc` SwiftPM built with) and names it in its report.
- Any other compiler: the gate fails closed. `swiftformal check` (and `sfverify`) warn and stamp the report
  `"pinned": false`; this page does not cover those verdicts. A new compiler goes through the
  [pin upgrade](guides/pin-upgrade.md) before it is pinned.
- With `--build` (and in `swiftformal check`, also with `--gate`) each module's arguments are SwiftPM's own: from the
  build log, else the command saved for the same Swift Build build description, else Swift Build's plan of it
  (`task-store.msgpack`, an internal format). Trusted: the plan's command for a module is the one that build runs. A
  plan that does not read, or two commands for one module, gives none; the module is then built alone.
- The description is the one of the build the run just ran, read as soon as it exits. Saved or planned commands count
  only while `prior-build-descriptions.txt` stays unchanged after they were read. Trusted: no other `swift build` in
  the same `.build` writes a new description in between (it would first have to take SwiftPM's lock, and load and plan
  the package).
- A linked module's command comes from the plan only when the plan holds it exactly as the run uses it.
  `sfverify --build-log` never reads the plan: the log may come from another build than the folder's last.

### Trusted: SIL reader and contracts

- The SIL reader and our instruction semantics: how each instruction behaves, and where Swift traps.
- A call to `Contract.requiresFailed` or `Contract.ensuresFailed` (what `@Verify` compiles `#requires` and `#ensures`
  into) is a trap, so a broken in-body contract is never proved. Both are matched by their full mangled names.
- A contract is only the `<name>_requires` / `<name>_ensures` that `@Verify` wrote, known by where the debug info
  places them (the expansion buffer of `@Verify`'s peer role, `@__swiftmacro_…6VerifyfMp_.swift`). A function of that
  name written by hand is reported (`ignoredContracts`) and never read. A `#sourceLocation` naming such a buffer makes
  a hand-written function count: not a soundness hole (it is still compiled and proved as the code it is).
- These peers pair with a function by name and exact parameter types, in the order
  parameters, result, `self`. SIL passing (`@out`, `@in_guaranteed`) is ignored and tuples are split. A `mutating`
  method's `ensures` gets the value before the call as `old` and after it as `self`. A getter pairs with
  `<property>_ensures(_ result:)`. A function with any other `inout` parameter gets no `ensures`.
- A type name declared more than once in scope is refused: SIL does not say which one it means. The compiler is
  trusted to say whether an imported module declares a name.

### Trusted: proof cache and verify stamps

A `safe` or `contractHolds` from the proof cache is not checked again; `SFCheck` checked it when it was stored.
Trusted:

- The SHA-256 key covers everything the claim depends on: the function's code and what it can reach, its contracts,
  the module's types, tables and encoder witnesses, the build, and the tool (by the UUIDs of its loaded images; see
  [the scan guide](guides/scan.md#the-proof-cache)). Tests check this change by change; nothing proves it.
- You wrote the entry: entries are read only from a directory no one else can change, as your regular files, opened
  without following links.

`swiftformal check --gate` skips a target that passed before while its stamp matches. Trusted:

- The stamp covers what the check read: the arguments of the target and its linked modules, with every file they
  name; every file in the compiler's dependency list (`-emit-dependencies-path`) outside the compiler's and SDK's
  directories; the manifests, compiler, SDK, tool and flags.
- Compiler and SDK files are fixed by their versions.
- An edit made during the check shows in `stat` (inode, size, modification or change time). A file named only by the
  dependency list must have changed a second before the check started.
- Not covered: a header found by `__has_include` or a search path, added where no argument names a directory (the
  compiler lists only files it read); the type-name probes' own imports (they import the checked modules, with the
  check's arguments).

Stamps are per tool, package and target. `--no-proof-cache` removes both assumptions; `--force` the second.

### Trusted: standard library summaries

`Sources/SFSIL/SILSummaries.swift` describes library calls instead of reading them. Results are unknown unless said
below: a wrong guess about a result cannot break a proof, but a listed call that can trap would. A trap that depends on
such a result is `undecided`, never `mayTrap`.

- Each call never traps, except where the summary encodes the trap: the `Array` calls, and
  `DefaultStringInterpolation(literalCapacity:interpolationCount:)` (checked arithmetic and allocation).
- Reviewed against the Swift 6.4 source of the pinned compiler. The claim covers the SDK's standard library only.
- Each row lists the `[_semantics "…"]` tags the pinned compiler prints on its symbol (checked in the oracle lane
  against `tools/summary-probe/probe.swift`). A call with any other tag is refused. A tag never decides what a call does.
- The code behind each summary, as the pinned compiler and SDK link it at `-O`, is hashed in
  `Scripts/baseline/stdlib-summaries.json` (`Scripts/check-summary-pin.py`, safety net), so it cannot change
  unreviewed. Twelve functions have no serialized body and are pinned by their printed declaration only.
- **Older OS.** At `-Onone` a summarized call goes to the `libswiftCore` of the OS the code runs on (all but
  `_finalizeUninitializedArray` and the default argument of `removeAll(keepingCapacity:)`, which are compiled in). It
  is a release build (`_debugPrecondition` off), and on the oldest supported OS (macOS 13, iOS 16) it is Swift 5.7's.
  Only transparent and `@_alwaysEmitIntoClient` code follows your build settings. On an OS with an older standard
  library than the SDK's, trap behaviour was not reviewed and verdicts do not cover it.
- **Printing** (`"\(x)"`, `String(describing:)`) runs `description` and `debugDescription`. A type with neither is
  printed field by field, active enum payload and tuple element (the `Mirror` fallback), so their printing code runs.
  A `customMirror`, a `TextOutputStreamable`, and a generic type of your module are refused. Trusted: the printer runs
  no other code of yours.
- **Hashing** a `RawRepresentable` with the default `hash(into:)` runs `rawValue`, then hashes the raw value.
- **Allocation.** No allocation of 2^48 bytes or more succeeds. An array, dictionary or set count, or a string
  capacity, that reaches 2^48 is a trap. No input collection is that big, so `count + 1` cannot overflow. Running out
  of memory below that is not claimed.
- **Destroying** an element of a type outside your module runs none of your code.

### Trusted: strings

`SILStrings.swift`, `SILStringFacts.swift`. A string is a 64-bit handle for its value up to Swift's `==`. An ASCII
literal's handle is a hash of its bytes; a collision between two texts in one run makes both unknown. Trusted:

- Two ASCII strings are equal exactly when their bytes are. Non-ASCII literals get unknown handles.
- The parser decodes `string_literal` escapes correctly. A mismatch with the declared UTF-8 length makes the literal
  unknown.
- `count`, `+`, `<`, `hasPrefix`, `hasSuffix`, `lowercased()` and `uppercased()`, run inside SwiftFormal on known
  texts, give what the checked program gets (true for ASCII; `lowercased()` is locale-independent). On other strings
  they give unknowns, limited by facts true of every string (`"" < s` for non-empty `s`, `s.hasPrefix("")`,
  `(a + b).isEmpty == (a.isEmpty && b.isEmpty)`).
- Facts link a result to every text the run records, before or after the call:
  - `s.lowercased()`/`s.uppercased()` is the converted text when `s` is a recorded ASCII text, also for non-ASCII
    strings Swift calls equal to it (U+212A KELVIN SIGN for "K");
  - a standard integer's text (interpolation, `String(n)`, `String(describing: n)`, `n.description`) is its canonical
    decimal, with a leading `-` for negatives and nothing else;
  - an interpolation starts empty, `appendLiteral` appends, `String(stringInterpolation:)` returns it.
- `_findStringSwitchCase(cases:string:)` returns the index of the first equal case, or -1, and never traps (from the
  6.4 source; no serialized body to pin). Cases come from the caller's `[StaticString]` array literal (`string_literal`
  pointers whose declared length is their UTF-8 length). Any other array gives an unknown index in `-1 ..< count`.

### Trusted: collections, ranges and iterators

- **Array literals** (`SILArrayLiterals.swift`). Elements are the values stored before `_finalizeUninitializedArray`,
  under a count of named constants for that literal (`CNFBuilder.namedConstant`: a variable fixed by a unit clause,
  folded by every gate, valid in every model). A count read as an `Int`, or made from one, loses those bits. Trusted:
  `Array.subscript.modify` is the only read call that writes an element and keeps the count (each forgets the elements
  of that count); the storage is written only through element addresses the compiler derives before finalizing (a
  later store is refused).
- **`Array`** summaries are exact on counts and traps (index out of range, `removeLast()` on an empty array, a negative
  `repeating:count:`). Trusted to match the library.
- **`Dictionary` and `Set`** (`SILDictionaries.swift`) have exact counts. Key presence is unknown unless the collection
  is empty. Counts follow the result (`updateValue` returns nil exactly when it inserted; `Set.insert` reports
  `inserted`). The library's three traps are kept:
  - equal keys in a dictionary literal, or in `init(uniqueKeysWithValues:)`: decided exactly when every key is a value
    the function computed, of an integer type, `Bool`, an optional of one, or a type of yours whose `==` logic runs;
    unknown otherwise;
  - `hash(into:)` and `==` that disagree: unknown, so `undecided`, when a key of your type is inserted next to another.

  Trusted: the library's own types hash consistently with `==` (integers, `Bool`, strings, floating point, and
  optionals and arrays of those); the listed calls trap nowhere else; each hashes the key it is given and compares
  only with `==`. Your `hash(into:)` and `==` run on the actual key where the library always hashes it, else on unknown
  keys.
- **Ranges of standard integers** (`SILRanges.swift`): `ClosedRange.contains`, `~=`, `isEmpty`, the partial-range
  initializers and `Array.indices` (`0 ..< count`) are exact (the 8-bit oracle checks them natively). Trusted: a
  `Range` or `ClosedRange` parameter has `lowerBound <= upperBound`. `Range(uncheckedBounds:)` only asserts it, so in a
  `-O` caller an inverted range can reach a proof that relies on it (for example that `upperBound - lowerBound` of a
  `ClosedRange<UInt8>` cannot wrap).
- **`for-in` iterators** (`SILIterators.swift`) of `Range` and `ClosedRange` over standard integers, of `Array` (also
  `enumerated()` and `indices`), and `stride(from:to:by:)`/`stride(from:through:by:)` over `Int` are written from the
  6.4 source (stored properties in declaration order, `next()`). Trusted: this is what the library runs.
  - Traps: the kept `_precondition`s (`Range requires lowerBound <= upperBound`, `Index out of bounds`,
    `Index out of range`, `Stride size must not be zero`) and the checked `+ 1`s. Not `_debugPrecondition`
    (`Range.subscript`).
  - A `ClosedRange` ends with its own `.pastEnd` index, so iterating up to `Int8.max` does not overflow.
  - The bodies are pinned, except `Int`'s `_step` (reached through a witness table). Logic uses 6.4's overflow-safe
    `_step`, which stops at the end of `Int` (checked natively in the zoo). An older OS library that traps there is
    not covered.
  - An iterator's well-formedness (for a `Range`, `lowerBound <= position <= upperBound`) is not assumed: it is a
    candidate loop invariant, checked on entry and on every pass.

### Trusted: floating point

- `SILFloatSummaries.swift` computes exact results with the circuits of `SILFloatArithmetic.swift`, and never traps,
  for: `abs` (sign bit cleared for `Double`, `Float`, `Float16`; `x < 0 ? -x : x` with its overflow trap for a signed
  integer; other types refused), `magnitude`, `bitPattern`, `Double(bitPattern:)`, `Double(Float)`, `Float(Double)`,
  `Double(n)` and `Float(n)` of a standard integer, `min`/`max` on floating point (`y < x ? y : x`, `y >= x ? y : x`,
  IEEE comparisons) and `_roundSlowPath(_:)` (the same switch as the inlined `rounded(_:)`). Trusted: this is what the
  6.4 library runs (bodies pinned; `_roundSlowPath` by its declaration).
- The default environment: round to nearest, ties to even, subnormals kept. Swift cannot change it. C code that calls
  `fesetround` or sets flush-to-zero while Swift code runs is not covered.
- The compiler never fuses multiply and add into one rounding: no `contract` flags, no `llvm.fmuladd`; `a * b + c`
  stays `fmul` and `fadd` at `-O` (checked on the pinned compiler).

### Trusted: closures, existentials, generics, globals and classes

- **Closures** (`SILClosures.swift`, `SILDeinits.swift`). Destroying a closure can run a `deinit` of what it captured.
  A `deinit` runs no code when it only releases, reads, branches and calls its superclass's (a class of the read
  modules, inspected the same way, or exactly `NSObject`, whose `-dealloc` is trusted to run none of your code), or
  calls a reviewed function: `NWPathMonitor.cancel()`, and `Task.cancel()` when no read module registers a
  cancellation callback (`withTaskCancellationHandler`, `onTermination`). Trusted: those calls cannot trap. For each
  other class (or a superclass outside the read modules, under its own name), a scan assumes "deinit of X does not
  trap" and lists it in `assumptions`; its other effects (a global it writes) are not modelled.
- **`Optional.map`/`flatMap`** with a closure literal of the calling function (`SILOptionalMap.swift`) run the inlined
  body when the optional holds a value, else give `nil`. Trusted: the library does exactly that (6.4 `Optional.swift`;
  generic, no body to pin), and a `@noescape` closure is never released, so it runs no deinit.
- **`Array` closure calls** `map`, `filter`, `compactMap`, `first(where:)`, `contains(where:)`, `allSatisfy` and
  `count(where:)` (`SILClosureCollections.swift`): trusted to call the closure once per element, in order, the
  searches stopping at the first match (6.4 `Sequence.swift`, `Collection.swift`, `Array.swift`). An array of unknown
  length is run on 8 elements at most, and such a proof is `undecided` (`bounded`), never `safe`
  ([KNOWN-ISSUES](KNOWN-ISSUES.md) 20).
- **Existentials** (`any P`) follow the closure rule: destroying one destroys the value inside. Their content is never
  read, so printing one (`"\(tracker)"`) is refused.
- **Generic calls** of your modules are read by replacing type parameters with the call's concrete types in the SIL
  text of the body. Trusted: a capitalized identifier equal to a parameter name means that parameter (a parameter
  named like a declared or standard type is refused; quoted text, member names and attributes are not rewritten); a
  non-generic witness table entry is the witness the runtime calls for that type.
- **Integer witnesses** (`IntegerWitness`, `SILGenerics.swift`): `Equatable.==` and `Comparable`'s `<`, `<=`, `>`,
  `>=` on standard integers (and `Bool.==`) use the exact integer comparison. Trusted: the library compares with
  `Builtin.cmp_*` and never traps. Tested in `SILGenericTests`; not pinned (no symbol of their own in the probe).
- **Globals** (`SILGlobals.swift`). A `static let` or global `let` is the value its one-time initializer stores, with
  its traps at every read. Trusted: `swift_once` runs the initializer exactly once, completely, before the first read
  returns; a `[let]` global is stored only by that initializer.
- **Simple classes** (`SILClasses.swift`). A `final class` without superclass, conformance or a `deinit` that runs code
  is read as its stored properties, one object per reference. A second reference is prevented by refusing every way to
  make one (two class parameters, class-typed fields, a class inside another type, globals, casts, `class_method`).
  Trusted: this list is complete for the SIL the pinned compiler prints.

### Trusted: package, SDK and foreign types

- **The Composable Architecture 1.26** (`SILPackageTypes.swift`), reviewed against its source:
  - `ObservationStateRegistrar.access(_:keyPath:)` records the read and returns nothing; `init()`, `==`,
    `hash(into:)` and `_$willModify()` never trap (results unknown).
  - Observation hashes the key path it records, and a key path hashes its captured values with their own
    `hash(into:)`. So `access` is accepted only with a key path literal of the same function that captures no values.
  - Key path and registrar values hold references logic does not see, so they are refused in a build where a `deinit`
    of a read module runs code.
  - `access` can trap in DEBUG only through IssueReporting's fatal-error reporter: it is accepted only when no read
    module mentions `IssueReporter`. The app target, usually not read, is assumed not to install that reporter.
  - The name `ObservationStateRegistrar` is used only when a compiler probe confirms, with the code's imports, that it
    is TCA's type. A module reached without an import is not seen by the probe.
- **`CGFloat`** (`SILCGFloat.swift`) is `struct CGFloat { var native: Double }` (64-bit Apple layout), used only when
  the probe confirms the name means `CoreFoundation.CGFloat` with a `Double` `native` for the target. Trusted: at
  `-Onone`, `CGFloat.init<A: BinaryInteger>(_:)` is `Double(n)` (serialized body, pinned with the summaries), and
  `Comparable` and `magnitude` are its `Double`'s. The rest is `@_transparent` and read from the code.
- **`UUID`, `URL`, `Locale`, `Date`, SwiftUI `Color`, and `Decimal`, `Calendar`, `TimeZone`, `DateComponents`,
  `URLComponents`, `CharacterSet`, SwiftUI `Image` and `Font`** (`SILOpaqueValues.swift`) are opaque 64-bit handles,
  used only when the probe confirms the Foundation (SwiftUI) type and no read module declares the name. Trusted:
  - the calls in `OpaqueValues.table` (listed in [KNOWN-ISSUES](KNOWN-ISSUES.md) 14) never trap and run no code of the
    read modules. An app subclass of `NSURL`, `UIColor` or `NSColor` bridged into these types is outside the claim;
  - `UUID.==` compares bytes, so UUIDs are equal exactly when their handles are; `URL.==` and `Locale.==` are reflexive;
  - each listed getter gives the same result for the same value within one run;
  - destroying a `UUID`, `URL`, `Locale` or `Date` runs none of your code. A `Color` may hold an app colour object, so
    it is refused in a build where a `deinit` of a read module runs code.

  Values these calls make are unknown. `Color.==` is unknown even on one value. A `Date` is the `Double` it wraps; its
  arithmetic and comparisons are Foundation's IEEE operations, checked bit for bit (`SILFoundationValueTests`). Any
  other call on these types is an assumption (below). A trap that depends on them is `undecided`, never `mayTrap`. These
  calls are not in the summary pin; `SILOpaqueValueTests` checks each symbol against the pinned compiler.
- **Objective-C and Kotlin objects** (`SILForeign.swift`). A type is foreign only when a mangled symbol of the read
  modules names it in the compiler's clang module (`__C.Name`, confirmed by the toolchain's demangler); never a name a
  read module declares. Trusted for a foreign object:
  1. Each getter, setter or method returns normally. An Objective-C exception, a Kotlin exception (a Kotlin function
     without `@Throws` ends the process) or a crash in foreign code is not a Swift trap and not covered by `safe`.
  2. It changes nothing Scan reads and calls back into no code of the read modules. Checked: no read class subclasses
     or conforms to the type, directly or through a foreign supertype (compiler probe, `ForeignTypeCheck`); no read
     module implements a same-named member for Objective-C, swaps methods (`method_exchangeImplementations`,
     `class_replaceMethod`, `method_setImplementation`) or uses `@_dynamicReplacement`. A subclass or conformer in an
     unread module is not seen.
  3. Releasing one runs only foreign code, which does not trap. If it holds the last reference to an object or closure
     of yours (a delegate, a block), that `deinit` is assumed not to trap, even in a build where a read `deinit` runs
     code (the closure and existential rule is not applied here).
  4. A `_Nonnull` result (also under `NS_ASSUME_NONNULL`) is not nil. Swift does not check it.
  5. Foundation's `String._unconditionallyBridgeFromObjectiveC(_:)` (nil becomes `""`) and
     `String._bridgeToObjectiveC()` never trap. They are not pinned, like the TCA rows.

  Each foreign call returns a fresh value. A counterexample lists them (`foreignResults`): values some object could
  return, not ones a given object does. A Kotlin `val` returns the same value twice; Scan does not assume it, so a
  report can show a trap your objects never take. `===` is exact. `AnyObject` is the same kind of handle, read only in
  a build where no read `deinit` runs code, and never passed to a foreign call.

### Trusted, and listed per function: assumptions

A framework Scan has no SIL bodies of (Kotlin Multiplatform through SKIE, any closed-source Swift or Objective-C
framework; `SILBinaryTypes.swift`, `SILOpaqueCalls.swift`, `BinaryTypeCheck`).

- **Checked by the compiler:** which modules are binary (`-Rmodule-loading`); an enum's cases (a probe `switch`) and
  whether it is closed (`@frozen`, or no library evolution; an open enum gets one more case, "unknown"); its module
  and payload types; the Swift name of a renamed Objective-C class. An enum the probe cannot show, or whose case the
  list lacks, is not read.
- **Trusted:** the framework the app runs with is the one it was compiled against; the derived `==` of a binary enum
  without payloads compares cases.
- **Assumed:** a call with no body (a function, getter or initializer of a binary module, `onEnum(of:)`, SKIE's
  `ordinal`, the bridging calls, `Double(truncating:)`, an Objective-C method, `==` through `isEqual:`, a Foundation
  call not listed above, a localization call) gives any value of its type, a fresh one each call, and is assumed to
  (1) return: not trap, throw or stop the process; (2) change nothing Scan reads and call no code of the read modules;
  (3) return a valid value. Its arguments must hold no code of the read modules; a closure, an existential, a value of
  a read package type or an `inout` is refused. Localization is assumed deterministic: the same key, table, bundle and
  locale give the same text during one call ([KNOWN-ISSUES](KNOWN-ISSUES.md) 21).
- **Listed:** each call is in the function's `assumptions` (JSON), an `assumes:` line (text) or a `note:` (gate), also
  when a proof uses another function's (inlined, or its contract with `--modular`, also from the cache). So `safe`
  and `contractHolds` mean: for every value these calls may return, provided they return. The summaries count such
  proofs. `--no-opaque-calls` takes nothing on trust: every such call makes its function `unsupported`.
- **Relational walk claims** (`Injective`, `RoundTrip`, `Agrees`, `Matches`) that `check` proves by self-composition
  are decided only after logic proves the rule returns normally, and list the assumptions of both queries
  ([KNOWN-ISSUES](KNOWN-ISSUES.md) 23).

### Tested, not proved

- Reader and encoder against the real compiler and real execution: a test calls the compiler's `Builtin.*` operations
  and compares them with our table, and tests run the same SIL cases natively.
- A second encoder, `SFLLVM` (`Sources/SFLLVM/LLVMEncoder.swift`), reads the LLVM IR of the same build, written from
  the LLVM Language Reference separately from the SIL encoder. In the oracle lane, on the pinned compiler,
  `LLVMVerifier.proveEquivalentToSIL` proves both trap on the same inputs, are undefined on the same inputs and
  otherwise return the same value:
  - 26 small integer functions at `-Onone` and `-O`, where both readers accept them; a changed IR instruction is
    caught (`Tests/SFOracleTests/LLVMTests.swift`);
  - 17 app-shaped functions at `-Onone` (accessors, memberwise initializers, synthesized `==`, enum switches,
    `Optional`, strings, closures, `sret` results), with 10 planted IR changes that must be caught
    (`Tests/SFOracleTests/LLVMBridgeTests.swift`).
- This checks the SIL encoder on those functions only. Only the maintainers' `sfverify --cross-check llvm`
  cross-checks; `swiftformal check` never does.

### Known limits

Scan reads integers, `Bool`, enums, `Optional`, structs, tuples, `inout`, calls (also through a protocol witness), and
generic types at their concrete types. Strings, collections, closures, TCA, existentials, globals, foreign objects and
Foundation values are read only in part: see [KNOWN-ISSUES](KNOWN-ISSUES.md) 6 to 24 and the
[Scan guide](guides/scan.md). Hashers are followed; their contents are unknown.

- **Modules:** other modules of your own packages are linked (`--build`, `check`). SDK modules and remote packages are
  not read.
- **`unsupported`, with the reason:** other classes; a `~Copyable` type with a `deinit`, or a type containing one;
  calling a closure that is not a literal of the function; opening, casting or boxing an existential; `async`; `for-in`
  over strings, dictionaries, sets, your own `Sequence` types, or `stride` over a type other than `Int`; code from
  unread modules; a generic function on its own (for all T), calls with non-concrete types, conditional conformances,
  and library generics without a summary; with `--no-opaque-calls`, any call with no body.
- **Foreign objects:** creating, casting (`as?`), passing a block to, or printing one, `@objc` members of your
  classes, and types your classes subclass or conform to stay `unsupported`.
- **Classes:** `begin_access [dynamic]` is read only where it cannot fail inside the function. A function with a class
  parameter is never `safe` (its caller may hold an access).
- **Loops** in the scanned function use the invariant `true` at each header. `safe` or `contractHolds` holds for runs
  that end; termination is not proved. Loops in called functions are `unsupported`.
  - `for-in` over a range, closed range, array, `enumerated()`, `indices` or `Int` stride uses the same proof. Array
    elements are unknown, so safety that depends on them, or on the loop variable versus a count
    (`for i in a.indices { a[i] }`), is `undecided`.
  - If that fails, a function with one loop and no `ensures` is tried by 2-induction (`SILUnwind.swift`): two header
    visits unrolled without a trap, and a safe returning iteration implies a safe next one. Also partial correctness.
  - Then loops are unrolled to find a trap (`--unwind`, 8 header visits by default). A trap found is a real run; none
    found proves nothing and stays `undecided`.
- **Throwing** (`throw`, `try`, `try?`, `do`/`catch` between your functions) is read. A throw is not a trap; the error
  is held but not read; `_ensures` holds on normal returns. Destroying an `any Error` box must run no code of yours.
- **Floating point:** a `Double`, `Float` or `Float16` is its IEEE 754 bit pattern. Exact: comparisons, classifications
  (`isNaN`, `isFinite`, ...), sign operations, bit casts, `+`, `-`, `*`, `/`, roundings to integral, conversions to and
  from integers and between widths. A NaN's sign and payload are unknown (quiet unless an operand is a signalling NaN,
  which LLVM may pass on), so a trap that depends on them is `undecided`. `squareRoot()`, `truncatingRemainder`, fused
  multiply-add and IEEE `minimum`/`maximum` give unknown results.
- **Configurations:** by default a verdict holds in debug and release (`--config both`): a failed `assert` is a trap,
  and so is a trap that appears once release removes an `assert` and its condition's side effects. `-Ounchecked` is
  not covered.
- **Fit:** bit, index and numeric kernels (about a quarter to a third of swift-collections' low-level targets), not
  app plumbing (0 to 2%).

## The editor (`swiftformal lsp`)

The language server proves nothing itself. Each lens, diagnostic, hover and Test Explorer item is an entry of a
`swiftformal check --json` report it runs as a child process, so all of Scan and Walk above applies. A `✓` lens means:
the last finished check proved this, for the configurations it names, about the file's text when that check started,
and nothing the server was told about since could have changed it.

- **Trusted:**
  - The editor reports edits (`didChange`, `didSave`) and outside changes (`workspace/didChangeWatchedFiles`).
  - A verdict shows as proved only while its file's current text (open buffer, else disk) has the SHA-256 the check
    read, so an unreported change to that file is caught. An unreported change to *another* file it depends on is
    caught only if it happened during a check (size, time and inode are compared before and after).
  - Staleness by package is fine enough: an edit makes stale every verdict of its package and of every package whose
    dependency closure (`swift package dump-package`) holds it. An unknown closure makes everything stale.
- **Not claimed:** unsaved text (never checked); code the last check did not read; code after an edit. `⚠ stale` and
  `? unchecked` are never proofs; a stale verdict comes back only from a check of the new text. A
  `~ walked … (sample)` lens is evidence, not proof.

## The trusted core is kept small and independent

The SAT step has a small independent checker. The encoding of Swift and the library models do not; tests and review
check them. Every wrong `safe` or `contractHolds` found so far came from the encoding, the SIL reader or a hand-written
model, never from the solver. A proof kernel like Lean's would not catch those: Swift has no formal semantics to check
against.

`SFCheck` re-checks every solver answer, so only `SFCheck` has to be right. In one run, a formula equal clause for
clause (same inputs and budget) to one whose proof `SFCheck` accepted, or whose counterexample satisfied it, reuses
that answer (`FormulaMemo`, only for answers that took 2,000 conflicts or more). Two gates keep the core honest:

- **Independence** (`Scripts/check-layering.py`): `SFCheck` depends only on `SFCNF` (the shared alphabet) and imports
  only `Foundation`, `Swift` and `SFCNF`, never `SFSAT`, `SFBV` or `SFProve`. In `SFProve` every `case .unsat` needs a
  call to `LRATChecker.check` or `RUPChecker.check` in the same file. This is a source rule, not a proof;
  `SelfVerificationTests` and the checker fuzzing in `SoundnessZooTests` exercise it.
- **Size** (`Scripts/measure-trust.py`, `Scripts/check-ratchet.py`): code lines (non-blank, non-comment) of the trusted
  pieces are in `Scripts/baseline/quality.json`. CI fails if one grows by more than 10% without a new baseline and a
  note here saying why.

| Trusted piece | Code lines | Growth notes (each approved by the owner) |
|---|---|---|
| `SFCheck` | 289 | 282 → 289 (2026-11-09): reads an original clause only when a proof first names it, so cost follows the proof. Same results and errors as before (`LRATLazyLoadTests` compares both on random proofs and mutations), except an invalid literal in a clause the proof never names is no longer an error. |
| Compiler pin | 45 | — |
| SIL semantic model | 548 | 223 → 272 (2026-11-07): `int_ctlz`, `int_cttz`, `int_ctpop`, `int_bswap`, `assumeNonNegative`, plain `trunc`/`zext`/`sext`, tested against Swift's integer APIs and `Builtin.*`. → 546 (same day; about 80 were estimated): floating point in `S0Float.swift` (16 `fcmp` predicates, sign operations, bit casts, the `fptosi`/`fptoui` range check, classifications), each written as an integer interpreter and a circuit, compared with each other and with `Double`/`Float` in `S0FloatTests`. → 548 (2026-11-08): `S0FloatInstance` keeps its builtin name. |

Floating-point arithmetic is trusted but not counted: the circuits for `fadd`, `fsub`, `fmul`, `fdiv`,
`int_trunc`/`floor`/`ceil`/`round`/`rint`, `sitofp`/`uitofp`, `fpext`/`fptrunc` and the value of `fptosi`/`fptoui`
(`Sources/SFSIL/SILFloatArithmetic.swift`, `SILFloatEncoding.swift`: 383 code lines), and `SILFloatSummaries.swift`
(128 code lines, pinned). They are checked bit for bit against hardware in `SILFloatArithmeticTests` (every operation
at 64 and 32 bits on edge and random operands, every `Float16` value through roundings and conversions), and against
native runs in `SILFloatSummaryTests` and the Scan zoo.

## Not claimed by any tool

- The compiler is correct.
- Swift has a formal definition. It does not, so our encoding matches Swift by tests and review, not by proof.
- With `--modular`, more than the engine's own soundness: a proof that lists `usesContracts` also rests on those
  callees' proofs in the same run, and on the contract replacing the call (`SILEncoder.summarize`: the call traps
  unless its arguments are valid and satisfy `requires`; only then is its result assumed to satisfy `ensures`).
  Without `--modular` no verdict uses a contract in place of code.
- That a contract stands for every promise. A `contractHolds` proves `requires` ⇒ `ensures`, nothing a walk states
  besides (a table, injectivity): `swiftformal check` calls a function "proved by logic" only when every walk linked
  to it also proved its own promises. A `@Verify` contract logic cannot read, or that does not pair, is never dropped:
  the function is `unsupported` (`contract not read`), or `contractFails`, never `safe` or `contractHolds`.
- Anything outside the domain, the contract, or the supported part of Swift.
- Agreement with a second encoder, unless you ask for the LLVM cross-check.

### The LLVM cross-check

`sfverify --cross-check llvm` proves, for each `safe` or `contractHolds` function, that the LLVM IR encoding (`SFLLVM`)
means the same (same traps, undefined behaviour and result), and reports `crossCheck`. `--cross-check llvm-strict`
keeps only verdicts both agree on. The IR reader reads less of Swift, so many functions are `unread`, with the reason
in `crossCheckReason` ([ADR 0008](decisions/0008-sfllvm-status.md)). An `agrees` also rests on:

1. **The bridge** (`Sources/SFLLVM/LLVMBridge.swift`), which predicts Swift's memory layout from the ABI. Each
   prediction must fit the IR header exactly (piece sizes, `dereferenceable(N)`, `sret`); a misfit is `unread`. Enums
   that may use spare payload bits (an `Optional` of a struct holding a string, a multi-payload enum of strings) are
   refused. Inputs range over SIL's domain (`SILFunction.inputAssumption`: real enum tags, array counts below 2^48),
   which is SIL-side code.
2. **Handles.** A handle (`String`, a closure, an array's count) enters the IR as a fixed one-to-one encoding into its
   words, nonzero where Swift keeps them nonzero. At `-Onone` the IR only moves the words, compares them with zero
   (`nil`) and reference-counts them; a call that reads them (library string or array functions) or a load through them
   is `unread`. IR arithmetic on the words would be compared on the artificial encoding and could only show as
   `disagrees`.
3. **Reference counting.** `swift_retain`, `swift_release` and their bridge-object forms are taken to change nothing
   compared. A release that runs your `deinit` is Scan's blind spot too, closed by refusing such types. Both readers
   share this assumption; the cross-check does not check it.
4. **Unread:** results written through an address (`inout`, mutating methods, setters, `@out`), throwing functions,
   and functions with class references.

## Where the numbers above come from

Experiment logs and the design notes:
[pure-Swift verifier design](../archive/design/specs/2026-11-05-pure-swift-verifier-design.md) and
[product design](../archive/design/specs/2026-11-05-swiftformal-product-design.md). The coverage figure:
[TRIZ and Swift semantics research note](../archive/research/2026-11-05-triz-and-swift-semantics.md). How-to pages with
the same limits: [Walk](guides/walk.md), [Prove](guides/prove.md), [Scan](guides/scan.md), [Gate](guides/gate.md).
