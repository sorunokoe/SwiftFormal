import Foundation
import Testing

@testable import SFVerifyKit

/// The compiler's answers feed the pin: a cached one must be used only for the very file and environment it came from.
@Suite struct ToolchainInfoCacheTests {
    @Test func answersAreKeptOnlyForTheSameCompilerFileAndEnvironment() throws {
        let directory = NSTemporaryDirectory() + "sfv-toolchain-cache-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory + "/bin", withIntermediateDirectories: true)
        let swiftc = directory + "/bin/swiftc"
        try "#!/bin/sh\necho one\n".write(toFile: swiftc, atomically: true, encoding: .utf8)
        let roots = [directory + "/cache"]
        let environment = ["DEVELOPER_DIR": "/A"]
        let key = try #require(ToolchainInfoCache.key(swiftc: swiftc, environment: environment))
        let answers = ToolchainInfoCache.Answers(targetInfo: Data("{}".utf8), sdkVersion: "27.0", sdkPath: "/SDK")
        #expect(ToolchainInfoCache.read(key: key, roots: roots) == nil)
        ToolchainInfoCache.write(answers, key: key, roots: roots)
        #expect(ToolchainInfoCache.read(key: key, roots: roots) == answers)

        #expect(ToolchainInfoCache.key(swiftc: swiftc, environment: ["DEVELOPER_DIR": "/B"]) != key)
        #expect(ToolchainInfoCache.key(swiftc: swiftc, environment: environment.merging(["SDKROOT": "/S"]) { $1 }) != key)
        #expect(ToolchainInfoCache.key(swiftc: swiftc, environment: environment.merging(["TOOLCHAINS": "x"]) { $1 }) != key)
        // A new compiler at the same path (another file, or the same file rewritten) is another key.
        try "#!/bin/sh\necho two, longer\n".write(toFile: swiftc, atomically: true, encoding: .utf8)
        let rewritten = try #require(ToolchainInfoCache.key(swiftc: swiftc, environment: environment))
        #expect(rewritten != key)
        #expect(ToolchainInfoCache.read(key: rewritten, roots: roots) == nil)
        // A symlink to the compiler is the compiler.
        try FileManager.default.createSymbolicLink(atPath: directory + "/bin/swift-link", withDestinationPath: swiftc)
        #expect(ToolchainInfoCache.key(swiftc: directory + "/bin/swift-link", environment: environment) == rewritten)
        #expect(ToolchainInfoCache.key(swiftc: directory + "/missing", environment: environment) == nil)
    }
}
