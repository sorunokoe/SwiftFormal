# SwiftFormalCLI: the `swiftformal` command

**Job (Inspector view):** the one front door. `swiftformal check` proves every `--scan` target with logic, then runs only the walks that cover a function logic did not prove, and gives one verdict per function. `check --gate` is the build check (`GateCommand.swift`), `check --build-log` reads an app target from its build log, `doctor` checks the setup, `lsp` wires the language server (SFLanguageServer) to standard input and output.
**Raw input → typed → result:** command-line flags (`--scan <dir>:<target>`, `--build-log`, `--tests <dir>:<target>`, `--gate`, `--json`, `--format xcode|sarif|github`) → `SFVerifyKit` (`Check`) → a text report or a `--json` report. The flags and the JSON are the public contract.
**Depends on:** SFVerifyKit, SFLanguageServer. **Must not depend on:** the engine modules directly.
**Fast loop:** `Scripts/sandbox.py SwiftFormalCLI` (builds the product; it has no test target, the merge logic is tested by `CheckTests` in `SFVerifyKitTests`). **Connected loop:** `Scripts/sandbox.py SwiftFormalCLI --connect`
**Real consumers:** `swift build --product swiftformal`, and `swiftformal check` on the packages of a production iOS app (app study rounds 5 and 6; not public).
**Run it:** `swift run swiftformal check --scan Examples/GatedPackage:Kernels`
**Platforms (verified):** macOS only (it needs the compiler and `Process`).
**Known gaps:** none of its own.
