# Swift-internals research, 2026-11-07

The evidence behind [the Swift-internals plan](../../design/plans/2026-11-07-swift-internals.md). Six
investigations ran in parallel on scratch copies of `main` at `d759be7`, with the pinned compiler (Apple Swift 6.4,
`swiftlang-6.4.0.34.1`) and the compiler sources at `swift-6.4.0-RELEASE` (`b8189d7`). Frozen history, like the rest
of `archive/` ([ADR 0001](../../../docs/decisions/0001-archive-policy.md)).

| Report | Prefix | Question |
|---|---|---|
| `reports/sil-coverage.md` | L | What Swift can Scan read, what blocks it, how to add each feature soundly |
| `reports/toolchain.md` | K | How Scan meets swiftc, SwiftPM, Swift Build, Xcode, macros, the pin, plugins |
| `reports/stdlib-trust.md` | R | Are the standard-library summaries right; can they be pinned or replaced |
| `reports/compiler-corpus.md` | V | Validation against the compiler's own tests and constant folder; pin upgrades; mutation testing |
| `reports/architecture.md` | H | Pipeline structure, IR, modular verification, modern Swift in the engine, packaging |
| `reports/dx.md` | U | What a user meets: onboarding, Swift Testing, macros, gate output, other tools' UX |

The reports refer to `SCRATCH/...`: the session's temporary scratch directory, which is gone. What was worth keeping
is here:

- `fixtures/stdlib-trust/`: the soundness repros for R1 to R5 (`fx.swift`: R1 and R4; `fx2.swift`: R4; `fx3.swift`:
  R2; `fx5.swift`: R3; `as.swift`: R5; `big.swift`: the allocation limit; `ns.swift`: String facts that are false;
  `all.swift`: one call per summary entry; `run*.swift`: native drivers). Scan them with a release `sfverify`
  (`sfverify fx.swift`), then build each with a `main.swift` calling the function at the input the report names and
  run it: it traps (exit 133).
- `fixtures/corpus/noncopyable-deinit.swift`: the V1 repro (`consume(Guard(x: 0))` traps natively; Scan said `safe`).
- `prototypes/sil-coverage-float-and-loop.diff`: the two coverage prototypes (floats as opaque values, loops with
  invariant `true`), behind `SF_PROTO_FLOAT` and `SF_PROTO_LOOPS`. Measurement only; not for merging as is.
- `tools/mutation/`: the V6 mutation harness (`mutants.py`, `run.py`, `attribute.py`) and both runs' results
  (`results-run1.txt`: 14 of 14 killed; `results-clean.txt`: the sequential rerun, 6 of 6 killed before it was
  stopped). Run from a repo copy: `python3 run.py <repo> '<test filter>' [M01 …]`.
- `tools/pin-churn/`: the V7 static churn scripts (SIL vocabulary, printer tokens, visitor fingerprints) that a
  `Scripts/pin-upgrade.sh` would start from.
- `tools/corpus/`: the V3 corpus drivers (`emit-one.sh`, `ir-one.sh`, `run-corpus.sh`, `run-diff.sh`). They expect
  the work-directory layout the report describes (`V` defaults to the current directory).
