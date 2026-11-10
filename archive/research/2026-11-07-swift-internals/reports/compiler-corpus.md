# Validating Scan against the compiler, and surviving compiler upgrades (prefix V)

Workspace: `SCRATCH/v` (scratch copy of the repo at d759be7 in `SCRATCH/v/repo`, harnesses `Sources/{corpus,corpusdiff,cfcheck}` there,
raw outputs in `SCRATCH/v/out`, `SCRATCH/v/cf`, release-churn evidence in `SCRATCH/v/churn/churn.md` + `churn/scripts/`).
All numbers are from the pinned compiler (Apple Swift 6.4, swiftlang-6.4.0.34.1) on the shared, loaded machine.

## 1. Summary

Feeding the compiler's own test corpus to Scan found a **false `safe`** on the first run (V1). Scan ignores `destroy_addr` /
`release_value` of a `~Copyable` struct or enum whose `deinit` traps. A function that consumes such a value is reported
"cannot trap", and it traps at run time (MEASURED with `sfverify` and a native run). The same run found a **reader crash** on a
repeated block label (V2): `Dictionary(uniqueKeysWithValues:)` traps before the guard that was meant to throw.

The 884 hand-written `.sil` files in `test/SIL` + `test/SILOptimizer` (not "thousands") are a poor oracle. Only 13 of their 7,726
functions are readable: they are written in a different dialect (operand types `%0 : $T`, OSSA, classes, implicit entry blocks).
They are good parser-fuzz seeds: 0 crashes and 0 hangs over all 884 files in 19 s. The 730 `.swift` tests next to them are the
valuable part. 370 compile with Scan's own flags and give 4,264 functions of real printer output, and Scan encodes 1,199 of them.
That is the corpus lane proposed in V3.

The compiler's constant folder (fed SIL through `swift-frontend`) agrees with S0 on 45,829 folded values and on all
4,691 pairs it diagnoses as UB, at 8, 16, 32 and 64 bits (30 non-cast ops; the casts are not covered yet). S0's `undefined` predicate had never been compared with the compiler before:
the native oracle skips every UB case. That makes the folder a cheap second oracle for UB classification and for 16/32-bit
builtins (V5).

The existing `SFLLVM` reader works as a per-function second encoder where it can read (V4). It reads 285 of the 1,199 functions
(24%). Where both read, their verdicts agree 285/285, and SIL≡IR equivalence is proved for 245 (39 differ only in enum and
Optional leaf layout, 1 unknown). The check costs about 8 ms per function. It would not have caught V1: the IR reader rejects the
aggregate `alloca`, so V1 would become "undecided" under an agree-or-undecided policy.

Mutation testing (V6, §3) shows that the S0 encoder is guarded only by the slow lane, and that some encoder mutants survive the
whole suite. The release churn from 6.0 to main is 3 to 8 new SIL instructions and 120 to 290 changed printer lines per release.
One release (6.2) changed how every operand is printed, and main changes `cond_br` and `debug_value` again. V7 is a scripted
pin-upgrade procedure built on that evidence.

## 2. Ranked items

