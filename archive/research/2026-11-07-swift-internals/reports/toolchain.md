# Scan and the toolchain: compiler invocation, build systems, macros, pin, diagnostics (prefix K)

Tree: `SwiftFormal-internals` at `d759be7`. Compiler: Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode toolchain, SwiftPM 6.4.
Prototypes, logs and fixtures live in `SCRATCH/k/`:
- `k/repo`: the repository copy, with the K1 patch applied.
- `k/pkg`: the `Base`/`Kern` package, with a `@TaskLocal`, a duplicated `Point` and the `Scan` command plugin.
- `k/pkg2`: a package named `Pkg2` with targets `Pkg2` and `Other`.
- `k/dm`: the demangler benchmark.
- `k/tools`: helper scripts.

Binaries:
- `k/sfverify-base`: release build of `d759be7`.
- `k/sfverify-k1`: the same with the K1 patch.

The machine was loaded, so wall times are the best of 3 unless a single run is given.

## 1. Summary

The way Scan talks to the toolchain is in better shape than the docs say, but it has two real defects.

**K1, a reproducible failure on common package layouts.** It occurs when a linked target has the same name as its package (`Foo` in package `Foo`). Then `removeProducts` deletes Swift Build's whole `Intermediates.noindex/<Package>.build` folder. The type-name check then fails on a deleted `-const-gather-protocols-list` file. As a result, the first `sfverify --build` or `swiftformal check` exits 2.
- Before the patch: 2 of 2 cold runs failed.
- After a 6-line patch: 2 of 2 passed.
- The same failure hit this repository's own `SwiftFormalContractsTests`.

**K2, a trust-document violation.** The compiler pin is never checked on the Scan path. `sfverify`, `swiftformal check` and the Gate all run on whatever `xcrun swiftc` resolves to, but TRUST.md:31 says other compilers "fail closed". `--build` also throws away the absolute `swiftc` path that SwiftPM used and resolves the compiler again through `xcrun`.

**KNOWN-ISSUES #2 is mostly stale.** Macros from the toolchain and the SDK already compile without `--build`: `@TaskLocal`, `@Observable` and `#Predicate` all do. Package macros and Swift Testing macros compile with `--build`: `SwiftFormalContractsTests` (`@Verify`, `@Test`) compiles to 3.5 MB of SIL with 158 functions. Two gaps remain:
- `import Testing` in loose-file mode fails today. Three extra flags fix it (measured).
- Package macros in loose-file and Gate mode. PackagePlugin has no API that would give a build-tool plugin the path of a built macro.

**Swift Build is already the default** in SwiftPM 6.4, and the current log parser handles it.

**The null-build problem behind P1 has a cheap, robust key.** Swift Build's build-description id is stable across null builds, and it changes when settings change, when a source file is added, or when a different target is requested.

**Other answers:**
- The dependency scanner gives the module graph and each module's origin in one call (0.40 s warm, 1.9 s cold). That is worth having as a test oracle, but not as a per-run step.
- No SIL print option qualifies type names. This is verified in `SILPrinter.cpp`, so the ambiguity check (0.06–0.23 s) stays.
- Running the toolchain's `libswiftDemangle` in-process gives byte-identical output in 0.8 ms instead of 75 ms.
- A `swift package scan` command plugin works. It reuses the user's `.build`, but the sandbox forces a different hand-off of the build log to `sfverify`.
- Xcode and xcodebuild logs carry the same `builtin-SwiftDriver`/`builtin-Swift-Compilation` lines, so one parser can serve SwiftPM, xcodebuild and Xcode's `.xcactivitylog`.

## 2. Ranked items

