# Standard-library semantics as a trust reduction (prefix R)

Author: research agent "stdlib-trust". Repo state: d759be7. Compiler: Apple Swift 6.4 (swiftlang-6.4.0.34.1), sources at swift-6.4.0-RELEASE (b8189d7).
Workdir with fixtures and a release `sfverify` build: `SCRATCH/rstd/` (`exp/fx*.swift`, `exp/run*.swift`, `exp/as.swift`, `exp/all.swift`, linked SIL in `exp/all.sil`).

## 1. Summary

The audit found **three summaries that let Scan print a false `safe`**. Each was MEASURED: Scan says `safe`, and the same code built natively exits 133 (SIGTRAP).

- **R1:** `.describe` (`String(describing:)` and interpolation of a generic value) ignores the `Mirror` fallback.
- **R2:** `.rawValueHash` never hashes the raw value.
- **R3:** `DefaultStringInterpolation.init(literalCapacity:interpolationCount:)` contains overflow-checked arithmetic.

There is also **a fourth gap, R4.** The "no array holds 2^48 elements" bound is applied only to unknown inputs, not to computed counts. So:
- `Array(repeating:count:)` with a large count gets `contractHolds`, but natively it aborts ("failed to allocate", exit 134) or, at 2^61, dies with SIGBUS.
- `append` after it gives a `contract FAILS` whose replay does not reproduce.

**R5: the TRUST.md sentence about `-Onone` is only half right.** `-Onone` is not a superset of release traps. An `assert` with a side effect gives `safe` at `-Onone` while the release binary traps (MEASURED). `-Onone -assert-config Release` reads release semantics with the same readable SIL and catches it.

Every array summary checks out against the 6.4.0 source:
- Each uses `_precondition`, which traps in both Debug and Release and is removed only in `-Ounchecked`.
- The trap conditions and messages match.

**Most non-array entries cannot trap on their own.** The exceptions are R1–R3 and memory exhaustion.

**Reading the real bodies instead of trusting summaries is possible.** At `-O`, the printed SIL after `performance-linker` contains serialized bodies for 44 of the 51 summarized symbols. Even so:
- Those bodies need a heap, `witness_method` and ObjC-bridge model that Scan does not have.
- At `-Onone`, the code that runs is the OS's `libswiftCore` (Release-built, and as old as the deployment floor), not that body.

So bodies are best used to pin the summaries (R6), not to replace them.

## 2. Ranked items

Class key: (a) time/memory only, (b) changes the CNF or the search, (c) user-visible behaviour.

