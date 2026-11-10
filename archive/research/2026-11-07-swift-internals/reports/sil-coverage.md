# Scan coverage of Swift, measured against the compiler (prefix L)

Repo read at d759be7. My copy is `SCRATCH/silcov/repo`. Compiler: Swift 6.4 (swiftlang-6.4.0.34.1); compiler sources: swift-6.4.0-RELEASE.
Everything was measured on this repository's targets, on `Examples/`, and on fixtures I wrote in `SCRATCH/silcov/fx/`. No external code was used.

Raw data:
- `SCRATCH/silcov/out`: run 1, the stock binary, `--json --show-unsupported --build`, `-Onone` and `-O`, 13 targets plus 3 examples.
- `out2`: the same run with SIL dumps and the loop prototype.
- `out3`: the opaque-float prototype.
- `sil/`: the `-Onone` SIL dumps.
- `feat.Onone.txt`, `census.Onone.txt`, `hist.*.txt`: the analysis results.

Scripts are in `SCRATCH/silcov/scripts`:
- `hist.py`: histogram of the first reason.
- `features.py`: every blocker per function, from the dumped SIL.
- `census.py`: opcode and builtin census.
- `flips.py`: verdict changes between two runs.

The two prototypes are guarded by environment variables (`SF_PROTO_FLOAT`, `SF_PROTO_LOOPS`) and live only in my copy.
- Their diff is `SCRATCH/silcov/prototypes.diff` (72 lines), and the built binary is `SCRATCH/silcov/sfverify.proto`.
- The machine's disk filled up near the end of run 2. Its last targets (`SwiftFormalTesting -O`, `SFGenKit`, the examples) have no dumps, so their numbers come from run 1. The `features.py`/`census.py` totals cover the 11 targets with dumps: 1,988 functions with a body, 1,281 of them refused.
- I then deleted my `.build` folders to free space.

## 1. Summary

**The instruction set is not the main limit. Types, restricted shapes and missing summaries are.**

- **Instructions.** The parser accepts 62 of the 232 instruction kinds in `SILNodes.def`@6.4.0, and 21 of those only in one narrow shape.
- **Builtins.** S0 covers 33 integer operation families out of 271 `Builtins.def` entries (plus `int_*` LLVM intrinsics).
- **What actually blocks.** At `-Onone`, 1,281 refused functions have a body in the dumps. Only 448 (35 %) contain an opcode kind the parser lacks. The other 833 are refused by a type (a `Double` field, a class, a `Dictionary`, an indirect enum), by a restricted shape of an accepted opcode (`begin_access [dynamic]` in 99, a class `ref_element_addr`, a generic or thick `apply`), or by a stdlib call without a summary.
- **The stock histogram ranks gaps wrongly.** It counts only the first reason. For example, "loops" shows 2 functions there, yet 173 refused functions contain a loop.
- **The stock classifier also misfiles.** `Verify.category(of:)` tests `hasPrefix("[")` before `Dictionary<`, so 236 of the 264 functions it calls "arrays" are really sugared dictionaries (`[K : V]`). Separately, 42 "array of X: destroying its elements …" refusals land in "existentials / protocols". Corrected `-Onone` totals: dictionaries and sets 398 (stock 162); genuine array refusals about 70 (28 stock "arrays" plus 42 misfiled). See L13.

**Gaps ranked by the functions they alone would unlock.** I scanned every blocker per function (`features.py`). These counts are the functions where the listed feature is the only blocker.

The counts are heuristic **upper bounds** from text patterns. Only floats were calibrated against a real run: 133 measured flips against 144 predicted. `features.py` also has no array feature, so array-specific refusals are not ranked here.

| Gap | Sole blocker (upper bound) | Functions that also need it |
|---|---:|---:|
| `Dictionary`/`Set` as count-only opaque values | 179 | 502 |
| Floating point as opaque values | 144 | 289 |
| A narrow class model | 107 | 406 |
| Indirect enums | 44 | 221 |
| Calls to user generic functions | 42 | 96 |
| Throws | 13 | 376 |
| Loops / `for-in` | 5 | 173 |

**Floating-point prototype, measured.**
- Treating `Double` and `Float` as opaque types is one line in my copy.
- It moved 133 functions from `unsupported` to a verdict: 130 `safe`, 3 `mayTrap`. These are SFSAT 85 of 156 and SFVerifyKit 48 of 516. The heuristic predicted 144.
- The three new `mayTrap` are `Solver.enqueue`, `recordLevelZero` and `isLocked`: array-index counterexamples with the arrays assumed empty, the same "struct invariant not modelled" kind as §6g. They are in integer code, not float code. (`internalLit` was already `mayTrap` in run 1.)

**Loop prototype.** It gives every loop header the invariant `true`.
- It is sound on fixtures: it never proves the loop that overflows.
- It proves 3 of 4 safe `-Onone` while-loop fixtures.
- It fails on every `-O` loop, because LoopRotate puts the increment before the exit test. That needs 2-induction.

