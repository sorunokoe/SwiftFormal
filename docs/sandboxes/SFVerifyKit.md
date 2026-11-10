# SFVerifyKit: Scan, the engine behind `swiftformal check`

**Job (Inspector view):** the scanner. It compiles a Swift target, reads the compiler's output for every function, asks `SFSIL` whether it can trap or break its contract, and prints a report or fails the gate.
**Raw input → typed → result:** a package or Swift files → `SwiftPM` / `Compile` run the compiler → `Verify` calls `SFSIL` → `ScanReport` (JSON or text) with verdicts `safe`, `mayTrap`, `contractHolds`, `contractFails`, `undecided`, `unsupported`; with `--mutate`, `ContractStrength` checks each holding contract on edits of its function (`SFSIL/SILMutation.swift`) and adds `weakContract`.
**Depends on:** SFCNF, SFBV, SFProve, SFSemantics, SFSIL, SFLLVM (only for `--cross-check llvm`).
**Fast loop:** `Scripts/sandbox.py SFVerifyKit` (about 45 s with the connected loop). **Connected loop:** `Scripts/sandbox.py SFVerifyKit --connect`
**Real consumers:** `Scripts/check-golden.sh` (the report for `Examples/GatedPackage`, timings stripped) and the gate on it, `swiftformal check --gate --package Examples/GatedPackage --target Kernels` (its `@Verify` functions, with the real macro); the `swiftformal` and `sfverify` commands.
**Platforms (verified):** macOS only. It starts `swiftc` and `swift` with `Process`; the iOS build fails (the first error is in `SFSIL/SILVerify.swift`). Scan inspects code at build time on a Mac; it is not shipped inside an iOS app.
**Known gaps:** about 1,279 lines in 7 files; not split because the JSON report has only one reader today (`docs/decisions/0009-carve-outs.md`). A fresh checkout's first golden run can fail (see `docs/guides/sandbox-workflow.md`, "Known problems").
