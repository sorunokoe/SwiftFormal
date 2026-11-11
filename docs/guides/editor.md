# Editor guide: verdicts in your editor

`swiftformal lsp` is a small language server. On each save it runs `swiftformal check` (Scan, "the logic", and the
walks you configure) and shows each function's answer above it. It runs beside sourcekit-lsp (completion,
navigation, compiler errors) and never replaces it. macOS only: elsewhere `swiftformal` has no `lsp` command.

## VS Code

The extension is in [`Editors/vscode`](../../Editors/vscode/README.md). Build it:

```sh
cd Editors/vscode
npm install
npx tsc -p .
```

1. Install it: **Developer: Install Extension from Location…** and pick `Editors/vscode`, or copy the folder to
   `~/.vscode/extensions/swiftformal`.
2. Build the server: `swift build -c release --product swiftformal`.
3. Set `swiftformal.path` to `.build/release/swiftformal` (or put it on `PATH`).

- Settings: `swiftformal.path`, `swiftformal.checkOn`, `swiftformal.scan`, `swiftformal.tests`, `swiftformal.walks`,
  `swiftformal.budget`.
- Commands: **SwiftFormal: Check Now**, **SwiftFormal: Stop the Running Check**, **SwiftFormal: Restart the Language
  Server**.
- Code lenses must be on (`editor.codeLens`, the default).

## Neovim

Neovim 0.11 or newer, beside sourcekit-lsp:

```lua
vim.lsp.config('swiftformal', {
  cmd = { 'swiftformal', 'lsp' },
  filetypes = { 'swift' },
  root_markers = { 'swiftformal.json', 'Package.swift', '.git' },
  init_options = { checkOn = 'save' },
})
vim.lsp.enable('swiftformal')
-- Lenses are not shown by default.
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client.name == 'swiftformal' then
      vim.lsp.codelens.refresh({ bufnr = args.buf })
      vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'TextChanged', 'InsertLeave' }, {
        buffer = args.buf,
        callback = function() vim.lsp.codelens.refresh({ bufnr = args.buf }) end,
      })
    end
  end,
})
```

## What the lenses mean

| Lens | Meaning |
|---|---|
| `✓ proved (debug, release asserts)` | Scan proved the function's promise (`@Verify` with `#requires`/`#ensures`) for every input, in the configurations named. |
| `✓ cannot crash (debug, release asserts)` | Scan proved the function cannot trap, for every input. No promise was checked. |
| `✓ walked 12/12 (complete domain)` | A walk (`Prove(it:over:)`) ran every input of a complete domain. With `✓ cannot crash ·` in front, Scan also proved it cannot trap. |
| `~ walked 40/2^63+ (sample), not a proof` | A walk ran the inputs it lists, a sample of the domain. Evidence, not a proof. |
| `✗ counterexample: …` | An input that breaks the promise or traps. Hover for the input and the replay call; a code action writes the replay as a test. |
| `? unchecked: <reason>` | Nothing was proved, for the reason given (unsupported code, budget, a linked walk that did not report). Never a proof. |
| `! known issue: a walk fails` | A walk marked as a known issue fails. |
| `⚠ stale: changed since the last check` | The code this verdict was about changed. It is not shown as proved again until a check of the new code proves it. |

Qualifiers name the configurations a verdict holds in (`debug`, `release asserts`, `-O`). `unpinned compiler` means
the compiler is not the pinned one ([What you have to trust](../TRUST.md)). When configurations disagree, the lens
says which: `✗ counterexample (release asserts)` above a function that traps only once release removes an `assert`.

## Configure

The server reads `swiftformal.json` in the workspace folder, then the client's settings (`initializationOptions`,
`workspace/didChangeConfiguration`) for keys the file does not set:

```json
{
  "checkOn": "save",
  "scan": ["Foundation/Core:AppCore", "Features/Feature/AppFeature:AppFeature"],
  "tests": ".:FormalVerificationTests",
  "walks": true,
  "budget": 300000
}
```

| Key | Default | Meaning |
|---|---|---|
| `checkOn` | `save` | `save`, or `never` (check only on the `swiftformal.server.check` command). |
| `scan` | none | `--scan` targets, `<package-dir>:<target>`, relative to the workspace folder. None: the target that holds the saved file. A save checks only the configured targets that can read the saved file's package (all of them when walks run). |
| `tests` | none | The `--tests` target with the walks. None: no walks. |
| `walks` | `true` | Run the walks of `tests`. |
| `budget` | SwiftFormal's | The prover's conflict budget per function (`--budget`). |

An invalid configuration is reported once. Nothing is checked until it is fixed.

## What it does

- **Checks on save.** A save runs `swiftformal check --json` in a child process, on the target that holds the saved
  file (`--scan <package>:<target> --no-walks`) or on the targets you configured.
  - One check runs at a time. A newer save replaces a queued check and stops a running one whose answers it would
    change. A stopped check is killed with every process it started (compilers too) before the server reports it
    cancelled.
  - Checks reuse the [proof cache](scan.md#the-proof-cache): after a small edit, only what changed is proved again.
    Building and compiling to SIL take most of the time: about 35–50 s for a 116-file target of a real app.
- **Edits make verdicts stale at once.** Typing (`didChange`) checks nothing. Verdicts of the edited file's package,
  and of every package that depends on it, turn `⚠ stale`. So do files changed on disk (`git checkout`, a generator)
  when the editor reports them, and everything when a manifest, `Package.resolved` or the configuration changes.
  Unsaved text is never checked and never shown as proved.
- **Results only for the code that was checked.** Each check records a generation and the hashes of the files it read.
  A verdict shows as proved only while the file's current text (open buffer, else file on disk) has that hash, and no
  change since the check started may have reached it. A check that raced an edit publishes its verdicts as stale.
- **Diagnostics** (with the document version) for counterexamples and walk failures, and a warning at a hand-written
  `f_requires` / `f_ensures` or `// sf:verify` comment (neither is read).
- **Hover:** the counterexample, the promise, the reason a function is unchecked.
- **Code actions:** replay a counterexample as a Swift Testing test; add a promise (`@Verify` with
  `#requires`/`#ensures`); a `Prove(it:over:)` skeleton.
- **Progress** (`$/progress`) while a check runs.
- **Test Explorer.** A `swiftformal/results` notification carries every verdict (`id` unique across packages,
  `package`, `module`, `function`, `uri`, `line`, `state`, `title`). VS Code shows them as test items: passed, failed,
  skipped. Stale and unchecked show as skipped, never passed. Publish-only: no run button. Save, or run
  **SwiftFormal: Check Now**.

## Limits

- A verdict says what the last check proved about the code it read. See
  [What you have to trust](../TRUST.md#the-editor-swiftformal-lsp) for what a lens claims and what it does not.
- Staleness is per package, not per function: an edit turns every verdict of its package and of the packages that
  depend on it stale, even those the edit could not change. A save checks them again (mostly from the proof cache).
- A change the editor does not report (no file watcher, or a file outside the workspace) is caught only when that
  file's own verdicts are shown (the hash no longer matches), or when it happens during a check. After changing files
  outside the editor, save or run **Check Now**.
- Walks run only when `tests` is configured. Without a configuration, a save checks one target with logic only.
- `ScanToolchain` and the compiler-probe cache of `TypeNameCheck` are per process. Each check is a new process, so
  the next check sees a change of compiler or dependencies.