| ID | What | Where | How | Evidence | Gain | Class | Guard | Effort | Builds on |
|---|---|---|---|---|---|---|---|---|---|
| **R1** | **SOUNDNESS.** `describe()` misses the reflection path | `SILEncoder.swift:780-803` (`describe`); Mirror.swift:584-587, OutputStream.swift:409-450, 302-397, 460-483@6.4.0 | Mirror the stdlib's order. For a module type that has no `TextOutputStreamable`, `CustomStringConvertible` or `CustomDebugStringConvertible` witness, run `describe` on every stored field (struct), every payload (enum) and every tuple element, each via the debug order (debugDescription, then description). Refuse (`unsupported`) a type with a `CustomReflectable` witness (`customMirror` is user code) and classes. For Optional, recurse with the debug order. | MEASURED: `exp/fx.swift`. `describeWrap`, `describeEnum`, `interpWrap` and `describeReflect` are `safe` in Scan; `exp/run <case>` exits 133 for all four | Removes false `safe` | (b)/(c) | New SoundnessZoo cases from fx.swift, each with a native replay; check-golden | S | — |
| **R2** | **SOUNDNESS.** `hashRawValue` runs the `rawValue` getter but never hashes the result | `SILEncoder.swift:750-756` (`hashRawValue`); CompilerProtocols.swift:196-199@6.4.0 (`hasher.combine(rawValue)`) | After the getter, call `hash(rawValueType, getterResult, when:)`. It is a no-op for standard raw types and runs the module type's `hash(into:)` otherwise | MEASURED: `exp/fx3.swift`. `Outer.hash(into:)` is `safe`; `exp/run3` exits 133 (`Key.hash` overflows) | Removes false `safe` | (b) | SoundnessZoo case `Outer`/`RR`/`Key` with a replay | S | — |
| **R3** | **SOUNDNESS.** `DefaultStringInterpolation.init(literalCapacity:interpolationCount:)` is listed as never trapping | `SILSummaries.swift:56`; StringInterpolation.swift:74-79@6.4.0 (`literalCapacity + interpolationCount * capacityPerInterpolation`, both overflow-checked) | Encode the checked `smul(count, 2)` and `sadd(cap, ·)` as traps (two S0 overflow ops), or require both arguments to be constants. Compiler-emitted interpolation always passes literals, so neither fix changes anything there | MEASURED: `exp/fx5.swift`. A direct call with `literalCapacity: Int.max` is `safe` in Scan; native exits 133 | Removes false `safe` | (b) | SoundnessZoo case + replay | S | — |
| **R4** | Make the 2^48 count bound a trap at every count-producing array operation (owner decision D1) | `SILEncoder.swift:589-635` (`makeArray` `.repeating`/`.concatenate`, `mutateArray` `.append`/`.appendArray`/`.insert`), `fresh` at :1103; GenClass.cpp:836@6.4.0 (`CreateMul(ElemStride, Count)`, unchecked); Heap.cpp:85-102@6.4.0 (`swift_abortAllocationFailure`) | `trap(count ≥ 2^48, "array too large: allocation fails")` on each new count. Sound because every element takes ≥ 1 byte (stride ≥ 1) and no Apple 64-bit process can allocate ≥ 2^48 bytes, so the real program dies there. Document that memory exhaustion below 2^48 is not claimed | MEASURED: `exp/big` aborts at counts of 2^44, 2^48 and 2^50 with "failed to allocate N bytes" (exit 134); 2^61 and 2^62 give exit 138 (SIGBUS, size wrapped). `exp/fx2.swift`: `makeCount` with `requires n >= 0` and `ensures r == n` gets `contract holds`; `appendWrap(Int.max)` gets `contract FAILS` with a fictitious result `-2^63` | Removes false `contractHolds` and non-reproducible counterexamples; restores the invariant `fresh` assumes | (b)/(c) | SoundnessZoo: `makeCount`/`appendWrap` contracts; SampleSequenceTests replay | S | — |
| **R5** | Release-configuration Scan: verify at `-Onone -assert-config Release` as well as Debug; `safe` only if safe in both (or in the configuration the user names) | `SILCompiler` invocation in SFSIL / `sfverify` flags; SILOptions.h:209-221@6.4.0; Assert.swift:44-56 (`assert`: Debug only), 318-330 (`_precondition`: Debug and Release), 373-387 (`_debugPrecondition`: Debug only)@6.4.0 | Compile twice and diff function SIL text. Verify the Release variant only for functions whose text differs (MEASURED 28 of 119 in SFCNF). Under `-Ounchecked` (assert-config Unchecked), say "not supported" (checks become UB) | MEASURED: `exp/as.swift` (`assert(a.popLast() != nil)` then `10 / (a.count - 1)`). Scan at `-Onone` says `safe`; `sfverify -O` and `--swiftc-arg=-assert-config --swiftc-arg=Release` both say `may trap` (`g(0)`); the native `-Onone` binary exits 0 and the `-O` binary exits 133 | Closes a real false-`safe` for release builds; TRUST.md sentence fixed | (c) | as.swift as a zoo case; check-cli for the new flag; golden | M | Round-2 E-items if any touch flags |
| **R6** | Summary pin: hash each summarized function's linked SIL closure at the pinned compiler and SDK; fail on drift | new `Scripts/check-summary-pin.py` + `Scripts/baseline/stdlib-summaries.json`; hook in `SILFrontendVersion.verifiedCompilers` bump procedure | See §3.2 | MEASURED: `exp/all.swift` → `-O -Xllvm -sil-print-after=performance-linker` gives 181 bodies (8,585 lines, 614 KB) covering 44/51 entries | Trusted entries cannot drift silently at a compiler/SDK bump | (a) (CI only) | itself; run in CI and on pin bump | M | — |
| **R7** | Put `StdlibSummary.table` into `SemanticsDigest` | `ProofDigest.swift:147-152`; `SILSummaries.swift:35-85` | Append a canonical dump (symbol, summary, arrayOperation, onCollection, isGeneric) to `SemanticsDigest.compute()`. Today, fixing R1–R4 invalidates no cached proof unless `SILFrontendVersion.semantics` is bumped by hand | VERIFIED: `compute()` hashes only `s0Report() + canaryReport()` | A stale `safe` from the cache cannot outlive a summary fix | (a) | ProofCache tests: a table edit changes the digest | S | — |
| **R8** | Record which stdlib actually runs (TRUST.md and pin) | TRUST.md "Scan" Trusted row; libswiftCore.tbd in the SDK | At `-Onone`, every non-transparent call is the exported symbol in the OS's libswiftCore (all summary symbols except `_finalizeUninitializedArray` and the `removeAll` default argument are exported). That dylib is Release-built (no `_debugPrecondition`) and, at the macOS 13 / iOS 16 floor, is Swift 5.7, not 6.4. Only transparent and `@_alwaysEmitIntoClient` code follows the client's configuration. The pin (R6) should also check the non-AEIC entries' trap conditions against the oldest tag the floor allows (swift-5.7-RELEASE) | VERIFIED: TBD grep (49/51 exported). SIL body of `remove(at:)` shows unfolded `builtin "assert_configuration"`, so the client folds it. MEASURED: SFCNF `FixedWidthInteger.init<T>(_:)` (AEIC) differs between Debug and Release ("Not enough bits…" check present only in Debug) | Honest trust statement; catches old-OS divergence | (c) docs | check-links; R6 | S | — |
| **R9** | Use `[_semantics "…"]` on the printed callee declaration as a fail-closed cross-check of the mangled-name table | `SILSummaries.swift`; SemanticAttrs.def:45-66@6.4.0 | Parser keeps the `_semantics` list of `sil` declarations; at table lookup, require the expected tag set (e.g. `remove(at:)` → `array.mutate_unknown`), else `unsupported`. Never derive behaviour from a tag | MEASURED: tags appear on declarations in `-Onone` SIL (`exp/onone.sil`). VERIFIED: tags are not unique (stdlib: `array.mutate_unknown` ×16, `array.make_mutable` ×9, `array.init` ×4) | Defence in depth if the table is mis-typed; little else, since public stdlib manglings are ABI-frozen | (b) (more `unsupported` only) | SILStringTests/SILTests | S | — |
| **R10** | Sound, Unicode-version-independent String facts via ghost leaves (utf8Count, isEmpty) | `SILSummaries.swift` string rows; `SILEncoder.swift` `summaryResults` | String value = opaque id + ghost `utf8Count` (64-bit, ≥ 0). Literal: exact from the `utf8CodeUnitCount` operand. `+`/`+=`: exact sum (with the R4-style 2^48 allocation trap). `isEmpty` ⇔ `utf8Count == 0`. `count`: `0 < count ≤ utf8Count` if non-empty, `0` if empty. `lowercased`/`uppercased`: emptiness preserved, count unknown. `==`: equal ⇒ same emptiness only | MEASURED (`exp/ns.swift`): `"\r\n".count == 1` with utf8 2; `"e\u{301}" == "\u{e9}"` with utf8 3 vs 2; regional indicators give counts 1 + 2 → 2; `"\u{130}".lowercased()` has count 1 and utf8 3 | Resolves `s.isEmpty ? … : …` and `s.count` emptiness traps (KNOWN-ISSUES 7 partly) | (b) | Native differential test over a corpus with CRLF, RI and combining marks; SILStringTests | M | KNOWN-ISSUES 7 |
| **R11** | Add `Hasher()` and `Hasher.finalize()` as unknown-result, no-trap rows | `SILSummaries.swift` | `$ss6HasherVABycfC`, `$ss6HasherV8finalizeSiyF` (both exported; Hasher.swift has no `_precondition`/`fatalError`) | VERIFIED: grep of Hasher.swift finds no trap calls. MEASURED: `hashRR` is `unsupported` today ("calls a function without a body") | Code that hashes locally becomes readable | (c) coverage | SILTests | S | needs R2 first |
| **R12** | Read stdlib bodies instead of summaries ("only the compiler is trusted") | Linker.cpp:322@6.4.0 (`LinkAll` only in the performance pipeline) | REJECTED for now (see §5); keep as long-term L work | MEASURED (see §3.3) | — | — | — | L | — |

