# Sandboxes

A sandbox is one small piece of SwiftFormal that builds, tests and runs on its own. It holds real production code
(never a copy) and is checked early against the real code that uses it (its consumers).

- How to work with them: [sandbox workflow](../guides/sandbox-workflow.md).
- What really builds on which platform: [platforms](../guides/platforms.md).
- Source of truth: `Scripts/sandboxes.py`. `Scripts/check-layering.py` and `Scripts/check-sandboxes.py` keep it,
  `Package.swift` and these cards in line.

| Sandbox | What it is | Tests (fast loop) | Platforms | Main known gap |
|---|---|---|---|---|
| [SwiftFormal](SwiftFormal.md) | Walk: domains, properties, the walk behind `Prove` and `@Verify` | `SwiftFormalTests` | macOS, iOS | a trap inside a walked function cannot be caught in-process |
| [SwiftFormalTesting](SwiftFormalTesting.md) | Walk inside Swift Testing | `SwiftFormalTestingTests` | macOS, iOS | no consumer command in the registry (`Examples/Walk` runs in CI only) |
| [SwiftFormalMacros](SwiftFormalMacros.md) | `@Finite`, `@Verify`, `#requires`, `#ensures` macros | `SwiftFormalMacrosTests` | macOS | checks expansion text only |
| [SFCNF](SFCNF.md) | Shared clause and formula types (29 lines, capped at 150) | none | macOS, iOS | tested only through its users |
| [SFSAT](SFSAT.md) | The SAT solver | `SFSATTests` (slow) | macOS, iOS | slow tests |
| [SFCheck](SFCheck.md) | Independent proof checker | `SFSATTests` (slow) | macOS, iOS | shares its tests with SFSAT |
| [SFBV](SFBV.md) | Bit-vector encoder | `SFBVTests` (very slow) | macOS, iOS | 11+ minutes in debug |
| [SFProve](SFProve.md) | Symbolic proofs (preview): whole integer ranges | `SFProveTests` (slow) | macOS, iOS | both test consumers are slow |
| [SFSemantics](SFSemantics.md) | What Swift's integer operations mean (`S0`) | `SFSemanticsTests` (about 50 s) | macOS, iOS | consumer tests are slow |
| [SFSIL](SFSIL.md) | Reads compiler SIL, proof cache, compiler pin | `SFSILTests` (slow) | macOS | largest sandbox; needs `Process` |
| [SFLLVM](SFLLVM.md) | Reads LLVM IR (second reader) | `SFOracleTests` (slow) | macOS | no production consumer; ADR 0008 |
| [SFVerifyKit](SFVerifyKit.md) | Scan: the engine behind `swiftformal check` | `SFVerifyKitTests` | macOS | needs `Process`; first golden run |
| [sfverify](sfverify.md) | The maintainers' scanner command (no product) | none | macOS | none of its own |
| [SwiftFormalScaling](SwiftFormalScaling.md) | Scaling curves (only with `SWIFTFORMAL_BENCH`) | none | macOS | needs `-enable-testing` |
| [SwiftFormalCLI](SwiftFormalCLI.md) | The `swiftformal` command: logic first, then walks | none | macOS | none of its own |
| [SFLanguageServer](SFLanguageServer.md) | `swiftformal lsp`: verdicts in the editor, never stale ✓ | `SFLanguageServerTests` | macOS | a change no watcher reports is caught only for the function's own file |
| [SFGenKit](SFGenKit.md) | Generates checks from symbol graphs | `SFGenKitTests` | macOS | no end-to-end check |
| [sfgen](sfgen.md) | The maintainers' generator command (no product) | none | macOS | no consumer in this repository |
| [SFTestSupport](SFTestSupport.md) | Test tags `.slow` and `.oracle` for the lanes | none | macOS | `swift test` cannot select tags yet |

"Slow": minutes in debug, so the fast lane (`Scripts/test-lane.sh fast`, run by `Scripts/safety-net.sh`) skips it. In
debug `SFBVTests` took over 11 minutes and `SFSILTests` about 10 (both stopped unfinished). In release each finishes in
under a minute (`Scripts/test-lane.sh slow`, `Scripts/baseline/timings.md`).

Decisions behind this layout: [ADR 0008](../decisions/0008-sfllvm-status.md) and
[ADR 0009](../decisions/0009-carve-outs.md).