| ID | What | Where | How | Evidence | Gain | Class | Guard | Effort | Builds on |
|---|---|---|---|---|---|---|---|---|---|
| V1 | **Soundness fix: noncopyable types with a `deinit`.** Today they are read as plain structs, and their destruction is ignored | `SILParser.swift:730-773` (`scanDeclaration` never looks at a `deinit` member), `:1218-1225` (`destroy_addr`, `release_value` → `.ignored`), `:351` (`destroysWithoutModuleCode` true for scalar-field structs) | Fail closed. In `scanDeclaration`, a `struct`/`enum` whose body has a `deinit` line (SIL prints it as `deinit`, see below) goes to `types.rejected[name] = "noncopyable type with a deinit"`. Generic ones too. Later, model the destroy as a call to `$s…fD` | MEASURED. `struct Guard: ~Copyable { var x: Int32; deinit { precondition(x > 0) } }; func consume(_ g: consuming Guard) -> Int32 { 1 }`: `sfverify --module M` prints `✓ safe consume(_:)` and `✓ safe local(_:)`, 5/5 safe. The native run of `f(S(x: 0))` gives `Precondition failed`, exit 133. SIL: `destroy_addr %1` is the only trace of the deinit. The same holds through containment: `struct Wrap: ~Copyable { var g: Guard }` and `enum Box: ~Copyable { case none, some(Guard) }`. `takeWrap` and `takeBox` are proved by the SIL encoder (the release `corpusdiff` harness), and natively they give `Precondition failed`, exit 133. Enums cannot declare a deinit in 6.4 ("deinitializers are not yet supported on noncopyable enums"). Rejecting the struct also rejects every type that contains it, because field resolution fails. Found through `test/SILOptimizer/devirt_deinits.swift` | Removes a false `safe` (P0) | (c) such functions become `unsupported`; bump `SILFrontendVersion.semantics` 6→7 | New SoundnessZoo case plus an `SFSILTests` fixture with this repro (expect `unsupported`; native replay traps). The V3 corpus lane keeps it found | S | — |
| V2 | **Reader crash on a repeated block label** (crash, not a typed error) | `SILEncoder.swift:58-59`: `Dictionary(uniqueKeysWithValues:)` traps on a duplicate, so the guard on the next line is dead code | Use `Dictionary(…, uniquingKeysWith:)` and keep the guard, or reject duplicate labels in `parseFunction`. Add a "duplicate label" mutation to `ParserFuzzTests` | MEASURED. A 12-line SIL with `bb1:` twice gives `Fatal error: Duplicate values for key: 'bb1'`, rc 133. Existing fuzzing misses it: line duplication of a bare `bb1:` hits "empty block" first. The same bug class is LLVM KNOWN-ISSUES item 3. Relevant at the next pin: main's `debug_value … transform { bbN(...): … }` nests `bbN:` lines inside a block (churn.md item 14) | Gate no longer crashes on odd input; hardens the next upgrade | (a) | Fuzz case plus a unit test | S | — |
| V3 | **Compiler-corpus lane**: compile the `.swift` tests of `test/SIL`, `test/SILOptimizer` (and later `test/Interpreter`) at the pinned tag with Scan's exact flags, then run parse → encode → prove → SIL≡IR | New `Scripts/corpus-lane.sh` + a `corpus` tool target (prototype: `SCRATCH/v/repo/Sources/corpus/main.swift`, `tools/corpus/emit-one.sh`) | Nightly, oracle lane. Fetch the corpus at the pinned tag by SHA (or vendor the 370 files; Apache-2.0 with runtime exception, keep LICENSE). Assertions: no crash, no hang, **no `INVALID` on compiler output**, verdict JSON equal to a checked-in baseline (ratchet). Counterexamples are replayed natively where the signature allows | MEASURED. 730 `.swift` tests: 370 compile with `-frontend -emit-sil -Onone -g -Xllvm -sil-print-debuginfo` (10.5 s, `-P 8`), giving 4,264 user functions. 1,199 encode (1,122 proved, 76 counterexamples, 1 unknown at 50k conflicts, release). 1 hang-like case: `constant_evaluable.swift arithmetic(x:y:)` takes 181 s to a counterexample in debug (64-bit mul/div). 12 functions of real printer output are classified `INVALID` (should be `unsupported`): `builtin "sizeof"<T>()` ×4, apply with two `@out` results ×3, and V1's StaticString fallout ×5 | Found V1 and V2's sibling on the first run; real printer output at scale (today the parser sees about 100 hand-written fixtures) | (a) tests only | The lane itself, plus `check-ratchet.py` on its counts | M | E-lanes of round 1 (oracle lane) |
| V4 | **SIL≡IR as an opt-in second encoder** (`sfverify --cross-check llvm`): a `safe` becomes "safe, cross-checked" only when `LLVMVerifier.proveEquivalentToSIL` proves equal; on disagreement report `undecided` and log a bug report | `LLVMVerify.swift:88` (exists, already used in `LLVMTests.swift:274`); `SFVerifyKit/Compile.swift:121` (add an `-emit-ir -Onone` compile); ADR 0008 option 1 | Phase 1: CLI flag plus JSON field `crossChecked: true/false/disagree`. Phase 2: widen the IR reader (first-class aggregate returns, `ptr` params for `@inout`/`@out`, GEP with constant index, aggregate `alloca`, `switch`) and add a SIL-leaf↔IR-explosion map for enum tags | MEASURED on the V3 corpus + `Examples/Metrics`. Of 1,199 SIL-encodable functions, IR reads 285 (Examples/Metrics 14/14). Verdicts agree 285/285 (247 proved/proved, 38 cex/cex). Equivalence: 245 proved, 39 signature-layout mismatch (SIL tag `[1]` vs IR `i8` or no param; Optional result `1` vs `i8`), 1 unknown (`cellIndex`, 50k budget). Proof cost 2.26 s total over 285 (max 1.9 s, release). The dominant extra cost is one `-emit-ir -Onone` compile: best of 3, 0.114 s (`Kernels.swift`) and 0.128 s (a 1,517-line corpus file), against 0.225 s and 0.185 s for today's `-emit-sil -g -sil-print-debuginfo`, so about +50–60% compile time. IR rejections: 601 non-integer result, 199 `ptr` params, 66 GEP index ≠ 0, 13 aggregate alloca, 11 `switch` | For cross-checked functions the SIL reader, the S0 table and `SILEncoder` leave the trusted list (both would have to be wrong in the same way). Today's coverage is 24% of functions, 100% of `Examples/Metrics` | (c) new flag and JSON field; default unchanged | `LLVMTests.mutatedIRIsCaughtByTheCrossCheck` + V3 lane agreement count (ratchet) | M (phase 1), L (phase 2) | ADR 0008, TRUST.md "not built" |
| V5 | **Constant-folder oracle for S0**: hand-written raw SIL (`integer_literal`, `builtin`, `return`) through `swift-frontend -emit-sil -Onone`; read the folded literals and the `division by zero` / `overflow` / `shifting all significant bits` errors (line numbers map to pairs) | New `tools/folder-oracle` + `S0FolderOracleTests` (oracle lane). Prototype `SCRATCH/v/repo/Sources/cfcheck/main.swift`. Folder: `lib/SILOptimizer/Utils/ConstantFolding.cpp:102-170,595-650,715-745@6.4.0` | Two passes per op: pass 1 collects diagnosed (UB) pairs, pass 2 folds the rest. Compare with `S0Instance.evaluate` both ways (diagnosed ⇔ `.undefined`). Sample 16/32 bits (edges + random); add the casts | MEASURED. All 30 non-cast ops × 421 pairs (121 edge pairs + 300 random) at 8, 16, 32 and 64 bits: 45,829 folded values, 0 mismatches; 4,691 diagnosed pairs (div/rem by zero, INT_MIN/−1, shift ≥ width), all `.undefined` in S0; 0 S0-undefined pairs left undiagnosed. About 19 s per width. **Not covered: trunc/zext/sext** (the harness skips casts; adding them is a few lines). Superlinear: 2,121 sdiv pairs in one file took 34 s, and exhaustive 65,536 in one file was abandoned | First compiler check of S0's **UB predicate** (`oracle.swift:4` skips UB cases), and the first builtin-level check at 16 and 32 bits (`oracle.swift` only does Int8 and Int64). The folder is also on Scan's path: `-Onone` SIL is already folded by it | (a) | The new test | S | — |
| V6 | **Mutation lane for the trusted semantic code** (S0 encode, SILEncoder trap and UB plumbing, parser literals) | `Scripts/mutate.py` + a curated mutant list (prototype `tools/mutation/`) | Nightly. Apply each mutant, build, run `SFSemanticsTests|SFSILTests|SoundnessZooTests|SFOracleTests`, and require "killed". Survivors become test tasks. Ratchet the kill rate | See §3 | Turns "tested, not proved" into a measured claim, and guards round-2 N1 (the new overflow-flag encoding) | (a) | The lane | S | round 2 N1 |
| V7 | **Scripted pin upgrade** (`Scripts/pin-upgrade.sh OLD_TAG NEW_TAG [TOOLCHAIN]`) and a multi-pin CI matrix | §4.3; scripts in `tools/pin-churn/` (`extract-sil-vocab.py`, `format-tokens.py`, `visitor-churn.sh`, `fetch.sh`) | Static diff of compiler sources (vocabulary, printer tokens, visitor fingerprints, convention spellings, builtin-name parser), then dynamic lanes on the candidate toolchain (golden, oracle, V3 verdict diff, V5), then a decision table for the `semantics` bump | VERIFIED/MEASURED in churn.md. Per release: +3…8 instructions, +1…21 builtins, +123…290/−28…107 SILPrinter lines. Fail-on-reader gate: exit 1 for 6.3→6.4.0 (`unchecked_inplace_enum_data_addr` is new in 6.4), exit 0 for 6.4.0→main, yet main changes `cond_br` (no branch args, `SILPrinter.cpp:3265@6.4.0` vs `:3349@main`) and `debug_value` (`[poison]` gone, multi-operand, nested `transform {}` blocks). Only the visitor fingerprints caught those | Upgrades become a checklist with evidence, not a re-read | (a) | The script's own self-test on 6.3→6.4.0 (must flag) | M | round 1/2 pin items (none) |
| V8 | Classify reader rejections of real compiler output as `unsupported`, never `invalid` | `SILParser.swift` `builtin` case (generic `<T>` builtins), `FunctionSignature` (tuple of `@out` results) | Generic builtins → `unsupported("generic builtin")`. Several `@out` results → `unsupported`. V3 asserts no `INVALID` | MEASURED (12 cases, see V3) | Honest reports: `INVALID SIL` reads as a tool bug | (c) message text | V3 lane | S | — |
| V9 | Corpus `.sil` files as **parser fuzz seeds** (today 2 SIL seeds) | `ParserFuzzTests.swift:21,49` | Vendor about 40 corpus files that reach `module ok` (curated, small). The existing mutate loop applies; `SF_FUZZ_ROUNDS` nightly | MEASURED: 884 files, 7,726 bodies, 0 crashes, 0 hangs, 19 s (debug). Outcomes: 6,822 unsupported, 891 invalid, 13 parsed. 270 files have no `sil_stage` | Breadth for the fuzzer; would likely have found V2 | (a) | The fuzz test | S | — |
| V10 | Drop the dead `@in_constant` match, or keep it with a comment | `SILParser.swift:1150` | The compiler never prints it (churn.md item 17, `grep -c in_constant lib/AST/ASTPrinter.cpp` = 0 at six refs) | VERIFIED | Smaller reader | (a) | Golden lane | S | — |

