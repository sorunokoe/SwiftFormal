import Foundation
import SFVerifyKit
import Testing

/// Text, Phase 5 (`SILLocalization.swift`, `SILTextSplits.swift`, `SILFormat.swift`): which key a rule picks, the text
/// of an interpolation, and `String(format:)`.
@Suite struct TextScanTests {
    static let source = """
        import Foundation

        public enum Club { case driver, iron, putter }

        // Two clubs pick the same key: their texts are the same, whatever the catalogue says.
        public func clubName(_ club: Club) -> String {
            switch club {
            case .driver: NSLocalizedString("club.driver", comment: "")
            case .iron: NSLocalizedString("club.driver", comment: "the iron")
            case .putter: NSLocalizedString("club.putter", comment: "")
            }
        }
        #sourceLocation(file: "@__swiftmacro_3App8clubName6VerifyfMp_.swift", line: 1)
        public func clubName_ensures(_ club: Club, _ text: String) -> Bool {
            club == .driver || text != clubName(.driver)
        }
        #sourceLocation()

        // Different keys: the texts may still be the same, so this is never proved.
        public func clubTitle(_ club: Club) -> String {
            switch club {
            case .driver: String(localized: "club.driver")
            case .iron: String(localized: "club.iron")
            case .putter: String(localized: "club.putter")
            }
        }
        #sourceLocation(file: "@__swiftmacro_3App9clubTitle6VerifyfMp_.swift", line: 1)
        public func clubTitle_ensures(_ club: Club, _ text: String) -> Bool {
            club == .driver || text != clubTitle(.driver)
        }
        #sourceLocation()

        // Which key: provable.
        public func clubKey(_ club: Club) -> String {
            club == .putter ? NSLocalizedString("club.putter", comment: "") : NSLocalizedString("club.other", comment: "")
        }
        #sourceLocation(file: "@__swiftmacro_3App7clubKey6VerifyfMp_.swift", line: 1)
        public func clubKey_ensures(_ club: Club, _ text: String) -> Bool {
            club != .putter || text == NSLocalizedString("club.putter", comment: "")
        }
        #sourceLocation()

        // An interpolation is never a text it cannot print.
        public func carry(_ yards: Int) -> String { "\\(yards) yd" }
        #sourceLocation(file: "@__swiftmacro_3App5carry6VerifyfMp_.swift", line: 1)
        public func carry_ensures(_ yards: Int, _ text: String) -> Bool { text != "Unknown" && text != "-0 yd" && text != " yd" }
        #sourceLocation()

        public func offset(_ n: Int) -> String { "-\\(n)" }
        #sourceLocation(file: "@__swiftmacro_3App6offset6VerifyfMp_.swift", line: 1)
        public func offset_ensures(_ n: Int, _ text: String) -> Bool { text != "-" && text != "--0" && text != "-01" }
        #sourceLocation()

        public func unit(_ n: Int) -> String { "+\\(n)".lowercased() }
        #sourceLocation(file: "@__swiftmacro_3App4unit6VerifyfMp_.swift", line: 1)
        public func unit_ensures(_ n: Int, _ text: String) -> Bool { n != 3 || text == "+3" }
        #sourceLocation()

        public func prefixed(_ n: Int) -> String { "No. \\(n)" }
        #sourceLocation(file: "@__swiftmacro_3App8prefixed6VerifyfMp_.swift", line: 1)
        public func prefixed_ensures(_ n: Int, _ text: String) -> Bool { text.hasPrefix("No") && !text.hasPrefix("Yes") }
        #sourceLocation()

        // String(format:)
        public func holes(_ played: Int32, _ total: Int32) -> String { String(format: "%d of %d", played, total) }
        #sourceLocation(file: "@__swiftmacro_3App5holes6VerifyfMp_.swift", line: 1)
        public func holes_ensures(_ played: Int32, _ total: Int32, _ text: String) -> Bool { !text.isEmpty && text != "Unknown" }
        #sourceLocation()

        public func holesShort(_ played: Int32) -> String { String(format: "%d of %d", played) }

        public func greeting(_ name: String) -> String { String(format: "Hi %@!", name) }
        #sourceLocation(file: "@__swiftmacro_3App8greeting6VerifyfMp_.swift", line: 1)
        public func greeting_ensures(_ name: String, _ text: String) -> Bool { name != "Bo" || text == "Hi Bo!" }
        #sourceLocation()

        public func wrongType(_ n: Int) -> String { String(format: "%@ yd", n) }

        // A length modifier that does not match the argument: `h`/`hh` narrow the value, `l`/`ll` of a narrow
        // argument read it zero-extended. Neither prints the decimal text.
        public func shortText(_ n: Int32) -> String { String(format: "%hd", n) }
        #sourceLocation(file: "@__swiftmacro_3App9shortText6VerifyfMp_.swift", line: 1)
        public func shortText_ensures(_ n: Int32, _ text: String) -> Bool { n != 70000 || text == "70000" }
        #sourceLocation()
        public func charText(_ n: Int32) -> String { String(format: "%hhd", n) }
        #sourceLocation(file: "@__swiftmacro_3App8charText6VerifyfMp_.swift", line: 1)
        public func charText_ensures(_ n: Int32, _ text: String) -> Bool { n != 300 || text == "300" }
        #sourceLocation()
        public func longText(_ n: Int32) -> String { String(format: "%ld", n) }
        #sourceLocation(file: "@__swiftmacro_3App8longText6VerifyfMp_.swift", line: 1)
        public func longText_ensures(_ n: Int32, _ text: String) -> Bool { n != -1 || text == "-1" }
        #sourceLocation()
        public func longLongText(_ n: Int8) -> String { String(format: "%lld", n) }
        #sourceLocation(file: "@__swiftmacro_3App12longLongText6VerifyfMp_.swift", line: 1)
        public func longLongText_ensures(_ n: Int8, _ text: String) -> Bool { n != -1 || text == "-1" }
        #sourceLocation()
        // The length that matches: the decimal text.
        public func wordText(_ n: Int) -> String { String(format: "%ld", n) }
        #sourceLocation(file: "@__swiftmacro_3App8wordText6VerifyfMp_.swift", line: 1)
        public func wordText_ensures(_ n: Int, _ text: String) -> Bool { n != -5 || text == "-5" }
        #sourceLocation()
        public func halfText(_ n: Int16) -> String { String(format: "%d", n) }
        #sourceLocation(file: "@__swiftmacro_3App8halfText6VerifyfMp_.swift", line: 1)
        public func halfText_ensures(_ n: Int16, _ text: String) -> Bool { n != -1 || text == "-1" }
        #sourceLocation()

        // Conversions that may print nothing: `%c` of 0, a precision of 0 of 0; `%x` always prints a digit.
        public func letter(_ n: Int32) -> String { String(format: "%c", n) }
        #sourceLocation(file: "@__swiftmacro_3App6letter6VerifyfMp_.swift", line: 1)
        public func letter_ensures(_ n: Int32, _ text: String) -> Bool { !text.isEmpty }
        #sourceLocation()
        public func noDigits(_ n: Int32) -> String { String(format: "%.0d", n) }
        #sourceLocation(file: "@__swiftmacro_3App8noDigits6VerifyfMp_.swift", line: 1)
        public func noDigits_ensures(_ n: Int32, _ text: String) -> Bool { !text.isEmpty }
        #sourceLocation()
        public func noHex(_ n: Int32) -> String { String(format: "%.0x", n) }
        #sourceLocation(file: "@__swiftmacro_3App5noHex6VerifyfMp_.swift", line: 1)
        public func noHex_ensures(_ n: Int32, _ text: String) -> Bool { !text.isEmpty }
        #sourceLocation()
        public func hex(_ n: Int32) -> String { String(format: "%x", n) }
        #sourceLocation(file: "@__swiftmacro_3App3hex6VerifyfMp_.swift", line: 1)
        public func hex_ensures(_ n: Int32, _ text: String) -> Bool { !text.isEmpty }
        #sourceLocation()
        public func padded(_ name: String) -> String { String(format: "%5@", name) }
        #sourceLocation(file: "@__swiftmacro_3App6padded6VerifyfMp_.swift", line: 1)
        public func padded_ensures(_ name: String, _ text: String) -> Bool { text == name }
        #sourceLocation()
        public func longDouble(_ d: Double) -> String { String(format: "%Lf", d) }

        // A class of this module conforms to CVarArg (as every NSObject does): an `any CVarArg` may run its deinit.
        public final class Tag: NSObject { deinit { print("gone") } }
        public func anyArgument(_ value: any CVarArg) -> String { String(format: "%@", value) }
        """

