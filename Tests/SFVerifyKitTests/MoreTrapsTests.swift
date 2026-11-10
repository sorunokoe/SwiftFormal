import Foundation
import SFVerifyKit
import Testing

/// Plan item H3: one scan reports every place a function can trap, each with an input that reaches it.
@Suite struct MoreTrapsTests {
    @Test func everyTrapSiteIsReportedWithItsOwnInput() throws {
        let directory = NSTemporaryDirectory() + "sfv-h3-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/two.swift"
        try """
        public func ratio(_ a: Int8, _ b: Int8) -> Int8 {
            let bumped = a + 1
            return bumped / b
        }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Two"), options)
        let ratio = try #require(report.functions.first { $0.name.hasPrefix("ratio(") })
        #expect(ratio.status == .mayTrap)
        let failures = ([ratio.counterexample] + (ratio.moreTraps ?? []).map { $0 }).compactMap { $0?.failure }
        #expect(failures.contains { $0.contains("overflow") }, "\(failures)")
        #expect(failures.contains { $0.contains("Division by zero") || $0.contains("division") }, "\(failures)")
        var off = options
        off.moreTraps = 0
        let single = try SFVerify.run(CompileOptions(files: [file], moduleName: "Two"), off)
        #expect(single.functions.first { $0.name.hasPrefix("ratio(") }?.moreTraps == nil)
    }
}