**Limits of this corpus.**
- It is engine code, so it over-weights classes, `Double` and `Dictionary` relative to app code.
- The production app's recorded numbers are proved counts only (2 -> 949 -> 1,095 -> 1,149), with no total and no categories. The cross-check is therefore limited to which §6g blockers have since landed: enums, Optional, opaque `String`, opaque closures, array counts, and generic user structs at concrete types.

**Compiler facts.**
- At `-Onone`, `-emit-sil` gives canonical non-OSSA SIL: OwnershipModelEliminator runs inside the Onone pipeline.
- `-sil-verify-all` works on the release compiler: it aborts on bad SIL, and costs about +40 % compile time on SFSIL.
- `-enforce-exclusivity=unchecked` and a changed `-assert-config` must never be used: they change the program being verified.

## 2. Ranked items

**Classes.**
- (a) = time or memory only.
- (b) = the CNF or the search changes.
- (c) = user-visible behaviour changes: verdicts move from `unsupported`, and the report text changes. Every coverage item here is (c), and also (b), because a function that was `unsupported` gets encoded.

**Labels.** M = MEASURED, V = VERIFIED, P = PROJECTED.

| ID | What | Where | How | Evidence | Gain | Class | Guard | Effort | Builds on |
|---|---|---|---|---|---|---|---|---|---|
| L1 | **Floating point, tier 1.** `Double`/`Float`/`CGFloat`/`Float16` become exact bit leaves. Exact: `float_literal`, bitcasts, `fneg`, `fcmp_*`. Fresh approximate values for arithmetic. `fptosi`/`fptoui` carry an `undefined` condition | `SILParser.swift:321` (`opaqueTypeName`), `parseInstruction` (`float_literal` is unparsed today), S0 | Sketch §3 L1 | M: prototype (opaque kind only) flips 133 functions (130 safe, 3 mayTrap), 0 lost. M: 140 of 144 sole-blocked functions use float only as a type or field. M: `Int(x)` at `-Onone` inlines bitcast plus integer checks (`fx/feats.swift`) | Largest measured single unlock, about 6 % of all functions here | c | New SILTests rows against native execution. S0 exhaustive Float16 `fcmp` test. `SoundnessZooTests`: an FP-dependent trap is `undecided`, never `mayTrap` | S (tier 1a), M (1b) | KNOWN-ISSUES 7 pattern |
| L2 | **`Dictionary`/`Set` as count-only opaque values**, like arrays. Exact `count`/`isEmpty`. `subscript` get returns a fresh Optional. `insert`/`remove`/`updateValue` model the count as a range. Each call runs the module's own `hash(into:)`/`==` on unknown elements, so a trap in them is never hidden | `SILSummaries.swift`, `SILEncoder.applyArray` | Summary table per mangled symbol, same honesty rule | M (heuristic upper bound): 179 sole, 502 joint. Sketch §3 L2 lists the traps the summary must keep. In this corpus the `[String: …]` fields of engine structs dominate | Big here; app code (caches, lookup tables) also common (P) | c | `SILStringTests`-style tests: proved without element facts, `undecided` when the trap depends on them. Zoo: a duplicate-key literal and `init(uniqueKeysWithValues:)` with unknown keys must never be `safe` | M | KNOWN-ISSUES 8 |
| L3 | **Loops in the CLI**, in three steps: (1) header invariant `true` (havoc); (2) 2-induction for rotated `-O` loops; (3) bounded unrolling from the entry with an unwinding check, for real counterexamples. A failed step is `undecided` | `SILEncoder.swift:282` throws today. `SILVerifier.proveLoopFunction` at `SILVerify.swift:470` exists | Sketch §3 L2 | M: fixtures `-Onone`: safeWrap, guarded and countdown become `safe`; unsafeCount and countdown2 are not proved. `-O`: all fail (6 at STEP/EXIT from loop rotation, 2 at ENTRY on the real n < 0 trap). M: only 2 corpus functions reach this stage; 173 refused functions contain a cycle | Unlocks jointly with L4/L1/L2, not alone | c | Fixtures above as zoo tests (`unsafeCount` must never be `safe`). Native comparison through `Fixture.functions` in SILTests on each `mayTrap` | M (1), M (2), M (3) | `proveLoopFunction` |
| L4 | **`for-in` at `-Onone`:** exact summaries for `IndexingIterator<Range/ClosedRange<I>>`, `StrideTo`/`StrideThrough`, `EnumeratedSequence.Iterator`, `indices`. Array iterators give fresh elements | `SILSummaries.swift` | Sketch §3 L3 | V: for-in is desugared in Sema (`SILGenStmt.cpp:1555@6.4.0`). M: `-Onone` calls `makeIterator`/`next` generically, with no body. M: 141 refused functions use an iterator, 0 alone (loops always come with it) | Needed for any `for` loop at `-Onone`, which is the default build | c | SILTests: sum of `0..<n` with `&+` is `safe`; with `+` on `UInt8` it is `mayTrap` at n = 23 (BMC) | M | L3 |
| L5 | **Narrow class model:** a final or non-overridden class, `self` as the only reference, fields as state, `alloc_ref` gives a fresh id, releases go through the deinit audit. Exclusivity: nested conflicts encoded exactly; entry conflicts per the Decision below | `SILParser.swift:1440-1479` (only array plumbing accepted today) | Sketch §3 L4 | M: 107 sole, 406 joint; 99 use `begin_access [dynamic]`. M: `-Onone` method calls are `function_ref` in a whole-module build (no `class_method`) | Large for app code (view models, services; P) | c | Zoo: aliasing pair (`f(a, b)` with `a === b`) and an exclusivity conflict inside the call tree must give `mayTrap` | L | — |
| L6 | **Throws:** a `try_apply` terminator, `throw`, typed-throw errors as values, `any Error` as an opaque box (`alloc/project_existential_box`, `willThrow` builtin as a no-op) | `parseTerminator` (`SILParser.swift:1189`) | Sketch §3 L5 | M: `try_apply` is in 331 refused functions, `throw` in 203, `willThrow` in 131. 13 sole, 376 joint | Unblocks error-handling code, which every app has (P) | c | SILTests: `try?` callers; a typed-throw enum payload is exact | M | — |
| L7 | **User generic calls at `-Onone`:** monomorphise at the call site from the substitution map. Resolve `witness_method $T` through the module's witness tables, or through integer witness summaries | `SILEncoder.swift:848` ("generic call to … with <…>") | Encode the callee body with τ := concrete type. Fail closed on conditional or inherited conformances, default implementations not in the table, and class-bound or existential substitutions | M: 42 sole, 96 joint. At `-O` the specializer already inlines (`useG` becomes plain `cmp_slt`, M) | Medium | c | SILTests: `clampG<Int>` equals the hand-specialized version on all 8-bit inputs | M | — |
| L8 | **S0 and parser small set:** plain `trunc`/`zext`/`sext` (not just `…OrBitCast`); width 128 (`multipliedFullWidth`); `int_ctlz/cttz/ctpop/bswap`; `assumeNonNegative` (identity, undefined if negative); generic builtin syntax `builtin "getEnumTag"<T>(…)` (thrown as *invalid* today) | `S0.swift:10-15, :94`; `SILParser.swift:1363-1384` | One `S0Op` per family with interpreter and circuit side by side | M census of dumped SIL: `trunc_Int8_Int1` and `zext_*` in 13 refused functions, `zext_Int64_Int128` and `truncOrBitCast_Int128_Int64` 56/69 sites, `int_ctlz_Int64` 47 sites, `getEnumTag` 94 sites (14 functions). V: `int_` names come from LLVM, not `Builtins.def` (`lib/AST/Builtins.cpp:2565-2571@6.4.0`) | Small, but exact and cheap | b/c | `S0Tests` exhaustive to 9 bits plus the 128-bit corners; LRAT miters as for N1 | S | — |
| L9 | **`hashValue` getters:** a summary of `_hashValue<T>(for:)` that runs `T.hash(into:)` with an opaque `Hasher` and returns a fresh `Int` | `SILSummaries.swift` | Reuse the Hashable-witness path (`SILEncoder.swift:752-775`) | M: 40 first-reason hits, almost all synthesized `CodingKeys.hashValue` | Low user value; derived code is counted as hand-written | c | SILTests | S | — |
| L10 | **Indirect enums:** refuse for now, and name the reason better | `SILParser.swift` | Recursive data needs a bounded-depth or uninterpreted model | M: 44 sole (SFSIL `ValueType`, SFLLVM `LType`) | Rare in app code (P) | — | — | L (do not start) | — |
| L11 | `-Xllvm -sil-print-types`: the compiler prints every operand's type. The parser checks each inferred type against it and refuses on mismatch | `Compile.swift:128`, parser | Defence in depth, not coverage | M: flag exists (`SILPrinter.cpp:90@6.4.0`) and its output was inspected on fixtures, not yet fed to the parser. `-sil-print-types` plus `-sil-print-no-uses` give 24 % less text on `fx/feats` | Catches parser mis-reads | a/b | Golden must be byte-identical in verdicts | M | Round 2 S6 (parser speed) |
| L12 | Optional `--paranoid`: add `-sil-verify-all` to the emit | `Compile.swift:128` | Pass the flag through | M: aborts (exit 134) on a hand-broken `.sil` with the release compiler; silent without the flag. Cost on SFSIL with links: best 7.19 s -> 10.61 s (noisy, n = 3) | Low: it checks the compiler's output, not our reading of it | a | `check-cli.py` | S | — |
| L13 | **Fix the coverage classifier:** test `[K : V]` before `[`; file "array of X: destroying its elements" under arrays | `Verify.swift:199-232` (`category(of:)`) | Reorder the checks; add a dictionary-sugar test | M: 236 of 264 "arrays" are dictionaries; 42 array refusals filed as existentials | Correct coverage tables for users and for planning | c (report text) | Golden and `check-cli.py` re-recorded; a unit test per category | S | — |