    static let report = Result { try StringFactsScanTests.run(source) }

    static func function(_ prefix: String) throws -> FunctionReport {
        try #require(try report.get().functions.first { $0.name.hasPrefix(prefix + "(") }, "no \(prefix) in the scan")
    }

    @Test func twoCasesPickingTheSameKeyHaveTheSameText() throws {
        let f = try Self.function("clubName")
        #expect(f.status == .contractFails, "\(f.detail ?? "")")
        #expect(f.counterexample?.inputs == ["club = .iron"])
        #expect(f.assumptions?.contains { $0.contains("localization is deterministic") } == true, "\(f.assumptions ?? [])")
    }

    @Test func differentKeysNeverProveDifferentTexts() throws {
        let f = try Self.function("clubTitle")
        #expect(f.status == .undecided, "\(f.status) \(f.detail ?? "")")
    }

    @Test func whichKeyARulePicksIsProvable() throws {
        let f = try Self.function("clubKey")
        #expect(f.status == .contractHolds, "\(f.status) \(f.detail ?? "")")
    }

    @Test func interpolationTexts() throws {
        for name in ["carry", "offset", "unit", "prefixed"] {
            let f = try Self.function(name)
            #expect(f.status == .contractHolds, "\(name): \(f.status) \(f.detail ?? "")")
        }
    }