## 3. Design sketches

### 3.1 R1 + R2 + R3 + R4 (one soundness patch, S)

**R1, `describe(type, value, when:)`.** The new order:
1. Standard type: return.
2. `Optional`: recurse on the payload, as today.
3. Array: element, as today.
4. If there is a `TextOutputStreamable` witness: `unsupported`, as today.
5. If there is a `CustomStringConvertible` or `CustomDebugStringConvertible` witness: run the witness(es) and return, as today.
6. **New:** if there is a `CustomReflectable` witness: `unsupported("printing T, which supplies its own Mirror")`.
7. **New:** struct or tuple: for each stored field, `describe(field)` with the same gate. Enum: for each payload case k, `describe(payload_k)` gated by `tag == k`.
8. **New:** class, existential, metatype, or anything else Scan cannot lay out: `unsupported`.

Step 7 over-approximates the debug order, because `describe` already runs both `description` and `debugDescription`. So the `_print_unlocked` vs `_debugPrint_unlocked` order difference (description first vs debugDescription first, OutputStream.swift:430-441 vs 466-477) needs no modelling.

Also put a depth limit (or memoization) on recursive types. An indirect enum is already refused elsewhere.

**R2.** In `hashRawValue`, take the getter's result and its type (from the witness's result type), then call `hash(rawType, result, when: c.trueLit)`.

