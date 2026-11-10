# 0003: Engine modules become `package`, only the front doors stay `public`

## Context

Most of the sixteen source targets expose `public` declarations. Most of them (the SAT solver, the bit-blaster, the SIL parser, the proof checker) are the engine room. Users do not need them, and every `public` symbol is a promise to strangers: once published, changing it is a breaking change.

## Decision

- Front doors stay `public`, documented and covered by semantic versioning: `SwiftFormal`, `SwiftFormalContracts`, `SwiftFormalTesting`, the documented facade of `SFProve` (`prove`, `ProofVerdict`, `proveSigned`, `SymbolicInt`, `SymbolicBool`, `SymbolicVerdict`, `SymbolicContext`), and the `SwiftFormalGate` plugin. The `sfverify` and `sfgen` command-line flags and the `--json` output are their contract.
- Engine modules (`SFCNF`, `SFSAT`, `SFCheck`, `SFBV`, `SFSemantics`, `SFSIL`, `SFLLVM`, `SFVerifyKit`, `SFGenKit`, `SwiftFormalMacros`) use `package` access.
- `SFVerifyKit` and `SFGenKit` stay library products for now because the plugin and tooling use them. They move to `package` after one release, once nobody outside depends on them.
- Demote one module at a time, leaf first, one commit per module. The compiler and an API diff check show every symbol that leaves the public surface; each must be an engine type nobody outside the package should use.
- If a symbol turns out to be needed by users, it goes back to `public` and the reason is written here.

## Consequences

- The semver promise is small and honest.
- Engine code can change freely between releases.
- Someone who built on an engine type today will break at the demotion. That is why the first release is `0.1.0`.
- A new tool outside this package cannot use the engine modules. If that is needed, open an issue; the answer may be a new front door instead of widening the engine.

## Outcome of the demotion (Phase 5)

Demoted one module per commit. Order was **dependents first** (`SFLLVM`, `SFSIL`, `SFSemantics`, `SFProve` internals, `SFBV`, `SFSAT`, `SFCheck`, `SFCNF`, then `SwiftFormalMacros`), not leaf first: a `public` declaration cannot mention a `package` type, so a leaf demoted first stops every public dependent from compiling.

Public declarations per module, before (tag `baseline-pre-oss`) and after:

| Module | Before | After | What stays public, and why |
|---|---:|---:|---|
| `SFCNF` | 7 | 1 | `Clause` (a typealias that the public `CNFBuilder.addClause` and `clauses` use) |
| `SFSAT` | 10 | 0 | |
| `SFCheck` | 12 | 0 | |
| `SFBV` | 56 | 52 | `BV` and `CNFBuilder`: the claim closure of the public `prove(inputWidths:…claim:)` is written with them. The multiplier hooks and the raw `cnf` are `package` |
| `SFSemantics` | 15 | 0 | |
| `SFSIL` | 190 | 1 | `Optimization`: part of `CompileOptions` in `SFVerifyKit` |
| `SFLLVM` | 26 | 0 | |
| `SFProve` | 69 | 42 | The facade: `prove`, `ProofVerdict`, `ProofFormat` (a parameter of `prove`), `ProveError`, `proveSigned`, `SymbolicContext`, `SymbolicInt`, `SymbolicBool`, `SymbolicVerdict`. `MulAbstraction`, `RefineStats`, `RefineOutcome`, `proveRefining*` and the LRAT bridge are `package` |
| `SwiftFormalMacros` | 11 | 0 | The macro implementations are loaded by name; nothing outside the module uses them |
| `SFVerifyKit` | 111 | 110 | Decision D1: still a library product. Only `CompiledModule.module` (a `SILModule`) became `package` |
| `SFGenKit` | 93 | 93 | Decision D1: still a library product |
| `SwiftFormal` | 99 | 99 | Same declarations; `Property.Observer`, `Property.Evaluate` and `Property.custom(_:makeObserver:)` are now `@_spi(Extending)` (`Property.perInput` stays the supported way to write a property) |

Things that were surprising, and the decision for each:

- **`prove` exposes `CNFBuilder` and `BV`.** The plan lists `prove` as facade, but its claim closure takes the circuit builder. Hiding them would remove `prove`. They stay `public`, and with them `Clause`. If the facade should shrink to `proveSigned` and the `Symbolic*` types, make `prove` `package` in a deliberate, announced change; `SFBV` and `Clause` then become `package` too.
- **`ProofFormat` stays public** although the plan listed it as `package`: it is a parameter of the public `prove`.
- **`MulAbstraction` and the `proveRefining*` family are `package`.** `prove(...strategy:)` now exposes `.refiningMultipliers` (Phase 6, ADR 0005).
- **`Scripts/check-api.sh` does not see `package` demotion.** The API digester counts `package` declarations as API, so narrowing an engine type does not show up as a break. The allowlist therefore holds only the Phase 4 renames and the four `@_spi` moves above; the public counts in this table are the record of what narrowed.
- `SFVerifyKit` and `SFGenKit` keep their public API (Decision D1). Revisit after the first release.