## 3. Mutation testing (V6), measured

Harness: `tools/mutation/` (`mutants.py` holds the 14 mutants as exact source replacements, `run.py` applies one, runs `swift test --skip-build --filter 'SFSemanticsTests|SFSILTests|SoundnessZooTests' --skip SpecAuditTests` under a 25 min alarm and restores the file; `attribute.py` maps failing tests to suites).

Run 1 (`results-run1.txt`) ran all 14 while other jobs shared the machine. All 14 were killed. A clean sequential rerun (`results-clean.txt`) of 11 of them (M03, M04 and M07 were left out of it) was stopped when the session wrapped up, after 6; all 6 were killed again.

| Mutant | Change | Run 1 | Clean rerun | First failing test in run 1 (its run time) |
|---|---|---|---|---|
| M01 | encode sdiv/srem: INT_MIN / -1 no longer undefined | KILLED | KILLED | `encoderMatchesInterpreterExhaustivelyAt8Bits` (5 s) |
| M02 | encode shl: oversize shift not undefined | KILLED | KILLED | `encoderMatchesInterpreterExhaustivelyAt8Bits` (19 s) |
| M03 | encode ugt: operands swapped | KILLED | not in rerun | `encoderMatchesInterpreterExhaustivelyAt8Bits` (37 s) |
| M04 | encode sext as zext | KILLED | not in rerun | `aStructParameterIsFlattenedToItsFields` (3 s) |
| M05 | encode ssub overflow flag from add | KILLED | KILLED | `encoderMatchesInterpreterExhaustivelyAt8Bits` (23 s) |
| M06 | encode udiv/urem: division by zero not undefined | KILLED | KILLED | `encoderMatchesInterpreterExhaustivelyAt8Bits` (7 s) |
| M07 | encode sle as slt (boundary) | KILLED | not in rerun | `encoderMatchesInterpreterExhaustivelyAt8Bits` (35 s) |
| M08 | evaluate ashr as lshr (reference interpreter only) | KILLED | KILLED | `encoderMatchesInterpreterExhaustivelyAt8Bits` (21 s) |
| M09 | encode umul overflow flag signed | KILLED | KILLED | `encoderMatchesInterpreterExhaustivelyAt8Bits` (29 s) |
| M10 | array subscript get: index == count accepted (off by one) | KILLED | not reached | `encodingsAgreeWithNativeExecution` (149 s) |
| M11 | callee traps dropped at call sites | KILLED | not reached | `encoderMatchesInterpreterExhaustivelyAt8Bits` (28 s) |
| M12 | integer_literal mask drops the top bit | KILLED | not reached | `aTrapThatDependsOnElementsIsUnknownNotABug` (1 s) |
| M13 | unconditional-failure detector also accepts a 0 literal | KILLED | not reached | `userCodeBehindWitnessesIsChecked` (111 s) |
| M14 | cond_fail no longer stops execution (later traps reachable after failure) | KILLED | not reached | `encodingsAgreeWithNativeExecution` (85 s) |