| ID | What | Where | How | Evidence | Gain | Class | Guard | Effort | Builds on |
|---|---|---|---|---|---|---|---|---|---|
| K1 | **Fix: `removeProducts` wipes the whole package's intermediates when a target has the package's name**, and `filter` passes `-const-gather-protocols-list <build file>` to the frontend | `SwiftPM.swift:101-123` (line 110: `name == target + ".build"` matches `Intermediates.noindex/<Package>.build` at depth 3), `SwiftPM.swift:204-207` (`dropWithValue`) | Match `<t>-t.build`, `<t>-p.build` (test targets, not handled today) and native `<triple>/<config>/<t>.build`, never a child of `Intermediates.noindex`. Add `-const-gather-protocols-list` to `dropWithValue`. Also drop `-Xcc -ivfsstatcache <file>`, `-clang-build-session-file <file>` and `-validate-clang-modules-once`: all three only reference build files | **MEASURED** on `k/pkg2` (package `Pkg2`, targets `Pkg2` and `Other`), `rm -rf .build/sfverify; sfverify --package . --target Other --build`. Base binary: 2 of 2 cold runs exit 2 with `could not check that type names are unique … <unknown>:0: error: cannot open constant extraction protocol list input file …Other_const_extract_protocols.json`. Afterwards `Pkg2.build/Debug/` holds only `Pkg2-t.build`. Patched binary: 2 of 2 pass ("Proved safe: 4"). Same failure on this repo: `--target SwiftFormalContractsTests --build`, 56 s cold, exit 2; a second run passes ("fails once, then works") | Correctness of `--build` and `check` for the most common package layout | (a) bug fix | New `SFVerifyKitTests` case: a fake scratch tree with `out/Intermediates.noindex/P.build/Debug/{P-t.build,Q-t.build,Q-p.build}`; `removeProducts(of: "P")` leaves `Q-*`. Oracle-lane test: cold `--build` on a two-target fixture whose package and target share a name | S | P1 (P1 removes the dependency rebuilds, but the main target still goes through `removeProducts`) |
| K2 | **Enforce the compiler pin on the Scan path, and use the `swiftc` SwiftPM used** | No call to `PinnedCompiler.check` or `CompilerToolchain.installed` anywhere in `SFVerifyKit` or the CLIs (grep: only `CompilerPin.swift`, `ProofDigest.swift:125`, `CachedVerifier.swift:48`, tests). `SwiftPM.swift:159-160` drop `tokens[0]`; `Compile.swift:153` runs `/usr/bin/xcrun swiftc` | In `ModuleCompiler.compile`, resolve the compiler once: the absolute path from the SwiftPM log when there is one, otherwise `xcrun --find swiftc`. Run `PinnedCompiler.check` against that same binary, so `swiftc -version` is cached per process. Use the same path for `emitSIL` and for `TypeNameCheck`. Add `--allow-unpinned`, which prints a warning line and adds an optional `compiler` key (version line, path) to the report schema | **VERIFIED:** TRUST.md:31 says "other compilers fail closed", but the CLI path has no check. **MEASURED:** `DEVELOPER_DIR=/Library/Developer/CommandLineTools` silently switches the compiler (the CLT `swiftc` happens to be the same 6.4 build: compile 15.8 s cold). `TOOLCHAINS=nonexistent` silently falls back to Xcode's `swiftc`. **Not shown:** a run on an unpinned compiler. `xcrun` refuses a fake `DEVELOPER_DIR` (`malformed developer path`), so no wrapper test was possible without writing outside scratch | Makes the trust claim true. Costs one `-version` per process (0.1 s; can be shared with K10's `-print-target-info`) | (c): users on another compiler now get `UNPINNED COMPILER` (exit 2) | Test with `CompilerToolchain` injected: fake version, so `SFVerify.run` throws `.unpinnedCompiler`; `check-cli.py` golden for the message and for `--allow-unpinned`; schema validation | S | Round 1 X-series and S2 (spawn helper) |
| K3 | **Args cache keyed by Swift Build's build-description id**, in place of "delete products and rebuild" on a null build | `SwiftPM.swift:22-37` | After `swift build`, read the last line of `<scratch>/out/Intermediates.noindex/XCBuildData/prior-build-descriptions.txt`, the id of the `.xcbuilddata` just used. Save the args together with that id, and reuse them only on an exact match and when every `@file` and path argument exists. Native build system: read `args` from `<scratch>/debug.yaml` directly; every target's full command is there after any build. Rebuild only when nothing matches | **MEASURED** on `k/pkg`. The id stays the same over 2 null builds and over `touch` of a source. It changes when Package.swift gains `.define("K2")`, when a source file is added (and returns when the file is removed: content-addressed), and when the request is a different `--target`. Native `debug.yaml` has `"C.Kern-…module": args: [swiftc, -module-name, Kern, … -DKERN_FLAG …]` | No product deletion in the warm case, so a stale cache can never hit. Saves one rebuild: 15–20 s cold, about 1–3 s warm on small targets | (a) | Same JSON on gate, Metrics and synthetic targets, cold and warm. Unit test: cache rejected when the id differs | S–M | P1, K1 |
| K4 | **Rewrite KNOWN-ISSUES #2 and complete `macroPluginArguments`** | `Compile.swift:167-185`; `docs/KNOWN-ISSUES.md` #2 | Add `-plugin-path <toolchain>/lib/swift/host/plugins/testing`, `-F <platform>/Developer/Library/Frameworks` and `-I <platform>/Developer/usr/lib` (SwiftPM passes the same). Then rewrite #2: "package-defined macros need `--build`; the Gate cannot load them" | **MEASURED:** `sfverify --package . --target SwiftFormal` (no `--build`) gives 139 functions, 46 safe, so `@TaskLocal` works. Loose `@Observable` + `#Predicate` (external `swift-plugin-server`) work. `SwiftFormalContractsTests --build` (`@Verify` through the passed-through `-Xfrontend -load-plugin-executable …SwiftFormalMacros#SwiftFormalMacros`, plus `@Test`) gives 158 functions, 3.5 MB SIL, compile 2.2 s. Loose `import Testing` + `@Test`: today `no such module 'Testing'`; with the 3 flags it compiles (5 functions). Loose `@Verify`: `plugin for module 'SwiftFormalMacros' not found` (expected) | Test files and Swift Testing users scan in loose mode; correct docs | (a) + docs (c) | Fixture test: loose file with `import Testing` and `@Test` compiles to SIL; KNOWN-ISSUES link check | S | a169c55 (added `macroPluginArguments`) |
| K5 | **`swift package scan` command plugin** for discoverability, on the user's own `.build` | New `Plugins/SwiftFormalScan`; `sfverify` takes a log file | The plugin calls `packageManager.build(.target(T), parameters: .init(logging: .verbose))` and writes `logText` into `context.pluginWorkDirectoryURL`. It then runs `sfverify --package . --target T --build-log <file> --cache-dir <workdir>`, which has no nested `swift build`. Needs the K3 cache, because a null build prints no compile command | **MEASURED** (prototype in `k/pkg/Plugins/Scan`). After the user's `swift build`, the plugin's build is a null build (0.75 s), so there is no second build tree. Today `--build` builds a separate `.build/sfverify`: 56 s cold for `SwiftFormalContractsTests`. After `touch`, `logText` (21.5 KB) holds the 3 `-module-name Kern` driver lines. `compilationConditions` = `["KERN_FLAG"]`. Spawning `sfverify` (loose files) inside the plugin works. `sfverify --build` inside the plugin fails: the sandbox blocks writing `.build/sfverify/sfverify-build.log` | One cold build instead of two; `swift package scan` shows up in `swift package plugin --list` | (c) new surface | `check-cli.py` entry; example package run in the oracle lane | M | P1, K3, S9 (separate scratch for tests stays) |
| K6 | **Xcode and Tuist: read the compile command from xcodebuild output or DerivedData** | `SwiftPM.swift:146-162` already parses `builtin-SwiftDriver -- ` / `builtin-Swift-Compilation -- ` | `sfverify --xcode-log <file|DerivedData dir> --target T`: take the newest `Logs/Build/*.xcactivitylog` (gzip, SLF0 text), or a teed `xcodebuild` log, and reuse `compileCommand` | **MEASURED:** `xcodebuild -scheme Pkg-Package build` prints the same `builtin-SwiftDriver -- …swiftc … -module-name Kern … -DKERN_FLAG -DK2 …` lines. `gunzip -c …xcactivitylog \| strings` holds 4 `module-name Kern` hits. `-showBuildSettings -json` returned 0 entries for a package scheme, and gives only settings, not command lines. **PROJECTED:** Tuist (`tuist build` runs xcodebuild on a generated project), not tested | Scan for Xcode app targets with exact flags; today only loose files work there | (c) | Fixture: a saved xcodebuild log gives the same args as SwiftPM's for the same package | M | — |
| K7 | **Demangle in-process with the toolchain's `libswiftDemangle`** | `Demangle.swift:36-54` spawns `xcrun swift-demangle --simplified` | `dlopen(<dir of resolved swiftc>/../lib/libswiftDemangle.dylib)` (`.so` on Linux), then `swift_demangle_getSimplifiedDemangledName(sym, buf, size)`. If the library is missing, fall back to the spawn | **MEASURED** (`k/dm`): 690 symbols from SwiftFormal's SIL. Library: 0.73–0.91 ms, **0 mismatches** with `swift-demangle --simplified`; spawn: 75–77 ms. The runtime's exported `swift_demangle` (in the macOS SDK's `libswiftCore.tbd`, so present on macOS 13) only fully demangles: any `flags` other than 0 is a `fatalError` (`stdlib/public/runtime/Demangle.cpp` ~:921@6.4.0). That gives 684 of 690 different strings (`SwiftFormal.SplitMix64.next() -> Swift.UInt64` vs `SplitMix64.next()`) | About 70 ms per scan with symbols in the report; about 10 ms after S2 | (a) with the library; (c) with the runtime | Golden reports unchanged; unit test comparing library output with the spawned tool on a fixed symbol list | S | S2 (rank low: S2 takes most of this) |
| K8 | **Use the dependency scanner as a test oracle for import discovery** (not per run) | `SILImports.swift:5-11`; `Compile.swift:75-108` | Oracle-lane test: for each SIL fixture module, `swiftc -frontend -scan-dependencies` gives the main module's `sourceImportedDependencies`. These must equal `module.imports` (minus `Builtin`). Catches C1-class misses (new import syntax). Optionally read Swift Build's free `<T>-dependencies-1.json` (transitive list, `modulePath`/`clangModulePath`, `isFramework`) to label each unlinked module as SDK or package in the report | **MEASURED:** one scan of `Kern` = 0.40 s warm, 1.92 s cold. The output names the graph (54 modules with `directDependencies`) and the origin: `moduleInterfacePath` under the SDK, `swiftPrebuiltExternal` + `compiledModulePath` under `.build` for package modules. The SIL `import` lines cost 0. `-dependencies-1.json` is written by every Swift Build compile (53 entries for Kern) | Guards soundness of linking and of the ambiguity check (C1 class) | test only (a) | The oracle test itself | S | C1 (5e669a1) |
| K9 | **One stable implicit module cache for every Scan compile** | `Compile.swift:121-139` (no `-module-cache-path` in loose mode); `--build` inherits `-module-cache-path <scratch>/out/ModuleCache.noindex` from SwiftPM | Pass `-module-cache-path` = one directory per toolchain (`<user cache>/sfverify/ModuleCache-<compiler hash>`) to `emitSIL` and `TypeNameCheck` in both modes, in place of SwiftPM's scratch path. Clang and Swift module caches are keyed by option hashes, so sharing is the designed use | **MEASURED:** `-emit-sil` of Kern (`import Foundation`) with a fresh module cache: 21.2–30.3 s; warm: 0.11–0.14 s. Through the driver with explicit modules from Swift Build: 3.8 s cold, 0.38 s warm. **PROJECTED:** the first scan of each new `--scratch-path`, CI checkout or plugin work dir drops from about 20 s to the warm cost | Cold-start latency (gate in a fresh CI job) | (a) | Same JSON; time of a cold-cache run reported in `metrics.py` (report only) | S | S3 |
| K10 | **Toolchain locator: `-print-target-info`, Linux, DEVELOPER_DIR/TOOLCHAINS** | `/usr/bin/xcrun` hard-coded in `Compile.swift:153,189,202`, `SwiftPM.swift:133`, `Demangle.swift:39`, `Check.swift:184`, `ProofDigest.swift:76`, SILVerify, LLVMVerify | Fold into S2's spawn helper. Darwin: `xcrun --find swiftc` and `--show-sdk-path` once. Linux or `SWIFT_EXEC`: `swiftc` from PATH, no `-sdk`. Then one `swiftc -print-target-info` (0.10 s) for `compilerVersion` (K2), `target.triple` and `paths.runtimeResourcePath`. The last one gives `host/plugins` without guessing from the SDK path. Print the resolved compiler path in `--json` and text | **MEASURED:** `-print-target-info` takes 0.10–0.11 s, and its JSON has `compilerVersion`, `swiftCompilerTag`, `triple` and `runtimeResourcePath`. `xcrun --find` / `--show-sdk-path` take under 0.01 s each (cached by xcrun). `DEVELOPER_DIR` is honoured (CLT `swiftc` used). An unknown `TOOLCHAINS` falls back silently. **VERIFIED:** loose-file mode passes no `-target`, so the frontend defaults to the host (`arm64-apple-macosx27.0.0`), not the package's deployment target. `--build` passes SwiftPM's `-target … macos13.0` | Linux becomes possible (D10 keeps Scan macOS-only today); one report line removes "which compiler?" questions | (a)/(c) | `check-portability.py` builds `sfverify` on Linux in CI when D10 changes. Unit test on the locator with a fake environment | M | S2, D10 (platforms.md), X4 |
| K11 | **Gate diagnostics: richer notes, planning-time errors** | `Gate.swift:93-98, 177-187`; `Plugins/SwiftFormalGate` | Keep one-line clang-style output, which is all a build command can give. Add `note:` lines: inputs at the trap line, the `f_ensures` line for a broken contract, the function's declaration line when the trap is in a callee. Report a marker that is not followed by a function from the plugin itself with `Diagnostics.error(_:file:line:)` at planning time, before any compiler run | **VERIFIED** in the PackagePlugin 6.4 interface (`PluginAPI/PackagePlugin.swiftmodule/arm64-apple-macos.swiftinterface:23-35,54-67`): `Command.buildCommand(displayName:executable:arguments:environment:inputFiles:outputFiles:)` has no diagnostics-file field, so no `.dia` for plugin commands. `Diagnostics` has `error`, `warning`, `remark`, `progress` with `file:line:` only: no column, no note. **MEASURED:** in the CLI, a plugin `Diagnostics.warning("…", file:, line:)` printed as a bare `warning: demo warning`. **PROJECTED:** Xcode turns `file:line:col: note:` lines of a build command into sub-issues (not tested here; gate.md records only that xcodebuild fails with the message) | Faster fixing in the editor | (c) | `GateTests` golden diagnostics | S | — |
| K12 | **Gate: package macros and imports of sibling targets** | `SwiftFormalGate.swift:8-21` passes only the target's files | Option A: document that a gated target must not use package macros (fails closed today). Option B: the plugin passes `--macro <name>` for each dependency with `kind == .macro`, and `sfverify` looks for `<name>` executables under the products dir derived from `pluginWorkDirectoryURL`. That relies on an undocumented layout and on build order | **VERIFIED:** no PackagePlugin API gives a build-tool plugin the path of a built macro or library (`tool(named:)` resolves only declared tool dependencies; `BuiltArtifact.url` exists only in a command plugin's `BuildResult`) | Gate on `@Verify` users, i.e. this package's own audience | (c) | Example package with `@Verify` + gate | M (B) | — |

