# App study round 5: fixes and improvements (2026-11-08)

Branch `fix/app-study-round-5`, worktree `../SwiftFormal-app-fixes`, from `main` at `ccbd1dd`.
Source: the round-5 evaluation of SwiftFormal on a production iOS app (its raw results are not public).
Every item: test first (seen failing on `ccbd1dd`), then the change, then the guard named in its row.
Goal: merge back into `main` with no regression (section "Done means").

## Status (2026-11-08): done, ready to merge

| Item | Commit | Guard |
|---|---|---|
| A1 module ownership by demangling | `eef337d` | `ModuleOwnershipTests`, gate test; SFSIL/SFVerifyKit scans identical, no parse-time change |
| A2, A3 macro output generated; readable categories | `a86e6a0` | `MacroGeneratedFunctionTests` |
| B1 integer ranges, `contains`, `~=`, `isEmpty`, `indices` (and partial ranges, `case lo...hi:`) | `ac0b153` | `SILRangeTests`; 5 functions in the exhaustive 8-bit oracle agree with native execution on all 65,536 pairs at `-Onone` and `-O` |
| C1 cannot-trap count, `--show-proved` | `dfa7b93` | `cannotTrapFunctionsAreCountedNotListed` |
| C2 to C4 docs | `569d31a` | links, examples; the `_requires` recipe checked on the tab example |
| C5 (found while re-checking on the app) garbled compile commands | `28a5f50` | `CompileCommandTests`; the app's corrupted cache rejected, `AppBooking` scans |
| `swiftformal verify` (from main) prints Scan's warnings | `47eb69e` | build; safety net |
| Soundness zoo range cases; TRUST.md range assumption; retired lint entries removed (337 -> 335) | `9d6d1ca` | `ScanZooTests` (oracle lane) |

`main` moved three times during the work (`bc03dc8`, `5e4d2ac`, `954cf17`, `89dcd6b`); each was merged into the branch
(CHANGELOG and README by hand, the SwiftLint baseline by taking `main`'s and re-applying this branch's four count
deltas). On the last merge (`32dfcb4`): safety net with the API check, slow lane, oracle lane and
`Scripts/check-examples.sh` all pass; metrics unchanged; the branch contains `main`, so merging back is a fast-forward.

Real app, re-checked through the umbrella package and then deleted: `AppStepByStep` 0 -> 577 functions;
`TemperatureUnitType.testTag` (Settings) and `LoadingState<…>.displayModel` (Booking) now reported; the latent
`TabsStore.State.selectedTab` trap still found; totals drop by the macro output now counted as generated
(Settings 793 -> 541, 253 generated).

## Bugs: what Scan reports is incomplete or misleading

### A1. Functions are silently dropped when the module name is mangled with word substitution (P1)

`SILText.prepare` (`Sources/SFVerifyKit/Compile.swift`) keeps a function only when its symbol starts with
`$s<len><module>` or contains `<len><module>E`. The Swift mangler substitutes words that already appeared in the
symbol, so both tests miss real functions of the module:

- module `AppStepByStep` mangles as `$s09AppStepByB0…` ("Step" repeated): the whole target reports
  0 functions, exit 0, from 19 MB of SIL;
- `extension TemperatureUnitType` (declared in `AppCore`) inside `AppSettings` mangles as
  `$s7AppCore19TemperatureUnitTypeO0A8SettingsE4codeSivg` ("App" substituted): the member is missing from
  an otherwise normal report;
- a constrained extension (`extension LoadingState<DetailsData>`) puts a generic signature between the module
  and `E`, so `<len><module>E` does not occur even without substitution.

Not a wrong `proved`: dropped functions get no verdict. But `swiftformal check` then shows nothing for them, and a
contract written on one is never checked (only `--gate` fails closed on an unfound function).

Change:
1. Ownership by demangling: keep the fast path (`hasPrefix("$s<len><module>")` is exact); send every other candidate
   (a named, non-skipped `sil` definition) to one batched `xcrun swift-demangle` call (the tool `Demangler` already
   uses) and own it when the demangled name starts with `<module>.`, `static <module>.` or
   `(extension in <module>):`. Measure the extra time on the largest SIL we have (budget: under 5 % of parse time).
