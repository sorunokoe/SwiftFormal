# Contributing

Thank you for helping. This page covers setup, how to make a change, and what a pull request needs. By taking part you
agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Contributions are licensed under the repository [LICENSE](LICENSE).

## Setup

- A Mac with Swift 6 or newer and the Xcode command line tools.
- The pinned compiler is Apple Swift 6.4 ([compilers](docs/guides/compilers.md)); all lanes are validated on it.
  Another compiler builds the package and runs the fast lane; oracle tests skip with a printed reason.
- `git clone https://github.com/sorunokoe/SwiftFormal.git`, then `swift build`. Nothing else is needed to build and run
  the fast lane.
- Not touching `sfgen` (the internal generator)? `swift build --disable-default-traits --scratch-path .build/notraits` leaves out sfgen's
  swift-syntax reader (the `Generator` trait). The `@Verify` macro still needs swift-syntax, so the saving is small.
  Its own scratch path keeps your main `.build` from rebuilding.
- Optional: `brew install swiftlint` (CI always runs it), and `Scripts/install-hooks.sh` (blame-ignore setting and a
  pre-commit hook).
- Where things live: [architecture](docs/ARCHITECTURE.md), [sandbox cards](docs/sandboxes/README.md). Words:
  [glossary](docs/GLOSSARY.md).

## How to make a change here