## 3. Design sketches (top items)

**K1, patch, 6 lines, measured.**
```swift
// SwiftPM.swift removeProducts, inner test
let native = name == target + ".build" && !dir.hasSuffix("/Intermediates.noindex")
if native || name == target + "-t.build" || name == target + "-p.build" { try? FileManager.default.removeItem(atPath: path) }
// dropWithValue += "-const-gather-protocols-list"
```
A stricter version matches the exact paths instead of searching 5 levels: `out/Intermediates.noindex/*/<Config>/<t>-{t,p}.build` and `<triple>/<config>/<t>.build`. With K3 in place, `removeProducts` should only run when there is no cache entry for the current description id.

**K2, the pin on the path that produces verdicts.**
- Add a `Toolchain` value, resolved once per process: swiftc path, version line, SDK path, resource dir.
- `ModuleCompiler.compile` takes it and calls `PinnedCompiler.check(toolchain:)` before `emitSIL`.
- For `--build`, the path comes from the log's `tokens[0]`. When it differs from `xcrun --find swiftc`, the log's path wins and is the one checked.
- `TypeNameCheck` and `Demangler` use the same `Toolchain`.
- Error text is already written: `ProofCacheError.unpinnedCompiler`.
- `--allow-unpinned` exists for people who validate a new compiler. It is printed in the report header and in JSON as `compiler.pinned: false`.
- Gate: no override flag. An unpinned compiler fails the build, which is what TRUST.md promises.