**R3.** Replace the `.unknown` summary with a small `.interpolationInit` case:
- `trap(smulOverflow(count, 2) ∨ saddOverflow(cap, 2·count))`.
- Message: "arithmetic overflow in string interpolation capacity".

**R4.** One helper, `newCount(_ n: BV, call:)`, that emits `trap(¬ult(n, 2^48), site + "array too large: allocation fails")` and returns n. Call it from `.repeating`, `.concatenate`, `.append`, `.appendArray` and `.insert`.

For `.repeating`, the real program has a negative-count `_precondition` first (Array.swift:947@6.4.0) and allocation second. Both are traps, so order only affects the message.

Update TRUST.md: "a count ≥ 2^48 is reported as a trap; memory exhaustion below that is not claimed".

**Upstream report candidate:** `Array(repeating: 0, count: 1 << 61)` gets SIGBUS instead of a clean trap. The size multiplication in `appendSizeForTailAllocatedArrays` is unchecked (GenClass.cpp:836@6.4.0). The cause is INFERRED from the exit code and the source; not debugged.

**Guards.**
- Each fixture goes into SoundnessZooTests as "Scan must not say `safe`".
- Add a test that runs the native binary for the counterexample, as `exp/run*.swift` did.
- Bump `SILFrontendVersion.semantics`, or do R7.

### 3.2 R6, the summary pin

**Inputs.**
- `StdlibSummary.table`, read by a tiny `swift run` helper, or `sfverify --dump-summaries` (new, package-internal flag).
- One generated probe file `Scripts/baseline/summary-probe.swift`. It calls every entry once, like `exp/all.swift`, and is generated from the table so a new entry cannot be forgotten.

**Extraction.**
1. Run `swiftc -emit-sil -O -module-name Probe summary-probe.swift -Xllvm -sil-print-after=performance-linker -Xllvm -sil-print-no-color`, keeping stderr up to the second "SIL module after" banner.
2. For each table symbol, take its body and the transitive closure of `function_ref` targets that have bodies. Stop at module boundaries and at declarations.
3. Normalize each body:
   - Drop `//` comments and debug scopes.
   - Replace the `string_literal utf8 "Swift/<arch>.swiftinterface"` file name, and the `integer_literal $Builtin.Int64, N` that becomes the `line:` `UInt`, with placeholders. In `remove(at:)` these are 1089 and 1090, which are line numbers in the SDK's `arm64e-apple-macos.swiftinterface`.
   - Keep messages and conditions.
4. Hash with `ProofDigest.hash`, both the body alone and the closure.