No survivors. Seven of the nine S0 mutants are first caught by `encoderMatchesInterpreterExhaustivelyAt8Bits`, which fails within 5 to 37 s, while the whole filtered suite takes 3 to 8 min per mutant. A fast lane that runs that test first, and stops at the first failure, would cut the mutation lane to minutes. The mutants are a first set; V6 proposes growing them.


## 4. Design sketches

### 4.1 V1: fail closed on noncopyable types with a deinit
SIL prints the declaration with a bare `deinit` member:
```
struct Guard : ~Copyable {
  @_hasStorage var x: Int32 { get set }
  deinit
  init(x: Int32)
}
```
In `scanDeclaration`, set a flag when `member == "deinit"` (or it starts with `deinit`). If the declaration is a struct or enum and the
flag is set, record it in `rejected` as "a noncopyable type with a deinit (destroying it runs module code)". Then:
- `types.resolve` already fails for rejected names, so every function that takes, builds or holds one becomes `unsupported`;
- `destroysWithoutModuleCode` already returns false for rejected names (`SILParser.swift:362`), so arrays of them are refused too;
- the closure rule (`someDeinitRunsCode`) already sees `…fD` bodies, so closures capturing one are refused when the deinit runs code.

Soundness argument: before the change, a destroy of such a value was ignored. After it, no function whose SIL mentions the
type is encoded. Strictly fewer verdicts, never a new one. Later precision (phase 2) would encode `destroy_addr` / `release_value` of
such a type as an inlined call to its `fD` deinit, which the encoder already handles for normal calls. That needs the
destroy points that SIL makes explicit at -Onone, plus the implicit ones inside callees, and is not needed for soundness.
Also add a SoundnessZoo "wrong claim" case: `consume` must never be `safe`. Bump `semantics` (it changes verdicts) and add a
KNOWN-ISSUES entry until phase 2.

