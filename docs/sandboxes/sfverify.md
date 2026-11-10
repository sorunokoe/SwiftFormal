# sfverify: the maintainers' command-line scanner

**Job (Inspector view):** the scanner's back office: a thin command that reads flags, calls `SFVerifyKit` and prints the per-module report. It is no product: users run `swiftformal check`; the golden scan, metrics, corpus and mutation lanes and `check-cli` run this one, built from a checkout (`swift build --product sfverify`).
**Raw input → typed → result:** command-line flags (`--package`, `--target`, `--build`, `--json`, `--gate`) → `SFVerifyKit` → text, `--json` report, or an exit code for the gate. Its flags and its JSON are recorded by `Scripts/check-cli.py` and the scan schema.
**Depends on:** SFVerifyKit. **Must not depend on:** the engine modules directly (it should only call `SFVerifyKit`).
**Fast loop:** `Scripts/sandbox.py sfverify` (builds the product; it has no test target). **Connected loop:** `Scripts/sandbox.py sfverify --connect`
**Real consumers:** `Scripts/check-golden.sh`, `Scripts/metrics.py`, `Scripts/corpus-lane.py`, `Scripts/mutation-lane.py`.
**Run it:** `swift run sfverify --package Examples/GatedPackage --target Kernels --build`
**Platforms (verified):** macOS only (it needs the compiler; see the SFVerifyKit card).
**Known gaps:** none of its own. `main.swift` also imports `SFSIL`, which SwiftPM allows through the `SFVerifyKit` dependency chain. `Scripts/check-layering.py` only looks at declared dependencies, so check this import when `SFSIL` is hidden in Phase 5.
