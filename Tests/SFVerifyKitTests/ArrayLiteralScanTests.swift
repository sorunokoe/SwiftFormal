import Foundation
import SFVerifyKit
import Testing

/// The app study's `UnitDefaults.defaultUnits()` shape through the whole pipeline: a private function returns a literal of
/// rows with a raw-value enum, a struct holds it, and the contract checks the rows (`SILArrayLiterals.swift`).
@Suite struct ArrayLiteralScanTests {
    static let source = """
        public enum UnitSystem: String { case metric, european, us }
        public struct UnitOption: Equatable {
            public let id: String
            public let type: UnitSystem
            public let isSelected: Bool
            public init(type: UnitSystem, isSelected: Bool) { self.id = type.rawValue; self.type = type; self.isSelected = isSelected }
        }
        public struct UnitsData { public let options: [UnitOption]; public let selected: UnitSystem }
        public struct UnitDefaults {
            public func defaultUnits() -> UnitsData { UnitsData(options: options(), selected: .european) }
            #sourceLocation(file: "@__swiftmacro_3App12defaultUnits6VerifyfMp_.swift", line: 1)
            public func defaultUnits_ensures(_ result: UnitsData) -> Bool {
                let o = result.options
                return result.selected == .european && o.count == 3 && o[0].type == .metric && o[1].type == .european
                    && o[2].type == .us && !o[0].isSelected && o[1].isSelected && !o[2].isSelected && o[2].id == "us"
            }
            #sourceLocation()
            public func wrongUnits() -> UnitsData { UnitsData(options: options(), selected: .us) }
            #sourceLocation(file: "@__swiftmacro_3App10wrongUnits6VerifyfMp_.swift", line: 1)
            public func wrongUnits_ensures(_ result: UnitsData) -> Bool { result.options[2].isSelected }
            #sourceLocation()
            public func loopWrite(_ x: Int8, _ n: Int8) -> Int8 {
                var a: [Int8] = [1, 2]
                var i: Int8 = 0
                var s: Int8 = 0
                while i < n { s = x / a[0]; a[0] = 0; i &+= 1 }
                return s
            }
            private func options() -> [UnitOption] {
                [
                    UnitOption(type: .metric, isSelected: false), UnitOption(type: .european, isSelected: true),
                    UnitOption(type: .us, isSelected: false),
                ]
            }
        }
        """

    @Test func aContractOnTheRowsOfAReturnedLiteralIsDecided() throws {
        let directory = NSTemporaryDirectory() + "sfv-literals-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/units.swift"
        try Self.source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Units"), options)
        func function(_ name: String) -> FunctionReport? { report.functions.first { $0.name.hasPrefix(name) } }
        let holds = try #require(function("UnitDefaults.defaultUnits()"))
        #expect(holds.status == .contractHolds, "\(holds.status): \(holds.detail ?? "")")
        let fails = try #require(function("UnitDefaults.wrongUnits()"))
        #expect(fails.status == .contractFails, "\(fails.status): \(fails.detail ?? "")")
        // The second iteration divides by the 0 the first one wrote: never safe, whatever the loop proof does.
        let loop = try #require(function("UnitDefaults.loopWrite("))
        #expect(loop.status != .safe, "\(loop.status): \(loop.detail ?? "")")
    }
}