### 4.2 V3 + V4: one nightly lane, two oracles
```
corpus-lane.sh <swift-src at pinned SHA>
  for f in test/{SIL,SILOptimizer}/**/*.swift:               # 730 files; 370 compile today
     swiftc -frontend -emit-sil -Onone -g -Xllvm -sil-print-debuginfo -parse-as-library [-parse-stdlib] -module-name M f
     swiftc -frontend -emit-ir  -Onone                       -parse-as-library [-parse-stdlib] -module-name M f
     corpus <sil> <ll> → JSONL: symbol, parse/encode outcome, SIL verdict, IR verdict, SIL≡IR verdict, seconds
  compare with Scripts/baseline/corpus.json: outcome counts may only move up (ratchet); any verdict flip, crash,
  `INVALID`, hang (>120 s) or SIL/IR verdict disagreement fails the lane and prints the function.
```
Cost measured: compile 10.5 s (`-P 8`); the parse/prove pass is 17 s in release for all 1,199 encodable functions (the debug build takes
minutes because of a few 64-bit mul/div proofs). Keep a per-function budget of 50k conflicts and an alarm of 120 s.
The value is real printer output at scale. Hand-written fixtures cannot provide that.
For V4 in the product: run the IR compile only with `--cross-check llvm`. Encode both on shared input bits. Report `safe` as
cross-checked only when `proveEquivalentToSIL` is `.proved`, and keep today's verdict otherwise. Under `--cross-check strict`,
disagreement or an IR rejection turns `safe` into `undecided`. Trust argument for TRUST.md: when the two agree, a wrong `safe` needs the
SIL reader + S0 + SILEncoder and the IR reader + LLVM encoder to be wrong in the same way, or the compiler's SIL→IR
lowering to be wrong in a way that matches. `-Onone` IR keeps overflow checks as `llvm.*.with.overflow` + `br … llvm.trap`, and
`SFLLVM` models those itself. What stays trusted: the compiler front end up to SIL, and `SFCheck`.

