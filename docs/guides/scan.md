# Scan: can this function trap? (`swiftformal check`)

Scan ("the logic") is the first step of `swiftformal check`. It compiles your Swift with the real `swiftc` and reads
the SIL. For each function it can read, it either **proves it cannot trap for any input** or prints **one concrete
input that traps** (file:line:col and a replay call). It also proves each `@Verify` promise (`#requires` and
`#ensures`) for every input. A second checker (`SFCheck`) confirms each proof. No promise is needed to find traps.

## Usage

```
swift build -c release --product swiftformal                                  # once, in the SwiftFormal checkout
swiftformal check --scan .:MyTarget --no-walks                                # a SwiftPM target, logic only
swiftformal check --scan .:MyTarget --format xcode                            # Xcode-style lines
swiftformal check --scan .:MyTarget ... --json | --format sarif|github | --strict | --budget N | --mutate
swiftformal check --scan .:MyTarget --at Sources/MyTarget/Score.swift:42      # only the function on that line
swiftformal check --scan .:MyTarget --symbol 'Score.clamp(_:)'                # only that function
swiftformal check --build-log <log or DerivedData> --target MyApp             # an app target a build compiled
```

**Exit codes:** 0 ok, 1 a promise is broken or a linked walk did not report (with `--strict`, also something may
trap), 2 usage or build error.