    @Test func stringFormat() throws {
        let holes = try Self.function("holes")
        #expect(holes.status == .contractHolds, "\(holes.status) \(holes.detail ?? "")")
        let short = try Self.function("holesShort")
        #expect(short.status == .mayTrap, "\(short.status) \(short.detail ?? "")")
        #expect(short.counterexample?.failure.contains("String(format:") == true, "\(short.counterexample?.failure ?? "")")
        let greeting = try Self.function("greeting")
        #expect(greeting.status == .contractHolds, "\(greeting.status) \(greeting.detail ?? "")")
        let wrong = try Self.function("wrongType")
        #expect(wrong.status == .mayTrap, "\(wrong.status) \(wrong.detail ?? "")")
        #expect(wrong.counterexample?.failure.contains("%@ given a number") == true, "\(wrong.counterexample?.failure ?? "")")
    }

    /// Exact decimal text only when the length modifier matches the argument; texts that may be empty are never
    /// assumed non-empty (docs/KNOWN-ISSUES.md #21).
    @Test func formatLengthsAndEmptyTexts() throws {
        for name in ["shortText", "charText", "longText", "longLongText", "letter", "noDigits", "noHex", "padded"] {
            let f = try Self.function(name)
            #expect(f.status != .contractHolds && f.status != .safe, "\(name): \(f.status) \(f.detail ?? "")")
        }
        for name in ["wordText", "halfText", "hex"] {
            let f = try Self.function(name)
            #expect(f.status == .contractHolds, "\(name): \(f.status) \(f.detail ?? "")")
        }
        let longDouble = try Self.function("longDouble")
        #expect(longDouble.status == .mayTrap, "\(longDouble.status) \(longDouble.detail ?? "")")
    }

    @Test func formatArgumentsOfUnknownTypeStayUnsupported() throws {
        // `holes` passes literal Int32s, whose destruction runs no code; `value` may be a `Tag`.
        let f = try Self.function("anyArgument")
        #expect(f.status == .unsupported, "\(f.status) \(f.detail ?? "")")
        #expect(f.detail?.contains("any CVarArg") == true, "\(f.detail ?? "")")
    }

    @Test func binaryLocalization() throws {
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(try BinaryFixture.client(["Texts.swift"], moduleName: "BinaryTexts"), options)
        func function(_ name: String) throws -> FunctionReport {
            try #require(report.functions.first { $0.name.hasPrefix(name + "(") }, "\(report.functions.map(\.name))")
        }
        let tee = try function("teeTitle")
        #expect(tee.status == .contractFails, "\(tee.status) \(tee.detail ?? "")")
        #expect(tee.counterexample?.inputs == ["tee = .middle"], "\(tee.counterexample?.inputs ?? [])")
        #expect(tee.assumptions?.contains { $0.contains("localization is deterministic") } == true, "\(tee.assumptions ?? [])")
        let holes = try function("holesPlayed")
        #expect(holes.status == .safe, "\(holes.status) \(holes.detail ?? "")")
        let any = try function("anyArgument")
        #expect(any.status == .unsupported, "\(any.status) \(any.detail ?? "")")
    }
}