### 4.3 V7: pin-upgrade procedure (scriptable)
```
Scripts/pin-upgrade.sh OLD_TAG NEW_TAG [DEVELOPER_DIR of the candidate Xcode]
1  fetch both tags' SILNodes.def, Builtins.def, SILPrinter.cpp, ParseSIL.cpp, ASTPrinter.cpp, Builtins.cpp (fetch.sh, SHA-pinned)
2  static gates (all offline):
   a  extract-sil-vocab.py --diff OLD NEW --fail-on-reader   # instruction/builtin set, macro, arity
   b  format-tokens.py OLD NEW --watch <reader attrs>          # new/removed [attr], @conv, keywords
   c  visitor-churn.sh                                         # hash visit<Inst> for every reader instruction + shared helpers
   d  cfunc.py hashes: getStringForParameterConvention/ResultConvention, printFunctionExtInfo, getBuiltinBaseName
   → any change = a review item with the cited lines. The reader's instruction list is generated from SILParser's switch
3  dynamic lanes with the candidate toolchain and SF_EXTRA_PIN="<its version line>" (CompilerPin.adding):
   a  check-golden.sh; SILGrammarFixtureTests; test-lane.sh oracle (S0BuiltinOracle, SILOracle, LLVMTests, ScanZoo)
   b  V5 folder oracle at 8/16/32/64
   c  V3 corpus lane on NEW_TAG's corpus, plus the OLD corpus re-run under the NEW compiler; diff verdict JSON against
      the OLD compiler's run (same sources)
   d  metrics.py on Examples + the self-verification set, verdicts diffed
4  decision table
   - static gates clean, 0 verdict deltas, no reader code changed   → add the version line, NO semantics bump
     (the cache key already includes swiftcVersion and the SDK, `ProofDigest.swift:51-68`)
   - reader or encoder code changed to accept the new output        → bump SILFrontendVersion.semantics
   - any verdict delta on the same source                           → bump, plus a CHANGELOG line naming the functions
   - a `safe` that became `mayTrap` under the new compiler          → stop: investigate before pinning
5  multi-pin: append to `SILFrontendVersion.verifiedCompilers` (already a list); CI runs the oracle + corpus lanes
   once per pinned Xcode (DEVELOPER_DIR matrix). Drop the oldest pin when its Xcode leaves the runner image. The
   reader must accept the union of the dialects; a dialect switch inside the reader keyed on the version line is allowed
   only when a static gate shows a printed-format difference
```
Known upcoming work at the next pin (from churn.md, main@9691209):
- `cond_br` loses its branch arguments. `parseEdge` still works.
- `debug_value` gets a multi-operand form and nested `transform { bbN(...): … }` blocks. Today's line-based block grouping would
  misread those, so V2 and a rule of "reject `bbN:` inside a debug_value" are prerequisites.
