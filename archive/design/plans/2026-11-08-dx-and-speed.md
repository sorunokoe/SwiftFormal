# DX and speed: editor feedback, proof cache in Scan, one-file fast path

Branch `feat/dx-speed`, worktree `../SwiftFormal-dx`. Research behind it (session notes, not committed): sourcekit-lsp
report and LSP DX/performance report. Merged back into `main` when every phase is green.

## Rules for every phase

- **Sound first.** A false `proved` (or a false ✓ in an editor) is a P0. When unsure, show less: `unchecked`,
  `stale`, or run the slow path.
- **No regressions.** Before a phase is done:
  - its focused tests pass, `swift format` and SwiftLint (`--baseline Scripts/baseline/swiftlint-baseline.json`) are clean,
    and `Scripts/safety-net.sh` prints `SAFETY NET GREEN`;
  - on the study app (a production iOS app's packages, never commit there) the full check
    gives the same per-function `logic`/`outcome` as the phase-0 baseline, and is not slower (cold) than the baseline.
- **Docs.** `CHANGELOG.md` (Unreleased), the guide the feature belongs to, and `docs/ARCHITECTURE.md` when the flow changes.
- Commits end with `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.

## Phase 0: baseline

Release-build `swiftformal` and `sfverify` from `main` (9da6b4c), copy to `/tmp/sf-dx-base/`, run the full app
check (command below) with `--json`, keep the JSON and the per-module times from stderr. Every later phase compares
against it. Note: building the *tool* in release does not scan the app at `-O`; the default `check` scans at `-Onone`
in both assert configurations (debug and release asserts). Record that in the baseline notes.

```
<bin>/swiftformal check --scan Foundation/Core:AppCore --scan Foundation/UICore:AppUICore \
  --scan Features/Feature/AppFeature:AppFeature --scan Features/Settings/AppSettings:AppSettings \
  --tests .:FormalVerificationTests --json
```

## Phase 1: compiler-style output for `check`, and "check one function"

Much already exists: `sfverify --xcode`/`--format xcode` (`ReportFormats.swift`), `swiftformal verify` through
`BuildCheck.swift`, and the gate prints locations, replay notes and refusal chains.

- Add compiler-format output (`path:line:col: error|warning|note: [swiftformal] …`) to `swiftformal check`. Share
  one renderer with the existing ones, but keep each command's severity, gating and exit policy unchanged.
  Distinguish a concrete counterexample (replayable) from an undecided answer in the text.
- An exact selector, e.g. `--at path:line` and/or `--symbol Name.member(label:)`: resolves to exactly one function
  (by a function-range index, since `FunctionInfo` only has the declaration line) or fails with a clear error
  (unknown or ambiguous position never means success). Keep `--only` (substring) as it is.
- Selection filters what is verified and reported only. The full function inventory stays for contract pairing and
  walk linking (`WalkLinker` decides default-argument matches from all scanned functions; filtering it first could link
  a walk to the wrong overload = false `provedByWalk`). Tests linked to the selected function run whole.
- JSON keeps the Scan qualifiers an editor needs (configuration, compiler-pin status, loop partial-correctness scope,
  walk domain completeness) so a later "✓" never implies coverage that did not happen.

Status: done — b76292d (one renderer), 734658b (`check --xcode`/`--format xcode`), 0508037 (`--at`/`--symbol` for
`sfverify` and `check`), 2e1a7bf (check JSON `modules` and per-entry qualifiers), 5defdeb (docs, CLI contract).
`swiftformal verify` has no selector yet. The app: per-function `logic`/`outcome` identical to the baseline on every
run (5 runs); timing on a loaded machine, back to back: baseline 3m57s / 2m06s, phase 1 5m52s / 1m50s (the spread is
load; per-module scan times match). `check --at LanguageOption.swift:37 --xcode`: 1m57s against 1m50s–2m21s for
the full check, because every module is still compiled for the inventory (Feature's build alone is ~50 s): the
selector saves solving, not compiling. That is the one-file fast path's job.

Review fixes: e8c7e9a (a compiler-written init or deinit is located at its type's name, so `--at` gives it only
that line; a blank or MARK line inside a type now says no function covers it, exit 2), baa7f38 (`check`'s
selector guard throws, so the background `--build-tests` build is cancelled), 79af4ac (soundness: `--at` selects
only in files the release build also compiles, a selected function forces the second build, and
`configurations` lists only the builds that ran). The app after the fixes, base / new / new / base, load average
at start 9.7 / 10.9 / 8.5 / 8.1: 4m45s / 3m07s / 1m53s / 2m28s; per module (Core, UICore, Feature, Settings, walks)
10/22/175/34/41 s, 8/27/79/33/38 s, 3/14/49/25/20 s, 3/17/78/27/21 s. Verdicts identical to the phase 0 baseline
and to both base runs (2994 functions). New is not slower; the spread is still load (other sessions' scans).

## Phase 2: the proof cache on the Scan path (plan items D4, S5, X6)

- **Scan-specific cache, own namespace.** Cache the checked evidence for Scan's *existing* claim
  (`Verify.swift`), not `CachedVerifier.prove` (which proves a different, weaker thing). On every hit Scan still
  runs: spec-shape validation, honest counterexample replay, caller-exclusivity (`heldByCaller`) classification,
  configuration merging, requested LLVM cross-checks, `--paranoid` compile checks. Loop proofs and modular retries stay
  uncached at first.
- **Complete identity.** The key covers: the function's dependency closure *and* the closures of its paired
  `_requires`/`_ensures` (and macro-expanded in-body contracts), with the argument mapping; generic headers,
  signatures and substitutions; witnesses, globals, module-wide safety flags (dangerous deinits, issue reporters,
  cancellation callbacks), `TypeNameCheck` ambiguity sets and witness conflicts; tables; widths; budget class; a new
  **Scan-claim version** (bumped whenever claim construction or interpretation changes) plus encoder/semantics
  versions; the *actual* compiler chosen by `ScanToolchain` (not `CompilerToolchain.installed()`), SDK, target,
  frontend settings, optimization and assert configuration. A name or a sampled `ClaimProbe` is never enough.
  Compute it from the final module, after dependency linking and type-name probes.
- **Only checked answers are stored:** `proved` after `LRATChecker` accepted, and replayed counterexamples. Never
  `unknown`, cancelled, timed out, or budget-limited.
- **Trust.** Cache under the package's `.build` (new flag, e.g. `--proof-cache <dir>` / `--no-proof-cache`; the
  existing `--cache-dir` stores build commands and must not change meaning). Validate the directory, its ancestors
  and every entry (owner = user, not writable by others, no symlinks), without a check-then-open race. If trust can't
  be established, ignore entries (or `Trust.recheck`); never return a stored proof just because its JSON repeats the
  key. Cache I/O failure falls back to normal verification.
- **Stamps.** `VerifyCommand`'s passing-target stamps skip the whole build; their fingerprint misses dependency
  contents, compiler/SDK and manifest settings. Make them validate the same complete identity, or disable them;
  `--no-proof-cache` bypasses stamps too. Test: an unchanged marked caller after a linked dependency starts trapping.
- **Cost.** Build an immutable per-module key context once (shared table/witness digests, each function node rendered
  once, reusable closure hashes, like `ClosureComparison`). Measure key time separately from solving. A change to
  any witness/table still invalidates everything that hashes it (by design). `SemanticsDigest.current` is already
  memoized per process.
- **Tests:** hit on unchanged code; miss after changing only the body, only a callee, only `_ensures`, only a
  `_requires` helper, the contract pairing, a generic header, a witness, the compiler fingerprint, a version bump, the
  configuration; forged entries via symlink, a shared leaf, or a writable parent are not trusted.
- **The app:** cold = same verdicts as baseline and not slower (if it is, keep the cache opt-in until fixed); warm =
  same verdicts, much faster; after a one-line edit only the functions whose identity changed are solved again.

Status: done — a2d2302 (keys), 007d6c1 (the cache in the verifier), 2bf3052 (CLI flags, stamps removed), then the
docs. The key is `ScanKeyContext` (built once per compiled module, nodes hashed level by level in parallel) plus `ScanClaimKeys`; the
store is `ScanProofCache`/`TrustedFiles`; `Verifier` looks up before solving and stores only checked proofs and
replayed counterexamples, and runs replay, `heldByCaller`, merging and the LLVM checks on every hit. Loop proofs,
`--modular` retries and `--gate` stay uncached. Review fixes: ba3457f (a relative `--proof-cache` is the directory
under the current one), 04bcd8f (the tool is the set of Mach-O `LC_UUID`s of the images holding the encoder, read from
memory first thing in each CLI `main`; no UUID, no cache), 59a61b3 + 660cc42 (safe `swiftformal verify` stamps: after
planning, hash every file and argument of the target and its local dependencies, the manifests, every module/header
the arguments reach, the ScanToolchain identity, the tool UUIDs and the outcome-changing flags; stamp passing targets
only, re-hash before storing, replay their output; a check that could not link a module is not stamped; `--force` and
`--no-proof-cache` bypass them). Precision found on the app and fixed: witness
edges only for real `witness_method` instructions (not `@convention(witness_method:)` types), archetype UUIDs
canonicalized, debug scope numbers dropped from synthesized names. The app, release binaries, loaded machine (load
9–66), verdicts identical to the base on every run: base 118 s; cold 122 s (2596 stored, keys 0.04–0.57 s per
module); warm 101 s (2596 of 2707 from the cache; Feature 51 → 38 s); one-line edit of
`AddModelActionState.isSubmitting` 141 s under load (2 claims solved again, debug and release; the rest hits);
`--no-proof-cache` 137 s, cache untouched; `check --at AddModelState.swift:6` warm 70–80 s against 85 s without the
cache. Compiling and linking to SIL is about 94 % of a warm module, so warm gains are bounded by Phase 3/compile work. After
the review fixes, full check 110 s at load 11 with a fresh binary (new UUID, so cold), verdicts identical. `swiftformal
verify` on AppFeature (load 12–22): before the stamps were removed, unchanged 0.1 s (unsound: it skipped the build);
now cold 13.5 s, unchanged 4.1–4.5 s (the null `swift build` alone is 3.5 s), after a one-line edit 13.4 s (12 of the
claims from the proof cache). Second review fixes (stamp soundness): 97f1298 (compiles can record
the files the compiler read: `-emit-dependencies-path`, parsed as Make syntax), 3558b34 (the target is hashed before
its promises and contracts are read, which come from the bytes hashed; every file and directory hashed keeps its
`stat` (dev, inode, size, mtime/ctime in ns) and a stamp is written only if none changed, so A→B→A during a check is
not stamped; the stamp, format 2, keeps every file the compiles listed outside the compiler's and SDK's directories
with its digest, and the skip decision rehashes them; a file first seen in that list must have changed 1 s before
the check started; no list, or a listed file that is gone: no stamp), then the docs. Measured on a fixture: the
dependency file lists the sources, the SDK `.swiftinterface`s, the generated module map, the umbrella header and
the nested `include/../limits.h` a C header includes (also with a warm module cache). On AppFeature it lists 275
files outside the SDK (241 sources, 29 `.swiftmodule`s, a module map, 4 macro plugins); rehashing them takes 12 ms.
The app has since changed (AppFeature now links SwiftFormal and 6 other local modules, each planned again by a
`swift build` of about 3 s when the stamp is checked), so on a loaded machine (load 3–8): base c622779 cold 56 s,
unchanged 25.4–26.0 s; with the fixes cold 78 s (a new binary, so its proof cache entries are new too), unchanged
25.1–25.6 s (three runs), after a one-line edit 75 s and after reverting it 79 s (both 12 from the proof cache).
Planning fix: 21fa0e3 (a local dependency's command comes from Swift Build's plan of the target's build description,
`task-store.msgpack`, when no command was saved for it: the saved one carried the description of the dependency's own
`swift build --target`, never current after the target's build, so each dependency was built again on every run; the
fallback build then saved it under its own description again, so the slow state never ended), e77feb5 (stamps per
tool), then the docs. Arguments identical to the per-dependency planning (raw command, files and filtered
arguments, compared in-process): 6 of 6 local modules of AppFeature, 9 of 9 of `Examples/GatedPackage` Kernels;
the stamps ask for the same 6 local modules. Same session, load 3–6, old = 1b24a98: unchanged 21–52 s old (once a
dependency's command is saved under another description; 3.7 s while all were saved under the target's) against
4.0–4.1 s new; edit/revert 74/70 s old against 15/14.7 s new; cold 21 s new (new binary). Full app `check`
75/75 s old against 54 s new, verdicts identical to the base.
Review fixes: 169e86f (stamp digests copy the file and hash it before the second `stat`; it was mapped, so a write in
place could reach the digest), da0445f (the task-store cache keys on `FileStatus`: `st_mtimespec` broke Linux),
e1a4e3a (the plan is read only after a build of this process: its description is read when the build exits and
`prior-build-descriptions.txt` must be unchanged after reading, and a dependency's command only from a plan holding the
target's exact command; `--build-log` never reads it, a null build's log stops with `upToDate` again). Unchanged
App verify after these: 3.7–3.9 s; first run with the new binary 20 s (no per-dependency builds).

## Phase 3: one-file fast path: experimental, opt-in, not needed by the editor

Research measured `-emit-sil -Onone` with one `-primary-file` at about 100× faster than whole-module, but soundness
needs more than matching bodies: all sources must still be given as non-primary inputs; safety depends on bodies
outside the call graph (dangerous deinits, issue reporters, cancellation callbacks); `SILModule.link` keeps old bodies
(no replace/delete); new declarations, conformances, imports or macro expansions change resolution without showing in
the old call graph. Normal checks and the editor stay on the whole-module path plus the cache.

- Investigate and, only if it can be made sound, add an opt-in experimental mode limited to context-independent
  scalar leaf functions (no generics, witnesses, opaque references, globals, modular proofs), with its own cache
  namespace and results labelled "fast, debug". Require fast-vs-whole verdict equality on fixtures and the pinned
  oracle/native cases. If it can't be made sound cheaply, write the findings down and stop.

**Status: investigated, not shipped.** It cannot be made sound cheaply, and the class it could serve is empty on the app.
Measured on AppFeature (116 files) with the exact frontend command `check` runs, on a shared machine:

- Speed: whole-module `-emit-sil` 4.1–4.3 s (46 MB of SIL); one `-primary-file` 0.35 s (0.47 MB). Type-checking alone
  is 2.6 s of the 4.1 s, and debug-info printing about 0.07 s. But a warm `sfverify --at` is 13.4 s wall: SIL for two
  configurations and four dependency modules (11.9 s summed, run in parallel), parsing 3.0 s, proving 1.7 s, plus a null
  `swift build` (3.3 s), which stays because dependency `.swiftmodule`s must be current. The best case for a fast path is
  about 4–5 s, so 2.5–3× faster, not 100×.
- The primary-file SIL is a different compilation, not a subset of the whole-module SIL. 11 of the 80 functions it
  defines have different bodies. For example, a synthesized `==` is called directly in whole-module SIL but through
  `witness_method` in primary-file SIL, because the conformance is in another file. So the claims and cache keys differ.
- Bodies and tables of other files are missing. 12 same-module callees are declarations only, as are stdlib bodies that
  whole-module SIL deserializes (`String.==`, string interpolation). Whole-module vs primary-file counts: vtables 2 vs 0,
  witness tables 587 vs 3, `sil_global` 99 vs 2, `sil_property` 1287 vs 12, bodies 7436 vs 80. A missing callee alone
  fails closed (`SILModule.function` throws "no body"), but module-wide facts Scan computes from the bodies it reads
  would become wrong instead of unknown: `deinitsMayRunCode` (releases are ignored only when no deinit runs code), the
  cancellation-callback and issue-reporter checks, `TypeNameCheck`'s modelled type names, witness and class layouts,
  contract pairing, and walk links. That is a false proof, not a lost one.
- Coverage: the strict class (stdlib scalars only; no calls, witnesses, globals, enums or retains) is 0 of 8,786
  functions in AppFeature, AppCore and AppUICore. Even a looser class (module enums and structs allowed,
  which already depends on context) gives 2,639, and only 66 of those have anything to prove, all compiler-synthesized
  `__derived_enum_equals` or Equatable thunks, which are not reported.
- What would be needed: the module-wide facts from a whole-module run keyed on every input (deinit bodies, the
  declarations and conformances of all files, the inventory), with primary-file SIL used only for the edited file's
  bodies, and a proof that those bodies match the whole-module ones. That is the whole-module run the fast path tries to
  avoid.

Cheaper and sound alternative, measured but not implemented: `check` scans its `--scan` modules one after another.
Running the four app modules as four concurrent `check --scan` processes (each package has its own `.build`; peak
memory 0.25–0.69 GB each) took 28.8 s and 26.5 s warm, against 55.5 s and 65.8 s sequential, about 2.2× faster. Verdicts
were identical on all 2,994 functions. The longest module (AppSettings, 24–30 s) bounds it. Doing this inside one
process first needs an audit of process-global state:
- the selected `ScanToolchain`;
- the background test build, which holds SwiftPM's lock, and the `builtPackage` log handoff;
- scans of the same package, which must stay serialized;
- deterministic report order and buffered notes.

It also needs the safety net and an app comparison. So it stays a follow-up.

**Status: done (`swiftformal check --jobs`).** The audit found two things that are global to the process. The selected
`ScanToolchain` is read by every compile, probe and proof-cache key, so modules are proved at the same time only when
their plans name the same compiler. The per-package SwiftPM state is the other: the lock, `build.log`, the saved commands
and the "last planned target" that linking reads. So the modules of one package (one `.build`) run plan → prove one
after another, in `--scan` order, and only different packages overlap. The `builtPackage` handoff only touches modules
of the tests package, so they are all in one such group. The rest is safe as it is: `TypeNameCheck`'s answers and
FormulaMemo are locked and keyed on everything they answer from (the memo changes which entries are kept, not answers);
temporary files have UUID names; proof-cache entries are written to a new file and renamed into place; the background
test build is another package, or the same package built before the scans start; only the CLI writes to stderr.
`ScanSchedule` hands notes and reports on in `--scan` order. On the first failure in that order, it waits for running
modules to finish, starts no later one, and throws that failure's error, as one after another would. Without `xcrun`,
planning runs the selected toolchain's `swift`, so it stays sequential there. The app: 54.9/59.0 s with `--jobs 1`,
34.5/34.7 s with the default, with identical verdicts and output ([PERFORMANCE](../../PERFORMANCE.md)). Tests:
`ScanScheduleTests` (fast) and `CheckJobsSlowTests` (end to end, `--jobs 1` against `--jobs 2`, including a target that
does not build).

## Phase 4: `swiftformal lsp` (editor server) and the VS Code extension

A separate small language server over stdio, next to sourcekit-lsp (never replacing it), built on SFVerifyKit.

- **On save** (default; `never` possible). `onChange` only shows existing results as stale until a save (no
  unsaved-buffer compile).
- Every run captures an immutable project generation and input snapshot (file hashes, manifest, build settings).
  Results are published (diagnostics, lenses, hover, test results) only if that generation is still current.
  Dependency/build-context changes invalidate probe answers (`TypeNameCheck`'s process cache) and affected results;
  if unsure, invalidate the whole module.
- Runs are serialized and coalesced at first; real cancellation (kill the compiler subprocess, stop solver work at a
  check point) before claiming cancellation. `ScanToolchain.select` is process-global: one toolchain per server.
- `textDocument/publishDiagnostics` with the document version; code lens above each function (`✓ proved`,
  `✓ cannot crash`, `walked 12/12 (complete domain)`, `✗ counterexample`, `? unchecked: reason`, `⚠ stale`) carrying
  configuration and pin qualifiers; hover with the counterexample, contract and reason; code actions: replay a
  counterexample as a test, add `#requires`/`@Verify`, generate a `Prove(it:over:)` skeleton; `$/progress`.
- Staleness: results are tied to the generation. On edit, that file's results and every function whose closure
  reaches it turn `stale` at once and never show as ✓ again until re-proved.
- `Editors/vscode`: a small extension that starts `swiftformal lsp` beside the Swift extension, plus a publish-only
  Test Explorer controller for walks and logic results. A Neovim config snippet in the guide.

**Status: done.** `swiftformal lsp` (library `SFLanguageServer`, CLI wiring in `LSPCommand.swift`),
`Editors/vscode`, [editor guide](../../guides/editor.md) with the Neovim snippet. Design decisions:

- **Child-process runner.** Each check is a child `swiftformal check --json` (same binary). Cancelling kills its
  whole process tree (descendants found by parent pid, since SwiftPM starts its own process groups; stopped top-down,
  killed, confirmed gone) before the server reports it cancelled. The solver has no cancellation points, so this is the
  only real cancellation; it also gives each check a fresh `ScanToolchain.select` and a fresh `TypeNameCheck` probe
  cache, so no invalidation hook was needed and `check`/`verify`/`sfverify` are untouched. Proof-cache writes are
  atomic renames, so a killed check leaves the cache valid. The server parses the `check --json` report (exit 0 or 1).
- **Generations.** Every change (edit, save with new bytes, watched-file event, configuration) bumps the generation
  and is logged with its scope (one package, or everything for manifests, `Package.resolved`, configuration). Results
  it reaches turn stale at once. A finished run's results are published with every change logged since it started
  applied again; a run also compares file signatures (size, mtime, inode) before and after and treats differences as
  changes. A verdict renders as proved only when it is not stale and the file's current text (buffer, else disk) has
  the SHA-256 the run read. Closures come from `swift package dump-package` (local dependencies); unknown closure
  means everything.
- **What a save checks.** No configuration: the target that holds the saved file, whole module, logic only. `--at`
  selects one function, not a file, and saves little: on AppFeature warm, whole module 42 s against 32 s for one
  function, and the whole module gives every lens of the target. With configured `scan`, the targets whose closure
  holds the saved file's package (all of them when walks run).
- **Serialized and coalesced.** One check at a time; a request merges into the queued one; a save that changes what
  the running check reads supersedes it (killed, then the merged job runs).

The app, AppFeature (116 files), scripted JSON-RPC client, release binary, loaded machine: first diagnostics 62 s
after the first save of a new server (48 s on a second try), 36 s after the next save (1,314 verdicts; the build and SIL
compilation dominate; the proof cache answers the rest). An edit turns all 27 lenses of the file stale at once. Full
App check with this branch: verdicts identical to the base.

## Phase 5: AGENTS.md and a skill

- `AGENTS.md` at the repo root (for contributors' agents) and a user-facing skill (for agents writing code in apps that
  use SwiftFormal): the loop "edit → `swiftformal check --at file:line --json` → read the outcome → fix, or add a
  contract or a walk → repeat", what each outcome means, and that `unchecked` or `stale` never means proved.
- No MCP server.

**Status: done.** `AGENTS.md` (contributors' agents: module map, change loop, checks, soundness rules; links, not
copies) and `skills/swiftformal/SKILL.md` with `reference.md` (every `check --json` field); the README says how to
install the skill. Every command in the skill was run as written on `Examples/GatedPackage` and on a scratch package
built from the skill's own snippets: `doctor` (exit 0); `check --at … --json` (safe, 25 s on GatedPackage; 16 s on the
scratch package); a missing zero guard gave `mayTrap` with inputs, failure and replay, then `cannotTrap` after the
fix; `--symbol` on a weak `@Verify` gave `contractFails` with `price = Int.min` and exit 1, then `provedByLogic`;
`--tests` gave `provedByLogicAndWalk` (about 29 s), a broken walk gave a walk counterexample and `--xcode` errors
with a replay line; `--show-unchecked` showed `unsupported` (generics) and `undecided` (loops, exclusivity) with
hints; `verify` passed (exit 0) and failed on the weak contract (exit 1); `scan --emit-tests` wrote a playback test;
a bad `--at` line or `--symbol` exits 2.