**Entries without a serialized body.** These are `String.count`, `lowercased`, `uppercased`, `hasPrefix`, `hasSuffix` and `BinaryInteger.description`; `String(describing:)` is also absent. Pin their source text instead: download `stdlib/public/core/<file>` at the tag, extract the declaration by regex, and hash it. Add a `reviewed:` note naming the callees that were checked by hand.

**Storage.** `Scripts/baseline/stdlib-summaries.json`, keyed by mangled symbol:

```json
{
  "compiler": "...6.4.0.34.1",
  "sdk": "...",
  "tag": "swift-6.4.0-RELEASE",
  "entries": {
    "$sSa6remove2atxSi_tF": {
      "kind": "sil",
      "body": "sha256:...",
      "closure": "sha256:...",
      "traps": ["index < count", "index >= 0"],
      "reviewed": "2026-11-07"
    }
  }
}
```

**Hook.**
- `Scripts/check-summary-pin.py` runs in CI and in `safety-net.sh` when `SILSummaries.swift` or the installed compiler changed (same pattern as the api check).
- Adding a version to `SILFrontendVersion.verifiedCompilers` (CompilerPin) without regenerating this file fails the check, because the compiler line is part of the file.
- Regeneration, `--update`, prints a diff of the normalized bodies for review. It is the only way to accept drift, exactly like `check-ratchet.py --update`.
- R8: an optional `--source-tag swift-5.7-RELEASE` mode greps the same functions' `_precondition` lines at the floor tag. This is a manual review aid, not a gate.

**Cost:** one extra 1–2 s compile in CI.

### 3.3 Reading stdlib bodies (measurements behind R12)

No compiler flag pulls stdlib bodies into `-Onone` output.
- **`-Onone`:** the mandatory linker (LinkNormal) brings in only transparent and shared bodies, plus a few others. On `exp/arr.swift` that is 10 bodies, including `Array.append`, `remove(at:)` and `Int.+`.
- **`-Xllvm -link-used-functions`:** changes nothing (25,432 bytes either way).
- **`-sil-link-all`:** does not exist in 6.4. VERIFIED: `LinkAll` is set only by the performance pipeline (SILModule.h:174-180, Linker.h:157@6.4.0).
- **Workable route:** `-O -Xllvm -sil-print-after=performance-linker`. The first printed module (EarlyModulePasses, pass 7) has all reachable serialized bodies before inlining.
  - `exp/arr.swift`: 105 bodies, 409 KB.
  - `exp/all.swift` (every summary entry): 181 bodies, 8,585 lines.
  - 44/51 summary symbols have bodies. Six are declarations only (`String.count`, `lowercased`, `uppercased`, `hasPrefix`, `hasSuffix`, `BinaryInteger.description`). `String(describing:)` did not appear, because the `CustomStringConvertible` overload `$sSS10describingSSx_tcs23CustomStringConvertibleRzlufC` was chosen, and that overload is not in the table.
- **What the bodies contain:**
  - Instructions: 147 `witness_method`, 21+ `ref_element_addr` on `__ContiguousArrayStorageBase`, `alloc_ref`, `bridge_object_to_ref`, `classify_bridge_object`, `checked_cast_br`, `address_to_pointer`/`pointer_to_address`, `load_borrow`/`begin_borrow`.
  - Builtins S0 lacks: `assert_configuration`, `assumeNonNegative`, `canBeClass`, `conditionallyUnreachable`, `copyArray`, `destroyArray`, `takeArrayFrontToBack`/`BackToFront`, `is_same_metatype`, `sizeof`, `strideof`, `stringObjectOr`, `getEnumTag`.
  - Builtins S0 already has: the integer, overflow, comparison and cast families, plus `int_expect`.
  - On Darwin, `_ArrayBuffer` is an ObjC bridge object, so even `count` goes through `canBeClass`/`classify_bridge_object`.
- **Conclusion:** replacing the Array summaries means modelling class storage, COW uniqueness and the ObjC bridge. That is far larger than the ~40 lines of `applyArray`, and it adds trusted code.
- **Execution mismatch:** at `-Onone` it would not even be the code that runs (R8). It only matches `-O` builds, where these bodies are what gets specialized.

### 3.4 R5, release configuration