1. Find your module in [docs/sandboxes](docs/sandboxes/README.md) and read its card.
2. Write the test first, in that module's test target, and see it fail.
3. Run `Scripts/sandbox.py <NAME>` (fast loop), then `Scripts/sandbox.py <NAME> --connect` (the module's real users).
4. Run `Scripts/safety-net.sh` before you commit. It must end with `SAFETY NET GREEN`.
5. The safety net runs only the fast lane. If you changed an engine module (SFSAT, SFCheck, SFBV, SFProve, SFSemantics,
   SFSIL, SFLLVM), also run the slow lane. For SFSIL, SFSemantics and SFLLVM, also the oracle lane ([below](#test-lanes)).

More: [sandbox workflow](docs/guides/sandbox-workflow.md). A new module goes into `Scripts/sandboxes.py` with a card.

## Style, lint and ratchets

Every check, its command and where it runs: [docs/TESTING.md](docs/TESTING.md#what-runs-where). The ones you will meet:

- **Format:** `swift format --in-place <files>` (Apple swift-format from the toolchain, `.swift-format`). CI runs
  `swift format lint --strict`. The one-time reformat commit is in `.git-blame-ignore-revs`: run
  `git config blame.ignoreRevsFile .git-blame-ignore-revs` (or `Scripts/install-hooks.sh`).
- **Lint:** `swiftlint lint --baseline Scripts/baseline/swiftlint-baseline.json --strict` (`.swiftlint.yml`). Old
  findings are in the baseline and never block you; a new one fails. SwiftLint checks meaning, never whitespace.
- **Ratchets:** `python3 Scripts/check-ratchet.py` fails if a quality number got worse (lint findings, `try!`,
  `Unsafe`, TODOs, trusted code size). If you improved one, record it with `--update` in the same change.
- **Examples:** README snippets are copied from `Examples/`. If you change a public name they use, run
  `Scripts/check-examples.sh` (several minutes cold; CI runs it, the safety net does not).
- **API docs:** DocC, in `Sources/<Module>/<Module>.docc`. Build with
  `SWIFTFORMAL_DOCS=1 swift package generate-documentation --target SwiftFormal --warnings-as-errors`. The env var adds
  the `swift-docc-plugin` dependency, which normal builds never fetch. CI builds each target listed in `.spi.yml`.
- Release steps: [docs/RELEASING.md](docs/RELEASING.md).

## Test lanes

Three lanes, one script. Why: [ADR 0004](docs/decisions/0004-test-lanes.md). Times: Apple M4 Pro, warm builds
(`Scripts/baseline/timings.md`).

| Lane | Command | Time | When |
|---|---|---|---|
| fast | `Scripts/test-lane.sh fast` | about 10 s | every commit; CI on every pull request |
| slow | `Scripts/test-lane.sh slow` | about 35 s warm, about 3 min with the first release build | by hand, before a release |
| oracle | `Scripts/test-lane.sh oracle` | about 45 s warm | by hand, before a release (needs the pinned compiler) |

- A test over 2 seconds in debug is tagged `.slow`. A test that starts `swiftc` or a native binary is tagged `.oracle`
  (`Tests/Support/Tags.swift`).
- The toolchain cannot select tags yet, so the script picks lanes by target and suite name. A new slow test goes in a
  slow target (`SFBVTests`, `SFProveTests`, `SFSATTests`, `SFSILTests`), or in a suite whose name ends in `SlowTests`
  (like `S0SlowTests`, `BitVectorSelfSlowTests`). Oracle tests live in `SFOracleTests`.
- The slow and oracle lanes build in release with `-Xswiftc -enable-testing`; the script adds it.
- On another compiler, oracle tests skip with a printed reason. A skipped lane is not a pass
  ([compilers](docs/guides/compilers.md)).
- A wrong `proved` is the worst bug, so the slow and oracle lanes are required before a release.

## What a pull request needs

- **A test that fails without your change.** A bug fix: a test that reproduces the bug. A feature: a test of its
  behavior. A pure move or rename needs no new test, but `Scripts/check-test-inventory.sh` must show no test
  disappeared.
- **A green safety net.** If you touched an engine module, the slow and oracle lanes too. Say in the pull request what
  you ran.
- **Reviewed API changes.** `Scripts/check-api.sh` compares the public API with the latest release tag. A public break
  goes into `Scripts/baseline/api-allowlist.txt` with a reason, and into the [CHANGELOG](CHANGELOG.md). Only front doors
  are `public`; engine modules use `package` access ([ADR 0003](docs/decisions/0003-package-access-for-engines.md)).
- **A CHANGELOG entry** under `[Unreleased]` for anything a user can see (new API, rename, changed verdict, fix).
- **Docs updated:** README, guides, and DocC comments on every public declaration (`Scripts/check-doc-coverage.py`).
- **Nothing private:** no personal paths, emails, tokens or credentials (`python3 Scripts/check-release-hygiene.py`).

## Naming

- New public names follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/):
  clear at the call site, labels that read as a phrase, `lowerCamelCase` except types, `-ed`/`-ing` for non-mutating
  twins, no abbreviations a reader must look up.
- Each tool keeps its own result type names (`Verdict`, `ProofVerdict`, `ScanReport`;
  [ADR 0002](docs/decisions/0002-one-vocabulary-three-tools.md)).
- Names that bend a guideline on purpose, and why: [ADR 0005](docs/decisions/0005-api-naming.md).
- Vocabulary: the [glossary](docs/GLOSSARY.md). A new word goes into it in the same change.

## Commit style

- One logical change per commit, safety net green at each commit.
- A commit that only reformats or only moves files says so and changes nothing else (review with `git diff -w`).
- Subject: lowercase type and scope, then an imperative summary, about 70 characters: `fix(SFSAT): reject a literal of
  zero`, `refactor(SFBV): package access for the multiplier hooks`, `docs: ...`, `test: ...`, `build: ...`,
  `chore: ...`. Body: why, and what you checked.
- Generated or machine-written changes (reformatting, baselines) go in their own commits.

## Reporting a soundness bug

A wrong `proved`, `safe` or `contractHolds` is the worst bug here: a
[P0 with a fixed procedure](docs/decisions/0006-soundness-policy.md).

1. **Report:** open a **Soundness bug** issue. The form asks for the tool, the verdict, why it is wrong, the smallest
   reproduction, the compiler version and the platform. If it might also be a vulnerability in someone's system, report
   privately: [SECURITY.md](SECURITY.md).
2. **Fix:** first add the case to the [soundness zoo](docs/guides/soundness-zoo.md) (or the oracle lane for a Scan
   verdict) and see the old code fail. Then fix. Never weaken the claim to make the test pass.

What each tool is trusted for: [TRUST.md](docs/TRUST.md). Known problems: [KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md).
