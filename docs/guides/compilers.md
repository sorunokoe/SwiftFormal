# Compilers: which ones SwiftFormal has been checked against

Scan (`swiftformal check`, `SFSIL`) reads the SIL text a compiler prints. That text has no stability promise, so the
reader can misread another compiler. SwiftFormal keeps a **pin**: the `swiftc --version` first lines whose SIL the
reader was validated against.

## Supported compilers

| Compiler (`swiftc --version`, first line) | Status | Validated by |
|---|---|---|
| `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)` | **pinned** | all three lanes, on the maintainer's machine (Apple M4 Pro, macOS 27) |
| anything else | **not validated** | nothing |

The list lives in `SILFrontendVersion.verifiedCompilers` (`Sources/SFSIL/ProofCacheVersions.swift`). This table must
say the same.

## Which compiler Scan runs

`swiftformal check`, its gate and the maintainers' `sfverify` pick one compiler per run and use it for every `swiftc`
they start:

1. With `--build`: the `swiftc` that SwiftPM ran (from its build log).
2. Else `SWIFT_EXEC`, when it names an executable.
3. Else `xcrun --find swiftc`, which honours `DEVELOPER_DIR` and `TOOLCHAINS`. If `TOOLCHAINS` names no installed
   toolchain, `xcrun` silently uses the default one; Scan warns (`sfverify: note: TOOLCHAINS=… names no installed
   toolchain`).
4. Without `xcrun` (Linux): the first `swiftc` on `PATH`, with no `-sdk`.

Then one `swiftc -print-target-info` (0.1 s) gives the version line for the pin, the target triple and the resource
directory (where the macro plugins are).

- When the environment picked the compiler (`DEVELOPER_DIR`, `TOOLCHAINS`, `SWIFT_EXEC`, `PATH`), `swiftformal check`
  prints a `note:` line with its path.
- `swiftformal doctor` always shows the path and how it was found.
- `sfverify --package <dir>` without `--build` compiles for the package's macOS deployment target
  (`platforms: [.macOS(.v13)]`, read with `swift package dump-package`), as SwiftPM does.
- Plain files and the gate have no manifest, so they compile for the compiler's default target (the host). Change it
  with `--swiftc-arg -target --swiftc-arg <triple>`.
- Linux is located but not validated. Scan stays macOS-only ([platforms](platforms.md)).

## What happens on a compiler that is not pinned

- Library calls through `PinnedCompiler` (`check`, `module`) throw `UNPINNED COMPILER` and say what to do.
- The **fast lane** needs no pin and runs wherever the package builds.
- The **oracle lane** (`SFOracleTests`) and the SIL grammar fixture test
  (`SILGrammarFixtureTests/installedCompilerPrintsTheSameSILAsTheFixtures`) are **skipped**, with the printed reason
  `needs the pinned compiler`. They do not fail: on an unchecked compiler, a failure would look like a SwiftFormal bug.
- A skipped oracle lane is not a pass. The compiler is unchecked until someone runs the lane on it.

## Adding a compiler

Start with `Scripts/pin-upgrade.sh` ([pin upgrade](pin-upgrade.md)). It lists the compiler changes that touch the
reader and prints these steps for the candidate.

1. Install it and make it the default `swiftc` (`xcrun swiftc --version`).
2. Add its version line to `SILFrontendVersion.verifiedCompilers` (local, uncommitted edit). Run
   `Scripts/test-lane.sh oracle` and `Scripts/test-lane.sh slow`.
3. Read every failure. A SIL grammar difference shows up in `SILGrammarFixtureTests`, which names the construct.
   Re-validate `SILParser` and `SILEncoder` against the new text, update the fixture snippets, and bump
   `SILFrontendVersion.semantics` if a verdict could change.
4. Only when all lanes pass: commit the new line, add a row to the table above, and run `Scripts/safety-net.sh`.

## Where the lanes run

| Lane | Local | CI |
|---|---|---|
| fast | yes | yes, on every pull request to `main` (`ci.yml`) |
| slow | yes | no: run by hand before a release |
| oracle | yes | no: run by hand before a release, on the pinned compiler |

CI runs only on pull requests to `main`. There is no nightly workflow.

The pin names an Apple Swift 6.4 toolchain: Xcode 27.0 (27A266a). The workflows run on GitHub's `xcode-27` runner
image (a preview image when this was written) and select that Xcode by path with `DEVELOPER_DIR`, because the image's
default Xcode can be newer. **The oracle lane is run locally before a release**, and a release is not tagged without
that run.