2. If the demangler cannot run, keep the prefix result and print one warning on stderr that compressed names may be
   missing (never silent).
3. Warn on stderr when the SIL is not empty but no function of the module was found.

Tests (SFVerifyKitTests, fast lane): `prepare` on SIL text with the three symbol shapes above finds them; a foreign
symbol that merely contains the module's words is not owned. Oracle lane: compile a module named `AppStepByStep`
and a two-module pair (`AppCore` type, `AppSettings` extension, plus a constrained extension) with the
pinned `swiftc` and check each function gets a verdict. Gate: a `// sf:verify` function in such a module is found.

Out of scope: `SILModule.symbol(module:name:)` / `LLVMModule.symbol(module:name:)` are test helpers used with
fixture names only; they get a doc comment naming the limit.

### A2. Macro-generated helpers are counted as hand-written (P3)

`#Preview` expands to a `PreviewRegistry` type whose `fileID`/`line`/`column` getters show up as "safe" functions
with mangled names (`static $s7AppCore0020Localizedswift_…PreviewRegistryfMu_.fileID.getter`). They inflate
`total` and `safe`. Change: a function whose display name contains a macro-expansion unique name (`fMu`, `fMf_`) is
generated (`compilerGenerated`, not `total`). `@Observable` accessors keep being reported: they stand for properties
the user wrote. Test: `prepare` fixture.

### A3. Misleading or unreadable `unsupported` categories (P3)

- Any `Range<…>` type is filed under "for-in over ranges and sequences", also when the code has no loop
  (`tabs.indices.contains(i)`). After B1, `Range` is supported; an iterator type keeps "for-in over sequences".
- Macro-generated type names become category keys (`type $s7AppCore0A6Locale10ObservablefMm_6MemberfMu3_`).
  Change: such names are filed as "macro-generated types".
Test: `Verifier.category(of:)` unit tests.

## Coverage: idiomatic Swift that Scan should read

### B1. Integer ranges and index checks (P2)

Today `i >= 0 && i < a.count ? a[i] : x` is proved, but the idiomatic `a.indices.contains(i) ? a[i] : x` is
`unsupported`, so fixing a reported trap the natural way makes the verdict disappear. At `-Onone` these are calls:

| Swift | SIL callee | Exact meaning |
|---|---|---|
| `a.indices` (Array) | `RandomAccessCollection<>.indices.getter` `$sSksSx5IndexRpzSnyABG7IndicesRtzSiAA_6StrideRTzrlE7indicesACvg` | `0 ..< a.count` |
| `x..<y` | `Comparable.<..` `$sSLsE3zzloiySnyxGx_xtFZ` | traps unless `x <= y`; `Range(x, y)` |
| `x...y` | `Comparable....` `$sSLsE3zzzoiySNyxGx_xtFZ` | traps unless `x <= y`; `ClosedRange(x, y)` |
| `r.contains(v)` | `Range.contains` `$sSn8containsySbxF`, `ClosedRange.contains` `$sSN8containsySbxF` | `lo <= v && v < hi` / `v <= hi` |
| `r ~= v` | `RangeExpression.~=` `$sSXsE2teoiySbx_5BoundQztFZ` at `Range`/`ClosedRange` | as `contains` |
| `r.isEmpty`, `lowerBound`, `upperBound` | fields / summary | exact |

Change: `Range<T>` and `ClosedRange<T>` for a standard integer `T` are aggregates of two `T` leaves (`lowerBound`,
`upperBound`), so `struct_extract` works as for user structs; the calls above get exact summaries (generic only at
a standard integer substitution; anything else stays `unsupported`). `for … in` and `Range.count` stay unsupported.
Engine module (SFSIL): slow and oracle lanes required.

Tests first:
- SFSILTests: each row above, proved and broken cases (`(0..<n)` with `n < 0` traps with that input;
  `(0...a.count).contains(i) ? a[i] : 0` traps at `i == a.count`; `a.indices.contains(i) ? a[i] : 0` is safe).