**Trust impact per item.** Trusted core = S0/SFBV/SFCheck/SFCNF.

| Item | New trusted-core lines | Encoder / summary lines (untrusted model, oracle-tested) |
|---|---|---|
| L1 tier 1a (carry floats) | 0 | ~40 (parser types, leaves, `float_literal`) |
| L1 tier 1b (exact `fcmp`, `fneg`, bitcasts) | ~80 in S0 | ~40 |
| L2 Dictionary/Set | 0 | ~250 (summaries, witness calls, trap conditions) |
| L3 loops (havoc, 2-induction, BMC) | 0 | ~150 in `SILVerify`/`Verify` (the cut-point machinery exists) |
| L4 iterator summaries | 0 | ~150 |
| L5 classes | 0 | ~400 (heap state, alias rule, access tracking) |
| L6 throws | 0 | ~200 |
| L7 call-site monomorphisation | 0 | ~200 |
| L8 S0 small set | ~60 in S0 (plain casts, 128-bit width, `ctlz/cttz/ctpop/bswap`, `assumeNonNegative`), plus SFBV support for width 128 | ~20 |
| L9, L11, L12, L13 | 0 | under 50 each |

All line counts are PROJECTED, from the size of the closest existing code (`SILEnums.swift` 217, `SILSummaries.swift` 217, `SILClosures.swift` 105).

