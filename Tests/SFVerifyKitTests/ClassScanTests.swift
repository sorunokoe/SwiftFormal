import Foundation
import SFVerifyKit
import Testing

/// Plan item L5 at the report: a method on a class parameter is `undecided` (decision 6: a caller may hold an access
/// to the object), never `safe`; a counterexample on one is still reported; contracts on one are refused.
@Suite struct ClassScanTests {
    static let source = """
        public final class Meter {
            public var value: Int8 = 0
            public init() {}
            public func add(_ x: Int8) { value = value &+ x }
            public func addChecked(_ x: Int8) { value += x }
        }
        public func addOnParameter(_ m: Meter) { m.add(1) }
        public func addCheckedOnParameter(_ m: Meter, _ x: Int8) { m.addChecked(x) }
        public func made(_ x: Int8) -> Int8 { let m = Meter(); m.add(x); return m.value }
        public func readBoth(_ a: Meter, _ b: Meter) -> Int8 { a.value &+ b.value }
        public func meter(_ m: Meter) -> Int8 { m.value }
        #sourceLocation(file: "@__swiftmacro_3App5meter6VerifyfMp_.swift", line: 1)
        public func meter_ensures(_ m: Meter, _ result: Int8) -> Bool { result == m.value }
        #sourceLocation()
        """

    static func scan() throws -> ScanReport {
        let directory = NSTemporaryDirectory() + "sfv-l5-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/meter.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Meters"), options)
    }

    private static func function(_ report: ScanReport, _ name: String) throws -> FunctionReport {
        try #require(report.functions.first { $0.name.hasPrefix(name + "(") }, "\(report.functions.map(\.name))")
    }

    @Test func classParametersFollowDecisionSix() throws {
        let report = try Self.scan()
        for name in ["addOnParameter", "Meter.add"] {
            let f = try Self.function(report, name)
            #expect(f.status == .undecided && f.category == "exclusivity", "\(name): \(f.status) \(f.category ?? "")")
        }
        let checked = try Self.function(report, "addCheckedOnParameter")
        #expect(checked.status == .mayTrap, "\(checked.status) \(checked.detail ?? "")")
        #expect(checked.counterexample?.replay == nil)
        #expect(try Self.function(report, "made").status == .safe)
        let both = try Self.function(report, "readBoth")
        #expect(both.status == .unsupported && both.category == "classes and objects", "\(both.status) \(both.category ?? "")")
        let contract = try Self.function(report, "meter")
        #expect(contract.status == .unsupported, "\(contract.status) \(contract.detail ?? "")")
    }
}
