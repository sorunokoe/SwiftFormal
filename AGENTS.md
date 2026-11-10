# AGENTS.md

Notes for AI coding agents that change SwiftFormal itself. If you are writing code in an app that *uses*
SwiftFormal, use the skill in [`skills/swiftformal`](skills/swiftformal/SKILL.md) instead.

Humans and agents follow the same rules: [CONTRIBUTING.md](CONTRIBUTING.md). This page is the short version and
links to the rest.

## What this project is

SwiftFormal checks Swift code, often code an AI wrote, and says honestly what it proved. Three tools:

- **Walk** (`SwiftFormal`, `SwiftFormalTesting`): runs the real function on every input of a domain you list.
- **Prove** (`SFProve`): proves a claim for whole integer ranges, on a copy written with `SymbolicInt`.
- **Scan** (`swiftformal check`, `SFVerifyKit` and the engine below it): reads the compiler's SIL and proves a function
  cannot trap and keeps its `f_requires` ⇒ `f_ensures` contract, for every input.

`swiftformal check` runs Scan first, then only the walks logic still needs. `swiftformal check --gate` is the build gate,
`swiftformal lsp` the editor server. Background: [README](README.md), [mental model](docs/MENTAL-MODEL.md),
[glossary](docs/GLOSSARY.md).

## Where things are

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the modules, who may import whom, how a Scan request flows, and
  recipes (add a SIL instruction, a standard library summary, a domain, a property).
- [docs/sandboxes](docs/sandboxes/README.md): one card per module, with its tests and known gaps.
  `Scripts/sandboxes.py` is the registry; if a card and the registry disagree, the registry wins.
- Engine modules use `package` access; only the front doors are `public`
  ([ADR 0003](docs/decisions/0003-package-access-for-engines.md)). `SFCheck` (the proof checker) imports only
  `SFCNF` and must never see the solver or the circuit builder.

## The change loop

1. Find the module's card in [docs/sandboxes](docs/sandboxes/README.md) and read it.
2. Write the test first, in that module's own test target, and see it fail.
3. `Scripts/sandbox.py <NAME>` (fast loop), then `Scripts/sandbox.py <NAME> --connect` (the module's real users).
4. `Scripts/safety-net.sh`. It must print `SAFETY NET GREEN`. It runs the fast lane and every check below; it can
   take a long time on a busy machine. Let it finish.
5. Changed an engine module (SFSAT, SFCheck, SFBV, SFProve, SFSemantics, SFSIL, SFLLVM)? Also run
   `Scripts/test-lane.sh slow`, and `Scripts/test-lane.sh oracle` for SFSIL, SFSemantics and SFLLVM.

Lanes, tags and where a slow test goes: [docs/TESTING.md](docs/TESTING.md) and the "Test lanes" part of
[CONTRIBUTING](CONTRIBUTING.md#test-lanes). More on the loop: [sandbox workflow](docs/guides/sandbox-workflow.md).

## Format, lint and ratchets

- Format: `swift format --in-place <files>`. The safety net runs `swift format lint --strict` on `Sources`, `Tests`,
  `Examples`, `Benchmarks` and the manifests.
- Lint: `swiftlint lint --baseline Scripts/baseline/swiftlint-baseline.json --strict`. Old findings are in the
  baseline; a new one fails.
- Ratchets: `python3 Scripts/check-ratchet.py` fails when a quality number gets worse (lint findings, `try!`,
  `Unsafe`, TODOs, size of the trusted code). If you made one better, run it with `--update` in the same change.
- Contracts the safety net also holds: the CLI help and exit codes (`python3 Scripts/check-cli.py`; record an
  intended change with `--record` and review the diff), the golden scan (`Scripts/check-golden.sh`), the JSON schema
  ([scan-report.schema.json](docs/schemas/scan-report.schema.json): a new key goes into the schema in the same
  change), the public API (`Scripts/check-api.sh`), doc comments on public declarations
  (`python3 Scripts/check-doc-coverage.py`), layering (`python3 Scripts/check-layering.py`), and links
  (`python3 Scripts/check-links.py`: every Swift block in README.md must be copied from a file under `Examples/`).

## Soundness rules

A false `proved` (or `safe`, `contractHolds`, a ✓ in the editor) is the worst bug here: a P0
([ADR 0006](docs/decisions/0006-soundness-policy.md)). Saying less is always allowed; saying more than is true never is.

- **Fail closed.** Anything the code does not understand becomes `unsupported` or `undecided`, with the reason.
  Never skip an instruction, a call or a file silently. When unsure, answer less.
- **Only checked answers count.** A Scan proof is `safe`/`contractHolds` only after `SFCheck` accepted the solver's
  proof; a counterexample is real only after it was replayed. Never cache an unknown answer, a budget or time-out
  result, or anything not checked. If you change what the parser, encoder or claim means, bump
  `SILFrontendVersion.semantics` or `ScanClaimVersion` (`Sources/SFSIL/ProofCacheVersions.swift`) so old cache entries
  are not reused.
- **Not proved:** `bounded`, `unchecked`, `undecided`, `unsupported`, `mayTrap`, `stale`, `knownIssue`, `walkMissing`,
  `internalError`. Never render, count or report any of them as proved.
- **Never weaken a claim to make a test pass.** A soundness fix starts with a case in the
  [soundness zoo](docs/guides/soundness-zoo.md) (or `ScanZoo` in the oracle lane for Scan) that fails on the old code.
- What each tool is trusted for: [docs/TRUST.md](docs/TRUST.md). Update it when what is trusted changes.

## Docs, CHANGELOG and hygiene

- Anything a user can see (new API, flag, verdict, fix) gets an entry under `[Unreleased]` in
  [CHANGELOG.md](CHANGELOG.md), and the README, the guide in [docs/guides](docs/guides) and DocC comments are updated
  in the same change. A changed flow also updates [ARCHITECTURE](docs/ARCHITECTURE.md). A new word goes into the
  [glossary](docs/GLOSSARY.md).
- Write docs in plain, short English. Every flag, field and verdict you name must exist in the code or the `--help`
  output; check it.
- No home-directory paths, emails, tokens or credentials in any file
  (`python3 Scripts/check-release-hygiene.py`). Use `<SwiftFormal checkout>` or relative paths in docs.
- Commits: one logical change each, safety net green at each, subject like `fix(SFSAT): …` or `docs: …`
  ([commit style](CONTRIBUTING.md#commit-style)).
