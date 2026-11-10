# sfgen: the maintainers' command-line generator

**Job (Inspector view):** the form-filler's front desk: it reads the command (`symbols`, `generate`, `prune`) and calls `SFGenKit`.
**No product:** a checkout builds it (`swift build --product sfgen`); `swiftformal` does not reach it.
**Raw input → typed → result:** command-line arguments → `SFGenKit` → files written to disk, exit code 0 or 2.
**Depends on:** SFGenKit. **Must not depend on:** any engine module.
**Fast loop:** `Scripts/sandbox.py sfgen` (builds the product; it has no test target). **Connected loop:** `Scripts/sandbox.py sfgen --connect`
**Real consumers:** none in this repository. The test target of a production iOS app is the one real run so far: [Generate guide](../guides/generate.md).
**Run it:** `swift run sfgen` prints the usage line `usage: sfgen symbols|generate|prune ...` (and exits 2: there is no `--help` yet).
**Platforms (verified):** macOS only.
**Known gaps:** no example package and no end-to-end test run it; `SFGenKitTests` are its only checks.