| Option | Effect |
|---|---|
| `--scan <dir>:<target>` | Build a SwiftPM target, reuse its exact flags ([below](#how---scan-gets-the-flags)). Repeatable. |
| `--build-log <file> --target <name>` | Flags from a build that ran ([below](#on-your-own-build---build-log), [Xcode](#xcode-and-tuist-app-targets---build-log-on-xcodes-logs)). |
| `--at <file>:<line>`, `--symbol <name>` | Check one function. |
| `--budget N` | Solver conflict budget per function. |
| `--strict` | "May trap" also exits 1. |
| `--no-opaque-calls` | Refuse calls with no body instead of [assuming them](#types-from-binary-frameworks). |
| `--mutate` | [Is the promise strong enough?](#is-my-promise-strong-enough---mutate) |
| `--xcode`, `--format sarif\|github`, `--json` | [Editor](#in-your-editor-no-language-server), [CI](#in-ci-sarif-and-github-annotations), [JSON](#the-json-report---json-schema-version-1) output. |
| `--emit-tests <dir>` | [Counterexamples as tests](#replaying-counterexamples-as-tests---emit-tests). |
| `--proof-cache <dir>`, `--no-proof-cache` | [Proof cache](#the-proof-cache) location, or none. |
| `--jobs N` | [Packages scanned at a time](#an-app-made-of-many-packages). |
| `--gate` | The build check of `@Verify` functions ([Gate](gate.md)). |

`swiftformal check --help` lists the rest (walks, `--show-unchecked`, `--show-proved`).

**Maintainer-only options.** A few options named below (`--modular`, `--unwind`, `--config`, `-O`, `--stats`,
`--cross-check`, `--paranoid`, `--confirm`) belong to `sfverify`, the internal scanner the maintainers use for
benchmarks and the engine's tests. It is not a product, and `swiftformal check` has none of them.

**`--at` and `--symbol`.** `--at <file>:<line>` picks the innermost function whose body, declaration, attribute or
doc comment holds that line (a closure belongs to its function). `--symbol` takes the name as the report prints it, or
`Type.member` with argument labels. Exactly one function must fit: several are listed, a promise function `@Verify`
wrote (`f_requires`) says to select `f`, and no match exits 2. The module is still compiled whole; only the other
proofs are skipped.

### How `--scan` gets the flags

- It builds in the package's own `.build` (the one `swift build` and `swift test` use) and reuses the exact flags
  (`-package-name`, `-D`, experimental features, dependency modules). Nothing is compiled twice. SwiftFormal's files
  go in `.build/swiftformal`. Scan from the package you build and test, so there is only one `.build`.
- A build that compiles nothing prints no command. So the last one is saved in `.build/swiftformal/args/<target>.args`
  with Swift Build's build-description id, and reused only while that id is the same (a new setting, an added file or
  another requested target changes it).
- Otherwise the command is read from Swift Build's plan
  (`.build/out/Intermediates.noindex/XCBuildData/<id>.xcbuilddata/task-store.msgpack`). Linked local modules get their
  command this way too (six linked modules: 4 s instead of 21–52 s when nothing changed). The plan is used only when no
  build with another description ran since the scan's own build, and, for a linked module, only when it holds the
  target's command exactly. A module with two commands (two architectures) gets none from it.
- Native build system: the command comes from `debug.yaml`.
- If nothing applies, or another task printed into the command line, the target is rebuilt one task at a time.
- The package must build for macOS (Scan runs on a Mac). A package that declares only iOS fails at the build step.

### An app made of many packages

Scanning each leaf package on its own builds the shared dependencies (TCA, a design system, ...) once per package.
Scan through one package that depends on all of them (an umbrella package) instead: same verdicts, dependencies built
once ([PERFORMANCE](../PERFORMANCE.md#scanning-a-multi-package-app)).

```
swiftformal check --scan App/Packages:Settings --scan App/Packages:Profile
```

`swiftformal check` scans different packages in parallel: at most `--jobs <n>` (default: half the cores, at most one per
2 GiB of memory). Targets of one package run one after another (SwiftPM locks `.build`). Packages with different
compilers are not proved at the same time. Output and exit code are the same as with `--jobs 1`. Without `xcrun`
(Linux), one package at a time. Trade-off: an umbrella package builds dependencies once but scans serially.

## Promises (`@Verify` contracts)

```swift
import SwiftFormal

@Verify
func clamp(_ x: Int8, _ lo: Int8, _ hi: Int8) -> Int8 {
    #requires(lo <= hi)                       // optional
    #ensures { $0 >= lo && $0 <= hi }         // optional
    ...
}
```

`@Verify` writes the promise as two functions next to `clamp` (`clamp_requires`, `clamp_ensures`), in every build
configuration, and Scan proves those on the compiled function for every input: `contractHolds`, or `contractFails`
with one input. Arguments: the parameters, then the result (if any), then `self` (for a method).

- **Only `@Verify` counts.** Scan knows its functions by where the compiler puts them (the `@Verify` expansion). A
  function of the same name written by hand is not read: it is listed under `ignoredContracts`, the verdict is about
  traps only, and `check --gate` fails on it. Write the promise in place with `@Verify`, `#requires` and `#ensures`.
- The body checks `@Verify` adds exist only where `DEBUG` is defined (unless `checks: .always`); the verdict does not
  depend on them. A broken promise shows as `ensures failed: …` with them, `ensures is false: …_ensures …` without.
- **`mutating` methods:** `#ensures { old in altitudeText == old.altitudeText }` (`self` is after the call, `old`
  before; `#requires` sees `self` before). No walk exists for these; Scan proves them for every `self`.
- **Other `inout` parameters:** no `ensures` (it would see the old value). Return the new value instead.
- **`Void` functions** (not `mutating`): no `ensures`.
- **Computed properties:** `@Verify var isLoading: Bool { #ensures { $0 == (state == .loading) }; … }` pairs with the
  getter. On a property with a setter, `@Verify` goes on the `get` and Scan sees only the checks in the getter (in a
  `DEBUG` build), so the promise is not proved: move the code into a read-only property or a function.
- **Rules called through a protocol extension:** with `extension Rule { func execute() -> Output { body } }`, a call
  `LevelScore(input: level).execute()` is read as `LevelScore`'s `body`, so a promise on a caller covers the rule's
  code. A generic conforming type (`Box<T>: Rule`) stays `unsupported`.

### Deep call chains

Scan inlines calls, at most eight levels deep. Deeper is `unsupported` ("deep call chain"); a large call tree can be
`undecided` (budget). The maintainers' `sfverify --modular` proves such functions again with each proved callee
replaced by its promise; `swiftformal check` does not.

## What Scan reads

| Reads | Notes |
|---|---|
| Integers, `Bool`, enums, `Optional`, structs, tuples | Also types nested in extensions. |
| Integer ranges | `Range`, `ClosedRange`, partial ranges; `contains`, `~=`, `case lo...hi:`, `isEmpty`. |
| Arrays | Count exact, `indices` is `0 ..< count`. Elements unknown, except an array literal your code builds, while unchanged. |
| Dictionaries, sets | Count exact; keys and values unknown. |
| Strings | [Text](#text). |
| `UUID`, `URL`, `Locale`, `Date`, `Decimal`, `Color`, … | [Foundation values](#foundation-values). |
| `Double`, `Float`, `Float16`, `CGFloat` | [Exact IEEE 754](#floating-point). |
| Generic functions of your modules | At the types they are called with. |
| `for-in` | Over integer ranges, arrays, `enumerated()`, `indices`, `Int` strides ([Loops](#loops)). |
| Classes | [Simple ones](#classes); [Objective-C and Kotlin](#objective-c-and-kotlin-objects) as opaque references. |
| `static let`, global `let` | The value its one-time initializer stores. `static var` is not read. |
| Closures | A closure literal that cannot throw, passed to `Optional.map`/`flatMap` or to a helper of your module that calls it. |
| `map`, `filter`, `compactMap`, `first(where:)`, `contains(where:)`, `allSatisfy`, `count(where:)` | With such a closure: exact when the count is known (a literal) or at most 64 by a `#requires`; otherwise solved for up to 8 elements and reported *bounded (n ≤ 8)*, never proved ([issue 20](../KNOWN-ISSUES.md#20-closures-over-arrays-unrolled-up-to-a-bound-by-design-for-now)). |
| Types and calls of binary frameworks | [Read with assumptions](#types-from-binary-frameworks). |

**Not read** (*unsupported*, with the reason, never guessed): calling other closures, opening protocols, other classes,
`for-in` over other sequences, `@Observable` and `ObservableObject` classes.

Coverage: kernels in [`archive/research/2026-11-05-triz-and-swift-semantics.md`](../../archive/research/2026-11-05-triz-and-swift-semantics.md)
§6g. On a real iOS app (SwiftUI and TCA), about 4 in 10 functions were read, almost all trivial without a promise.

### Text

Each ASCII literal in your code (`"Fairway"`, `""`) is a known string; any other string is "some string", equal only
to itself. `==` and `isEmpty` are exact on every string; `count`, `+`, `<`, `hasPrefix`, `hasSuffix`, `lowercased()`
and `uppercased()` are exact on texts from your code. Counterexamples show real text (`"a"`, `"b"`, … stand for any
non-literal strings):

```
✗ changeTemperature(_:) — ensures failed: … when text = "a", self = ValuesState(data: .loading, …, temperatureText: "c")
```

Also known:

- `s.lowercased()`/`uppercased()` is empty exactly when `s` is, and is the converted literal when `s` is one of your
  ASCII literals (so `switch input?.lowercased() { case "home": .app … }` meets `input != "home" || result == .app`).
- The text of an integer (`"\(n)"`, `String(n)`, `String(describing: n)`, `n.description`) is its decimal form: `"18"`
  exactly when `n == 18`, never `"F"`, `""`, `"007"` or `"-0"`.
- An interpolation with ASCII literal parts (`"-\(n)"`, `"\(n) km"`) equals one of your literals only where the
  literal parts line up: `"-\(n)" == "-0"` exactly when `n == 0`, and `"\(n) km"` is never `"Unknown"`.
- `NSLocalizedString("key", comment:)`, `String(localized: "key")` and a body-less `"key".localized(…)` of your app are
  an unknown text of their key and arguments, the same for the same key. Two cases that pick the same key are a
  `contractFails`; a contract that needs two keys to differ is `undecided`. The function's `assumptions` list that
  localization is deterministic. The catalogues themselves are checked by
  [`swiftformal strings`](#localization-catalogues-swiftformal-strings).
- `String(format:)` with a literal format: `%d`/`%i` print an `Int32` or narrower, `%ld`/`%lld` an `Int`, `%@` the
  string. Other conversions print some text. A format that reads more arguments than it is given, or a number as `%@`,
  is `mayTrap`. A format that is not a literal is an assumption (`unsupported` with `--no-opaque-calls`); `%*d` and an
  `any CVarArg` argument are `unsupported` ([issue 21](../KNOWN-ISSUES.md#21-text-localization-keys-stringformat-and-interpolations-by-design)).
- A `String` raw-value enum's `init(rawValue:)` and `==`, `!=`, `~=` on raw-value enums are exact. `@objc` enums are not read.

Not known (the contract is `undecided`, never wrongly broken): length or order of non-literal strings, equality of two
such strings (also after `lowercased()`), text with two unknown parts and no literal between them (`"\(a)\(b)"`), what
`%f` prints, and non-ASCII literals (`"é"` has two encodings Swift calls equal).

### Foundation values

`UUID`, `URL`, `Locale` and SwiftUI `Color` are identities: Scan knows only which values are the same. Accessors,
initializers, synthesized `==` and `hash(into:)` of a state holding them are read, and traps show stand-ins
(`id: <UUID 1>`).

- `UUID` equals another exactly when it is the same value (`result == id` is proved; `a.id == b.id` is not).
- A copy of a `URL` or `Locale` equals itself; two others may or may not be equal. `Color.==` is unknown.
- Values a call makes (`UUID()`, `URL(string:)`, `uuidString`, `hashValue`) are unknown; a getter gives the same
  result for the same value.
- A `Date` is the `Double` it wraps: `addingTimeInterval`, `+`, `-`, `timeIntervalSince`, comparisons are IEEE
  arithmetic on it (a due date one day early is found; a NaN date is not equal to itself).
- `Decimal`, `Calendar`, `TimeZone`, `DateComponents`, `URLComponents`, `CharacterSet`, `Image` and `Font` are held like
  a `URL`. `Decimal` arithmetic is `unsupported` (reading it as `Double` would prove what is false).
- Calls listed in [KNOWN-ISSUES](../KNOWN-ISSUES.md#14-scan-holds-foundation-values-but-reads-only-a-few-calls-on-them-by-design-for-now)
  are read. Any other call on these types returns any value and is an assumption, `unsupported` with
  `--no-opaque-calls` ([issue 22](../KNOWN-ISSUES.md#22-foundation-values-dates-decimals-and-calls-that-are-assumed-by-design-for-now)).

### Floating point

`Double`, `Float` and `Float16` are IEEE 754 bit patterns, computed like the hardware: round to nearest even,
subnormals, signed zero, overflow to infinity (`x / 0` is an infinity, not a trap). Exact: arithmetic, comparisons,
`isNaN`, `isFinite` and other classifications, `rounded()`/`rounded(_:)` with every rule, `abs`, `magnitude`, `sign`,
`min`/`max` (`min(.nan, 1)` is NaN, `min(1, .nan)` is 1), `bitPattern`, `Double(n)`, `Double(Float)`, `Float(Double)`,
`Int(x)`. So `Int((abs(x) * 10.0).rounded())` is refuted with a real input (NaN, infinity, or above 9.2e17).

- Open on purpose: sign and payload of a NaN result (hardware and constant folder disagree). A trap that depends on them
  is `undecided`, never `may trap`.
- Not read yet (unknown result): `squareRoot()`, `truncatingRemainder(dividingBy:)`, `addingProduct`.
- A NaN input other than `Double.nan` is replayed with its bits (`Double(bitPattern: 0x...)`).
- **`CGFloat`** is the `Double` it wraps on 64-bit Apple platforms (shown as `CGFloat(1.5)`). It is used only after a
  compile probe confirms that `CGFloat` is CoreFoundation's and wraps a `Double`; on 32-bit targets (a `Float`) it stays
  *unsupported*.

### Loops

1. Prove with nothing assumed at the loop header. `safe` then holds for every run that ends; termination is not proved.
2. Else, for one loop and no `ensures`: 2-induction (proves `repeat … while` and `-O` loops).
3. Else, unroll up to 8 header visits to find a trap: a trap found is real (`may trap`); none
   found is `undecided`.

### Classes

A `final class` with no superclass, no protocol conformance, and readable stored properties is read as its properties,
if each object has one reference: a function may take one as a parameter, create objects (`Counter()`), call their
methods and return them.

- *Unsupported* (a second reference is possible): two class parameters; a class in a struct, tuple, `Optional` or
  array; a class-typed property; a global; `weak`/`unowned`; a subclass; a `deinit` that runs code; passing an object
  while one of its properties is being modified; `@Observable` and `ObservableObject`.
- A function that only uses objects it creates can be `safe`. One that takes an object (also `self`) is never `safe`:
  a caller could hold an open access, so a proof is `undecided` ("exclusivity"); a trap is still `may trap`. Contracts
  on such functions are refused.
- Destroying an escaping closure may run the `deinit` of an object it captured. When a `deinit` of your modules can
  trap or calls code, the verdict lists "deinit of X does not trap" among its assumptions (`unsupported` with
  `--no-opaque-calls`).

### Objective-C and Kotlin objects

Objective-C classes and protocols (SDK classes, Kotlin Multiplatform exports such as `DomainItemData`) are opaque
references: held, passed, stored, released, compared with `===`.

- Their getters, setters and methods are not read. Scan assumes they return normally with any value of the declared type
  (integers, `Bool`, floating point, such objects, optionals of those, `String` from `NSString`). `_Nonnull` is not nil;
  `nullable` may be.
- Each call returns its own value: `x.index >= 0 && x.index < 3 ? a[Int(x.index)] : 0` may trap.
- A trap needing a foreign value is shown with it (`input.index returned 7`, `foreignResults` in the JSON), without replay.
- `==` of two objects (`isEqual:`) is either answer, an assumption. Kotlin enums and sealed classes are read as the
  SKIE enums of the framework ([below](#types-from-binary-frameworks)).
- Refused: types your classes subclass or conform to, member names your modules implement for Objective-C, creating
  objects, casts (`as?`), blocks, and printing.

Assumptions: [TRUST.md](../TRUST.md).

## Debug and release builds

A release build removes `assert` and the side effects of its condition, so a function can be safe in one build and trap
in the other. By default a `-Onone` scan also compiles with `-assert-config Release` and re-checks functions whose code
differs: `safe` means safe in both, and a release-only trap says `in a release build (-assert-config Release): …`.

## The proof cache

`swiftformal check` and `swiftformal check --gate` reuse each checked answer while nothing it depends on changed.
Compiling and reading still run; only solving is skipped.

- **Where:** `<package>/.build/swiftformal/proofs/scan-v1/`, one JSON file per claim (under each `--scan` package).
  `--proof-cache <dir>` moves it; `--no-proof-cache` disables it. A `--build-log` scan has no cache unless given
  `--proof-cache`. (`--cache-dir` is unrelated: it keeps build commands.) Runs may share a cache: entries are written to
  a temporary file and renamed.
- **Kept:** `safe` or `contractHolds` whose LRAT proof `SFCheck` accepted, and replayed counterexamples (replayed again
  before use, dropped if they no longer fail). **Never kept:** `undecided`, `unsupported`, loop proofs.
  `check --gate` reads and writes the same cache.
- **A hit still runs** promise-shape checks, the exclusivity check and the debug/release merge.
- **The key** covers the function and all it can reach (callees, contracts, witnesses), the module's types, tables,
  globals and flags, the budget class, the build (compiler, SDK, target, arguments, optimization, assert config,
  linked modules), and the tool (the Mach-O UUIDs of its loaded images; no UUID or no Mach-O means no cache). Debug and
  release never share an entry. A function with no key is proved normally (`unkeyed`). Editing one function re-proves
  only claims that reach it; a new type or table entry changes every key of the module, a rebuilt tool every key.
- **Trust:** the cache directory must be yours and writable only by you, and every parent owned by you or root and not
  writable by others (unless sticky, like `/tmp`); else it is ignored (`trusted: false`). Entries must be regular files
  of yours, opened with `O_NOFOLLOW` and checked with `fstat`; others are skipped (`rejected`). I/O errors mean proving
  normally (`ioErrors`).
- **`check --gate` stamps** (`<cache>/verify-v1/`): a target that passed is skipped while its stamp matches; its
  diagnostics end `(unchanged since it last passed)`. The stamp hashes the target's arguments and every file they name,
  the manifests and `Package.resolved`, linked local modules, compiler, SDK, triple, tool, `--strict`/`--budget`, and
  every file in the compiler's dependency list (`-emit-dependencies-path`) outside the compiler's and SDK's directories.
  No stamp for relative paths, VFS overlays, a compile that cannot list what it read, or a listed file that is gone.
  Everything is hashed again (with `stat`) after the check; the stamp is written only if nothing changed, files first
  seen in the dependency list changed at least a second before the check, every module linked, and the target passed.
  Same trust rules as entries. `--force` checks every target; `--no-proof-cache` ignores stamps. What is not covered:
  [TRUST.md](../TRUST.md).
- **Report:** `N from the proof cache` per module; the JSON has `proofCache` and `fromCache: true`.

## Is my promise strong enough? (`--mutate`)

A promise that says too little still holds when the code is broken. `--mutate` re-checks each holding promise on
small SIL edits of the function: skip a call that changes `self`, drop a write to `self`, return another value, negate a
branch, swap two neighbouring `switch` cases, change an operator (`<` to `<=`, `+` to `-`) or a constant by one. An edit
that the promise accepts but that changes the result on some input meeting `requires` makes it **weak**:

```
✓ contract holds ValuesState.discardEdit()  (ValuesState.swift:92)
      weak: the contract still holds when the call to ValuesState.show(_:) is skipped (ValuesState.swift:94:35)
            the function and the edited one may differ on self = ValuesState(data: .loaded(ValuesData(altitude: 0, …)), tile: .applied, altitudeText: "a", temperatureText: "a")
            (the two may differ only in what String.init(_:) returns, which logic does not model)
```

The input shows where the promise is silent. Make it say more, or accept a partial promise.

- An edit proved equivalent to the function is not reported. If the difference depends on unmodelled results (here
  `String(_:)`), it is listed as `may differ` with the reason.
- No effect on verdicts, exit code, or output without the flag.
- Limits: 16 edits per function, 100,000 conflicts per check, 30 s per function. Only promises with an `ensures`, on
  functions without loops, in the first build configuration (including the `@Verify` closure, without positions). The
  checks `@Verify` writes (`#requires`, the `#ensures` closure) are not edited.
- JSON: `weakContract` per function, `summary.weakContracts`.

## On your own build: `--build-log`

`swiftformal check --build-log <file> --target <T> [--scratch-path <dir>] [--cache-dir <dir>]` reads the target's
exact compile command from the log of a build that ran (`swift build -v`, `xcodebuild`, or Xcode's activity logs)
instead of building it.

A build that compiled nothing has no command, so the command saved by an earlier scan of the same build description is
used. On the first scan of an up-to-date target there is none, and the scan stops and says to touch a file of the
target and build again. Scan never guesses flags (other `-D` conditions mean other code).

## Xcode and Tuist app targets: `--build-log` on Xcode's logs

App targets have no `Package.swift`. Xcode's log has the same `swiftc` lines, so `--build-log` reads them:

```
xcodebuild -scheme MyApp build > build.log
swiftformal check --build-log build.log --target MyApp                       # xcodebuild's output
swiftformal check --build-log ~/Library/Developer/Xcode/DerivedData/MyApp-abc --target MyApp
swiftformal check --build-log path/to/Logs/Build/<id>.xcactivitylog --target MyApp
```

- `--target` is the module name (`PRODUCT_MODULE_NAME`).
- With DerivedData, Scan takes the newest activity log that compiled the module, whatever its configuration or
  destination. For a specific build, pass its log.
- Imported targets of the same build are linked (with a single log file, only if `--scratch-path` names DerivedData).
  A dependency missing from an incremental log is taken from another log with the same `-target` and `-sdk`; if none,
  a warning says "module X could not be linked" and functions using its types are `unsupported`.
- A build that compiled nothing has no command: change a file and build. The command is saved next to the log (or in `--cache-dir`).
- Tested with `xcodebuild` on a two-target package. Tuist uses `xcodebuild`, so it should work the same; not tried.

### Kotlin Multiplatform and Tuist apps, built for the simulator

Scan needs only the Swift compile commands. Build for the simulator against a headers-only framework and let the link fail:

```
xcodebuild build -workspace MyApp.xcworkspace -scheme MyApp \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 \
  -derivedDataPath /tmp/myapp-dd <the setting that skips the Gradle build phase, e.g. SHAREDKT_SKIP_GRADLE=YES>
swiftformal check --build-log /tmp/myapp-dd --target MyApp --scratch-path /tmp/myapp-dd --cache-dir /tmp/myapp-scan --json
```

- `ARCHS=arm64` if the framework has only an arm64 Swift module (one command per target).
- Every Swift module must compile; "Linking failed" is fine.
- `--scratch-path` links the app's other targets and packages (22 modules on a real iOS app); failures are in `warnings`.
- `--cache-dir` keeps the saved command out of DerivedData.
- Kotlin types are [opaque references](../KNOWN-ISSUES.md#13-objective-c-objects-every-call-returns-its-own-value-by-design-for-now);
  creating, casting and printing them stay `unsupported`. Kotlin enums and sealed classes are read through SKIE
  ([below](#types-from-binary-frameworks)). `summary.plumbing` counts wiring functions apart
  ([JSON](#the-json-report---json-schema-version-1)).

### Types from binary frameworks

A binary framework (Kotlin Multiplatform through SKIE, any closed-source Swift or Objective-C framework) has no SIL
bodies. Scan reads its types anyway:

- **Enums:** the cases come from the compiler (a probe `switch` lists them). An enum is closed only when the compiler
  says a `switch` is exhaustive without `@unknown default`; otherwise it has one more case, "unknown". Payload objects
  are opaque.
- **Calls with no body** (getters and methods of the binary module, `onEnum(of:)`, SKIE's `name`/`ordinal`, bridging
  calls, `Double(truncating:)`, Objective-C methods, `==` through `isEqual:`) return any value of their type, a fresh
  one at each call, and are assumed not to trap. Each is an **assumption**, listed per function and on every caller
  whose proof uses it (`assumptions` in the JSON, `assumes:` in text, a `note:` in `check --gate`). The summary counts
  proofs that assume (`Proved safe …: 12 (3 with assumptions)`).
- **Where the call goes:** `no body: binary module M`; `no body: not scanned (module M)` for a module the build
  compiled but the scan did not read (add `--scan <dir>:M` to check it); `no body available (module M)` otherwise.

```swift
// SharedKt (binary): public func onEnum<T: Item>(of: T) -> Skie.Item.__Sealed  { case note(Note), photo(Photo) }
func itemTitle(_ item: Item) -> String {
    switch onEnum(of: item) { case .note: "Note"; case .photo: "Photo" }
}
```
```
✓ CONTRACT HOLDS itemTitle(_:)
      assumes: `onEnum(of:)` may return any case of Skie.Item.__Sealed and is assumed not to trap (no body: binary module SharedKt)
```

A proof holds for every value the assumed calls may return; it does not cover a call that traps or never returns
(SKIE's `fromObjectiveC` stops the process on `nil`). `--no-opaque-calls` (`check`, also with `--gate` and
`--build-log`) refuses every call with no body: such a function is `unsupported`, with the call named.
Two calls are never assumed to give the same value.

## Localization catalogues: `swiftformal strings`

Logic proves which key a function picks, not what a key's text is. The catalogues are checked without a build:

```sh
swiftformal strings App/Resources --sources App/Sources
```

It reads every `.xcstrings`, `.strings` and `.stringsdict` under the paths (`<language>.lproj` files make one table per
file name) and reports, per key and language:

- `missing`: a language has no text for the key. An `.xcstrings` key that is a sentence may lack a source-language
  text (the key is shown); one that looks like an identifier (`item.title`) may not.
- `format`: the text reads more arguments than the reference language's, or one as another type (`%d` where the
  reference has `%@`). The reference is the `.xcstrings` source language (or the key), else `en`, `Base` or the first.
- `textIsKey`: an identifier-like key has itself as its text.
- `unknownKey` (with `--sources`): a literal key in `NSLocalizedString("…")`, `String(localized: "…")` or
  `"…".localized…` that no catalogue has.

`--json` prints the report for scripts. Exit 1 when there is a problem.

## In your editor (no language server)

**`swiftformal check --xcode`** (or `--format xcode`) prints logic and walk verdicts as compiler lines tagged
`[swiftformal]`, with `note:` lines for the input, the replay, the walk and the call chain (`diagnostics()` in
[`Sources/SFVerifyKit/CheckDiagnostics.swift`](../../Sources/SFVerifyKit/CheckDiagnostics.swift)). An `error` is
exactly what fails the run (broken promise, failing walk, silent walk; a trap only with `--strict`, else a `warning`):

```
/…/Score.swift:5:9: error: [swiftformal] clamp(_:_:_:) ensures is false when x = 1, lo = 2, hi = 0 — concrete counterexample (logic, every input)
/…/Score.swift:5:9: note: [swiftformal] replay: clamp(1, 2, 0)
```

`--show-unchecked` notes functions no engine checked (why, and the fix); `--show-proved` notes proofs (`…, for every
run that ends` for loops). `--at`/`--symbol` checks one function and its linked walks:

```sh
swiftformal check --scan .:MyTarget --tests .:MyTargetTests --at "$FILE:$LINE" --xcode
```

Its `--json` adds per module `package`, `configurations`, `compiler`, `pinned`, `selection`; per function `package`,
`category`, `detail`, `hint`, `calledFrom`, `proofScope`; per walk `domainComplete`.

- `Undecided: N` is split into `budget` (raise `--budget`, narrow types, add a `#requires`) and `unmodelled results`
  (depends on a call such as `String.count`; use a walk or a test).
- A finding with no location starts with the module name; matchers miss it.
- Paths are as given to the compiler (absolute with `--scan`).

**VS Code.** `$swiftc` comes with the Swift extension (`swiftlang.swift-vscode`). In `.vscode/tasks.json`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "swiftformal",
      "type": "process",
      "command": "<SwiftFormal checkout>/.build/release/swiftformal",
      "args": ["check", "--scan", "${workspaceFolder}:MyTarget", "--no-walks", "--format", "xcode"],
      "problemMatcher": "$swiftc"
    }
  ]
}
```

Without the extension, use this matcher (checked against `diagnostics()` output; the task was not run in VS Code):

```json
"problemMatcher": {
  "owner": "swiftformal",
  "fileLocation": "absolute",
  "pattern": {
    "regexp": "^(.*?):(\\d+):(\\d+):\\s+(warning|error|note):\\s+(.*)$",
    "file": 1, "line": 2, "column": 3, "severity": 4, "message": 5
  }
}
```

**Xcode.** Use the [Gate](gate.md), `swiftformal check --gate` in a Run Script phase (`@Verify` functions only; fails
the build like a compiler error). For every function, the phase can run (not tried in Xcode):

```sh
"<SwiftFormal checkout>/.build/release/swiftformal" check --scan "$SRCROOT/<package dir>:MyTarget" --no-walks --format xcode
```

It needs a SwiftPM target and `ENABLE_USER_SCRIPT_SANDBOXING = NO`; its `swift build` writes to `<package dir>/.build`.

## Replaying counterexamples as tests (`--emit-tests`)

`--emit-tests <dir>` writes `<dir>/<Module>ScanPlaybackTests.swift`, one Swift Testing test per counterexample with a
replay (a free function, or a method, getter, static method or initializer of a struct or enum):

```swift
@Test("percent(_:_:) traps: Division by zero when part = 0, whole = 0") func playback_1_percent() async {
    await #expect(processExitsWith: .failure) { _ = percent(0, 0) }
}
@Test("bad(_:) ensures is false: … when x = 255") func playback_2_bad() {
    #expect(!bad_ensures(255, bad(255)))
}
```

- A test **passes while the bug reproduces**. After you fix it, the test fails: delete it.
- `self` and arguments are written as Swift: memberwise init, enum cases, `nil`, numbers, `Bool`, strings (`"a"` as a
  stand-in). TCA `@ObservableState` properties are passed by name. A mutating method runs on a copy.
- A stored property a replay cannot write (array, `UUID`, no literal) keeps its default, if any; the test is written
  only if a proof shows the trap happens whatever it holds. Else: `no replay (the trap may depend on stored properties a
  test cannot set (…))`.
- No test for: `private` types or functions, non-memberwise initializers, generic types, setters, broken promises of
  methods, inputs without a literal, `inout`, `throws`/`async`, undefined behaviour in a primitive (listed at the end of
  the file; `noReplay` in `--json`).
- Put the file in a test target (`@testable import <Module>`). Release-only counterexamples are wrapped in `#if !DEBUG`
  (run `swift test -c release`). Exit tests need Swift 6.3+ on macOS or Linux; elsewhere the file is compiled out.

Run the emitted file in your own test target. (The maintainers' `sfverify --confirm` builds and runs these tests
itself and sets `confirmed` in the JSON; `swiftformal check` does not.)

## In CI: SARIF and GitHub annotations

`--format sarif` prints [SARIF 2.1.0](https://docs.oasis-open.org/sarif/sarif/v2.1.0/); `--format github` prints
workflow commands. Both are the findings of `--format xcode` (`CheckFormats.swift` in
[`Sources/SFVerifyKit`](../../Sources/SFVerifyKit)), so the three cannot disagree, and the exit code is the same: an
`error` fails the run, a `warning` is what logic and the walks could not settle, a `note` (`notice` on GitHub) the
input, replay and call chain. Paths are relative to the working directory: run from the repository root.

- **SARIF:** one rule per severity (`swiftformal.error`, `.warning`, `.note`), one result per finding, its notes as
  related locations. Relative paths use base id `SRCROOT`; other files get an absolute `file://` URI.
- **GitHub:** `::error file=Sources/K/K.swift,line=19,col=36,title=swiftformal::…`, the notes in the message.

```yaml
- run: .build/release/swiftformal check --scan .:MyTarget --format github
- run: .build/release/swiftformal check --scan .:MyTarget --format sarif > swiftformal.sarif
- uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: swiftformal.sarif
```

`--strict` makes a trap fail the step. This workflow was not run on GitHub; the format follows GitHub's documentation (`%`, CR, LF, and in properties `:` and `,`, are escaped).

## The JSON report (`--json`, schema version 1)

Defined by [`docs/schemas/scan-report.schema.json`](../schemas/scan-report.schema.json). Objects are closed (a new key
goes into the schema in the same change). `schemaVersion` changes only when a key is removed or changes meaning.
Optional keys are omitted, never `null`. `Scripts/metrics.py` validates real output against the schema.

| Key | Meaning |
|---|---|
| `schemaVersion` | `1`. |
| `module`, `optimization` | Module name; `-Onone` or `-O`. |
| `functions` | One entry per hand-written function (below). |
| `summary` | Counts: `total`, `safe`, `mayTrap`, `contractHolds`, `contractFails`, `undecided`, `unsupported`, `internalErrors`; `compilerGenerated` and `generatedCode` (not in `total`); `unsupportedByCategory`; `plumbing`; `weakContracts` (`--mutate`); `withAssumptions` (proofs that rest on `assumptions`). |
| `timing` | `compileSeconds`, `parseSeconds`, `verifySeconds`, `silBytes`. Wall-clock: do not compare. |
| `compiler` | First line of `swiftc -version`. |
| `pinned` | `false` if the compiler is not validated: verdicts not covered by [TRUST.md](../TRUST.md), and the Gate would fail ([pin upgrade](pin-upgrade.md)). |
| `configurations` | `debug` and/or `release` (`-assert-config Release`); `-O` gives `["release"]`. |
| `warnings` | Run problems: `xcrun swift-demangle` failed, no function found, or `module <Name> could not be linked, …` (its types are unknown). Also on stderr. |

Each entry of `functions`:

| Key | Meaning |
|---|---|
| `name`, `symbol`, `location` | Readable name, mangled symbol, `file`/`line`/`column`. |
| `status` | `safe`, `mayTrap`, `contractHolds`, `contractFails`, `undecided`, `unsupported`, `internalError`. |
| `category`, `detail`, `hint` | Why `unsupported` or `undecided` (`budget` or `unmodelled results`), and what to change. |
| `at`, `calledFrom`, `typePath` | For `unsupported`: where the unread construct is, the calls leading there (innermost first), or the path to an unreadable type (`self.tabs.style: Color`). |
| `counterexample` | `inputs`, `failure`, optional `result`, `at`, `replay`, `ensuresCall`, `confirmed` (maintainers' `--confirm`). |
| `moreTraps` | Other trap places, same keys as `counterexample`. |
| `hasContract` | The function has a `@Verify` promise (`@Verify` wrote `f_requires` or `f_ensures`). If `unsupported` or `undecided`, it was not checked. |
| `ignoredContracts` | Hand-written look-alike promise functions (`f_requires`, `f_ensures`) that were not read. |
| `origin` | `macro` or `build` for generated code (not counted in `summary`). |
| `crossCheck`, `crossCheckReason` | Maintainers' `--cross-check llvm` only: `agrees`, `disagrees`, `unread` (with reason) or `undecided` (20,000 conflicts). With `llvm-strict`, anything but `agrees` makes the verdict `undecided`. |
| `usesContracts` | Maintainers' `--modular` only: callees whose promises were used. |
| `assumptions` | Calls with no body the verdict takes on trust, callees' included ([binary frameworks](#types-from-binary-frameworks)). |
| `weakContract` | `--mutate`: `mutantsTried`, `survivors` (`mutation`, `kind`, `at`, `differsOn`, `mayBeEquivalent`, `reason`). |
| `seconds` | Wall time; functions run in parallel, so the sum can exceed `verifySeconds`. |
| `solverConflicts`, `cnfVariables`, `cnfClauses` | Maintainers' `--stats` only: exact, deterministic proof cost (compare across machines, not solver versions). |

**Plumbing.** `summary.plumbing` counts `unsupported` functions that wire the app rather than compute: they stop at a
property wrapper or injection type (`Injected<…>`, `Dependency<…>`, `Environment<…>`, `State<…>`, `Binding<…>`,
`Store<…>`, Factory's `Container`), are a view or reducer `body`, or a TCA `@ObservableState` setter. It is only a count;
they stay `unsupported` (579 of 3,334 on a real iOS app's main target).

`Scripts/metrics.py` records counts for [`Examples/Metrics`](../../Examples/Metrics) in `Scripts/baseline/metrics.json`
and fails on a verdict change or growth over 10 % ([PERFORMANCE](../PERFORMANCE.md)).
