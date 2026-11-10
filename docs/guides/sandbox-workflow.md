# Working in one sandbox at a time

A *sandbox* is one module that builds, tests and runs on its own (see [the cards](../sandboxes/README.md)). Change one
module, check it alone, then check it against the real code that uses it.

## The routine

1. **Pick the sandbox** in [docs/sandboxes](../sandboxes/README.md). Read its card: what it must not depend on, who
   uses it.
2. **Write the check first.** Add or change a test in the sandbox's own test target. Watch it fail.
3. **Run the fast loop.** `Scripts/sandbox.py <NAME>` builds the target and its tests, and runs them.
4. **Connect it.** `Scripts/sandbox.py <NAME> --connect` also runs the real consumers from the card (gate build,
   golden check, another module's tests). A module can pass alone and still break its users.
5. **Before you commit**, run `Scripts/safety-net.sh`. It must print `SAFETY NET GREEN`.

Other options:

| Command | What it does |
|---|---|
| `Scripts/sandbox.py --affected <git-ref>` | Lists the sandboxes changed since `<git-ref>` and every sandbox that depends on them. |
| `--affected <git-ref> --run` | Runs them (without `--run` it only prints). |
| `--dry-run` | Prints every command, runs nothing. |
| `--skip-slow` | Leaves out commands that use slow tests, and says so in the last line. |

The last line of `Scripts/sandbox.py` says what was and was not covered, for example
`Core: 3 passed; consumers: 2 passed; not run: iOS builds (...)`. Read it. Green here never means "the product is
green".

## Slow tests

These take minutes in debug, so the fast lane (`Scripts/test-lane.sh fast`, run by `Scripts/safety-net.sh`) skips
them:

- `SFBVTests`, `SFSILTests`, `SFProveTests`, `SFSATTests`, `SFOracleTests`.
- Every suite named `*SlowTests` (`S0SlowTests`, `BitVectorSelfSlowTests`, ...).
- The list for `Scripts/sandbox.py` is `SLOW_TESTS` in `Scripts/sandboxes.py`.

In debug, `SFBVTests` took over 11 minutes and `SFSILTests` about 10 (both stopped unfinished). **In release each
finishes in under a minute** (`Scripts/baseline/timings.md`).

When you change SFSAT, SFCheck, SFBV, SFProve, SFSIL or SFLLVM, run `Scripts/test-lane.sh slow`. For SFSIL, SFLLVM
and SFSemantics also run `Scripts/test-lane.sh oracle`. Once built in release they take about 35 s and 45 s; about 3
minutes the first time.

A green safety net does not include the slow and oracle lanes. CI does not run them either (CI runs only on pull
requests to `main`). Run them by hand before a release.

## What it costs

Cold builds on an Apple M4 Pro (fresh `--scratch-path`; full numbers in `Scripts/baseline/timings.md`):

| Command | Cold | After touching one file |
|---|---|---|
| `swift build --target SFSAT` | 9 s | 2 s |
| `swift build --target SFBV` | 7 s | 2 s |
| `swift build --target SFSIL` | 15 s | 3 s |
| `swift build --target SwiftFormal` | 7 s | 2 s |
| `swift build` (everything) | 21 s | 3 s |

One target saves 6 to 14 seconds against a full build. That is small. The real gain is a clearer failure (only that
module's errors) and a smaller test run, not speed.

## Did a change in a sandbox reach its consumers?

Tried once, for SFSAT only, on a throwaway copy. The redundancy check of clause minimisation in `analyze` was removed
(an unsound change: the solver can accept a wrong answer).

- `Scripts/check-golden.sh`: red.
- `swift build --package-path Examples/GatedPackage`: the gate failed (`gate FAILED: 1 of 2 gated functions proved`).
- `SFSATTests`: **not run** (too slow). Unknown whether it alone catches this.

That is why `Scripts/check-golden.sh` is a consumer of SFCNF, SFSAT, SFCheck and SFBV. Other sandboxes were not
tried.

## Known problems

- **Golden check on the first run in a fresh checkout (fixed).** `sfverify --build` reads the `swift build -v` log.
  The gate could print "sfverify: gate passed ..." into the middle of a compile command in that log (seen as
  `-seriali` / `ze-diagnostics`). The broken command was cached and broke later runs. `SwiftPMBuild.compileCommand`
  now removes gate messages first (test: `aGateLineInsertedInTheMiddleOfTheCompileCommandIsRemoved`). If you still see
  `unknown argument` from the compiler, delete `.build/swiftformal/args/Kernels.args` in `Examples/GatedPackage` and
  run again.
- **Checkout folder name (fixed).** It no longer has to be `SwiftFormal`: `Examples/GatedPackage` names the dependency
  (`.package(name: "SwiftFormal", path: "../..")`). Checked by running `Scripts/check-golden.sh` in a clone with
  another name.
- **`sfgen --help` exits with status 2**, and so does `sfgen` with no arguments. So the sfgen consumer check is
  `swift build --product sfgen`. It only proves the tool builds.
- **`SwiftFormalTesting` has no consumer command in the registry.** Its loop runs its own tests only. Its example
  (`Examples/Walk`) runs in CI through `Scripts/check-examples.sh`.
- **`SFLLVM` has no production consumer**, only tests. See [ADR 0008](../decisions/0008-sfllvm-status.md).
- **`Scripts/sandbox.py` never runs iOS builds.** See [platforms](platforms.md).

## Keeping the rules

- `Scripts/sandboxes.py` is the one list of modules, their allowed dependencies, tests and consumers.
- `python3 Scripts/check-layering.py` fails if `Package.swift` does not match it, if a new target is missing from it,
  if SFCheck depends on anything but SFCNF, or if SFCNF grows past 150 non-blank lines.
- `python3 Scripts/check-sandboxes.py` fails if a card is missing or disagrees with the registry.
- A new target needs: an entry in `Package.swift`, an entry in the registry, a card. The checks tell you what you
  forgot.
