import Foundation
import SFLanguageServer
import Testing

@Suite struct JSONRPCTests {
    @Test func framesSplitAnywhereAreReadWhole() throws {
        let one = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
        let two = Data(#"{"jsonrpc":"2.0","method":"initialized"}"#.utf8)
        let stream = MessageFramer.frame(one) + MessageFramer.frame(two)
        var framer = MessageFramer()
        var bodies: [Data] = []
        for byte in stream { bodies += try framer.append(Data([byte])) }
        #expect(bodies == [one, two])
        var whole = MessageFramer()
        #expect(try whole.append(stream) == [one, two])
    }

    @Test func otherHeadersAndCaseAreAccepted() throws {
        var framer = MessageFramer()
        let body = Data("{}".utf8)
        let header = "content-length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n"
        #expect(try framer.append(Data(header.utf8) + body) == [body])
    }

    @Test func aHeaderWithoutLengthIsAnError() {
        var framer = MessageFramer()
        #expect(throws: MessageFramer.FramingError.self) { try framer.append(Data("Content-Type: x\r\n\r\n{}".utf8)) }
    }

    @Test func messagesAreReadByShape() throws {
        #expect(
            try RPCMessage(body: Data(#"{"jsonrpc":"2.0","id":"a","method":"shutdown"}"#.utf8))
                == .request(id: .string("a"), method: "shutdown", params: .null))
        #expect(
            try RPCMessage(body: Data(#"{"jsonrpc":"2.0","method":"exit"}"#.utf8)) == .notification(method: "exit", params: .null))
        #expect(try RPCMessage(body: Data(#"{"jsonrpc":"2.0","id":3,"result":null}"#.utf8)) == .response(id: .number(3), result: .null))
        #expect(
            try RPCMessage(body: Data(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"no"}}"#.utf8))
                == .errorResponse(id: .number(4), code: -32_601, message: "no"))
        #expect(throws: (any Error).self) { try RPCMessage(body: Data("[1]".utf8)) }
        #expect(throws: (any Error).self) { try RPCMessage(body: Data(#"{"jsonrpc":"2.0"}"#.utf8)) }
    }

    @Test func encodingRoundTrips() throws {
        let message = RPCMessage.request(id: .number(7), method: "textDocument/hover", params: ["position": ["line": 3]])
        #expect(try RPCMessage(body: message.encoded()) == message)
        let error = RPCMessage.errorResponse(id: nil, code: -32_700, message: "parse error")
        #expect(try JSONDecoder().decode(JSONValue.self, from: error.encoded())["id"] == .null)
    }

    /// An editor keeps the pipe open: a message must be handled when it arrives, not when the buffer fills.
    @Test(.timeLimit(.minutes(1))) func aMessageIsHandledWhileTheInputStaysOpen() {
        let pipe = Pipe()
        let transport = StdioTransport(input: pipe.fileHandleForReading, output: .nullDevice)
        let handled = DispatchSemaphore(value: 0)
        let thread = Thread { _ = transport.run { _ in handled.signal() } }
        thread.start()
        let message = RPCMessage.notification(method: "initialized", params: [:])
        pipe.fileHandleForWriting.write(MessageFramer.frame(message.encoded()))
        #expect(handled.wait(timeout: .now() + 10) == .success)
        try? pipe.fileHandleForWriting.close()
    }
}

@Suite struct ServerConfigTests {
    @Test func readsTargetsRelativeToTheRoot() throws {
        let config = try ServerConfig.parse(
            ["checkOn": "never", "scan": ["Core:AppCore", "/abs/pkg:Other"], "tests": ".:FormalTests", "walks": false, "budget": 5],
            base: "/work")
        #expect(config.checkOn == .never)
        #expect(
            config.scans == [TargetRef(package: "/work/Core", target: "AppCore"), TargetRef(package: "/abs/pkg", target: "Other")])
        #expect(config.tests == TargetRef(package: "/work", target: "FormalTests"))
        #expect(!config.walks)
        #expect(config.budget == 5)
    }

    @Test func aFileOverridesOnlyWhatItSays() throws {
        let settings = try ServerConfig.parse(["checkOn": "never", "scan": "A:B"], base: "/w")
        let merged = try ServerConfig.parse(["walks": false], base: "/w", defaults: settings)
        #expect(merged.checkOn == .never && merged.scans.count == 1 && !merged.walks)
    }

    @Test func badValuesAreErrors() {
        #expect(throws: ConfigError.self) { try ServerConfig.parse(["checkOn": "change"], base: "/w") }
        #expect(throws: ConfigError.self) { try ServerConfig.parse(["scan": ["NoColon"]], base: "/w") }
        #expect(throws: ConfigError.self) { try ServerConfig.parse(["budget": 0], base: "/w") }
    }

    @Test func packageRootIsTheNearestManifest() {
        let manifests: Set<String> = ["/a/Package.swift", "/a/b/c/Package.swift"]
        #expect(Paths.packageRoot(of: "/a/b/c/Sources/X/x.swift", exists: manifests.contains) == "/a/b/c")
        #expect(Paths.packageRoot(of: "/a/b/x.swift", exists: manifests.contains) == "/a")
        #expect(Paths.packageRoot(of: "/z/x.swift", exists: manifests.contains) == nil)
        #expect(Paths.isIgnored("/a/.build/x.swift") && !Paths.isIgnored("/a/build/x.swift"))
        #expect(!Paths.isIgnored("/w/.build/p/Sources/x.swift", roots: ["/w", "/w/.build/p"]))
        #expect(Paths.isIgnored("/w/.build/p/.build/x.swift", roots: ["/w/.build/p"]))
    }

    @Test func readsLocalDependenciesAndTargetsFromDumpPackage() throws {
        let dump = """
            {"name": "App", "dependencies": [
               {"fileSystem": [{"identity": "core", "path": "/w/Core"}]},
               {"sourceControl": [{"identity": "remote"}]}],
             "targets": [{"name": "App", "type": "regular", "path": null},
                         {"name": "AppTests", "type": "test", "path": "Tests/Unit"}]}
            """
        let manifest = try PackageManifest.parse(Data(dump.utf8), root: "/w/App")
        #expect(manifest.localDependencies == ["/w/Core"])
        #expect(manifest.hasRemoteDependencies)
        #expect(manifest.targets.map(\.path) == ["/w/App/Sources/App", "/w/App/Tests/Unit"])
        #expect(manifest.target(containing: "/w/App/Sources/App/A.swift")?.name == "App")
        #expect(manifest.target(containing: "/w/App/Tests/Unit/T.swift") == nil)
        #expect(manifest.target(containing: "/w/App/Tests/Unit/T.swift", tests: true)?.name == "AppTests")
        let core = try PackageManifest.parse(Data(#"{"targets": []}"#.utf8), root: "/w/Core")
        #expect(PackageGraph([manifest, core]).closure(of: "/w/App") == ["/w/App", "/w/Core"])
        #expect(PackageGraph([manifest]).closure(of: "/w/App") == nil)
    }
}