Async: 0 occurrences in this corpus (no `@async`, `hop_to_executor`). It is not ranked here; it is needed for apps, after L6.
Closure calls: 19 joint, 1 sole. Inline only a closure whose `partial_apply`/`thin_to_thick_function` of a `function_ref` is visible in the same function; unknown closures stay refused (KNOWN-ISSUES 9).

### Instruction inventory (Q1), condensed

The source is `include/swift/SIL/SILNodes.def`@6.4.0, read with `FULL_INST` expansion (232 kinds; the reference-storage variants such as `unowned_retain` are extra).

**Accepted in full (41).**
- Literals and functions: `integer_literal`, `string_literal` (failure text only), `function_ref`, `global_value`.
- Aggregates: `tuple`, `tuple_extract`, `tuple_element_addr`, `struct_extract`, `struct_element_addr`.
- Enums: `enum`, `unchecked_enum_data`, `init_enum_data_addr`, `unchecked_take_enum_data_addr`, `unchecked_inplace_enum_data_addr`, `select_enum`, `inject_enum_addr`.
- Stack and access: `alloc_stack`, `dealloc_stack`, `dealloc_stack_ref`, `dealloc_ref`, `end_access`, `destroy_addr`.
- Debug: `debug_value`, `debug_step`, `fix_lifetime`.
- Reference counting: `strong_retain`, `strong_release`, `retain_value`, `release_value`.
- Terminators: `return`, `br`, `cond_br`, `switch_enum`, `cond_fail`.
- Other: `convert_function`, `convert_escape_to_noescape`, `mark_dependence`, `end_cow_mutation`, `begin_dealloc_ref`, `end_apply`, `abort_apply`.

**Restricted shape (21).**
- `begin_access`: `[static]` only.
- `alloc_ref`: stack array only.
- `upcast`, `unchecked_ref_cast`, `ref_element_addr`, `ref_tail_addr`, `index_addr`: array plumbing only.
- `metatype`: empty aggregate only.
- `unreachable`: only after a failure call.
- `apply`: thin, method or witness conventions, no generic callee unless summarized.
- `begin_apply`: array `modify` only.
- `struct`: not `StaticString` or array bodies.
- `store` and `load`: tracked stack slots only.
- `copy_addr`, `switch_enum_addr`, `select_enum_addr`: on enum or stack values.
- `builtin`: the S0 table only.
- `partial_apply` and `thin_to_thick_function`: opaque closure only.
- `begin_cow_mutation`: `[native]` only.

**Not accepted (170).** Grouped below. Counts are refused `-Onone` functions containing the opcode (`census.Onone.txt`).
- Error handling: `try_apply` 331, `throw` 203, `alloc_existential_box` and `project_existential_box` 112, `open_existential_box` 10, `throw_addr`.
- Boxes (captured `var`s): `project_box` 86, `alloc_box` 21, `dealloc_box` 3.
- Pointers: `pointer_to_address` 61, `address_to_pointer` 26, `ref_to_unmanaged` 25 (plus `unmanaged_to_ref` 25).
- Dispatch: `witness_method` 39, `objc_method` 36, `class_method` 7, `super_method`, `dynamic_method_br`.
- Existentials: `open_existential_addr` 34, `init_existential_ref` 12, `init_existential_addr` 2, `value_metatype`, `existential_metatype`.
- Key paths: `keypath` 28.
- Floats: `float_literal` 9.
- Casts: `checked_cast_addr_br` 3, `checked_cast_br`, `unconditional_checked_cast*`.
- Async: `hop_to_executor`, `get_async_continuation*`, `await_async_continuation`.
- Other terminators: `switch_value`, `yield`, `unwind`.
- `global_addr`: mutable globals (refused on purpose).
- Packs and variadic generics (`*_pack*`), differentiation, Objective-C blocks.

