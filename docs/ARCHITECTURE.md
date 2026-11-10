# Architecture

Modules, allowed dependencies, how a Scan request flows, and where to add things. The idea behind it:
[MENTAL-MODEL.md](MENTAL-MODEL.md). One card per module: [sandboxes](sandboxes/README.md). If this page and
`Scripts/sandboxes.py` disagree, the registry wins.

## The modules

| Layer | Modules | Rule |
|---|---|---|
| **Front doors** (the three products: public, documented, versioned) | `SwiftFormal` (app code: Walk, `@Verify`, `#requires`, `#ensures`), `SwiftFormalTesting` (tests: `Prove`, the one way to walk, and the `SFProve` facade, which it re-exports), the `swiftformal` command (`check`, `check --gate`, `doctor`, `lsp`, `strings`) | `public`; every public declaration has a `///` comment (`Scripts/check-doc-coverage.py`) |
| **Maintainers' tools** (executable targets, no product) | `sfverify` (Scan, for the golden scan, metrics, corpus and mutation lanes), `sfgen` | built from a checkout (`swift build --product sfverify`). Their flags and the scan `--json` [schema](schemas/scan-report.schema.json) are recorded by `Scripts/check-cli.py` |
| **Engine room** | `SFCNF`, `SFSAT`, `SFCheck`, `SFBV`, `SFSemantics`, `SFSIL`, `SFLLVM`, `SFVerifyKit`, `SFGenKit`, `SFLanguageServer`, `SwiftFormalMacros` | `package` access, so outside code cannot use them ([ADR 0003](decisions/0003-package-access-for-engines.md)). None of them is a product. |
| **Test support** | `SFTestSupport` (`Tests/Support`) | test tags only; production code never imports it |

| Engine module | Role |
|---|---|
| `SFCNF` | Shared alphabet: literals, clauses, a CNF formula. Capped at 150 non-blank lines. |
| `SFSAT` | The SAT solver. Writes a proof log while it works. |
| `SFCheck` | The independent proof checker (`LRATChecker`, `RUPChecker`). The trusted core. |
| `SFBV` | Fixed-width integers as bits (`BV`) and the circuit builder (`CNFBuilder`). |
| `SFSemantics` | `S0`: what each `Builtin.*` operation means, as one table used by an interpreter and a circuit encoder. |
| `SFSIL` | Reads compiler SIL text (`SILParser.swift` and the files it names). Turns a function into a formula (`SILEncoder.swift`; one `FunctionRun` per function in `SILFunctionRun.swift`; `SILRun*.swift` per instruction family). Proves it (`SILVerify.swift`). Also the proof cache, the compiler pin and `SpecAudit`. |
| `SFLLVM` | A second reader, for LLVM IR. No production code uses it yet ([ADR 0008](decisions/0008-sfllvm-status.md)). |
| `SFVerifyKit` | The Scan driver: runs the compiler, verifies every function, builds the report, runs the gate. |
| `SFGenKit` | The code behind `sfgen`. |
| `SFLanguageServer` | The code behind `swiftformal lsp`: JSON-RPC framing, generation and staleness store, run scheduler, and a runner that starts `swiftformal check --json` as a killable child process ([editor guide](guides/editor.md)). It reads check reports; it does not prove. |
| `SwiftFormalMacros` | The compiler plugin that expands `@Verify`, `@Finite`, `#requires`, `#ensures`. |

## Who may depend on whom

```
SwiftFormalMacros  (compiler plugin: runs in the compiler, never linked into an app)
   ^
SwiftFormal
   ^
   +-- SwiftFormalTesting  -->  SFProve (re-exported)

SFCNF  <--  SFSAT, SFCheck, SFBV  <--  SFProve  <--  SFSIL  <--  SFVerifyKit  <--  sfverify
                    SFBV  <--  SFSemantics  <--  SFSIL            (SFLLVM sits beside SFSIL)

SFGenKit  <--  sfgen
SFVerifyKit  <--  SFLanguageServer  <--  swiftformal (check, doctor, lsp)  -->  SFVerifyKit
```

An arrow means "is imported by". Allowed edges: `Scripts/sandboxes.py`; `Scripts/check-layering.py` fails on any other
edge in `Package.swift`.

**Most important rule:** `SFCheck` imports only `SFCNF`. It never sees the solver (`SFSAT`) or the circuit builder
(`SFBV`), so their bugs cannot hide in the checker ([TRUST.md](TRUST.md)).

## How a Scan request flows

