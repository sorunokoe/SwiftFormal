# Pin upgrade: checking a new compiler before you pin it

Scan reads the SIL text that `swiftc` prints, and that text changes between releases. The pin
(`SILFrontendVersion.verifiedCompilers`, see [compilers](compilers.md)) lists the compilers the reader was checked
against. `Scripts/pin-upgrade.sh` compares the pinned and the candidate compiler sources where the reader uses them,
then prints the lanes to run and the decision table.

## When to run it

- A new Xcode or Swift release is out and you want to pin its compiler.
- The gate or the oracle lane refuses or skips the installed compiler because it is not pinned.
- You changed the reader and want to know which compiler changes it now depends on.

## How to run it

```sh
Scripts/pin-upgrade.sh swift-6.4.0-RELEASE swift-6.5-RELEASE                     # static gates only
Scripts/pin-upgrade.sh swift-6.4.0-RELEASE swift-6.5-RELEASE /Applications/Xcode-27.1.app/Contents/Developer
python3 Scripts/pin-upgrade/selftest.py                                            # offline self-test, under 1 s
```

- Refs: swiftlang/swift tags, branches or commit SHAs. The pin,
  `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)`, is tag `swift-6.4.0-RELEASE`
  (b8189d766d86ad7fc8106787d6ce9e402f38dd72).
- For a candidate Xcode, use the open-source tag of the Swift version it reports. Apple's build can have changes the
  tag does not have; the dynamic lanes cover that.
- Third argument (optional): the candidate's `DEVELOPER_DIR`. The script prints its version line and puts
  `DEVELOPER_DIR` in front of the lane commands.
- `--diff-lines N`: lines shown per changed function (default 30, 0 for none).
- Network: `git ls-remote` for the SHAs, raw.githubusercontent.com for six files per SHA. Cache:
  `.build/pin-upgrade/<sha>/`, or `--cache DIR` / `PIN_UPGRADE_CACHE`. A branch such as `main` is fetched again when
  its SHA moves.
- Offline: pass full 40-digit SHAs that are in the cache. Short SHAs are not accepted.
- Exit status: 0 = no static gate touches the reader, 1 = one does, 2 = usage or download error.

## The four steps

1. **Sources.** Fetch `SILNodes.def`, `Builtins.def`, `SILPrinter.cpp`, `ParseSIL.cpp`, `ASTPrinter.cpp` and
   `Builtins.cpp` for both SHAs.
2. **Static gates** (`Scripts/pin-upgrade/gates.py`, standard library only). A finding is a **flag** (touches what
   the reader uses; exit 1) or a **review item** (listed, does not block).
3. **Dynamic lanes.** Printed, not run.
4. **Decision.** Printed as a table.

### What the reader uses

Derived from the reader's source on every run, never copied by hand:

- **Instructions** (70 today): every string literal in `Sources/SFSIL/*.swift` that is an instruction name in either
  compiler's `SILNodes.def`. The reader matches instructions by literal text (`case "apply":`,
  `line.hasPrefix("cond_br ")`, the deinit allow-list in `SILClosures.swift`, ...).
- **Builtins** (35): names in `Sources/SFSemantics/S0.swift` and quoted builtin names in the reader
  (`"ptrtoint_Word"`).
- **Watched tokens** (24): `@word` and `[word` in the reader's literals, and word literals on a line about attributes
  (`attributes.contains("static")`).

A literal for an instruction the reader rejects only makes the gates stricter.

### Gate 1: vocabulary

Compares instruction names (`SILNodes.def`) and builtin names (`Builtins.def`): added, removed, renamed (same C++
class), changed (other macro, parent class or flags). A change to a name the reader uses is a flag; the rest are
review items.

### Gate 2: tokens

Compares the SIL-like string literals of `SILPrinter.cpp` (`[attr] `, `@...`, `!...`, short keywords) and the keyword
literals of `ParseSIL.cpp`. An added or removed printer token the reader watches is a flag; the rest are review items.
This gate is coarse: a new `[unresolved]` on `begin_access` is only a review item here. Gate 3 catches it.

### Gate 3: fingerprints

SHA-256 of the printer code, with comments and whitespace outside string literals removed. A comment or re-indent
does not change it; any code change does. Each flag shows the function's line in both versions and a short diff.

- **Instructions:** `visit<Class>` in `SILPrinter.cpp`, or the parent class's visitor if there is none
  (`strong_retain` is printed by `visitRefCountingInst`). A changed hash is a flag. A visitor missing on either side
  is also a flag: "not found" never means "unchanged".
