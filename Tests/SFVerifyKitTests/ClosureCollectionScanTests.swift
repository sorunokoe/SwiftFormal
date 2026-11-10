import Foundation
import SFVerifyKit
import Testing

/// Closure literals in `map`, `filter` and `first(where:)` through the whole pipeline: a literal or a length fixed by a
/// `requires` is proved for every input; an array of unknown length is at most `bounded (n ≤ 8)`, never safe
/// (`VerifyCollections.swift`).
@Suite struct ClosureCollectionScanTests {
    static let source = """
        public struct Rows {
            public func halves() -> Int8 { let r = ([2, 4, 6] as [Int8]).map { $0 / 2 }; return r[0] + r[2] }
            #sourceLocation(file: "@__swiftmacro_4Rows6halves6VerifyfMp_.swift", line: 1)
            public func halves_ensures(_ result: Int8) -> Bool { result == 4 }
            #sourceLocation()
            public func firstBig() -> Int8? { ([1, 5, 9] as [Int8]).first { $0 > 4 } }
            #sourceLocation(file: "@__swiftmacro_4Rows8firstBig6VerifyfMp_.swift", line: 1)
            public func firstBig_ensures(_ result: Int8?) -> Bool { result == 5 }
            #sourceLocation()
            public func pair(_ xs: [Int8]) -> Int { xs.filter { $0 > 0 }.count }
            #sourceLocation(file: "@__swiftmacro_4Rows4pair6VerifyfMp_.swift", line: 1)
            public func pair_requires(_ xs: [Int8]) -> Bool { xs.count == 2 }
            public func pair_ensures(_ xs: [Int8], _ result: Int) -> Bool { result <= 2 }
            #sourceLocation()
            public func few(_ xs: [Int8]) -> Int { xs.filter { $0 > 0 }.count }
            #sourceLocation(file: "@__swiftmacro_4Rows3few6VerifyfMp_.swift", line: 1)
            public func few_requires(_ xs: [Int8]) -> Bool { xs.count <= 8 }
            public func few_ensures(_ xs: [Int8], _ result: Int) -> Bool { result <= xs.count }
            #sourceLocation()
            public func any(_ xs: [Int8]) -> Int { xs.filter { $0 > 0 }.count }
            #sourceLocation(file: "@__swiftmacro_4Rows3any6VerifyfMp_.swift", line: 1)
            public func any_ensures(_ xs: [Int8], _ result: Int) -> Bool { result <= xs.count }
            #sourceLocation()
            public func plusOne(_ xs: [Int8]) -> [Int8] { xs.map { $0 + 1 } }
        }
        """

    @Test func aBoundedLengthIsProvedAndAnUnknownOneIsOnlyBounded() throws {
        let directory = NSTemporaryDirectory() + "sfv-collections-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/rows.swift"
        try Self.source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Rows"), options)
        func function(_ name: String) throws -> FunctionReport {
            try #require(report.functions.first { $0.name.hasPrefix("Rows.\(name)(") }, "\(name)")
        }
        for name in ["halves", "firstBig", "pair", "few"] {
            let f = try function(name)
            #expect(f.status == .contractHolds && f.bounded == nil, "\(name): \(f.status) \(f.detail ?? "")")
        }
        let any = try function("any")
        #expect(any.status == .undecided && any.category == "bounded", "\(any.status) \(any.detail ?? "")")
        #expect(any.bounded == ["filter over Array<Int8> (n ≤ 8)"], "\(any.bounded ?? [])")
        let plusOne = try function("plusOne")
        #expect(![.safe, .contractHolds].contains(plusOne.status), "\(plusOne.status) \(plusOne.detail ?? "")")
        #expect(report.summary.bounded == 1)
        #expect(report.text().contains("      bounded: filter over Array<Int8> (n ≤ 8)"))
        #expect(try report.json().contains("\"bounded\" : ["))
    }
}
