import Foundation
import SFVerifyKit
import Testing

/// Plan item H2: a trap inside a callee is reported where it happens, in the callee, not only at the call.
@Suite struct TrapSiteTests {
    @Test func aTrapInACalleeIsReportedAtItsOwnLine() throws {
        let directory = NSTemporaryDirectory() + "sfv-h2-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/calls.swift"
        try """
        public func inc(_ x: Int8) -> Int8 {
            x + 1
        }
        public func twiceInc(_ x: Int8) -> Int8 { inc(inc(x)) }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Calls"), options)
        let outer = try #require(report.functions.first { $0.name.hasPrefix("twiceInc(") })
        #expect(outer.status == .mayTrap)
        let example = try #require(outer.counterexample)
        #expect(example.failure.hasPrefix("in inc(_:): traps: arithmetic overflow"), "\(example.failure)")
        #expect(example.at?.line == 2)
    }
}
