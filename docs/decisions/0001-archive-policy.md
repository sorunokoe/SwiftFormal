# 0001: Keep research history in `archive/`, and keep build output out of git

## Context

Before open-sourcing, the repository root held the library and also seven experiment folders (0.0.x), an earlier prototype, a real-app validation run, two long reports and four research notes. The experiments alone were about 456 MB on disk, almost all of it build output and proof artifacts (`.artifacts/`). A newcomer opening the repository could not tell what was the library and what was history.

The history is worth keeping: SwiftFormal's claims come from these experiments, and they explain why the design is what it is.

## Decision

- Move `experiments/`, `prototype/`, `validation/`, `EXPLAINED.md`, `REPORT.md` and `docs/research/` into `archive/` with `git mv`, so file history is kept.
- Write `archive/README.md` saying what each folder was and what it led to.
- Build output and `.artifacts/` folders stay out of git (`.gitignore`). They remain on disk where they were generated and can be rebuilt by the experiment scripts.
- Do not edit the archived documents to fix paths. They still say `experiments/...`; add `archive/` in front.
- One thing stays at the root for now: `tools/builtin-oracle/`. The test `S0BuiltinOracleTests` reads `tools/builtin-oracle/oracle.swift` by path, and the tidy-up does not change tests. It can move together with a one-line path change in that test.

## Consequences

- The repository root shows the library, its tests, its scripts and its docs.
- Links from archived text to other archived text break unless you add `archive/`. This is accepted: the archive is read, not maintained.
- Anyone who wants an evidence bundle has to rerun the experiment, as described in each `RESULTS.md`.
