# Archive: how we got here

This folder is frozen history. It is kept because SwiftFormal's honesty comes from evidence, but you do not
need it to use or contribute to the library.

| Folder | What it was | Result |
|---|---|---|
| `experiments/` 0.0.3 to 0.0.7 | Lean proofs of Swift SIL, translation validation, control flow | led to the pure-Swift SAT prover; run log in `experiments/CHANGELOG-0.0.x.md` |
| `prototype/` | first spec language and Lean emitter | superseded |
| `research/` | feasibility and design notes | decisions summarised in `docs/decisions/` |
| `design/` | the working plans and design specs the code was built from | decisions summarised in `docs/decisions/` |
| `EXPLAINED.md`, `REPORT.md` | beginner explanation and first report | read `docs/MENTAL-MODEL.md` instead |

The validation runs on a production iOS app ("app study" rounds) are summarised in
[`CHANGELOG-pre-0.1.md`](CHANGELOG-pre-0.1.md), the development log before 0.1.0. Their raw material (the app's code,
manifests and logs) is not public.

Evidence bundles (hundreds of MB of build output, `.artifacts/` folders) are not in git. See
`docs/decisions/0001-archive-policy.md`. They stay on disk where they were generated, inside `experiments/`.

Not here on purpose: `tools/builtin-oracle/` stays at the repository root. The test `S0BuiltinOracleTests` reads
`tools/builtin-oracle/oracle.swift` by path, and we do not change tests while tidying. It moves when that test is
allowed to change.

Paths inside the moved documents still use the old root-relative names (`experiments/...`, `prototype/...`,
`docs/research/...`). Add `archive/` in front when you look for them.