Dropped from the gap list:
- OSSA-only and raw-SIL-only kinds cannot appear in `-emit-sil` output: `copy_value`, `destroy_value`, `begin_borrow`, `end_borrow`, `load_borrow`, `store_borrow`, `move_value`, `destructure_*`, `mark_unresolved_*`, `assign*`, `mark_uninitialized`, `*moveonlywrapper*`, `explicit_copy_*`, `unchecked_ownership_conversion`.
- The reason: OwnershipModelEliminator runs in the Onone pipeline (`PassPipeline.cpp:1100@6.4.0`) and in the performance pipeline (`:1031`). M: 0 `[ossa]` functions in our `-Onone` output.

**Builtins** (`include/swift/AST/Builtins.def`@6.4.0, 271 entries):
- **Covered (33 families):** `add/sub/mul/sdiv/udiv/srem/urem`, `and/or/xor/shl/lshr/ashr`, the 6 `*_with_overflow`, 10 integer `cmp_*`, `trunc/zext/sextOrBitCast`, `int_expect`. Also the special cases `truncOrBitCast_Int64_Word` and `ptrtoint_Word` (failure text).
- **Not covered, but they occur:** `willThrow` 131 functions, `getEnumTag` 14, plain `trunc`/`zext`/`sext` 13, 128-bit widths, `int_ctlz` and the other LLVM intrinsics, all FP (`fcmp_*`, `fadd`, `fmul`, `fdiv`, `fsub`, `sitofp`, `fptosi`, `int_floor/ceil/round/rint/trunc`), `assumeNonNegative` (at `-O`).
- **Not seen in this corpus:** atomics, `once`, task and actor builtins, and the SIL-level builtins (`load`, `take`, `gep`).

## 3. Design sketches (top items)

### L2. Dictionary and Set: count-only values, with the traps kept

What the compiler emits (M, `fx/dict.swift`, `-Onone`): calls to the stdlib entry points `Dictionary.init(dictionaryLiteral:)`, `Dictionary.subscript.getter`/`.setter`, `Dictionary.count.getter`, `Dictionary.init<A>(uniqueKeysWithValues:)` and `Set.contains(_:)`. None of them has a body in our SIL.

Model:
- A dictionary or set is an opaque value plus an exact `count` leaf (≥ 0), the same shape as arrays (KNOWN-ISSUES 8).
- `count` and `isEmpty` are exact. `subscript` get gives a fresh `Optional` (an approximation). A set or remove changes `count` within a range (+0/+1, or −0/−1), as a fresh value bounded by those facts.
- Each call that hashes or compares keys runs the module's own `hash(into:)` and `==` on unknown keys, as `Array.contains` already does. A trap in user code is therefore never hidden. Keys and values whose destruction may run module code are refused, as for arrays.

These calls trap and must stay traps in the summary (V):
- A dictionary literal with duplicate keys: `_precondition(!found, "Dictionary literal contains duplicate keys")` at `Dictionary.swift:880@6.4.0`.
- `init(uniqueKeysWithValues:)` with a duplicate key: `fatalError("Duplicate values for key: …")` at `NativeDictionary.swift:823-825@6.4.0`.
- A `Hashable` type whose `hash` and `==` disagree: `KEY_TYPE_OF_DICTIONARY_VIOLATES_HASHABLE_REQUIREMENTS` at `NativeDictionary.swift:458,487,557@6.4.0`.

With unknown keys these conditions are unknown, so a function that reaches them is `undecided`, never `safe`. The exception is a literal whose keys are distinct constants, which is exactly checkable. Dropping these traps would give a false `safe`.

Trust: no trusted-core code; encoder and summary code only.

### L1. Floating point as exact bit leaves, with arithmetic as fresh values

What the compiler emits (M, `fx/feats.swift`, `-Onone`):
- `x * y + 1.0` lowers to `struct_extract #Double._value`, `builtin "fmul_FPIEEE64"`, `float_literal $Builtin.FPIEEE64, 0x3FF0…`, `builtin "fadd_FPIEEE64"`, `struct $Double`.
- `Int(x)` is inlined (transparent): `bitcast_FPIEEE64_Int64`, exponent tests in integer builtins, two failure blocks ending in `unreachable`, then `fptosi_FPIEEE64_Int64`.
- No FP builtin traps. Only the integer checks around a conversion do.

