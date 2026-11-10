#if canImport(SFLanguageServer)
    import Darwin
    import Foundation
    import SFLanguageServer

    let lspUsage = """
        swiftformal lsp — a language server that proves on save, beside sourcekit-lsp (it never replaces it).

        USAGE
          swiftformal lsp [--stdio]  speaks LSP (JSON-RPC, Content-Length framing) on standard input and output

        It checks the target that holds a saved Swift file (`swiftformal check --scan <package>:<target> --no-walks
        --json`, in a child process it can stop), and shows each function's verdict as a code lens, a diagnostic and a
        hover. An edit turns the verdicts it may change into `⚠ stale` at once; they are shown as proved again only after a
        check of the new code. Configure it in `swiftformal.json` at the workspace root, or with the client's settings
        (initializationOptions, workspace/didChangeConfiguration):

          { "checkOn": "save" | "never", "scan": ["<package-dir>:<target>", …], "tests": "<package-dir>:<test-target>",
            "walks": true, "budget": 300000 }

        Editors: docs/guides/editor.md (VS Code extension in Editors/vscode, Neovim).

        EXIT CODES  0 after shutdown and exit · 1 exit without shutdown, or the input ended · 2 usage error
        """

    /// `swiftformal lsp`: wires the server to standard input and output; each check is a child `swiftformal check`.
    func runLanguageServer(_ arguments: [String]) -> Never {
        if arguments.contains("-h") || arguments.contains("--help") {
            print(lspUsage)
            exit(0)
        }
        // Clients that start servers with `--stdio` (vscode-languageclient's stdio transport) get what they asked for.
        if let unknown = arguments.first(where: { $0 != "--stdio" }) { fail("unknown option \(unknown)\n\n\(lspUsage)") }
        // A client that goes away must not kill the server before it has stopped its checks.
        signal(SIGPIPE, SIG_IGN)
        let transport = StdioTransport(input: .standardInput, output: .standardOutput)
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
        let manifests = ManifestCache()
        let runner = ProcessCheckRunner(
            executable: executable, manifests: manifests,
            context: { ProcessCheckRunner.context(executable: executable) })
        let server = LanguageServer(runner: runner, manifests: manifests, send: transport.send, onExit: { exit($0) })
        Thread.detachNewThread {
            let why = transport.run(server.receive)
            FileHandle.standardError.write(Data("swiftformal lsp: \(why); stopping\n".utf8))
            server.receive(.notification(method: "exit", params: .null))
        }
        dispatchMain()
    }
#endif
