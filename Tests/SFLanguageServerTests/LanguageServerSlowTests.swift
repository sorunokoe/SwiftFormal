import Foundation
import SFLanguageServer
import Testing

/// The built `swiftformal lsp`, driven over pipes like an editor would, against a small package: a save checks it,
/// the verdicts arrive as lenses and diagnostics, an edit turns them stale, and shutdown stops cleanly.
@Suite struct LanguageServerSlowTests {
    /// `swiftformal` next to this test bundle (SwiftPM builds every product before it runs tests): the bundle's
    /// folder, else this package's newest `.build/<configuration>/swiftformal`.
    static var executable: String? {
        let fm = FileManager.default
        let bundles = (Bundle.allBundles.map(\.bundlePath) + CommandLine.arguments).filter { $0.contains(".xctest") }
        var candidates = bundles.map { path -> String in
            let bundle = path.components(separatedBy: ".xctest")[0] + ".xctest"
            return (bundle as NSString).deletingLastPathComponent + "/swiftformal"
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let built = ["debug", "release"].map { root + "/.build/\($0)/swiftformal" }.filter { fm.isExecutableFile(atPath: $0) }
        candidates += built.sorted { modified($0) > modified($1) }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    private static func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    /// A language client over the server's standard input and output.
    final class Client: @unchecked Sendable {
        let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let condition = NSCondition()
        private var received: [RPCMessage] = []
        private var nextID = 0

        init(executable: String) throws {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["lsp"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let handle = output.fileHandleForReading
            Thread.detachNewThread { [self] in
                var framer = MessageFramer()
                while let chunk = handle.readAvailable() {
                    let bodies = (try? framer.append(chunk)) ?? []
                    condition.lock()
                    received += bodies.compactMap { try? RPCMessage(body: $0) }
                    condition.broadcast()
                    condition.unlock()
                }
            }
        }

        func send(_ message: RPCMessage) {
            input.fileHandleForWriting.write(MessageFramer.frame(message.encoded()))
        }

        func notify(_ method: String, _ params: JSONValue) { send(.notification(method: method, params: params)) }

        func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = 30) -> JSONValue? {
            nextID += 1
            let id = nextID
            send(.request(id: .number(id), method: method, params: params))
            return wait(timeout: timeout) {
                if case .response(.number(id), let result) = $0 { return result }
                return nil
            }
        }

        /// The first message (from the start) that `match` accepts, waiting for it up to `timeout`.
        func wait<T>(timeout: TimeInterval, after count: Int = 0, _ match: (RPCMessage) -> T?) -> T? {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let found = received.dropFirst(count).lazy.compactMap(match).first { return found }
                guard condition.wait(until: deadline) else { return nil }
            }
        }

        var count: Int {
            condition.lock()
            defer { condition.unlock() }
            return received.count
        }

        /// The parameters of the first `method` notification since message `count` that `accept` takes.
        func notification(
            _ method: String, after count: Int, timeout: TimeInterval, where accept: @escaping (JSONValue) -> Bool = { _ in true }
        ) -> JSONValue? {
            wait(timeout: timeout, after: count) { message -> JSONValue? in
                if case .notification(method, let params) = message, accept(params) { return params }
                return nil
            }
        }

        func lensTitles(_ uri: JSONValue) -> [String] {
            (request("textDocument/codeLens", ["textDocument": ["uri": uri]])?.array ?? []).compactMap { $0["command"]["title"].string }
        }

        /// Answers the server's own requests (progress tokens, registrations, refreshes) with null.
        func answerServerRequests(from start: Int) -> Int {
            condition.lock()
            let requests = received.dropFirst(start).compactMap { message -> RequestID? in
                if case .request(let id, _, _) = message { return id }
                return nil
            }
            let end = received.count
            condition.unlock()
            for id in requests { send(.response(id: id, result: .null)) }
            return end
        }
    }

    @Test(.timeLimit(.minutes(10))) func aSaveIsCheckedAndAnEditTurnsItStale() throws {
        let executable = try #require(Self.executable, "build the swiftformal product first")
        let package = try FixturePackage()
        defer { package.remove() }
        let client = try Client(executable: executable)
        defer { if client.process.isRunning { client.process.terminate() } }
        let uri = JSONValue.string(Paths.uri(path: package.source))
        let capabilities: JSONValue = ["window": ["workDoneProgress": true], "workspace": ["codeLens": ["refreshSupport": true]]]
        let initialized = client.request(
            "initialize", ["rootUri": .string(Paths.uri(path: package.root)), "capabilities": capabilities, "initializationOptions": .null])
        #expect(initialized?["serverInfo"]["name"] == "swiftformal")
        client.notify("initialized", [:])
        client.notify(
            "textDocument/didOpen",
            ["textDocument": ["uri": uri, "languageId": "swift", "version": 1, "text": .string(FixturePackage.libText)]])
        let start = client.count
        client.notify("textDocument/didSave", ["textDocument": ["uri": uri]])

        // A cold check builds the package: give it time. Progress requests are answered after it.
        let results = client.notification("swiftformal/results", after: start, timeout: 600)
        let answered = client.answerServerRequests(from: start)
        let items = try #require(results?["items"].array, "no results: \(client.count) messages")
        #expect(items.count >= 3)
        let lenses = client.lensTitles(uri)
        #expect(lenses.contains { $0.hasPrefix("✓ cannot crash") }, "\(lenses)")
        #expect(lenses.contains { $0.hasPrefix("✗ counterexample") }, "\(lenses)")
        #expect(lenses.contains { $0.hasPrefix("✓ proved") } == false)
        let diagnostics = client.notification("textDocument/publishDiagnostics", after: start, timeout: 5) {
            $0["diagnostics"].array?.isEmpty == false
        }
        #expect(diagnostics?["version"] == 1)
        #expect(client.notification("$/progress", after: start, timeout: 5) { $0["value"]["kind"] == "end" } != nil)

        client.notify(
            "textDocument/didChange",
            ["textDocument": ["uri": uri, "version": 2], "contentChanges": [["text": .string(FixturePackage.libText + "\n")]]])
        let stale = client.lensTitles(uri)
        #expect(stale.count == lenses.count)
        #expect(stale.allSatisfy { $0.hasPrefix("⚠ stale") }, "\(stale)")

        _ = client.answerServerRequests(from: answered)
        #expect(client.request("shutdown", .null) == .null)
        client.notify("exit", .null)
        client.process.waitUntilExit()
        #expect(client.process.terminationStatus == 0)
    }
}