**Semantics** (VERIFIED, Assert.swift@6.4.0 and SILOptions.h:209-217):

| Construct | Debug (0) | Release (1) | Unchecked (2) |
|---|---|---|---|
| `assert`, `assertionFailure` | trap | removed | removed |
| `precondition`, `_precondition`, `fatalError` | trap | trap | removed or UB (`fatalError` always traps on non-embedded builds) |
| `_debugPrecondition` | trap | removed, unless the stdlib was built with `SWIFT_STDLIB_ENABLE_DEBUG_PRECONDITIONS_IN_RELEASE` | removed |
| Integer overflow `cond_fail` | trap | trap | removed |

`_internalInvariant` is compiled only into asserts-enabled stdlib builds and is never active in a shipped SDK.

**Why `-Onone` is not a superset of Release.**
- A removed `assert` can change state: its condition is not evaluated at all.
- In `as.swift`, Debug pops the element and Release does not, so a later division by zero is reachable only in Release.
- Conversely, Release removes traps.
- So a `safe` in one configuration does not carry over to the other.

**Proposal.**
- `sfverify --config debug|release|both`, default `both`.
- `both` compiles twice (+0.3–0.5 s compile on small inputs).
- Release SIL is re-verified only for functions whose normalized SIL differs from Debug. MEASURED 28 of 119 in SFCNF, mostly AEIC stdlib helpers such as `FixedWidthInteger.init<T>(_:)`.
- A function is `safe` only if safe in each requested configuration.
- `mayTrap` reports name the configuration.
- `-Ounchecked`/`-remove-runtime-asserts` builds: say so and refuse (`unsupported configuration`), because overflow becomes UB rather than a trap.
- The Gate should use the configuration of the build it gates (SwiftPM passes `-Onone` for debug and `-O` for release).

**Proof cache.** `CompilerFingerprint.optimization` already keys the cache by optimization. Add the assert config to that string.

## 4. Decisions for the owner

- **D1 (R4).** Choose between:
  - **(i)** report `count ≥ 2^48` as a trap (recommended, sound);
  - **(ii)** treat it as an assumption ("allocation always succeeds"), which makes natively-aborting paths vacuously hold;
  - **(iii)** keep today's behaviour and document that memory exhaustion is excluded.

  Under (iii), `contractHolds` for `makeCount` stays false for n ≥ 2^44 on this machine.
