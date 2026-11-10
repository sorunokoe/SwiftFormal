import Foundation
import SFVerifyKit
import Testing

/// Library values inside app types (`SILFoundationValues.swift`): an `Image`, a `Font`, a `Calendar`, a `TimeZone` or
/// a `Decimal` field no longer blocks the type; what is inside them stays unknown, and a call on one that logic does
/// not read is an assumption the report lists, or a refusal with `--no-opaque-calls`.
@Suite struct LibraryValueScanTests {
    static let source = """
        import Foundation
        import SwiftUI

        public struct Badge {
            public var id: UUID
            public var icon: Image
            public var font: Font
            public var calendar: Calendar
            public var zone: TimeZone
            public var price: Decimal
            public var count: Int8
        }
        public func bump(_ b: Badge) -> Badge {
            var c = b
            c.count = b.count < 100 ? b.count + 1 : 0
            return c
        }
        #sourceLocation(file: "@__swiftmacro_6Badges4bump6VerifyfMp_.swift", line: 1)
        public func bump_ensures(_ b: Badge, _ r: Badge) -> Bool {
            r.id == b.id && r.calendar == b.calendar && r.zone == b.zone && r.price == b.price && r.count != b.count
        }
        #sourceLocation()
        public func zoneName(_ b: Badge) -> String { b.zone.identifier }
        #sourceLocation(file: "@__swiftmacro_6Badges8zoneName6VerifyfMp_.swift", line: 1)
        public func zoneName_ensures(_ b: Badge, _ r: String) -> Bool { !r.isEmpty }
        #sourceLocation()
        public func isToday(_ b: Badge, _ d: Date) -> Bool { b.calendar.isDateInToday(d) }
        #sourceLocation(file: "@__swiftmacro_6Badges7isToday6VerifyfMp_.swift", line: 1)
        public func isToday_ensures(_ b: Badge, _ d: Date, _ r: Bool) -> Bool { !r }
        #sourceLocation()
        public func tomorrow(_ b: Badge, _ d: Date) -> Date? { b.calendar.date(byAdding: .day, value: 1, to: d) }
        """

    static func scan(opaqueCalls: Bool) throws -> ScanReport {
        let directory = BinaryFixture.packageRoot.path + "/.build/sf-fixtures/library-values-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/badge.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        options.opaqueCalls = opaqueCalls
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Badges"), options)
    }

    static let report = Result { try scan(opaqueCalls: true) }
    static let strict = Result { try scan(opaqueCalls: false) }

    static func function(_ name: String, in report: Result<ScanReport, any Error> = report) throws -> FunctionReport {
        let functions = try report.get().functions
        return try #require(functions.first { $0.name.hasPrefix(name + "(") }, "\(functions.map(\.name))")
    }

    static func describe(_ f: FunctionReport) -> String { "\(f.name): \(f.status) \(f.detail ?? "") assumes \(f.assumptions ?? [])" }

    /// Each library value is passed through and equal to itself; the `Int8` beside them is read exactly.
    @Test func libraryValuesDoNotBlockTheTypeThatHoldsThem() throws {
        let bump = try Self.function("bump")
        #expect(bump.status == .contractHolds, "\(Self.describe(bump))")
        #expect(bump.assumptions == nil, "\(Self.describe(bump))")
    }

    /// What is inside one is unknown: a property of it is any value, an assumption the report names.
    @Test func whatALibraryValueHoldsIsUnknownAndAssumed() throws {
        let name = try Self.function("zoneName")
        #expect(![.contractHolds, .safe].contains(name.status), "\(Self.describe(name))")
        #expect(
            name.assumptions?.contains { $0.contains("TimeZone.identifier") && $0.contains("not to trap") } == true,
            "\(Self.describe(name))")
        // A calendar is never read as the device's: whether a date is today is never decided, and a failure that rests
        // on what such a call returns is not claimed either.
        let today = try Self.function("isToday")
        #expect(today.status == .undecided && today.detail?.contains("Calendar.isDateInToday") == true, "\(Self.describe(today))")
        #expect(today.assumptions?.contains { $0.contains("Calendar.isDateInToday") } == true, "\(Self.describe(today))")
        // Calendar arithmetic takes a `Calendar.Component`, which logic does not read.
        #expect(try Self.function("tomorrow").status == .unsupported)
    }

    @Test func strictModeRefusesCallsOnLibraryValues() throws {
        for name in ["zoneName", "isToday"] {
            let f = try Self.function(name, in: Self.strict)
            #expect(f.status == .unsupported && f.detail?.contains("--no-opaque-calls") == true, "\(Self.describe(f))")
        }
        #expect(try Self.function("bump", in: Self.strict).status == .contractHolds)
    }
}