Steps:
1. **Carry them.**
   - Each float type is a leaf of width 16/32/64 that holds the IEEE bit pattern. Do not use `.opaque`, which has no bits, so that step 2 can be exact.
   - Copies, stores, loads, payloads, getters and setters are then exact.
   - The prototype used `.opaque`: SFSAT 85/156 and SFVerifyKit 48/516 functions change verdict; nothing that was decided changed.
2. **Exact and cheap.**
   - `float_literal` (a constant); `bitcast_*` (identity on bits); `fneg` (flip the sign bit).
   - The 16 `fcmp_*` predicates. NaN means the exponent is all ones and the mantissa is not zero. Ordered compare is a sign-magnitude compare, with +0 == -0.
   - With these, `Int(x)` on an input `x` is exact.
   - `fptosi`/`fptoui` give a fresh, approximate result plus `undefined` when the operand is NaN or out of range. That is LLVM poison, and the condition is computed exactly from the bits.
3. **Approximate.**
   - Applies to `fadd/fsub/fmul/fdiv/frem`, `int_*_FPIEEE*`, `sitofp/uitofp`, `fpext/fptrunc`.
   - Each gives a fresh value, recorded in `approximations`, so `honest()` (`Verify.swift:155-170`) turns a counterexample that depends on it into `undecided`.
   - It cannot give a false `safe`: these operations never trap, and a fresh value over-approximates the result.

Tier 2 is bit-precise IEEE circuits in the SymFPU style (Brain, Schanda, Sun, TACAS 2019). It means hundreds of trusted lines and large circuits. Not before tier 1 shows FP-dependent traps that users care about.

Trust:
- Steps 1 and 3 add no S0 code.
- Step 2 adds about 80 lines to S0. Guards:
  - Exhaustive `fcmp` against native `Float16` on arm64, over all pairs from a class-complete set (±0, subnormals, ±inf, NaNs of both signs and payloads), with all 2^32 pairs in the slow lane.
  - Random Float/Double against native.

### L3/L4. Loops: havoc, then 2-induction, then bounded unrolling. Never a false `safe`

`proveLoopFunction` already cuts loops at their headers. Its free header state covers block parameters and stack cells. It checks INIT/STEP/EXIT.

1. **Havoc (invariant `true`).** Prototype: 30 lines in `Verify.swift`, used only for functions without a contract when the encoder throws "loops in f".
   - Proved `safe`: `-Onone` `safeWrap` (`s &+= 1`), `guarded`, `countdown`.
   - Not proved: `unsafeCount` (`s: UInt8; while k < n { s += 1; k += 1 }`, which really overflows at n = 256). Also not proved: `countdown2`, which is safe but needs `k + x == n`.
   - A failed obligation is `undecided`, because the havocked state may be unreachable.
2. **2-induction.**
   - Under havoc, all 8 `-O` loop fixtures fail (M). Six fail STEP/EXIT. `sumTo` and `sumWrapped` fail ENTRY, which is the real `Range requires lowerBound <= upperBound` trap for n < 0. LoopRotate moves the exit test to the latch: the body runs `k + 1` before testing `k != n`.
   - The fix: assume one previous iteration from a havocked state that did not trap and took the back edge. Then check the next one.
   - References: Sheeran, Singh and Stålmarck (FMCAD 2000); Donaldson et al. (SAS 2011) for software.
   - The base case is step 3, so no new trusted code is needed.
3. **Bounded unrolling from the entry, with an unwinding check** (CBMC style).
   - A trap within k iterations is a real input: `mayTrap`, confirmed by replay.
   - If iteration k+1 is reachable and steps 1-2 failed: `undecided ("loop bound k reached")`.
   - Example: `sumChecked(n: UInt8)` (`for i in 0..<n { s += i }`) traps at n = 23, which needs k >= 23. The budget scales with k times body size.
4. **Later:** Houdini over candidate invariants mined from the SIL (iterator bounds, `0 <= i <= count`), each one checked.

For L4 (`for-in` at `-Onone`):
- **The gap.** Since Swift 6.x, Sema desugars `for x in s` into `var $x$generator = s.makeIterator(); while let x = $x$generator.next() {…}` (`SILGenStmt.cpp:1555@6.4.0`). At `-Onone` the SIL has generic calls `apply %44<Range<Int>>(…)` to `makeIterator()` and `IndexingIterator.next()` (M).
  - `next()` is `@inlinable @inline(__always)` (`Collection.swift:123-130@6.4.0`), but only `@_transparent` is inlined at `-Onone`.
  - At `-O`, the same loop is plain integer SIL with the induction variable as a block argument (M). There, L2 alone is enough.
- **The summary.** The iterator state is (lower, upper, position).
  - `next`: if position == upper, return `none`. Otherwise return `some(position)` and set position to position + 1.
  - Keep the trap `!(lower <= position < upper)`. It is unreachable, because the state comes from `makeIterator`. The `Range.init` check `lower <= upper` stays a real `cond_fail` in user code.
  - `StrideToIterator.next` follows `Stride.swift:348-355@6.4.0`.
  - Array iterators: elements are fresh values and the count is exact (KNOWN-ISSUES 8).

