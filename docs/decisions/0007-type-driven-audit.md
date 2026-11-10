# 0007: Type-driven design audit

## Context

Phase 7B, Task Q.3: make illegal states unrepresentable and let the compiler find the work. The rule (decision D8) is that every change is **additive**: verdicts, golden values and conflict counts stay identical, and `Scripts/check-api.sh` shows no removal that is not allowlisted. A row that would break the public API is written down here as a recommendation and not done.

## Decision

### 1. Compiler flags

`Package.swift` defines `strictSettings` once: `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`. The language mode stays Swift 6.

It is applied to every library and executable module: `SwiftFormal`, `SwiftFormalContracts`, `SwiftFormalTesting`, `SFCNF`, `SFSAT`, `SFCheck`, `SFBV`, `SFProve`, `SFSemantics`, `SFSIL`, `SFLLVM`, `SFVerifyKit`, `sfverify`, `SFGenKit`, `sfgen`. It is not applied to the macro target (its imports come from SwiftSyntax macros) or to test targets. One commit per module group, each green on the safety net.

- No module needed a behavior change. Every fix was an import access level.
- `ExistentialAny` and `MemberImportVisibility` produced no error in any module.
- With `InternalImportsByDefault`, `import X` is internal. A declaration whose signature uses a type from `X` needs `public import X` (public API) or `package import X` (package API). The compiler warns (`#UnusedImportAccess`) when the level is higher than needed, and those were lowered until the build had 0 warnings. The result is that a user who imports `SFProve` does not get `SFBV`, `SFCNF` or `SFSAT` re-exported by accident, except where `SFProve`'s public signatures really use them (`public import SFBV` in `Prove.swift` and `Symbolic.swift`).
- `LRATProof.init(_:)` in `SFProve/LRATBridge.swift` is a `package` initializer that was already package-level before this task. Once `SFProve` uses explicit import levels, the API digester reports it as "removed" from a module that is not its home. Nobody outside the package could call it, so it is allowlisted in `Scripts/baseline/api-allowlist.txt`.
- Not done, on purpose: no test target and no macro target uses the flags, because the tests import engine modules freely and nothing is gained there.

### 2. Warnings are errors in CI only

CI builds with `swift build -Xswiftc -warnings-as-errors`. `Package.swift` does not set it: a consumer's newer compiler must never fail on our warnings.

### 3. Audit table