- **D2 (R5).** Choose the default for plain `sfverify`: `both` (honest, about 1.2× cost) or `debug` (today's behaviour, with the TRUST.md sentence corrected to say it does not cover release builds).
- **D3 (R8).** Decide whether the trust statement covers the deployment floor's stdlib (Swift 5.7 on macOS 13) or only the SDK's. The first needs the R6 `--source-tag` review per floor bump.
- **D4 (R10).** Decide whether String ghost leaves are worth one more trusted model, or whether to wait for a full string model. Only emptiness and utf8-count facts are Unicode-version-independent. Facts about grapheme counts change with the OS's Unicode tables and must not be added.
- **D5 (R1).** For types with `CustomReflectable`, `unsupported` is the simple sound answer. Reading `customMirror` and the `Mirror` children it builds is possible but means modelling `Mirror`.

## 5. Rejected ideas

- **Trusting `@_semantics` tags as behaviour.**
  - UnderscoredAttributes.md:1146-1155@6.4.0: the tags let "the optimizer make use of some key invariants"; "violating the optimizer's assumptions about the semantics results in undefined behavior".
  - That is a promise from the stdlib to the optimizer, not a statement about traps. It is a hint the optimizer may rely on, not a guarantee to us.
  - Tags are shared by functions with different trap behaviour (`array.mutate_unknown` ×16, including `remove(at:)` which traps and `removeAll` which does not).
  - The docs never mention traps. This is absence evidence: a grep of the file for "trap" finds nothing.
  - Use only as the fail-closed cross-check in R9.
  - Detecting operations by tag instead of mangled name buys little: public stdlib manglings are frozen by ABI stability (49/51 table symbols are in libswiftCore.tbd).
- **Using `@_effects(readnone/readonly)` as "cannot trap".**
  - The documentation's own `readnone` example (UnderscoredAttributes.md, `@_effects(readnone)` section) is `lookup(i) { [7,3,6,9][i] }`, which traps on a bad index.
  - The effects describe memory, not termination.
- **Replacing summaries by reading serialized bodies (R12), now.** See §3.3:
  - It needs a heap, COW and ObjC-bridge model.
  - At `-Onone`, the body is not what runs (R8).
  - Revisit only together with class support.
- **Treating `assumeNonNegative` inside stdlib bodies as a free fact.** It is an optimizer hint whose violation is UB (Builtins.def:172-175@6.4.0). If bodies are ever read, it must become an `undefined` condition, not an assumption.
- **A `count < 2^48` upper bound for String parameters.**
  - On Darwin a `String` may be a bridged NSString whose length comes from Foundation, so this is a new environmental assumption, not a stdlib fact.
  - My probe of a custom subclass was inconclusive: one variant was copied eagerly, another reported `isEmpty` with a huge `length`.
  - The bound is only sound for strings Scan builds itself (R10 with the R4 trap).
- **Grapheme-count laws** (`count(a+b) = count(a)+count(b)`, `a == b ⇒ utf8 equal`, case mapping keeps `utf8Count`). Each was MEASURED false (R10 row).

## 6. Sources

**Swift sources at 6.4.0:**
- stdlib/public/core/Array.swift:387-460 (subscript checks, `_checkIndex`), 750-770 (subscript), 924-990 (`repeating:`, `_uninitializedCount`), 1236-1275 (`append(contentsOf:)`), 1316-1351 (`_customRemoveLast`, `remove(at:)`), 1382-1400 (`insert`, `removeAll`), 1462-1471 (`+`, `+=`)
- ArrayShared.swift:38-58, 179-198
- ContiguousArrayBuffer.swift:349-382, 694-712
- ArrayBody.swift:28-64
- RangeReplaceableCollection.swift:846-870
- OutputStream.swift:302-483
- Mirror.swift:584-587
- StringInterpolation.swift:74-79, 108-184
- CompilerProtocols.swift:196-199
- StringGutsRangeReplaceable.swift:120-215
- Character.swift:173-178
- Assert.swift:44-56, 106-121, 275-283, 318-430
- AssertCommon.swift:24-70
- include/swift/AST/SILOptions.h:209-221
- include/swift/AST/Builtins.def:172-175, 725-786
- include/swift/AST/SemanticAttrs.def:27-66
- include/swift/SIL/SILModule.h:174-180
- lib/SIL/IR/Linker.cpp:322, Linker.h:157

**Fetched:**
- lib/IRGen/GenClass.cpp:821-840
- stdlib/public/runtime/Heap.cpp:85-102
- docs/ReferenceGuides/UnderscoredAttributes.md:150-260, 1146-1155

**SDK:**
- `MacOSX.sdk/usr/lib/swift/libswiftCore.tbd` (exported symbols)
- `Swift.swiftmodule/arm64e-apple-macos.swiftinterface:903, 1089-1090` (inlinable bodies, and the line numbers seen in the SIL)

**Repo:**
- Sources/SFSIL/SILSummaries.swift
- Sources/SFSIL/SILEncoder.swift:540-800, 820-1000, 1100-1125
- Sources/SFSIL/ProofDigest.swift:147-152, 266-294
- Sources/SFSIL/ProofCacheVersions.swift
- docs/TRUST.md, docs/KNOWN-ISSUES.md 7-9

**Commands** (all in `SCRATCH/rstd/exp`; `sfverify` = `../repo/.build/release/sfverify`):
- `sfverify --module Sample fx.swift fx2.swift fx3.swift fx5.swift as.swift`
- `xcrun swiftc -Onone run.swift -o run && ./run wrap|enum|interp|reflect|rr` (exit 133), `./run3` (133), `./run5` (133)
- `./big 44|48|50|61|62` (134, 134, 134, 138, 138)
- `./asd` (0) vs `./aso` (133)
- `xcrun swiftc -emit-sil -O -module-name M all.swift -Xllvm -sil-print-after=performance-linker`
- `xcrun swiftc -emit-sil -Onone -assert-config Debug|Release -wmo ... Sources/SFCNF/*.swift`