**K3, key the args cache on the build description.**

`plan()`:
1. Run `swift build --target T -v`.
2. Read the description id, `descId = lastLine(XCBuildData/prior-build-descriptions.txt)`.
3. Parse the log for T's command. If found, store `{descId, args}`.
4. If not found and the stored entry has the same `descId` and every referenced file exists, use it.
5. Otherwise remove only T's own `-t.build` and rebuild (K1).

Under P1, a single root-target build serves all dependencies under one id. Native build system: parse `<scratch>/debug.yaml` (`commands["C.<T>-<triple>-debug.module"].args`), with no rebuild ever. Both files are internal formats, so every read falls back to today's rebuild path.

**K5, the command plugin.** `swift package scan [--target T] [-- sfverify args]` works like this:
1. `packageManager.build(.target(T), .init(configuration: .debug, logging: .verbose))`.
2. If the build fails, report through `Diagnostics.error` and exit.
3. Write `logText` to `workdir/build.log`.
4. Run `context.tool(named: "sfverify")` with `--build-log workdir/build.log --cache-dir workdir --package <root> --target T`. `--cache-dir` keeps K3's cache in the plugin's writable directory.

Read-only to the package, so no `permissions:` are needed. A JSON report written into the package would need `.writeToPackageDirectory`.

**K4: the macro and Testing flags.**