### L5. Classes: refuse aliasing, and make the exclusivity rule explicit

What the compiler emits for `c.n += 1` at `-Onone` (M): `ref_element_addr %0, #Counter.n`, `begin_access [modify] [dynamic]`, load/add/store, `end_access`.

**Model.**
- A reference is an opaque id. The stored fields of `self` are input leaves, and writes are outputs, exactly as for `inout` structs.
- Accepted only when aliasing is decided:
  - `self` is the only class value;
  - no class value is loaded from a field;
  - no class value is passed to unread code.
- Later: several references, with a case split on id equality.
- `alloc_ref` gives a fresh id distinct from every input.
- Releases reuse the deinit audit (`SILClosures.swift`).
- Exclusivity conflicts inside the analysed call tree are encoded exactly: open accesses per (id, field), and a conflict is a trap.
- A conflict with an access the *caller* holds is invisible here. Example: `swap(&c.n, &y)` where code inside reads `c.n`. See Decision 1.

### L6. Throws: a second exit

What the compiler emits (M):
- The callee type is `(Int) -> (Int, @error any Error)`. Typed throws is `(Int, @error E)`.
- The callee ends in `throw %e`.
- The caller ends a block with `try_apply %f(…), normal bb1, error bb8`.
- An untyped error is boxed: `alloc_existential_box`, `project_existential_box`, `store`, `builtin "willThrow"`.

Encoding:
- The result becomes (isError, normal leaves, error leaves), and `try_apply` branches on isError.
- A typed error of a modelled enum is exact.
- `any Error` is an opaque box. `catch let e as E` (`checked_cast_addr_br`) is a fresh condition, recorded as an approximation.
- Releasing a box can run a deinit, so the box goes through the deinit audit.
- Throwing is not a trap.

## 4. Compiler-side facts (Q4), each tried on the installed 6.4 compiler

