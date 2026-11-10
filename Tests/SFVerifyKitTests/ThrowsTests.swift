import Foundation
import SFVerifyKit
import Testing

/// Plan item L6: throwing functions, `try`, `try?` and `do`/`catch` are read; throwing is not a trap, and `ensures`
/// is about a normal return.
@Suite struct ThrowsTests {
    @Test func throwingIsNotATrapAndEnsuresHoldsOnNormalReturn() throws {
        let directory = NSTemporaryDirectory() + "sfv-l6-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/throws.swift"
        try """
        public enum Failure: Error { case negative, tooBig }
        public func parse(_ x: Int8) throws -> Int8 {
            if x < 0 { throw Failure.negative }
            if x > 100 { throw Failure.tooBig }
            return x + 1
        }
        #sourceLocation(file: "@__swiftmacro_3App5parse6VerifyfMp_.swift", line: 1)
        public func parse_ensures(_ x: Int8, _ r: Int8) -> Bool { r > 0 }
        #sourceLocation()
        public func wrongParse(_ x: Int8) throws -> Int8 { if x < 0 { throw Failure.negative }; return x }
        #sourceLocation(file: "@__swiftmacro_3App10wrongParse6VerifyfMp_.swift", line: 1)
        public func wrongParse_ensures(_ x: Int8, _ r: Int8) -> Bool { r > 0 }
        #sourceLocation()
        public func doubled(_ x: Int8) throws -> Int8 { try parse(x) * 2 }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Throws"), options)
        func status(_ name: String) -> ScanStatus? { report.functions.first { $0.name.hasPrefix(name + "(") }?.status }
        #expect(status("parse") == .contractHolds, "x + 1 cannot overflow below 101; a throw needs no result")
        #expect(status("wrongParse") == .contractFails, "x = 0 returns 0")
        let doubled = try #require(report.functions.first { $0.name.hasPrefix("doubled(") })
        #expect(doubled.status == .mayTrap)
        #expect(
            doubled.counterexample?.inputs.first.map { $0 >= "x = 64" && $0 <= "x = 99" } == true, "\(doubled.counterexample?.inputs ?? [])"
        )
    }
}