## Merge of `main` 821de7a (round 6, NL-0…NL-T, semantics 26, H0/H1)

**Status: merged.** What the merge decided beyond the textual conflicts:

- **Proof-cache default.** Main's NL-T dropped `sfverify`'s default proof-cache directory because it was
  `NSTemporaryDirectory()`, which other local users can write to: an entry planted there would be a `proved` nobody
  checked. The Scan cache's default is `<package>/.build/swiftformal/proofs/scan-v1`, and `TrustedFiles` reads an entry
  only when the directory and every directory above it belong to the current user (or root) and nobody else can write
  them, and opens it with `O_NOFOLLOW` and an `fstat` owner check. That answers NL-T's reason, so the default stays;
  without `--package` there is still no default. Main's `CachedVerifier` (the `--gate`/`ProofCache` path) is
  unchanged and still has no default directory.
- **Key completeness.** The key holds `SILFrontendVersion.semantics` (now 26, main's bump for the pre-fix proofs) and
  `SemanticsDigest`, so main's fixes invalidate old entries by themselves. Main's new module state (`letGlobals`,
  `conflictingWitnesses`, `genericWitnessRequirements`, `TypeContext.confirmedPackageTypes` and `foreign`, imports)
  is in `tablesText` (a `Mirror` over every `SILModule` field but the bodies), hence in the key; a `let` global's
  initializer is reached through its addressor's `function_ref`, so it is in the closure digest. Floats, strings,
  foreign objects and literal arrays are encodings of code the closure digest already hashes, and every encoder
  witness lookup uses a requirement in `encoderWitnessRequirements`. `ScanClaimVersion` went from 1 to 2: main changed
  what a claim's answer means (`honest` inside `proveClaim`, NaN wording, approximations as a set), so entries written
  before the merge are not read.
- **What is not cached.** A counterexample that rests on what Objective-C calls returned (`refuteWithForeignResults`)
  and the trap search under undecided ensures (`refuteTrapUnderUndecidedEnsures`) are not stored; loops (`--unwind`,
  2-induction), `--modular` and `--gate` never touch the cache; `--mutate` runs after the answer, cached or not.
- **NL-S3 and NL-S1.** The formula memo is per process and compares whole clause lists, and cone proofs are checked
  against the whole formula, so neither can turn a cached entry wrong; the cache stores only answers that passed the
  LRAT check or the replay.
- **H1.** Every hook of this branch (cache lookup in `verifyUntimed`, `solve`, the selector) is in `SFVerifyKit`, not
  in the encoder, so `FunctionRun` needed none. H5 (main's ledger) defers its Merkle key to this branch's
  `ScanKeyContext`.
- **New outcomes.** Main's `conflict` and `typeWalkFailed` are handled by `check --xcode` (a failing walk over a whole
  type is one error at the walk, a note when marked as a known issue, a note at each member; a conflict is a note)
  and by the language server (`walksProved` follows the CLI's attribution; neither outcome is shown as proved). The
  skill's reference lists both and the new fields (`weakContract`, `wholeType`, `notRunWalks`, `scanHints`).
- **Checked.** `Scripts/safety-net.sh` green, `test-lane.sh slow` and `oracle` pass. App full check (release
  binaries, machine shared): main 821de7a 131 s; merged cold 55 s, warm 53 s (3,016 cache hits; compiles and walks
  dominate). Logic status, outcome, counterexamples and walks are identical to main's for all 2,994 functions, cold
  and warm; the merged JSON also has `detail`, `category` and `hint`, which main's `check --json` does not.