Add to `macroPluginArguments` and `sdkArguments`, under each one's `fileExists` check:
- `-plugin-path <tc>/lib/swift/host/plugins/testing`
- `-F <platform>/Developer/Library/Frameworks`
- `-I <platform>/Developer/usr/lib`

Here `<platform>` is the SDK path with two components removed, as for `swift-plugin-server` today.

## 4. Decisions for the owner

1. **K2 behaviour.** Should an unpinned compiler be a hard failure for `sfverify` and `check`, with `--allow-unpinned` as the only way through, or a warning? (TRUST.md promises failure.) Also: should `--build` prefer SwiftPM's `swiftc` path over `xcrun`'s when they differ?
2. **K12.** Gate plus package macros: document the limit (A), or rely on an undocumented products layout (B).
3. **K5.** Add a second plugin product, `SwiftFormalScan`, to the public manifest (API surface, CHANGELOG).
4. **K10.** Is Linux worth enabling for Scan? D10 says macOS-only. The locator is cheap; the pin and the SIL grammar on Linux would need their own lane run.
5. **K9.** Where the shared module cache lives: under the user's cache directory, or SwiftPM's global cache. Either way it is written outside the package.

## 5. Rejected

- **Fully-qualified type names from SIL, to remove TypeNameCheck at its root.** No option exists.
  - `PrintOptions::printSIL` (`lib/SIL/IR/SILPrinter.cpp:5121-5135@6.4.0`) never sets `FullyQualifiedTypes`. None of the SIL printer's `cl::opt`s (`SILPrinter.cpp:68-108@6.4.0`: `-sil-print-types`, `-sil-full-demangle`, `-sil-print-debuginfo` …) do either.
  - `FullyQualifiedTypesIfAmbiguous` (`include/swift/AST/PrintOptions.h:270-277, 850-854@6.4.0`) is used only by `printQualifiedSILType`. That covers witness tables, vtables and `witness_method` (`SILPrinter.cpp:2756, 4483-4772@6.4.0`), not instruction types.
  - **MEASURED:** `func useBase(_ p: Base.Point)` prints as `func useBase(_ p: Point)` next to `Kern.Point`, with and without `-sil-print-types` / `-sil-full-demangle`.
  - Mangled symbols carry modules: a full demangle gives `Base.Point` in signatures. But types inside bodies stay unqualified, so this could only add information, never replace the check.
