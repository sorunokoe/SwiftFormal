# SwiftFormal for VS Code

Starts `swiftformal lsp` for Swift files, beside the Swift extension's sourcekit-lsp (never instead of it). On save it
checks the code and shows:

- a code lens per function: `✓ proved`, `✓ cannot crash`, `✗ counterexample`, `? unchecked: <reason>`, `⚠ stale`;
- counterexamples as diagnostics, details on hover;
- code actions: replay a counterexample as a test, add a promise (`@Verify`, `#requires`, `#ensures`), add a
  `Prove(it:over:)` test;
- every verdict in the Test Explorer (publish-only: save or run **SwiftFormal: Check Now**). Stale and unchecked show
  as skipped, never passed.

What each lens means: [editor guide](../../docs/guides/editor.md).

## Build and install

```sh
swift build -c release --product swiftformal   # in the SwiftFormal checkout
cd Editors/vscode
npm install
npx tsc -p .
```

Then **Developer: Install Extension from Location…**, pick this folder, and set `swiftformal.path` to the built
`swiftformal` (or put it on `PATH`).

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `swiftformal.path` | `swiftformal` | The executable; the extension runs `<path> lsp`. Changing it restarts the server. |
| `swiftformal.checkOn` | `save` | `save`, or `never` (only **Check Now**). |
| `swiftformal.scan` | `[]` | `--scan` targets, `<package-dir>:<target>`, relative to the workspace folder. Empty: the target of the saved file. |
| `swiftformal.tests` | `""` | The `--tests` target with the walks. Empty: no walks. |
| `swiftformal.walks` | `true` | Run the walks of `swiftformal.tests`. |
| `swiftformal.budget` | `null` | Scan's solver conflict budget per function (`--budget`). |

A `swiftformal.json` in the workspace folder wins over these settings (same keys, without the prefix).

## Commands

- **SwiftFormal: Check Now**: check the configured targets, or those of the open files.
- **SwiftFormal: Stop the Running Check**
- **SwiftFormal: Restart the Language Server**
