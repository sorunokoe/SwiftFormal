import Foundation
import SFLanguageServer
import Testing

/// The status the server exited with, set from its exit callback.
final class ExitStatus: @unchecked Sendable {
    var value: Int32?
}

/// The server with a fake runner: what an editor sees after a save, an edit, and a check that raced an edit.
@Suite struct LanguageServerTests {
    final class Harness {
        let package: FixturePackage
        let runner: FakeRunner
        let outbox = Outbox()
        let server: LanguageServer
        var nextID = 100
        let exitStatus = ExitStatus()

        init(checkOn: String = "save", runner: FakeRunner = FakeRunner(), capabilities: JSONValue = [:]) throws {
            package = try FixturePackage()
            self.runner = runner
            let outbox = outbox
            let exitStatus = exitStatus
            server = LanguageServer(
                runner: runner, manifests: ManifestCache(swift: "/usr/bin/false"), send: { outbox.append($0) },
                onExit: { exitStatus.value = $0 })
            let root = package.root
            let initOptions: JSONValue = ["scan": .array([.string(root + ":Lib")]), "checkOn": .string(checkOn)]
            #expect(
                request(
                    "initialize",
                    ["rootUri": .string(Paths.uri(path: root)), "initializationOptions": initOptions, "capabilities": capabilities])?[
                        "capabilities"]["codeLensProvider"] != nil)
            notify("initialized", [:])
        }

        deinit { package.remove() }

        var uri: JSONValue { .string(Paths.uri(path: package.source)) }

        func notify(_ method: String, _ params: JSONValue) {
            server.receive(.notification(method: method, params: params))
            server.sync {}
        }

        @discardableResult
        func request(_ method: String, _ params: JSONValue) -> JSONValue? {
            nextID += 1
            server.receive(.request(id: .number(nextID), method: method, params: params))
            server.sync {}
            return outbox.response(nextID)
        }

        func open(_ text: String = FixturePackage.libText) {
            notify("textDocument/didOpen", ["textDocument": ["uri": uri, "languageId": "swift", "version": 1, "text": .string(text)]])
        }

        func edit(_ text: String, version: Int) {
            notify(
                "textDocument/didChange",
                ["textDocument": ["uri": uri, "version": .number(Double(version))], "contentChanges": [["text": .string(text)]]])
        }

        func save() { notify("textDocument/didSave", ["textDocument": ["uri": uri]]) }

        /// Finishes the latest run with the fixture report.
        func finish() throws {
            let run = try #require(runner.runs.last)
            run.completion(.finished(try finishedRun(package, generation: run.generation, job: run.job)))
            server.sync {}
        }

        func lensTitles() -> [String] {
            (request("textDocument/codeLens", ["textDocument": ["uri": uri]])?.array ?? []).compactMap { $0["command"]["title"].string }
        }