- **Replacing TypeNameCheck with other sources.**
  - `swift-symbolgraph-extract`: Foundation alone takes 24.4 s and writes 46 MB. **MEASURED.**
  - Reading `.swiftinterface` files misses clang modules. That is unsound: `Point` exists in MacTypes.h, which is reachable through `import CoreServices`.
  - The compiler probe costs 0.06–0.23 s warm (MEASURED with Foundation, SwiftUI and package modules), so there is nothing to win.
- **libSwiftScan in-process.** The toolchain ships it as `lib/swift/host/lib_InternalSwiftScan.dylib`, an internal name with no stable ABI. The command-line scanner (K8) is enough for a test.
- **Emitting SIL through the driver with Swift Build's explicit modules.** It works and gives the same SIL except one `loc` on an imported declaration, but it is slower: 0.38 s against 0.11 s warm (MEASURED). The frontend with an explicit module map fails because the SDK pcm target does not match (macos27 vs 13).
- **Parsing `task-store.msgpack`** in `.xcbuilddata`, which holds the arguments of every task. It is a private binary format; K3's description id gives the same robustness through public behaviour (the `-v` log).
- **`xcodebuild -showBuildSettings -json`** as the source of flags: it gives settings, not the composed command, and nothing at all for package schemes (MEASURED: 0 entries).
- **Skipping the null `swift build` when sources look unchanged** (0.78–0.96 s per call, MEASURED). A stale dependency `.swiftmodule` with changed `@inlinable`/`@_transparent` bodies would be inlined into the SIL that gets proved. Only safe with a complete input-closure check, which is what the build system already does.

