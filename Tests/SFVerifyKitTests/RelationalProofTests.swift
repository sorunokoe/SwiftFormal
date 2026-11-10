import Foundation
import SFVerifyKit
import Testing

/// Relational claims (`RelationalProofs.swift`): a walk's `Injective`, `RoundTrip` and `Agrees`, decided by logic for
/// every input. Shape 15 of the planted-bug suite (`PlantedBugs/MappedCorrectly.swift`) and the claims logic must
/// refuse or leave unknown.
@Suite struct RelationalProofTests {
    typealias Step = RelationalStep

    static func free(_ name: String) -> [Step] { [Step(.function, name: name, labels: ["_"])] }

    static func request(_ claim: RelationalRequest.Claim, _ forward: [Step], _ other: [Step] = [], unwraps: Bool = false)
        -> RelationalRequest
    {
        RelationalRequest(
            claim: claim, file: "Walks.swift", line: forward.count, property: claim.rawValue, forward: forward, other: other,
            unwrapsOther: unwraps)
    }

    static let planted: [RelationalRequest] = [
        request(.injective, free("seatCodeBroken")),
        request(.injective, free("seatCodeFixed")),
        request(.roundTrip, free("cardCode"), free("cardFromCodeBroken")),
        request(.roundTrip, free("cardCode"), free("cardFromCodeFixed")),
        request(.agrees, free("bandBroken"), free("bandReference")),
        request(.agrees, free("bandFixed"), free("bandReference")),
    ]