        func lastDiagnostics() -> JSONValue? { outbox.notifications("textDocument/publishDiagnostics").last }
    }

    @Test func requestsBeforeInitializeAreRefused() {
        let outbox = Outbox()
        let checked = LanguageServer(
            runner: FakeRunner(), manifests: ManifestCache(swift: "/usr/bin/false"), send: { outbox.append($0) }, onExit: { _ in })
        checked.receive(.request(id: .number(1), method: "textDocument/codeLens", params: [:]))
        checked.sync {}
        #expect(outbox.error(1) == RPCMessage.ErrorCode.serverNotInitialized)
    }

    @Test func aSaveChecksAndShowsVerdicts() throws {
        let harness = try Harness()
        harness.open()
        #expect(harness.lensTitles().isEmpty)
        harness.save()
        #expect(harness.runner.runs.count == 1)
        #expect(harness.runner.runs[0].job.scans == [harness.package.target])
        try harness.finish()
        #expect(
            harness.lensTitles() == [
                "✗ counterexample (release asserts): traps: arithmetic overflow when a = 9223372036854775807, b = 1",
                "✓ cannot crash (debug, release asserts)", "? unchecked: undecided (budget)",
            ])
        let diagnostics = try #require(harness.lastDiagnostics())
        #expect(diagnostics["version"] == 1)
        #expect(diagnostics["diagnostics"].array?.count == 1)
        #expect(diagnostics["diagnostics"].array?.first?["range"]["start"]["line"] == 1)
        let results = try #require(harness.outbox.notifications("swiftformal/results").last)
        #expect(results["items"].array?.compactMap { $0["state"].string } == ["failed", "passed", "skipped"])
    }

    @Test func anEditTurnsVerdictsStaleAtOnce() throws {
        let harness = try Harness()
        harness.open()
        harness.save()
        try harness.finish()
        harness.edit(FixturePackage.libText + "// more\n", version: 2)
        #expect(harness.lensTitles().allSatisfy { $0.hasPrefix("⚠ stale") })
        #expect(harness.lensTitles().count == 3)
        #expect(harness.lastDiagnostics()?["diagnostics"].array?.isEmpty == true)
        #expect(harness.lastDiagnostics()?["version"] == 2)
        #expect(harness.outbox.notifications("swiftformal/results").last?["items"].array?.allSatisfy { $0["state"] == "stale" } == true)
        // Undoing the edit does not bring the old verdicts back: only a check of this text does.
        harness.edit(FixturePackage.libText, version: 3)
        #expect(harness.lensTitles().allSatisfy { $0.hasPrefix("⚠ stale") })
        #expect(harness.runner.runs.count == 1)
    }

    @Test func aCheckThatRacedAnEditIsShownStale() throws {
        let harness = try Harness(runner: FakeRunner(cancelsAtOnce: false))
        harness.open()
        harness.save()
        harness.edit(FixturePackage.libText + "\n", version: 2)
        try harness.finish()
        #expect(harness.lensTitles().count == 3)
        #expect(harness.lensTitles().allSatisfy { $0.hasPrefix("⚠ stale") })
        #expect(harness.outbox.notifications("textDocument/publishDiagnostics").allSatisfy { $0["diagnostics"].array?.isEmpty == true })
    }

    @Test func aSaveDuringACheckSupersedesIt() throws {
        let harness = try Harness(runner: FakeRunner(cancelsAtOnce: false))
        harness.open()
        harness.save()
        harness.save()
        #expect(harness.runner.runs[0].cancelled)
        harness.runner.runs[0].completion(.cancelled)
        harness.server.sync {}
        #expect(harness.runner.runs.count == 2)
        try harness.finish()
        #expect(harness.lensTitles().contains("✓ cannot crash (debug, release asserts)"))
    }

    @Test func aBufferThatDiffersFromTheCheckedFileIsNotProved() throws {
        let harness = try Harness()
        harness.open(FixturePackage.libText + "// unsaved\n")
        harness.save()
        try harness.finish()
        #expect(harness.lensTitles().allSatisfy { $0.hasPrefix("⚠ stale") })
    }

    @Test func checkOnNeverDoesNotCheckOnSave() throws {
        let harness = try Harness(checkOn: "never")
        harness.open()
        harness.save()
        #expect(harness.runner.runs.isEmpty)
    }

    @Test func hoverAndCodeActionsUseCurrentVerdictsOnly() throws {
        let harness = try Harness(capabilities: [
            "workspace": ["workspaceEdit": ["documentChanges": true, "resourceOperations": ["create"]]]
        ])
        harness.open()
        harness.save()
        try harness.finish()
        let position: JSONValue = ["textDocument": ["uri": harness.uri], "position": ["line": 1, "character": 4]]
        let hover = try #require(harness.request("textDocument/hover", position)?["contents"]["value"].string)
        #expect(hover.contains("**Counterexample**"))
        let range: JSONValue = [
            "textDocument": ["uri": harness.uri], "range": ["start": ["line": 5, "character": 0], "end": ["line": 5, "character": 0]],
        ]
        let titles = harness.request("textDocument/codeAction", range)?.array?.compactMap { $0["title"].string } ?? []
        #expect(titles.contains("Add a contract (@Verify, #requires, #ensures)"))
        harness.edit(FixturePackage.libText + " ", version: 2)
        #expect(harness.request("textDocument/codeAction", range)?.array?.isEmpty == true)
        #expect(harness.request("textDocument/hover", position)?["contents"]["value"].string?.contains("Counterexample") == false)
    }

    @Test func aWatchedChangeOnDiskTurnsVerdictsStaleButASaveEchoDoesNot() throws {
        let harness = try Harness()
        harness.save()
        try harness.finish()
        let change: JSONValue = ["changes": [["uri": harness.uri, "type": 2]]]
        harness.notify("workspace/didChangeWatchedFiles", change)
        #expect(harness.lensTitles().contains("✓ cannot crash (debug, release asserts)"))
        try (FixturePackage.libText + "// changed\n").write(toFile: harness.package.source, atomically: true, encoding: .utf8)
        harness.notify("workspace/didChangeWatchedFiles", change)
        #expect(harness.server.sync { harness.server.resultStore.all.allSatisfy(\.stale) })
        #expect(harness.lensTitles().allSatisfy { $0.hasPrefix("⚠ stale") })
    }

    @Test func savingTheSameBytesAgainKeepsVerdictsButANewerFileDoesNot() throws {
        let harness = try Harness()
        harness.save()
        try harness.finish()
        harness.save()
        #expect(harness.runner.runs.count == 2)
        #expect(harness.lensTitles().contains("✓ cannot crash (debug, release asserts)"))
        // Changed on disk with no event; reading it for the lenses must not make the next save look like an echo.
        try (FixturePackage.libText + "// changed\n").write(toFile: harness.package.source, atomically: true, encoding: .utf8)
        #expect(harness.lensTitles().allSatisfy { $0.hasPrefix("⚠ stale") })
        harness.save()
        #expect(harness.server.sync { harness.server.resultStore.all.allSatisfy(\.stale) })
    }

    @Test func shutdownWaitsForTheRunToStop() throws {
        let harness = try Harness(runner: FakeRunner(cancelsAtOnce: false))
        harness.open()
        harness.save()
        #expect(harness.request("shutdown", .null) == nil)
        #expect(harness.runner.runs[0].cancelled)
        harness.runner.runs[0].completion(.cancelled)
        harness.server.sync {}
        #expect(harness.outbox.response(harness.nextID) == .null)
        harness.notify("exit", .null)
        #expect(harness.exitStatus.value == 0)
    }
}
