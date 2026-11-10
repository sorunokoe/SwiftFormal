# SFGenKit: `sfgen`'s engine

**Job (Inspector view):** the form-filler. It reads a package's symbol graphs and the `Rule` sources and writes the SwiftFormal checks (the `Domain`s) for them.
**Raw input → typed → result:** compiler symbol graphs and Swift source (swift-syntax) → `SymbolGraphLoader`, `SourceIndexer`, `TypeModel` → `DomainBuilder` / `Generator` → generated Swift source text, or a reason why a type could not be turned into a domain.
**Depends on:** nothing in this package (only swift-syntax). **Must not depend on:** any engine module.
**Fast loop:** `Scripts/sandbox.py SFGenKit` (about 15 s). **Connected loop:** `Scripts/sandbox.py SFGenKit --connect`
**Real consumers:** the `sfgen` command.
**Platforms (verified):** macOS only (a build-time tool).
**Known gaps:** the connected loop only builds `sfgen` (`swift build --product sfgen`). `sfgen` has no zero-exit smoke command (`swift run sfgen --help` exits 2, and running it with no arguments also exits 2), and a real `sfgen generate` run needs symbol graphs, so there is no cheap end-to-end check yet. The slow `GeneratedTestsSlowTests` builds a generated file in a package that depends on SwiftFormal as an app does, so the file uses only the public API. It was run end to end once on a production iOS app (392 of 468 Rules, see the [Generate guide](../guides/generate.md)); that needs a Mac, an iOS simulator and the app's own build, so it is a manual check.