## 6. Sources

- Repository: `Sources/SFVerifyKit/{Compile,SwiftPM,TypeNameCheck,Demangle,Gate,SFVerify,Check}.swift`, `Sources/sfverify/main.swift`, `Sources/SwiftFormalCLI/main.swift`, `Plugins/SwiftFormalGate/SwiftFormalGate.swift`, `Sources/SFSIL/{CompilerPin,ProofCacheVersions,ProofDigest,SILImports}.swift`, `docs/TRUST.md:31`, `docs/KNOWN-ISSUES.md` #2/#6, `docs/guides/{gate,compilers,platforms}.md`; round 2 plan (P1, S2, S3, S8, S9).
- Swift 6.4.0:
  - `lib/SIL/IR/SILPrinter.cpp:68-108, 2756, 4483-4772, 5121-5135`
  - `include/swift/AST/PrintOptions.h:270-277, 735-760, 848-854`
  - `stdlib/public/runtime/Demangle.cpp` (`swift_demangle`, flags must be 0; WebFetch)
- Toolchain files:
  - `usr/lib/libswiftDemangle.dylib`, which exports `swift_demangle_getSimplifiedDemangledName`, `swift_demangle_getModuleName` and others
  - `MacOSX.sdk/usr/lib/swift/libswiftCore.tbd`, which exports `_swift_demangle`
  - `usr/lib/swift/pm/PluginAPI/PackagePlugin.swiftmodule/arm64-apple-macos.swiftinterface`
  - `usr/lib/swift/host/plugins/{libSwiftMacros,libObservationMacros,libPlaygroundMacros}.dylib` and `host/plugins/testing/`
  - `MacOSX.platform/Developer/usr/{lib/swift/host/plugins,bin/swift-plugin-server}`
- SwiftPM 6.4 `swift build --help`: `--build-system` (default: swiftbuild; native and xcode are deprecated).
- Logs: `SCRATCH/k/pkg-build-v.log`, `k/pkg-v2.log`, `k/xcb.log`, `k/sfct-build.err`, `k/sfct-build2.json`.
