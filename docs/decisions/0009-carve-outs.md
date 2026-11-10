# 0009: Which modules to carve out of bigger ones (Phase 3B)

## Context

Working in a small sandbox is faster and safer than working in a big one. So for each large module we asked: is there a clean piece that could become its own module without changing any code, only by moving files? A carve-out must not create a dependency cycle, must not be a copy, and must not be a new package that only exists to dodge a build.

Sizes today: `SFSIL` 2,965 lines (8 files), `SFVerifyKit` 1,279, `SFLLVM` 1,280, `SFGenKit` 1,115.

## Decisions

| Candidate | Decision | Why (evidence) |
|---|---|---|
| **`SFToolchain`** from `SFSIL` (the compiler pin, digests and versions in `CompilerPin.swift`, `ProofDigest.swift`, `ProofCacheVersions.swift`, `ProofCache.swift`) | **No-go** | The go-condition was "only `CachedVerifier` needs `SFSIL` symbols". That is false. `ProofDigest.swift` builds an `SILModule` and runs `SILEncoder` as its "encoder canary" (lines ~256 and ~267). `CompilerPin.swift` calls `SILCompiler.module` (line 57). `ProofCache.swift` takes `SILModule` in its key functions (lines ~106, 127, 153). `ProofDigest.swift` and `CompilerPin.swift` also use `Optimization`, which is declared in `SILVerify.swift`. Only `ProofCacheVersions.swift` is free of `SFSIL` types (its mentions are comments). Moving the rest would make `SFToolchain` import `SFSIL` while `CachedVerifier` (which stays in `SFSIL`) imports `SFToolchain`: a cycle. Breaking the cycle needs code changes (a protocol or an injected closure), and that is a behavior-adjacent change that gets its own task if we ever want it. |
| **`SFProcess`** (one place that starts `swiftc`, `swift`, `swift-demangle`, `clang`) | **Deferred, no code** | Owner decision D10: Scan and Gate stay macOS-only. `Process` is used in 7 files (10 call sites): `sfgen/main.swift`, `SFLLVM/LLVMVerify.swift`, `SFSIL/ProofDigest.swift`, `SFSIL/SILVerify.swift`, `SFVerifyKit/Compile.swift`, `SFVerifyKit/Demangle.swift`, `SFVerifyKit/SwiftPM.swift`. This is what stops `SFSIL`, `SFLLVM` and `SFVerifyKit` from building for iOS. Revisit if someone needs those modules on iOS: then funnel the call sites through one `ToolRunning` protocol with a real runner guarded by `#if os(macOS)`, not guards scattered over 7 files. Unit tests would use a fake; the oracle lane and the connected loop would keep using the real runner. |
| `SFVerifyKit` split into report and driver | **No-go** | Cohesive. The `--json` report is the contract, but nothing else reads it yet. Re-check when it passes about 1,500 lines or a second reader of the report types appears. |
| `SFGenKit` | **No-go** | Already its own module and sandbox; depends only on swift-syntax. |
| `SFCNF` | **Guard, not carve** | It is 29 lines. `Scripts/check-layering.py` fails if it grows past 150 non-blank lines, so it cannot quietly become a dumping ground. |
| `SFLLVM` | **Not a carve** | An owner decision, see ADR 0008. |

## Consequences

- Phase 3B adds no new modules. The registry in `Scripts/sandboxes.py` lists exactly the targets in `Package.swift`.
- The `SFSIL` sandbox stays large. Its card says that, and it is the first place to look when a change feels slow.
- The cycle that blocks `SFToolchain` is worth removing only together with a real need (for example the iOS decision above).
