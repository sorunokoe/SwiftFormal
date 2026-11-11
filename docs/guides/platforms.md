# Platforms: what really builds where

`Package.swift` declares `.macOS(.v13)` and `.iOS(.v16)` for the whole package. That is a declaration, not a promise.
This page lists what was **actually built** for the iOS Simulator, and what was not.

Last checked: 2026-11-05, Xcode with Swift 6.4, destination `generic/platform=iOS Simulator`.

## The short version

| Part | Targets | macOS | iOS |
|---|---|---|---|
| **Scan** | `SFSIL`, `SFVerifyKit`, the `swiftformal` command | yes | **no** |
| Scan's builtin semantics | `SFSemantics` | yes | builds |
| Second reader | `SFLLVM` | yes | **no** |
| **Walk** | `SwiftFormal`, `SwiftFormalTesting` | yes | builds |
| **Symbolic proofs** | `SFProve` (re-exported by `SwiftFormalTesting`) and the SAT kernel it needs: `SFCNF`, `SFSAT`, `SFCheck`, `SFBV` | yes | builds |
| **Gate**, `@Verify` macros | `swiftformal check --gate`, `SwiftFormalMacros` (compiler plugin) | yes | n/a: runs on the Mac that builds your app |
| Generator (internal) | `SFGenKit`, `sfgen` (no product) | yes | n/a: a build-time tool |

- **Scan runs at build time on a Mac. It is not shipped inside an iOS app.**
- Walk and symbolic proofs can be linked into an iOS app or its tests.
- "Builds" means the library compiles for the simulator. It does **not** mean tests ran on a simulator: they did not
  (see [Not verified](#not-verified)).

## What was run

The commands are in [The CI `ios` job](#the-ci-ios-job): `xcodebuild -scheme <T>` for targets with a scheme,
`swift build --target <T> --triple arm64-apple-ios16.0-simulator ...` for the others.

| Target | Command | Result |
|---|---|---|
| `SwiftFormal`, `SwiftFormalTesting`, `SFProve` (and its closure) | `xcodebuild` | builds |
| `SFCNF`, `SFSAT`, `SFCheck`, `SFBV`, `SFSemantics` | `swift build --triple` | builds |
| `SFVerifyKit` | `xcodebuild` (when it was a product) | **fails**: `cannot find 'Process' in scope` in `SFSIL/SILVerify.swift` (lines 22 and 39) |
| `SFSIL`, `SFLLVM` | `swift build --triple` | **fails**: the same `Process` error |

Why two kinds of command:

- SwiftPM makes an Xcode scheme only for products. `SFSemantics`, `SFSIL` and `SFLLVM` are not products. The
  `SwiftFormal-Package` scheme would also build the targets that fail.
- `swift build --triple` with the simulator SDK compiles one target for iOS. Where both commands were run
  (`SwiftFormal`, `SwiftFormalTesting`, `SFProve`, and `SFSIL`'s failure), they agreed.

The registry (`Scripts/sandboxes.py`) lists "iOS" only for the "builds" rows. Its `ios_command(name)` prints the exact
command for each.

## Why Scan does not build for iOS

`Process` (to start `swiftc`, `swift`, `swift-demangle`, `clang`) does not exist on iOS. Scan, `SFLLVM` and `sfgen` use
it in several files (for example `SFSIL/SILVerify.swift`, `SFSIL/ProofDigest.swift`, `SFLLVM/LLVMVerify.swift`,
`sfgen/main.swift`, and files in `SFVerifyKit`).

Decision: Scan stays macOS-only. No code change. The alternative, an `SFProcess` module with a `ToolRunning` protocol
and a real runner behind `#if os(macOS)`, is **deferred** (see `docs/decisions/0009-carve-outs.md`). Do not guard
`Process` call sites one by one.

## The CI `ios` job

`.github/workflows/ci.yml` has an `ios` job (written, not yet run on a hosted runner). It builds every sandbox whose
`platforms` contains `iOS`. Never use macOS results as iOS results.

```sh
# targets that have a scheme
xcodebuild -scheme SwiftFormal            -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme SwiftFormalTesting     -destination 'generic/platform=iOS Simulator' build
# SFProve builds as a dependency of SwiftFormalTesting, which re-exports it

# targets without a scheme
for t in SFCNF SFSAT SFCheck SFBV SFSemantics; do
  swift build --target "$t" --triple arm64-apple-ios16.0-simulator \
    --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path .build/ios-spm
done
```

- The job adds `-derivedDataPath .build/ios-dd` to each `xcodebuild`, so build output stays in `.build/` and the
  schemes share one build.
- The job's list must match the "builds" rows above (`Scripts/sandboxes.py` knows them).

## Not verified

- No test was run on an iOS simulator or a device. "iOS" in this repository means "the library builds", not "the
  tests pass".
- Next step, **not tried yet**: `xcodebuild test -scheme SwiftFormal-Package -destination 'platform=iOS Simulator,name=<device>'`,
  with a device from `xcrun simctl list devices available` (this machine has an iPhone 15 Pro simulator on iOS 17.0).
  `SwiftFormal-Package` also contains targets that do not build for iOS, so expect to need a test plan or
  `-only-testing`.
- No iOS app links these libraries in this repository (`Examples/Walk` and `Examples/Prove` are macOS packages).
- Walk cannot catch a Swift trap on iOS (see `docs/TRUST.md`).