    static let plantedResults = Result {
        let fixtures = PlantedBugScanTests.fixtures
        let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path).filter { $0.hasSuffix(".swift") }.sorted()
        var options = VerifyOptions()
        options.relational = planted
        options.only = ["seatCode", "cardCode", "cardFromCode", "band"]
        let report = try SFVerify.run(
            CompileOptions(files: names.map { fixtures.appendingPathComponent($0).path }, moduleName: "PlantedBugs"), options)
        return try #require(report.relational)
    }

    @Test func shape15CollidingCodeIsFoundAndTheFixedOneProved() throws {
        let results = try Self.plantedResults.get()
        #expect(results[0].verdict == .refuted, "\(results[0].detail ?? "")")
        // Seat 128 of a row and seat 0 of the next row: any such pair, which the walk's samples do not reach.
        let inputs = try #require(results[0].inputs)
        #expect(inputs.hasPrefix("a = Seat(row: ") && inputs.contains("b = Seat(row: "), "\(inputs)")
        #expect(results[0].detail?.hasPrefix("both give ") == true, "\(results[0].detail ?? "")")
        #expect(results[1].verdict == .proved, "\(results[1].detail ?? "")")
        #expect(results[1].assumptions == nil)
    }

    @Test func shape15LossyRoundTripIsFoundAndTheFixedOneProved() throws {
        let results = try Self.plantedResults.get()
        #expect(results[2].verdict == .refuted, "\(results[2].detail ?? "")")
        #expect(results[2].inputs?.hasPrefix("Card(strokes: ") == true, "\(results[2].inputs ?? "")")
        #expect(results[2].detail?.contains("putts: 99") == true, "\(results[2].detail ?? "")")
        #expect(results[3].verdict == .proved, "\(results[3].detail ?? "")")
    }

    @Test func shape15SiblingRulesThatDisagreeAtOneBoundary() throws {
        let results = try Self.plantedResults.get()
        #expect(results[4].verdict == .refuted, "\(results[4].detail ?? "")")
        #expect(results[4].inputs == "20", "\(results[4].inputs ?? "")")
        #expect(results[4].detail == "gives .high, the other rule .middle", "\(results[4].detail ?? "")")
        #expect(results[5].verdict == .proved, "\(results[5].detail ?? "")")
    }

    static let source = """
        import Foundation

        public struct Seat: Equatable { public var row: UInt8; public var number: UInt8 }
        public struct SeatRule {
            public let input: Seat
            public var body: UInt16 { UInt16(input.row) << 8 | UInt16(input.number) }
            public func execute() -> UInt16 { body }
        }
        public struct SeatBack {
            public let input: UInt16
            public func execute() -> Seat { Seat(row: UInt8(input >> 8), number: UInt8(truncatingIfNeeded: input)) }
        }

        public struct OptionalSeatBack {
            let input: UInt16?
            public var body: Seat { input.map { Seat(row: UInt8($0 >> 8), number: UInt8(truncatingIfNeeded: $0)) } ?? Seat(row: 0, number: 0) }
        }
        public func seatOrFirst(_ code: UInt16?) -> Seat { Seat(row: UInt8((code ?? 0) >> 8), number: UInt8(truncatingIfNeeded: code ?? 1)) }

        public struct Point: Equatable { public var x: Double; public var y: Double }
        public func pointCode(_ point: Point) -> UInt64 { point.x.bitPattern ^ point.y.bitPattern }

        public struct Parity: Equatable {
            public var value: UInt8
            public static func == (a: Parity, b: Parity) -> Bool { a.value % 2 == b.value % 2 }
        }
        public func parityCode(_ parity: Parity) -> UInt8 { parity.value }

        public enum Club: Equatable { case driver, iron, putter }
        public func clubTitle(_ club: Club) -> String {
            switch club {
            case .driver: String(localized: "club.driver")
            case .iron: String(localized: "club.iron")
            case .putter: String(localized: "club.putter")
            }
        }
        public func clubLetter(_ club: Club) -> String {
            switch club {
            case .driver: "D"
            case .iron: "I"
            case .putter: "P"
            }
        }
        public func clubLetterBroken(_ club: Club) -> String { club == .driver ? "D" : "I" }
        public func club(letter: String) -> Club? {
            switch letter {
            case "D": .driver
            case "I": .iron
            case "P": .putter
            default: nil
            }
        }

        public func percent(_ part: UInt8) -> UInt8 { 200 / part }

        public struct Row: Equatable { public var number: UInt8; public var code: UInt8 { number } }
        """

    static let inlineResults = Result {
        let dir = NSTemporaryDirectory() + "sfv-relational-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/Rules.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.only = ["percent"]
        options.relational = [
            request(.injective, [Step(.initializer, type: "SeatRule", name: "init", labels: ["input"]), Step(.getter, name: "body")]),
            request(
                .roundTrip, [Step(.initializer, type: "SeatRule", name: "init", labels: ["input"]), Step(.method, name: "execute")],
                [Step(.initializer, type: "SeatBack", name: "init", labels: ["input"]), Step(.method, name: "execute")]),
            request(.injective, free("pointCode")),
            request(.injective, free("parityCode")),
            request(.injective, free("clubTitle")),
            request(.injective, free("clubLetter")),
            request(.injective, free("clubLetterBroken")),
            request(.roundTrip, free("clubLetter"), [Step(.function, name: "club", labels: ["letter"])], unwraps: true),
            request(.injective, free("percent")),
            request(.injective, free("missing")),
            request(
                .roundTrip, [Step(.initializer, type: "SeatRule", name: "init", labels: ["input"]), Step(.getter, name: "body")],
                [Step(.initializer, type: "OptionalSeatBack", name: "init", labels: ["input"]), Step(.getter, name: "body")]),
            request(
                .roundTrip, [Step(.initializer, type: "SeatRule", name: "init", labels: ["input"]), Step(.getter, name: "body")],
                free("seatOrFirst")),
            request(.injective, [Step(.getter, name: "code")]),
        ]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Rules"), options)
        return try #require(report.relational)
    }

    @Test func aWalkClosureOfAnInitializerAndAMember() throws {
        let results = try Self.inlineResults.get()
        #expect(results[0].verdict == .proved, "\(results[0].detail ?? "")")
        #expect(results[1].verdict == .proved, "\(results[1].detail ?? "")")
    }

    /// Swift wraps a value in `.some` to pass it where an `Optional` of it is taken, to a memberwise initializer too.
    @Test func aValuePassedAsAnOptional() throws {
        let results = try Self.inlineResults.get()
        #expect(results[10].verdict == .proved, "\(results[10].detail ?? "")")
        #expect(results[11].verdict == .proved, "\(results[11].detail ?? "")")
    }

    /// `-0.0 == 0.0` and `nan != nan`: logic compares bits, so a float in a compared type is not read.
    @Test func floatsAndAHandWrittenEqualityAreRefused() throws {
        let results = try Self.inlineResults.get()
        #expect(results[2].verdict == .unknown)
        #expect(results[2].detail?.contains("floating-point") == true, "\(results[2].detail ?? "")")
        #expect(results[3].verdict == .unknown)
        #expect(results[3].detail?.contains("hand-written ==") == true, "\(results[3].detail ?? "")")
    }

    /// Different localization keys may give the same text: never proved from the keys, never refuted either.
    @Test func textIsComparedByIdentityAndLocalizedTextIsUndecided() throws {
        let results = try Self.inlineResults.get()
        #expect(results[4].verdict == .unknown, "\(results[4].detail ?? "")")
        #expect(results[5].verdict == .proved, "\(results[5].detail ?? "")")
        #expect(results[6].verdict == .refuted, "\(results[6].detail ?? "")")
        #expect(results[6].detail == "both give \"I\"", "\(results[6].detail ?? "")")
        #expect(results[7].verdict == .proved, "\(results[7].detail ?? "")")
    }

    /// The claim is decided only for a rule that returns normally on every input.
    @Test func aRuleThatMayTrapOrIsNotFoundStaysUnknown() throws {
        let results = try Self.inlineResults.get()
        #expect(results[8].verdict == .unknown)
        #expect(results[8].detail?.contains("not proved to return normally") == true, "\(results[8].detail ?? "")")
        #expect(results[9].verdict == .unknown)
        #expect(results[9].detail?.contains("no scanned function missing(_:)") == true, "\(results[9].detail ?? "")")
    }

    /// `$0.code` names no type: the result says which type's `code` logic read, as Swift prints it with its module, so
    /// that it is laid only over a walk over that type (`Check.applyingRelational`).
    @Test func aResultNamesTheTypeTheRuleTakes() throws {
        let results = try Self.inlineResults.get()
        #expect(results[12].verdict == .proved, "\(results[12].detail ?? "")")
        #expect(results[12].inputType == "Rules.Row")
        #expect(results[0].inputType == "Rules.Seat")
        #expect(results[11].inputType == "Rules.Seat")
        #expect(results[2].inputType == nil)
        // No scanned function of that name: this scan says nothing; one that read the rule and could not decide does.
        #expect(results[9].unresolved == .noMatchingFunction)
        #expect(results[8].unresolved == nil)
    }
}
