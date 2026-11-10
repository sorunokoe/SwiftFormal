import Foundation
import SFVerifyKit
import Testing

/// Plan item L9: a `hashValue` getter runs the type's own `hash(into:)`, so it is proved or refuted like the rest.
@Suite struct HashValueTests {
    @Test func hashValueRunsTheTypesOwnHash() throws {
        let directory = NSTemporaryDirectory() + "sfv-l9-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/hashes.swift"
        try """
        public struct Plain: Hashable { public var k: Int8 }
        public struct Bumped: Hashable {
            public var k: Int8
            public func hash(into h: inout Hasher) { h.combine(k + 1) }
        }
        public func plainHash(_ k: Int8) -> Int { Plain(k: k).hashValue }
        public func bumpedHash(_ k: Int8) -> Int { Bumped(k: k).hashValue }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Hashes"), options)
        #expect(report.functions.first { $0.name.hasPrefix("plainHash(") }?.status == .safe)
        let bumped = try #require(report.functions.first { $0.name.hasPrefix("bumpedHash(") })
        #expect(bumped.status == .mayTrap, "\(bumped.detail ?? "")")
        #expect(bumped.counterexample?.inputs == ["k = 127"])
    }
}