| Question | Looked at | Decision |
|---|---|---|
| Can a verdict hold a combination that makes no sense? | `SwiftFormal/Report.swift`, `SFVerifyKit/Report.swift` | **No for `Verdict`**: `proved`, `bounded` and `counterexample` already carry their own payload, so a counterexample on a `proved` cannot be written. `Counterexample` and `PropertyResult` have no public initializer. **Yes, but deferred, for `FunctionReport`** (`SFVerifyKit`): it is one flat struct with `status` plus optional `counterexample`, `category` and `detail`, so `safe` with a counterexample compiles. It is a public `Codable` type and its JSON is the output contract of `sfverify --json`, so reshaping it into an enum with payloads would change the JSON and the API. Recommended for 0.2 together with a JSON schema version bump. |
| Can anyone outside the engine construct a "proved" result? | `ProofVerdict`, `Verdict`, `ScanStatus`, `ProofCache` | **Partly. Deferred.** `Verdict`, `Report` and `PropertyResult` cannot be built outside `SwiftFormal` (no public initializer). `ProofVerdict.proved` is a public enum case, so any caller of `SFProve` can write one; it carries no evidence. A `ProofCertificate` that only the engine and the checker create would remove the public case, which breaks the API. Recommended for 0.2. Meanwhile `prove` accepts UNSAT only after `LRATChecker` or `RUPChecker` accepts, and `ProofCache` (package access) documents that anyone who can write to the cache directory can forge an entry, hence `Trust.recheck`. |
| Raw `Int` or `Int32` for different kinds of things (variable, literal, clause index, width, budget)? | `SFCNF`, `SFSAT`, `SFBV` | **Yes, but deferred.** Literals are `Int32`, widths and budgets are `Int`. Newtypes (`Variable`, `Literal`) would touch the solver's inner loop and every public `claim` closure (`(CNFBuilder, [BV]) throws -> Int32` is in `prove`'s public signature). The plan requires identical conflict counts, measured with the Phase 8 metrics (`Scripts/metrics.py`, `docs/PERFORMANCE.md`); the public signature change is breaking. Recommended for 0.2, in `SFSAT` first (package-internal), with conflict counts compared before and after. |
| Stringly-typed identities (compiler version, digests, cache keys)? | `SFSIL/CompilerPin.swift`, `ProofCache*.swift`, `ProofDigest.swift` | **Partly done.** `CompilerFingerprint` and `CompilerToolchain` are already typed. `ProofCache.Entry.verdict` was a `String` compared with `"proved"` in four places, so a typo could never match and never fail to compile. It is now `ProofCache.Entry.Kind` (`proved`, `counterexample`), a `String`-backed `Codable` enum: the JSON written to disk is byte-identical. A file with any other verdict (including `"unknown"` or a forged value) fails to decode and `lookup` rejects it exactly as before (counted in `rejectedEntries`). **Deferred**: a `Digest` type for cache keys (`String` today, `sha256:…`) and a `ToolchainFingerprint` that wraps `CompilerPin.acceptedVersions`. Both are package-internal and safe, but they touch 20 or more call sites in `SFSIL`, `SFLLVM` and tests for no behavior gain. Recommended when the cache format next changes. |
| Untyped `throws` where the error set is closed? | engine modules | **No, for now.** `prove` throws `ProveError` and whatever its `claim` closure throws, and the encoders throw `SILError` and `LLVMError` (package-level) next to the closure's errors; the public `throws` is part of the contract, and typed throws would change public signatures. Package-level functions that throw one error type (`ProofCache.store`, `PinnedCompiler.check`) are called from untyped contexts, so typed throws would only add `any Error` conversions. Recommended only if a public API gets a documented, closed error type. |
| Public protocols and types that are not meant for outside conformance or subclassing? | all public types | **No change needed.** Every public class is `final` (`CNFBuilder`, `SymbolicContext`, `DomainBuilder`, `SourceIndexer`, `TypeIndex`). The only public protocol is `Finite`, which is meant for conformance (the `@Finite` macro writes conformances). The engine modules (`SFBV`, `SFCNF`, `SFSAT`, `SFCheck`) are not products. Their `public` declarations are needed by `SFProve`'s public signatures or by tests, and `package` access was applied where possible in Phase 6 (ADR 0003). |
| Mutable state shared across tasks? | `ProofCache`, `Contract.Recorder`, `Results`, global caches | **Reviewed; one tidy-up done.** `ProofCache` is `@unchecked Sendable` with its only mutable state (`counters`) behind an `NSLock`; `directory` is immutable; files are written atomically. Correct, so it stays a class (an actor would make the synchronous package API async). `Contract.Recorder` is used by one synchronous call at a time through a `@TaskLocal`. `Domain` is `@unchecked Sendable` because it holds closures; it is immutable once built (documented). `Results` (the parallel scan in `SFVerifyKit`) locked every write but read `storage` without the lock; the read happens after `concurrentPerform` returns so it was not a race, but the read now takes the lock too. There are no global mutable variables (`static var` is only computed properties). The TSan lane is Task Q.6. |
| Domain-size and budget arguments that can be zero or negative? | `Budget`, `Domain`, `verify(…budget:)` | **Done.** `Budget.init` already had `precondition(maxEvaluations > 0)`, but `maxEvaluations` is a public `var`, so `budget.maxEvaluations = 0` after creation bypassed it and gave a negative `planned` count. The check now also runs in `didSet`, with a message. A valid budget behaves exactly as before. `Domain` constructors already check `limit > 0`, `maxLength >= 0` and index range. Conflict budgets (`conflictBudget: Int`) accept any value on purpose: zero or negative gives `.unknown` and never a wrong verdict (soundness zoo, `docs/guides/soundness-zoo.md`). |

### 4. What was implemented, and checked how

| Change | Why it is additive |
|---|---|
| Strict settings on 15 modules | Compiler flags and import levels only; golden unchanged. |
| `ProofCache.Entry.Kind` | Package API; same on-disk JSON; same rejection of unknown values; the cache tests pass unchanged except for `== "proved"` becoming `== .proved`. |
| `Budget.maxEvaluations` `didSet` precondition | Valid values behave as before; only a call that would have been a latent bug traps earlier. |
| `Results.values` takes its lock | No behavior change. |

Each change was checked with `Scripts/check-api.sh` (no removal except the allowlisted `LRATProof.init(_:)`) and `Scripts/check-golden.sh` (unchanged), then the safety net.

## Consequences

- The next person who wants to reshape `FunctionReport`, replace `ProofVerdict.proved` with a certificate, or introduce `Variable`/`Literal` newtypes has the reason, the blocker and the measurement they need here. All three are breaking or need the Phase 8 metrics, so they belong to 0.2, with a `CHANGELOG.md` entry and an allowlist line each.
- CI fails on any new compiler warning, including an import level that is higher than needed.