- Soundness zoo: the off-by-one (`...` instead of `..<`) must never be `safe`.
- Oracle lane: every new summary against real execution on boundary inputs (`Int.min`, `-1`, `0`, `count`, `Int.max`).
- Fixture of the app's pattern (`allCases.indices.contains(i) ? allCases[i] : .first`) proved safe.

## Developer experience

### C1. `swiftformal check` prints ~2,000 "cannot trap" lines before what matters (P2)

On four app targets the text report listed 1,955 `✓ … cannot trap` lines (mostly macro accessors) before the
walks and the summary. Change: by default the logic section lists broken functions and contracts (held or broken),
then one line `✓ N functions cannot trap for any input (--show-proved lists them)`; `--show-proved` restores the full
list. `--json` is unchanged. Guards: a `CheckReport.text` test, `Scripts/check-cli.py` (new flag in usage), README.

### C2. The README build line builds only one product (P2)

`swift build -c release --product swiftformal --product sfverify --product sfgen` builds only `sfgen` (SwiftPM keeps
the last `--product`). Change: one `swift build -c release --product <p>` per product. Also check that `swiftformal
check` names the missing tool and the command to build it when `sfverify` is not next to it (the `scan`/`gen`
forwarders already do).

### C3. Multi-package apps: scan through one root package (P2, docs)

Measured on the app: `sfverify --package <leaf package> --build` gives every package its own scratch directory, so
TCA and friends are rebuilt per package: about 2 min per target cold, 40 min and 37 GB for 19 targets. Scanning the
same targets through the umbrella package that depends on all of them (`--package App/Packages --target
AppSettings`) gives the same verdicts (checked on 4 targets) with one shared build: 69 s for the first feature
target, then 19 to 24 s each, 2.1 GB. Change: Scan guide and PERFORMANCE get this recipe and the numbers.

### C4. Walk guide: two recipes the evaluation needed (P3, docs)

- Listing every failing input of a data audit: `expectProved` stops at the first counterexample per property (by
  design, pinned); `partition` groups all inputs by a Boolean "fails" output.
- Stating "inputs come from the UI" for a computed property: `<name>_requires()` on the getter, so Scan proves the
  rest instead of reporting an out-of-contract input, and the linked walk is no longer skipped.

## Evidence

The evaluation, the two new app test files (`LocalizationFormalTests`, `TabsFormalTests`) with the `Package.swift`
lines they need, and the per-target sweep table were kept outside this repository: they hold the app's code. The app
itself is not changed by this branch.

## Order and commits

1. `docs: plan and round-5 evidence` (this file, archive).
2. `fix(SFVerifyKit): own functions by demangled module, not by mangled prefix` (A1).
3. `fix(SFVerifyKit): macro helpers are compiler-generated; readable categories` (A2, A3 without the Range part).
4. `feat(SFSIL): integer ranges, contains, ~= and Array.indices` (B1, with A3's Range category).
5. `feat(swiftformal): summary line for cannot-trap functions, --show-proved` (C1).
6. `docs: build each product; multi-package recipe; walk recipes` (C2, C3, C4), CHANGELOG `[Unreleased]` entries for
   every user-visible change, KNOWN-ISSUES if anything stays open.

## Done means

- Each new test failed on `ccbd1dd` and passes now.
- `Scripts/safety-net.sh` ends `SAFETY NET GREEN`; `Scripts/test-lane.sh slow` and `oracle` pass (SFSIL and
  SFVerifyKit changed); `Scripts/check-examples.sh` passes.
- `Scripts/metrics.py`: verdict changes only where B1 now reads ranges, each reviewed and recorded in the baseline in
  the same commit; no cost growth over 10 % elsewhere.
- `Scripts/check-test-inventory.sh`: no test disappeared. Ratchets not worse; SwiftLint baseline changed by delta only.
- Public API unchanged (`Scripts/check-api.sh`): the changes are behind `package` access and CLIs.
- Trial merge: `main`'s tree as of the merge, with this branch's diff applied, passes the safety net too.
- Real app (optional, temporary): a fresh worktree of the app, `AppStepByStep` and `AppSettings` scanned through
  the umbrella package now report functions (and `TemperatureUnitType.testTag`); the worktree is deleted afterwards.
