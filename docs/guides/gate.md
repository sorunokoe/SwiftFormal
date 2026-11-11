# Gate: the build fails unless it is proved

## Build checks, tests walk: `swiftformal check --gate`

On build, Scan ("the logic") checks every `@Verify` promise you wrote. The tests (walks) check the rest. CI runs the
same two steps and gets the same result.

```swift
@Verify(over: .product(.int(0 ... 100), .int(0 ... 100)))
public func discounted(price: Int, percent: Int) -> Int {
    #requires(price >= 0 && price <= 1_000_000 && percent >= 0 && percent <= 100)
    #ensures { $0 >= 0 && $0 <= price }
    return price - price * percent / 100
}
```

Break it (`/ 99` instead of `/ 100`) and press ⌘B. The build fails, and the error sits on the function in the editor:

```
Shop.swift:4:13: error: [SwiftFormal] discounted(price:percent:) breaks its promise: ensures failed: { $0 >= 0 && $0 <= price } when price = 524288, percent = 100
swiftformal: gate: Shop: 2 of 4 promises proved by logic, 1 broken, 1 left to the tests (8 s)
```

### Xcode

1. Build the tool once, in a SwiftFormal checkout: `swift build -c release --product swiftformal`.
2. Add a Run Script phase to the app target, before "Compile Sources", with "Based on dependency analysis" off.
3. Set the build setting `ENABLE_USER_SCRIPT_SANDBOXING = NO`. The script runs `swift build`, which a sandboxed
   script cannot.

```sh
"<SwiftFormal checkout>/.build/release/swiftformal" check --gate --package "$SRCROOT/Packages"
```

- XcodeGen: the same script under `preBuildScripts` with `basedOnDependencyAnalysis: false`.
- Tuist: a `.pre(script:name:basedOnDependencyAnalysis: false)` target script.

Verified with an XcodeGen iOS app on Xcode 27: a broken promise fails the build at the right line.

**Tip:** on the command line, build an iOS app with `-destination 'generic/platform=iOS Simulator'`, not
`-sdk iphonesimulator`. With `-sdk`, Xcode 27 builds macro plugins (`@Verify` and others) for the simulator instead
of the Mac, and the compiler reports "malformed response" from the plugin.

### CI

Run the same command, then the walks:

```sh
swiftformal check --gate --package Packages
swiftformal check --scan Packages:MyTarget --tests Packages:MyTargetTests   # or: swift test
```

### An app target: `--build-log`

Code in the app target itself has no `Sources/<Target>/` for SwiftPM to build. Give the gate the log of a build that
already ran; it reads the target's compile command (with the macro plugin flags) and builds nothing:

```sh
xcodebuild -scheme App -destination 'generic/platform=iOS Simulator' build | tee build.log
swiftformal check --gate --build-log build.log --target App
```

- `--build-log` also takes the folder of Xcode's activity logs.
- `--scratch-path` names that build's folder when it is not `<package>/.build` or the log's folder; `--cache-dir`
  where the command is saved for a later build that compiled nothing.
- Every run checks again: a log is not a build whose inputs a stamp can hash.
- This is the CI flow; a Run Script phase cannot read the log of the build it runs in. `Scripts/check-examples.sh`
  runs it on `Examples/GatedPackage`.

### What it checks

- **Which functions:** functions and computed properties marked `@Verify` (also `mutating` methods, and a `get`
  marked `@Verify`). In every target of the package (`Sources/<Target>/`), or only the `--target` ones. Functions
  without a promise are not reported.
- **Not read:** a hand-written `f_requires` / `f_ensures` and a `// sf:verify` comment. Each is an **error** that says
  to write the promise in place with `@Verify`, `#requires` and `#ensures` (`@Verify` alone asks for a proof that
  the function cannot trap).
- **Error:** a broken promise or a trap, for a concrete input.
- **Warning:** a `@Verify` function or promise that logic cannot read yet (a class, a closure it cannot see into,
  undecided within the budget). Only a test can check it. For a `@Verify` function the warning names its walk
  (`#expect(verify_boxed().isProved)`). A computed property, a `mutating` method or a function with nothing to walk
  has no walk: the test must call it. The build cannot see whether such a test exists. `--strict` makes every warning
  an error.
- **Assumptions:** a proof that trusts calls with no body (a binary framework, a module that was not scanned) lists
  them in a note, and the summary counts such proofs: `3 of 4 promises proved by logic (1 assuming calls with no
  body), …` ([types from binary frameworks](scan.md#types-from-binary-frameworks)). `--no-opaque-calls` refuses such
  calls instead: the function is unsupported, and the gate fails.
- **Exit codes:** 0 no error; 1 an error, or a target that could not be built; 2 a usage error. A `check` option that
  does not apply to the gate (`--scan`, `--tests`, `--at`, `--json`, …) is a usage error, not ignored.

### Speed: the same `.build`, a stamp and the proof cache

- Targets are built with SwiftPM in the package's own `.build` (the one `swift build` and `swift test` use): no
  second build.
- Xcode's iOS build settings (`SDKROOT`, `ARCHS`, …) are dropped, so Xcode, a terminal and CI run the same check.
- Every target is built (a null build when nothing changed). A target that passed and whose stamp still matches is
  not checked again; its diagnostics are printed again.
- The stamp covers what can break a promise without its own file changing: the local modules it links, every module,
  header and macro its arguments name, every file the compiler read (also a C header included as `"../limits.h"`),
  the manifests, the compiler, SDK, tool and flags. An edit saved during the check is never stamped
  ([what a stamp covers](scan.md#the-proof-cache)).
- A checked target reuses answers for the same code, promises, callees, compiler and flags from the proof cache in
  `<package>/.build/swiftformal/proofs`.
- `--force` checks every target. `--no-proof-cache` also proves everything again.

## Limits

- A call into another module has no body to read. If that module is a local target the build compiled, it is
  linked. Otherwise the call is an assumption (listed in the note), or, with `--no-opaque-calls`, unsupported.
- **Wide multiplication and division are hard for the SAT prover.** With default settings: an 8-bit index kernel is
  decided in 0.02 s; a 16-bit one with two multiplications was still undecided after 100 000 conflicts (5.1 s); the
  32-bit version was still undecided after 300 000 conflicts (27 s, release build). Narrow the types or move the
  check into a test.
- **Fail closed:** a gated function that may trap, breaks its promise, is undecided, is outside the supported subset,
  was not found, or sits in a file that does not compile is never a silent pass. Remove `@Verify` if the function is
  out of scope.

There is no build plugin: a build-tool plugin cannot load a macro built by the package (`@Verify` itself), so on a
target that uses `@Verify` it could only fail. If a target still applies the pre-0.1.0 gate plugin,
`swiftformal doctor` names it and says to run `swiftformal check --gate` instead.