| Fact | Evidence | Use |
|---|---|---|
| `-emit-sil` is canonical SIL after the mandatory passes, **not OSSA** at `-Onone` or `-O`. OME runs in both pipelines | V `PassPipeline.cpp:1100` (Onone), `:1031`@6.4.0. M: 0 `[ossa]` in `fx/feats` output | Drop all OSSA instructions from the roadmap. Ownership verification is moot |
| DefiniteInitialization: canonical SIL has no reads of uninitialized memory and no `mark_uninitialized` | V `PassPipeline.cpp:129`; `docs/SIL/SIL.md:95-98` ("Dataflow errors must be eliminated") | The encoder's "load of an uninitialized slot" refusal is a backstop that real input should never hit. Keep it fail-closed |
| Static exclusivity: a statically enforced conflict is a compile error. AccessEnforcementSelection turns every remaining access into `[static]` or `[dynamic]` | V `PassPipeline.cpp:113,122`; `AccessEnforcementSelection.cpp:52,59`; `docs/SIL/Instructions.md:1521-1575` | Justifies treating `begin_access [static]` as a plain alias (today's code). `[dynamic]` is a real runtime trap point (L5) |
| DiagnosticConstantPropagation folds constants and **rejects constant overflow at compile time**; NoReturnFolding and DiagnoseUnreachable shape failure paths | V `PassPipeline.cpp:124,228,244` | Explains why `unreachable` follows a `Never` call (the parser relies on it, `SILParser.swift:1084`). No soundness reliance needed |
| `-sil-verify-all` (FrontendOptions.td:1092) **works on the release compiler** | M: a hand-broken `.sil` aborts with "SIL verification failed: return value type does not match" (exit 134); without the flag, exit 0. Cost: SFSIL with links, best 7.19 s vs 10.61 s | Optional `--paranoid` (L12). It verifies the compiler, not our parser. Low value |
| `-sil-ownership-verify-all` (:1098) | Exists; nothing to check after OME | Reject |
| `-emit-sorted-sil` (:1138) | M: same output size; only the order changes | Reject: the parser indexes by symbol |
| `-Xllvm -sil-print-types` (`SILPrinter.cpp:90`), `-sil-print-no-uses` (:98), `-sil-print-loopheaders` (on by default, :112) | M: operand types are printed inline; with both flags the `fx/feats` SIL is 24 % smaller (167 KB to 127 KB) | L11: a cross-check of inferred types. These are cl::opts, stable only because the compiler is pinned (`CompilerPin.swift`) |
| `-enforce-exclusivity=unchecked` (Options.td:1825) | M: removes the `[dynamic]` `begin_access` in `Base.get` | **Never use.** It verifies a different program |
| `-assert-config` (Options.td:1316) | M on `fx/asrt.swift` at `-Onone`: Debug has 2 `cond_fail` and 4 `unreachable`; Release has 4 `cond_fail` and 0 `unreachable` (`assert` gone, `precondition` becomes a `cond_fail`); Unchecked has 2 `cond_fail` | Use only the user's real configuration. A "release semantics at `-Onone`" mode is possible, but only if it matches what the user ships |
| `-emit-lowered-sil` | Exists (Options.td:1446) | Not useful: lowering adds address-only plumbing |

## 5. Decisions for the owner

1. **The entry assumption for class exclusivity (L5).** Should `safe` for a method that does `begin_access [dynamic]` mean "safe, assuming no conflicting access to the same object field is active when it is called"? The report would state this per function. The alternative is `undecided`, which makes class code nearly never `safe`. Recommendation: allow it, print it, and count it as an assumption in TRUST.md, like `requires`.
2. **Should a float verdict print "float values not modelled"** when the proof used fresh FP values (it is still `safe`), or only when the verdict is `undecided`? Recommendation: only on `undecided`, as for strings.
3. **Loop bound k for BMC** (L3 step 3): a fixed default (for example 16) plus `--unwind N`, or derived from `requires`? Recommendation: default 8, the flag, and the bound named in the `undecided` detail.
4. **Should derived conformance code** (`CodingKeys.hashValue`, `==` of enums) count as hand-written in the totals? Today it inflates "unsupported" (L9).
5. **What `safe` means for a function with a loop (L3).** The havoc and induction proofs show partial correctness: no trap on any path that reaches it. A function that never terminates comes out `safe`, and `contractHolds` holds only if the function returns. Today no function with a loop is ever `safe`, so this changes what users and the build gate see. Recommendation: allow it, say "termination not proved" in the detail, and add the point to TRUST.md. A variant (`LoopVariant`, already in `SILVerify.swift:203`) can upgrade it to total correctness later.
6. **`-sil-print-types`** changes operand syntax the parser relies on. Adopt it only together with Round 2 S6 (byte scanner), not as a separate parser change.

## 6. Rejected ideas

- **SymFPU-style IEEE circuits first:** large trusted code, and tier 1 already unlocks 133 of 144 measured functions.
- **`-enforce-exclusivity=unchecked`**, or any `-assert-config` other than the user's: they change the program.
- **Ownership verification or OSSA input** (`-sil-stop-optzns-before-lowering-ownership`): no coverage gain; adds about 20 OSSA instructions to parse.
- **Reading generic function bodies "for all T":** unsound without a model of every conformance. Monomorphise at call sites only (L7).
- **Existentials through closed-world dispatch for public protocols:** another module may conform. Possible later only for `internal`/`private` protocols, where every conformance is in the module. 0 sole blockers here (existentials always come with throws), so not ranked.
- **Treating `begin_access [dynamic]` as an alias**, as is done for `[static]`: it hides a runtime trap.
- **Using `-O` SIL as the main coverage lever:** it inlines stdlib internals: raw pointers appear in 141 of 591 refused `-O` functions (7 engine targets), and `fields of String`/`_ArrayBody` show up as first reasons. Total coverage is lower (344 of 1,536 safe at `-O` vs 780 of 2,237 at `-Onone`). Keep `-O` for release semantics.

## 7. Sources

- **swiftlang/swift@swift-6.4.0-RELEASE:**
  - `include/swift/SIL/SILNodes.def`, `include/swift/AST/Builtins.def`, `lib/AST/Builtins.cpp:2565`
  - `lib/SILOptimizer/PassManager/PassPipeline.cpp` (fetched)
  - `lib/SILGen/SILGenStmt.cpp:1498-1558`
  - `lib/SILOptimizer/Mandatory/AccessEnforcementSelection.cpp`
  - `lib/SIL/IR/SILPrinter.cpp:68-113`
  - `include/swift/Option/FrontendOptions.td`, `Options.td`
  - `docs/SIL/SIL.md:84-98`, `docs/SIL/Instructions.md` (begin_access 1521, try_apply 5417, throw 5075)
  - `stdlib/public/core/Collection.swift:69-131`, `Range.swift:180,238`, `Stride.swift:348`
- **Repo:** `Sources/SFSIL/SILParser.swift:454-504,1189-1519`, `SILEncoder.swift:40-160,282`, `SILVerify.swift:470-616`, `Sources/SFSemantics/S0.swift:10-120`, `Sources/SFVerifyKit/Verify.swift:142-232`; `archive/research/2026-11-05-triz-and-swift-semantics.md` §6g; app study numbers from commit bodies d759be7, dd8e9c5, 35238ef.
- **Literature:**
  - Brain, Schanda, Sun, *Building better bit-blasting for floating-point problems*, TACAS 2019.
  - Sheeran, Singh, Stålmarck, *Checking safety properties using induction and a SAT-solver*, FMCAD 2000.
  - Donaldson, Haller, Kroening, Rümmer, *Software verification using k-induction*, SAS 2011.
  - Clarke, Kroening, Lerdahl, *A tool for checking ANSI-C programs* (CBMC unwinding assertions), TACAS 2004.
