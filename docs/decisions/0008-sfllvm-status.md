# 0008: What to do with `SFLLVM`

Status: **decided 2026-11-07** (see [Decision](#decision)), **built 2026-11-08** (`sfverify --cross-check llvm|llvm-strict`). The facts below were recorded before the decision; they still describe the code today.

## Context

`SFLLVM` (1,280 lines in 3 files) reads LLVM IR produced by `swiftc -emit-ir` and encodes it for the same solver that `SFSIL` uses. It was built as a second, different way to read the compiler's output.

Facts, checked in Phase 3B:

- **No production target imports it.** `SFVerifyKit`, `sfverify`, the Gate plugin and the front-door modules never use it. Only two test files import it: `Tests/SFOracleTests/LLVMTests.swift` and `Tests/SFBVTests/MulHookTests.swift`.
- It is built and tested only as a side effect of the oracle lane. That lane starts `swiftc` and native binaries, so it is slow and needs the pinned compiler.
- It spawns `swiftc` itself (`Process`), so it cannot build for iOS.
- It depends on `SFSIL`, so a change in `SFSIL` can break it. Nothing a user runs would notice.
- Its public API is not part of any product in `Package.swift`.

## Options

1. **Wire it into `sfverify`**, for example as a second reader that must agree with the SIL reader before a function is called proved. This gives it a real consumer, but it adds work and one more thing to trust.
2. **Mark it experimental** and keep it as a test-only oracle: the cross-check for the SIL reader. Say that in its card and in `TRUST.md`.
3. **Remove it** (move it to the `archive/` folder with a note, see ADR 0001). This is the smallest package, but we lose the cross-check.

## Decision

2026-11-07: option 1, as an **opt-in** cross-check, `sfverify --cross-check llvm` (item V4 of the
[Swift internals plan](../../archive/design/plans/2026-11-07-swift-internals.md)). A `safe` would count as cross-checked only
when `LLVMVerifier.proveEquivalentToSIL` proves the SIL and the LLVM IR encodings of that function equal. The default
`sfverify` run does not change.

The SIL and LLVM readers must not share an encoder. The check is worth something only because the two are written
separately.

What exists today (2026-11-07): no `--cross-check` flag. `SFLLVM` is still test-only. The oracle lane
(`Tests/SFOracleTests/LLVMTests.swift`) proves SIL and IR equal on a fixed set of 26 small integer functions, at
`-Onone` and `-O`, and checks that a deliberately changed IR instruction is caught. Measured for V4: the IR reader
reads 285 of the 1,199 compiler-corpus functions that Scan can encode (24 %), so the flag would cover a small part of what Scan reads until the reader is
widened.

## Consequences

- 2026-11-08: the flag is built. `SFVerifyKit` depends on `SFLLVM` (`Scripts/sandboxes.py`); each proved function
  gets `crossCheck` = `agrees`, `disagrees`, `unread` (the IR reader does not support it) or `undecided` (the
  equivalence did not finish in 20,000 conflicts). `llvm-strict` turns anything but `agrees` into `undecided`. On
  `Examples/Metrics` (release build) it adds about 0.5 s: 4 of 5 contracts agree, 1 is undecided.
- `docs/TRUST.md` says what a cross-checked verdict means.
- 2026-11-08 (app study round 6, item 6): on the AppFeature app target the cross-check read 9 of 876 proofs (1 %). The first
  refusal was the signature (544 results that are not one integer, 117 pointer parameters, 73 signatures whose SIL
  leaves and IR parameters differ in count or width). The IR reader now follows `-Onone` stack memory and pointers as
  opaque values, and `LLVMBridge.swift` ties SIL's leaves to the IR's arguments and result through Swift's memory
  layout. It still shares no encoder with the SIL reader: the bridge reads SIL *types*, not its semantics. Result: 218
  `agrees`, 0 `disagrees`, 658 `unread`, each with a `crossCheckReason`. What remains: results written through an
  address (209, mostly `@out` initializers of types holding an existential and `hash(into:)`), existentials (100),
  witness tables and other constant expressions (99), enums that keep their tag in spare bits (about 150 together).