`swiftformal check --scan .:MyTarget` (and the maintainers' `sfverify --package . --target MyTarget --build`):

1. **Flags.** `Sources/SwiftFormalCLI/main.swift` (or `Sources/sfverify/main.swift`). `SwiftPMBuild.plan`
   (`Sources/SFVerifyKit/SwiftPM.swift`) builds the target once with SwiftPM and reuses its compiler flags.
2. **Compile to SIL.** `SFVerify.run` (`SFVerify.swift`) calls `ModuleCompiler.compile` (`Compile.swift`): `swiftc
   -frontend -emit-sil` through `xcrun`. `SILText.prepare` collects names and source positions.
   - With `--build` (and in `swiftformal check`), `compile(_:linking:)` follows the SIL `import` lines: each imported
     target of your own packages (`SwiftPMBuild.localDependency`) is compiled too and merged with `SILModule.link`, so
     its types, conformances and bodies are known.
   - `TypeNameCheck` marks a type name ambiguous if an unlinked module or the standard library also declares it (SIL
     prints type names without their module).
3. **Parse.** `SILModule(text:)` (`Sources/SFSIL/SILParser.swift`) reads blocks and instructions. Anything it does not
   understand makes the function `unsupported`, with the reason.
4. **Encode, per function, in parallel.** `Verifier.run` (`Sources/SFVerifyKit/Verify.swift`) builds one claim: *if
   `f_requires` holds, then `f` does not trap and `f_ensures` holds*. Only the `f_requires` / `f_ensures` that
   `@Verify` wrote count (`SpecIndex` in `VerifySupport.swift`, `FunctionInfo.isVerifyPeer`); a hand-written one is
   listed in `FunctionReport.ignoredContracts` and never read. `SILEncoder.encode` (`Sources/SFSIL/SILEncoder.swift`)
   builds the claim, with `CNFBuilder` (`Sources/SFBV/CNFBuilder.swift`) for circuits and `S0`
   (`Sources/SFSemantics/S0.swift`) for builtin operations.
5. **Solve and check.** `proveReporting` (`Sources/SFProve/Prove.swift`) negates the claim and asks `Solver`
   (`Sources/SFSAT/Solver.swift`) for an input that breaks it.
   - "No such input": `LRATChecker.check` (`Sources/SFCheck/LRATChecker.swift`) must accept the solver's proof, or the
     run throws. Only then is it `proved`.
   - An input found: the model is checked against the formula and returned as a counterexample.
   - Conflict budget ran out: `unknown`.
6. **Report.** The answers become `safe` or `contractHolds`, `mayTrap` or `contractFails`, and `undecided`
   (`ScanStatus` in `Verify.swift`). `ScanReport` (`Report.swift`) prints text or `--json`.

### Around the flow

- **Build gate** (`swiftformal check --gate`, `Sources/SwiftFormalCLI/GateCommand.swift` with `BuildCheck` in
  `Sources/SFVerifyKit`): the same flow for the `@Verify` functions of each target, planned from a SwiftPM build or a
  build log (`--build-log`). Every result that is not proved becomes a compiler error or warning.
  `Sources/SFVerifyKit/Gate.swift` is the same rule for `sfverify --gate`.
- **`swiftformal check`** runs steps 1–6 per `--scan` target (`Check.scan` in `Sources/SFVerifyKit/CheckScans.swift`,
  scheduled by `ScanSchedule.swift`). Different packages run at the same time (`--jobs`). Targets of one package run in
  order: they share its `.build`, SwiftPM's lock and the saved build commands. Parallel targets share one compiler
  (`SFVerify.run` selects the process's `ScanToolchain`). Output comes in `--scan` order, the same as `--jobs 1`.
- **Walks.** `Check.findWalks` reads every `Prove(` in the test sources and names the function each one calls
  (`WalkSubjects.swift`): the subject written first, or the first call of the `it:` closure, or the `call` of an
  `ExitTestWalk` type for `Prove(neverTraps:)`, with the one type a name is declared with in the test sources
  (`WalkSources.swift`). What cannot be read stays unlinked. `Check.plan` runs only the walks whose function logic did
  not prove.

### The Scan proof cache

It sits in step 4. After linking, `Verifier.run` builds one `ScanKeyContext` (`Sources/SFSIL/ScanProofKey.swift`) per
module. It hashes, in parallel, level by level:

- each function's header and body;
- the edges to what it can reach (named callees, witnesses of each `witness_method`'s requirement);
- the module's tables, and the witnesses the encoder looks up by type alone (`SILModule.encoderWitnessRequirements`);
- the build's identity (`ModuleCompiler.identity`: compiler, SDK, target, frontend arguments, configuration, linked
  modules) and the tool's versions.

Then:

- `ScanClaimKeys` (`Sources/SFVerifyKit/ScanClaimKeys.swift`) keys each claim: that base, the closures of the function
  and its contracts, the declarations the claim reads, the budget class.
- `Verifier` looks the key up in `ScanProofCache` (`Sources/SFVerifyKit/ScanProofCache.swift`; file checks in
  `TrustedFiles.swift`). A stored proof replaces steps 4–5. A stored counterexample is replayed first.
- Only checked proofs and replayed counterexamples are stored.
- Everything after step 5 (caller exclusivity, configuration merging, `--llvm-check`) runs as without the cache.
- Not used by loop proofs, `--modular` or the gate.
- `ProofCache.swift`/`CachedVerifier.swift` in `SFSIL` cache Prove's claim, not Scan's.

## Recipes

Every change starts with a failing test. Run the module's own tests first (`Scripts/sandbox.py <NAME>`, see
[sandbox workflow](guides/sandbox-workflow.md)), then `Scripts/safety-net.sh`.

### Add a SIL instruction (Scan understands one more instruction)

1. `Sources/SFSIL/SILInstructions.swift`: add a case to `enum Instruction`. `SILInstructionParser.swift`: teach
   `parseInstruction` to produce it. An unrecognized instruction must keep the function `unsupported`: never skip it
   silently.
2. `Sources/SFSIL/SILFunctionRun.swift`: handle the case in the one `switch instruction` of `FunctionRun.execute`, with
   a method in the `SILRun*.swift` file of its family (values, memory, arrays, calls). Say how it affects `trap` and
   `undefined`.
3. `Sources/SFSIL/ProofCacheVersions.swift`: bump `SILFrontendVersion.semantics`.
4. Test: add a function that uses it to `Fixture.source`, and its row to `Fixture.functions`, in
   `Tests/SFSILTests/SILTests.swift`. These tests compare the proof with the same function compiled and run natively.
   Then run the oracle lane (`Scripts/test-lane.sh oracle`): it checks the parser against the real compiler.
5. For a new `Builtin.*` operation instead: add it to `S0Op` in `Sources/SFSemantics/S0.swift` and a case to
   `Tests/SFSemanticsTests/S0Tests.swift`.

### Add a standard library summary (Scan can call one more standard library function)

1. `Sources/SFSIL/SILSummaries.swift`: add the mangled symbol to the table. Use `unknown` only if the function can
   never trap; its result is then a fresh unknown value. If it can trap, do not summarize it: the caller must stay
   `unsupported`.
2. If the result can be computed exactly (like `min` and `max`), add a case and build the result in
   `StdlibSummary.Entry`. Exact results do not count as approximations.
   - An `Array` call goes through `StdlibSummary.ArrayOperation` and `applyArray` in `SILEncoder`. They model the count
     and add each trap the call can make (for example "Index out of range"). Returned elements are `fresh` and count
     as an approximation.
3. Bump `SILFrontendVersion.semantics` in `Sources/SFSIL/ProofCacheVersions.swift`.
4. Test in `Tests/SFSILTests/SILStringTests.swift`: a function that uses the call and cannot trap is proved, and a trap
   that depends on the unknown result is `unknown`, not a counterexample.

### Add a Domain combinator (Walk can describe one more kind of input)

1. `Sources/SwiftFormal/Domain.swift`: add a `static func` on `Domain`, next to `optional`, `arrays` or `product`, with
   a `///` comment. A domain made of samples must say so, so that the verdict is `bounded`.
2. Test: a case in `DomainTests` (`Tests/SwiftFormalTests/SwiftFormalTests.swift`), like `optionalAddsNilFirst`: check
   `count`, the first and last element, and that every value appears once.
3. For a type that needs a derived domain: `Sources/SwiftFormal/Finite.swift` and
   `Sources/SwiftFormalMacros/FiniteMacro.swift`.

### Add a property (Walk can state one more kind of rule)

1. `Sources/SwiftFormal/Properties.swift`: add a `static func` in an `extension Property`, with a `///` comment. Build
   it from `Property.perInput(_:_:)`. For what `perInput` cannot express (such as re-running the function), use
   `Property.custom` (`@_spi(Extending)`), like `deterministic()` and `injective()`. A failure message must name the
   input.
2. Test: a case in `VerifyTests` (`Tests/SwiftFormalTests/SwiftFormalTests.swift`), like
   `injectivityNamesTheCollision`: one function that satisfies it (expect `.isProved`) and one that breaks it (expect a
   counterexample with an input you can name).
3. So users can write it like the others (`Matches(table: [...])`): add a struct conforming to `PropertyConvertible` in
   `Sources/SwiftFormal/PropertyTypes.swift` that wraps the factory. `Prove` takes any `Property` or
   `PropertyConvertible`.