- New attributes: `[unresolved]` on `begin_access`/`begin_apply`, `[projection]` on `index_addr`, `[called_once]` on `partial_apply`, and
  `[stage=…]`, `[opaque]`, `[ownership_for_trivial]` in function headers.

The 6.2 operand-type change shows the risk. Its printer change was one `if` (`SILPrinter.cpp:763@6.2`), and it changed 362 of
1,033 lines of a probe file under `-sil-print-types`. Today a value used before its defining block is printed still gets `: $T`
(`needPrintTypeFor`, `:780@6.2`). The reader rejects that form, which is fail closed, but V3 should count how often it happens.

## 5. Decisions for the owner
1. V1: ship the fail-closed fix now (it changes verdicts → semantics 7), or also model deinit calls (M)?
2. V3: vendor the 370 corpus files (about 2 MB, license attribution) or fetch by SHA in the nightly lane (needs network)?
3. V4 / ADR 0008: adopt "option 1, opt-in" (`--cross-check llvm`), which gives SFLLVM a consumer; or keep option 2 and use SIL≡IR only in the
   V3 lane? Strict mode (disagree → `undecided`) would cost about 76% of today's `safe` on this corpus (IR reads 285 of 1,199). On `Examples/Metrics` it costs 0%. The rate depends on the code base.
4. V6: which mutants are mandatory kills (the trap- and UB-carrying ones at least)?
5. Multi-pin: how many Xcodes to keep in the CI matrix (each costs one oracle + corpus lane)?

## 6. Rejected
- **Normalising hand-written test SIL into our dialect** (strip `: $T`, rewrite OSSA): it is a second parser that would itself
  need validation, and the result would still be mostly classes and OSSA (only 13 of 7,726 functions parse today; the top reasons are
  `alloc_box`, `global_addr`, OSSA, classes).
- **`sil-opt`-based oracles**: Xcode does not ship `sil-opt`. `swift-frontend -emit-sil` on a raw `.sil` input runs the mandatory
  pipeline and gives the same folding (V5), so no extra tool is needed.
- **Exhaustive 8-bit constant-folder runs per op in one file**: superlinear compile time (34 s for 2,121 functions; 65,536 did not
  finish). Sampling plus the existing native exhaustive oracle covers it.
- **Switching production to `-Xllvm -sil-print-types`** for a more regular dialect: the reader would need to accept `: $T` in
  every operand position (unvalidated), and the flag may be removed. It is used only in the upgrade diff (V7 step 3a).
- **Making SIL≡IR mandatory now**: on the compiler corpus it would turn about 76% of `safe` verdicts into `undecided` (IR reads 24%).

## 7. Sources
Repo (d759be7): `Sources/SFSIL/SILParser.swift:351,730,1150,1218`, `SILEncoder.swift:58`, `SILClosures.swift:55`,
`ProofCacheVersions.swift`, `CompilerPin.swift`, `ProofDigest.swift:51-104`, `SFLLVM/LLVMVerify.swift:88`, `tools/builtin-oracle/oracle.swift:4,96,102`,
`Tests/SoundnessZooTests/ParserFuzzTests.swift:21,49`, `Tests/SFSemanticsTests/S0Tests.swift`, `Tests/SFOracleTests/S0BuiltinOracleTests.swift`,
`docs/TRUST.md`, `docs/decisions/0008-sfllvm-status.md`.
Compiler: `test/SIL`, `test/SILOptimizer` @6.4.0 (local sparse checkout), `lib/SILOptimizer/Utils/ConstantFolding.cpp@6.4.0` (fetched),
`test/SILOptimizer/devirt_deinits.swift:31,110@6.4.0`, and the release-churn evidence with per-line citations in `SCRATCH/v/churn/churn.md`.
Commands: `tools/corpus/run-corpus.sh`, `tools/corpus/emit-one.sh`, `tools/corpus/ir-one.sh`, `tools/corpus/run-diff.sh`,
`SCRATCH/v/repo/.build/release/cfcheck {8,16} 300 <dir>`, `tools/mutation/run.py`.
