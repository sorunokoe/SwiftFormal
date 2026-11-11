# Changelog

All notable changes, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The project follows [Semantic Versioning](https://semver.org/) (see [Versioning](#versioning)).

## [Unreleased]

### Changed

- Docs use one set of words everywhere ([glossary](docs/GLOSSARY.md)): Scan ("the logic") first, then Walk. The
  `SFProve` engine is now called **symbolic proofs**, so `Prove` means only the test API.
- `swiftformal check --help`: `--mutate` no longer points to an internal tool.

### Fixed

- `Scripts/check-api.sh` works against the `0.1.0` tag. It compares `SwiftFormal` and `SwiftFormalTesting` only;
  `SFProve` (a preview) is not compared.

## [0.1.0] - 2026-11-10

The first public release. License: [Apache-2.0](LICENSE). Three products: `SwiftFormal` (app code), `SwiftFormalTesting`
(tests) and the `swiftformal` command.

### Added

- **Walk** (`SwiftFormalTesting`): `Prove(it: f, over: domain) { … }` runs your real function on every input of a
  domain and checks the properties you list (`Matches`, `Satisfies`, `Injective`, `RoundTrip`, `Agrees(with:)`,
  `NeverOutputs`, …). Also sessions of actions and `Prove(neverTraps:)`. Answers: `proved`, `bounded`,
  `counterexample` ([Walk guide](docs/guides/walk.md)).
- **Contracts** (`SwiftFormal`): `@Verify` with `#requires` and `#ensures` in the body. Scan proves them for every
  input, and `@Verify` also writes a `verify_<name>()` walk. It is the only contract Scan reads.
- **`swiftformal check`**: one answer per function. `--scan` proves every target with Scan (the compiler's SIL), then
  runs only the walks that cover what Scan did not prove. `--build-log` reads an Xcode or Tuist app target from a
  build log. `--at <file>:<line>` checks one function. Relational claims of a walk (`Injective`, `RoundTrip`,
  `Agrees`, `Matches`) are proved for every input by logic where it can read them. Output: text, `--json`
  (`schemaVersion` 1), `--xcode`, `--format sarif|github`; `--emit-tests` writes a test per counterexample
  ([Scan guide](docs/guides/scan.md)).
- **`swiftformal check --gate`**: the build-time check of every `@Verify` promise. A broken one is a `file:line:col`
  error with the input. Run it from Xcode (Run Script phase) and in CI ([Gate guide](docs/guides/gate.md)).
- **What Scan reads**: integers, `Double`, `Bool`, enums, structs, optionals; closures, `map`/`filter` and other array
  functions (arrays up to 8 elements); text (literals, interpolation, `String(format:)`, localized keys as an unknown
  function); `Date` and other Foundation values; classes with a `deinit`. Calls into binary frameworks (Kotlin through
  SKIE, Objective-C) are listed assumptions; `--no-opaque-calls` refuses them.
- **`swiftformal strings`**: checks localization catalogues (missing texts, format arguments, unknown keys) without a
  build.
- **`swiftformal doctor`** for setup problems, and an agent skill in [`skills/swiftformal`](skills/swiftformal/SKILL.md).
- **Prove** (preview, re-exported by `SwiftFormalTesting`): proves a claim for all values of 8 to 64-bit integers with
  a SAT solver, checked by an independent proof checker ([Prove guide](docs/guides/prove.md)).
- **Generators** (`sfgen`, built from a checkout): a Walk check for every `Rule` of an app, and `sfgen domains` for
  the types of a binary framework ([Generate guide](docs/guides/generate.md)).
- **Editor support**: `swiftformal lsp` shows each answer as a code lens on save. VS Code extension in
  `Editors/vscode` ([Editor guide](docs/guides/editor.md)).
- **Speed**: a proof cache in `<package>/.build/swiftformal/proofs` (`--no-proof-cache` turns it off), and
  `swiftformal check --jobs <n>` to scan several packages at the same time. Entries from pre-release builds are not
  reused (cache semantics 37, claim 6).
- **Platforms**: needs Swift 6.1 or newer. The package declares macOS 13 and iOS 16. Walk and Prove build for iOS
  (tests not run on a simulator). Scan, the gate and `sfgen` run on a Mac ([platforms](docs/guides/platforms.md)).
- **Pinned compiler for Scan**: `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)`. On any other
  compiler, answers are not covered by [TRUST](docs/TRUST.md) (`pinned: false`) ([compilers](docs/guides/compilers.md)).

### Known limits

- `bounded`, `unchecked`, `undecided`, `unsupported` and `unknown` never mean proved.
- Scan does not read most classes or generic code, and knows a localized text only by its key. There a walk must
  cover the function ([Scan guide](docs/guides/scan.md)).
- Scan reads other modules only from your own package and local path dependencies. SDK modules and remote packages
  stay `unsupported`.
- Names from before 0.1.0 (`expectProved`, `verify`, `partition`, …) do not compile; the error says what to write
  ([Walk guide](docs/guides/walk.md#migrating-from-the-pre-release-names)).
- Scan's model of Swift is tested against real runs, not proved correct. Open issues:
  [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md).

Development history before this release: [archive/CHANGELOG-pre-0.1.md](archive/CHANGELOG-pre-0.1.md).

## Versioning

SemVer. The public API is the products `SwiftFormal` and `SwiftFormalTesting`, plus the `swiftformal` command-line flags and its `--json` output (its `schemaVersion`). Engine modules (`package` access) and the maintainers' tools `sfverify` and `sfgen` are not covered.

Before 1.0, a minor version (0.1 to 0.2) may break the API. Every break is listed here under **Changed** or **Removed**, with the old name and the new one. A patch version (0.1.0 to 0.1.1) does not break. A fix that makes a tool say less (more `unsupported`) to remove a wrong verdict is a fix, not a break ([ADR 0006](docs/decisions/0006-soundness-policy.md)). Deprecated names stay for one minor version.

[Unreleased]: https://github.com/sorunokoe/SwiftFormal/compare/0.1.0...HEAD
[0.1.0]: https://github.com/sorunokoe/SwiftFormal/releases/tag/0.1.0