- **Shared helpers** (`HELPERS` in `gates.py`, 21 today): block headers and block arguments, the instruction line
  (`print(const SILInstruction *)`, `printInstOpCode`), operand printing (`operator<<(SILValuePrinterInfo)`,
  `needPrintTypeFor`), branch arguments, debug variables and locations, function, global and witness-table headers,
  the parameter and result convention spellings and `printFunctionExtInfo` (`ASTPrinter.cpp`), and
  `getBuiltinBaseName` (`Builtins.cpp`). A helper missing on either side is a flag. If upstream renames a helper,
  update the list.

**Limits of the static gates:**

- They read the open-source compiler, not Apple's build.
- They miss changes in functions that no visitor or helper covers, for example `getIDAndType`, how `SILDeclRef` and
  types print, and the `SILDebugInfo` and scope printers the helpers call.
- A flag means "read this", not "this breaks the reader".
- A clean result is not a pass. Only the dynamic lanes run the candidate compiler.

### Step 3: dynamic lanes

The steps of [compilers](compilers.md#adding-a-compiler), with the candidate compiler selected:

1. Add the candidate's `xcrun swiftc --version` first line to `SILFrontendVersion.verifiedCompilers`. Local edit, do
   not commit yet.
2. Run `Scripts/test-lane.sh oracle` and `Scripts/test-lane.sh slow`.
3. Run `Scripts/check-golden.sh` (golden `sfverify` verdicts) and `python3 Scripts/metrics.py` (verdicts and solver
   cost on `Examples/Metrics`).
4. Compare every verdict with the pinned compiler's run.
5. Run `SF_FOLDER_ORACLE=full Scripts/test-lane.sh oracle` (constant-folder oracle for S0).
6. Run `python3 Scripts/check-summary-pin.py`. It fails on a pinned compiler that is not the one the pin was recorded
   with. `--update` records the new compiler's standard-library code behind every summary and writes the changed code
   to `.build/summary-pin/`. Review each changed function against its summary in `Sources/SFSIL/SILSummaries.swift`
   before you commit the baseline.
7. Run `python3 Scripts/corpus-lane.py` (Scan on the compiler's own `test/SIL` and `test/SILOptimizer`). It fails on
   the candidate until its baseline is recorded. Run it first with the old compiler on the new tag's corpus (change
   `TAG` and `SHA` in the script), then with the new compiler. Compare per-file verdicts, then `--update`.

### Step 4: decision table

| Static gates and lanes | Action |
|---|---|
| Static gates clean, no verdict delta, no reader code changed | Add the version line only. Do not bump `semantics`: the proof cache key already includes the compiler version and the SDK. |
| Reader or encoder code changed to accept the new output | Bump `SILFrontendVersion.semantics`. |
| Any verdict delta on the same source | Bump `semantics`, and add a CHANGELOG line that names the functions. |
| A `safe` that became `mayTrap` under the new compiler | Stop. Investigate before you pin. |

A flag alone does not choose the row. Read each flag. If the reader accepts the new text unchanged (for example, a
new `[attr]` it never sees at `-Onone`), say so in the pull request. Otherwise change the reader, add a fixture, and
bump `semantics`.

## A second pinned compiler

`SILFrontendVersion.verifiedCompilers` is a list, and `CompilerPin` accepts any line in it.

1. Run this procedure with the current pin as OLD and the new compiler as NEW.
2. Append the new version line. Keep the old one while its Xcode is in use.
3. The reader must accept both dialects. Switch on the version line only where a static gate shows the printed text
   differs; otherwise accept both.
4. Add a row to the table in [compilers](compilers.md). The oracle and slow lanes must pass on each pinned compiler.
   In CI that needs one lane per pinned Xcode (a `DEVELOPER_DIR` matrix). That matrix does not exist yet.
5. Drop the oldest line when its Xcode leaves the CI runner image. No `semantics` bump needed.

## Recorded runs (2026-11-07)

Reader at commit 685a07e. Outputs shortened (token lists and diff lines cut). Control: the same tag on both sides
(`b8189d7…` twice, installed Xcode as third argument) exits 0, with 70 of 70 visitors and 21 of 21 helpers unchanged.

### `swift-6.3-RELEASE` to `swift-6.4.0-RELEASE`: exit 1

Expected: a flag on `unchecked_inplace_enum_data_addr`. It is there.

```text
  OLD swift-6.3-RELEASE = aa782beb23b8bd83bd16fca831532a05dd6cea39
  NEW swift-6.4.0-RELEASE = b8189d766d86ad7fc8106787d6ce9e402f38dd72
Reader vocabulary, derived from Sources/SFSIL, Sources/SFSemantics/S0.swift (15 files):
  70 instructions: ...   35 builtins: ...   24 watched tokens: ...

[gate 1] vocabulary (SILNodes.def, Builtins.def)
  instructions: 222 -> 230; added 8, removed 0, renamed 0, changed 1
    added:   dereference_addr_borrow dereference_borrow dereference_borrow_addr init_borrow_addr make_addr_borrow make_borrow unchecked_borrow_enum_data_addr unchecked_inplace_enum_data_addr
    changed: unchecked_take_enum_data_addr
  FLAG    instruction `unchecked_inplace_enum_data_addr` is new (SILNodes.def:632@swift-6.4.0-RELEASE)
  FLAG    instruction `unchecked_take_enum_data_addr` changed: SINGLE_VALUE_INST(UncheckedTakeEnumDataAddrInst, SingleValueInstruction, MayWrite, DoesNotRelease) (SILNodes.def:627@swift-6.3-RELEASE) -> SINGLE_VALUE_INST(UncheckedTakeEnumDataAddrInst, UncheckedEnumDataAddrInstBase, MayWrite, DoesNotRelease) (SILNodes.def:628@swift-6.4.0-RELEASE)
  builtins: 244 -> 251; added 9, removed 2, renamed 0, changed 0

[gate 2] printer and parser tokens (SILPrinter.cpp, ParseSIL.cpp; review-only lines are listed)
  SILPrinter.cpp: 335 -> 347 tokens; added 24, removed 12
  ParseSIL.cpp: 260 -> 270 tokens; added 10, removed 0

[gate 3] fingerprints (printer visitor of each reader instruction, shared helpers)
  FLAG    `alloc_stack` printer changed: visitAllocStackInst SILPrinter.cpp:1582@swift-6.3-RELEASE -> visitAllocStackInst SILPrinter.cpp:1677@swift-6.4.0-RELEASE
  FLAG    `partial_apply` printer changed: visitPartialApplyInst SILPrinter.cpp:1730@swift-6.3-RELEASE -> visitPartialApplyInst SILPrinter.cpp:1829@swift-6.4.0-RELEASE
  FLAG    `struct` printer changed: visitStructInst SILPrinter.cpp:2411@swift-6.3-RELEASE -> visitStructInst SILPrinter.cpp:2557@swift-6.4.0-RELEASE
  FLAG    `tuple` printer changed: visitTupleInst SILPrinter.cpp:2444@swift-6.3-RELEASE -> visitTupleInst SILPrinter.cpp:2591@swift-6.4.0-RELEASE
  unchecked_inplace_enum_data_addr: defined by one compiler only (see the vocabulary gate)
  instructions: 65 of 70 printer visitors unchanged
  FLAG    helper `void print(const SILBasicBlock *BB)` changed: SILPrinter.cpp:989@swift-6.3-RELEASE -> SILPrinter.cpp:1041@swift-6.4.0-RELEASE
  FLAG    helper `void print(const SILInstruction *I)` changed: SILPrinter.cpp:1318@swift-6.3-RELEASE -> SILPrinter.cpp:1402@swift-6.4.0-RELEASE
  FLAG    helper `printAllocRefInstBase` changed: SILPrinter.cpp:1602@swift-6.3-RELEASE -> SILPrinter.cpp:1699@swift-6.4.0-RELEASE
  FLAG    helper `printDebugLocRef` changed: SILPrinter.cpp:1185@swift-6.3-RELEASE -> SILPrinter.cpp:1264@swift-6.4.0-RELEASE
  FLAG    helper `SILFunction::print` changed: SILPrinter.cpp:3574@swift-6.3-RELEASE -> SILPrinter.cpp:3734@swift-6.4.0-RELEASE
  FLAG    helper `printFunctionExtInfo` changed: ASTPrinter.cpp:6628@swift-6.3-RELEASE -> ASTPrinter.cpp:7131@swift-6.4.0-RELEASE
  shared helpers: 15 of 21 unchanged

== Summary
  flags (touch the reader): vocabulary 2, tokens 0, fingerprints 10
  review items (the reader does not use them): 64
```

### `swift-6.4.0-RELEASE` to `main`: exit 1

Expected: only the fingerprints catch `cond_br` and `debug_value`. Result: vocabulary and token gates clean;
fingerprints flag `cond_br`, `debug_value`, 6 other visitors and 4 helpers. The block printer change is the nested
`transform { bbN: ... }` block inside `debug_value`.

```text
  OLD swift-6.4.0-RELEASE = b8189d766d86ad7fc8106787d6ce9e402f38dd72
  NEW main = 9691209cd1612a7163f8f23327d021bd5a227898

[gate 1] vocabulary (SILNodes.def, Builtins.def)
  instructions: 230 -> 234; added 4, removed 0, renamed 0, changed 0
    added:   com_method diagnose end_formal_scope open_com_existential
  builtins: 251 -> 271; added 21, removed 1, renamed 0, changed 0

[gate 2] printer and parser tokens (SILPrinter.cpp, ParseSIL.cpp; review-only lines are listed)
  SILPrinter.cpp: 347 -> 360 tokens; added 18, removed 5
  ParseSIL.cpp: 270 -> 283 tokens; added 17, removed 4

[gate 3] fingerprints (printer visitor of each reader instruction, shared helpers)
  FLAG    `begin_access` printer changed: visitBeginAccessInst SILPrinter.cpp:3017@swift-6.4.0-RELEASE -> visitBeginAccessInst SILPrinter.cpp:3102@main
  FLAG    `begin_apply` printer changed: visitBeginApplyInst SILPrinter.cpp:1811@swift-6.4.0-RELEASE -> visitBeginApplyInst SILPrinter.cpp:1821@main
  FLAG    `cond_br` printer changed: visitCondBranchInst SILPrinter.cpp:3262@swift-6.4.0-RELEASE -> visitCondBranchInst SILPrinter.cpp:3349@main
  FLAG    `convert_function` printer changed: visitConvertFunctionInst SILPrinter.cpp:2329@swift-6.4.0-RELEASE -> visitConvertFunctionInst SILPrinter.cpp:2384@main
  FLAG    `debug_value` printer changed: visitDebugValueInst SILPrinter.cpp:2203@swift-6.4.0-RELEASE -> visitDebugValueInst SILPrinter.cpp:2225@main
  FLAG    `destroy_value` printer changed: visitDestroyValueInst SILPrinter.cpp:2549@swift-6.4.0-RELEASE -> visitDestroyValueInst SILPrinter.cpp:2608@main
  FLAG    `index_addr` printer changed: visitIndexAddrInst SILPrinter.cpp:3067@swift-6.4.0-RELEASE -> visitIndexAddrInst SILPrinter.cpp:3153@main
  FLAG    `partial_apply` printer changed: visitPartialApplyInst SILPrinter.cpp:1829@swift-6.4.0-RELEASE -> visitPartialApplyInst SILPrinter.cpp:1841@main
  instructions: 62 of 70 printer visitors unchanged
  FLAG    helper `void print(const SILBasicBlock *BB)` changed: SILPrinter.cpp:1041@swift-6.4.0-RELEASE -> SILPrinter.cpp:1046@main
  FLAG    helper `SILFunction::print` changed: SILPrinter.cpp:3734@swift-6.4.0-RELEASE -> SILPrinter.cpp:3819@main
  FLAG    helper `SILGlobalVariable::print` changed: SILPrinter.cpp:3979@swift-6.4.0-RELEASE -> SILPrinter.cpp:4081@main
  FLAG    helper `printFunctionExtInfo` changed: ASTPrinter.cpp:7131@swift-6.4.0-RELEASE -> ASTPrinter.cpp:7271@main
  shared helpers: 17 of 21 unchanged

== Summary
  flags (touch the reader): vocabulary 0, tokens 0, fingerprints 12
  review items (the reader does not use them): 70
```

## Files

- `Scripts/pin-upgrade.sh`: fetch, gates, lanes, decision.
- `Scripts/pin-upgrade/gates.py`: the three gates and the summary. Also runs alone with `--old ROOT --new ROOT`.
- `Scripts/pin-upgrade/compiler_sources.py`: reads `.def` files; finds and fingerprints C++ functions.
- `Scripts/pin-upgrade/reader_vocabulary.py`: derives what the reader uses from its Swift sources.
- `Scripts/pin-upgrade/selftest.py` and `fixtures/`: offline self-test. Covers a new reader instruction, a changed
  visitor, a comment-only edit, a missing visitor, a watched token, a changed or missing helper, a missing file, the
  derivation on the real `Sources/SFSIL`, and the shell script on a pre-filled cache.
