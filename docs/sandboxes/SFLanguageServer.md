# SFLanguageServer: `swiftformal lsp`

**Job (Inspector view):** shows the inspectors' verdicts where the code is written, and takes a verdict down the moment the code under it changes. It checks on save by running `swiftformal check --json` as a child process (which it can stop with every compiler it started), and turns the report into code lenses, diagnostics, hovers and code actions. It never shows `✓` for code that changed after its check started.
**Raw input → typed → result:** LSP messages (JSON-RPC with `Content-Length` framing) → documents, a generation counter and a change log (`ResultStore`), one check at a time (`RunScheduler`) → `textDocument/publishDiagnostics`, code lenses, hovers, code actions, `$/progress` and `swiftformal/results`.
**Depends on:** SFVerifyKit (the report's types, `SourceRanges`, `Playback`). **Must not depend on:** the engine modules; checks run in a child `swiftformal`, never in the server's process.
**Fast loop:** `Scripts/sandbox.py SFLanguageServer` (framing, staleness, scheduling with a fake runner, rendering, code actions, killing a process tree). **Connected loop:** `Scripts/sandbox.py SFLanguageServer --connect`
**Real consumers:** `swift build --product swiftformal`; `LanguageServerSlowTests` (slow lane) drives the built server over pipes against a small package; the VS Code extension in `Editors/vscode`.
**Run it:** `swift run swiftformal lsp --help`; editor setup in [../guides/editor.md](../guides/editor.md).
**Platforms (verified):** macOS only (it spawns and stops processes with Darwin calls, and SFVerifyKit needs `Process`).
**Known gaps:** a file changed on disk that no `workspace/didChangeWatchedFiles` reports turns stale only when it is the function's own file (its hash is compared on every render), or when it changes while a check runs.
