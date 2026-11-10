import Foundation
import SFBV
import SFProve
@testable import SFSIL
import Testing

/// A mapper written as a protocol with an associated `Output`, a `body` and a one-line `execute()` in a protocol
/// extension, called as `X(input: x).execute()`. At `-Onone` that call is a generic call to `Mapper.execute()` at
/// `<X>`, whose body names `Self.Output`: logic reads it at `X`, with `X.Output` taken from `X`'s witness table.
enum ForwarderFixture {
    static let source = """
        public protocol Mapper { associatedtype Output; var body: Output { get } }
        public extension Mapper { func execute() -> Output { body } }
        public extension Mapper where Output == Int8 { func twice() -> Int8 { body &* 2 } }
        public enum Level: String { case low, mid, high }
        public enum Shade { case light, dark }

        public struct LevelScore: Mapper {
            public let input: Level
            public var body: Int8 { switch input { case .low: 1; case .mid: 2; case .high: 3 } }
        }
        public struct LevelScoreBug: Mapper {
            public let input: Level
            public var body: Int8 { switch input { case .low: 1; case .mid: 2; case .high: 120 } }
        }
        public struct Bonus: Mapper {
            public let input: Level
            public var body: Int8 { LevelScore(input: input).execute() + 100 }
        }
        public struct BonusBug: Mapper {
            public let input: Level
            public var body: Int8 { LevelScoreBug(input: input).execute() + 100 }
        }
        public struct ShadeOf: Mapper {
            public let input: Level
            public var body: Shade { input == .high ? .dark : .light }
        }
        public struct LevelOf: Mapper {
            public let input: Shade
            public var body: Level { input == .dark ? .high : .low }
        }
        public struct Box<T>: Mapper {
            public let input: T
            public var body: T { input }
        }

        public func bonus(_ level: Level) -> Int8 { Bonus(input: level).body }
        public func bonusBug(_ level: Level) -> Int8 { BonusBug(input: level).body }
        public func score(_ level: Level) -> Int8 { LevelScore(input: level).execute() }
        public func scoreBug(_ level: Level) -> Int8 { LevelScoreBug(input: level).execute() }
        public func thereAndBack(_ level: Level) -> Level { LevelOf(input: ShadeOf(input: level).execute()).execute() }
        public func doubled(_ level: Level) -> Int8 { LevelScore(input: level).twice() }
        public func doubledBug(_ level: Level) -> Int8 { LevelScoreBug(input: level).twice() }
        public func boxed(_ value: Int8) -> Int8 { Box(input: value).execute() }
        """
    static let module = try! SILCompiler.module(source: source, name: "Fw", optimization: .none)

    static func symbol(_ name: String) throws -> String { try module.symbol(module: "Fw", name: name) }

    static func unsupportedReason(_ name: String) throws -> String? {
        do {
            _ = try SILVerifier.prove(try symbol(name), in: module)
            return nil
        } catch let error as SILError {
            if case .unsupported(let reason) = error { return reason }
            throw error
        }
    }
}

@Suite(.tags(.slow)) struct SILForwarderTests {
    /// The level tag is the case index in declaration order: low 0, mid 1, high 2.
    private static func inRange(_ c: CNFBuilder, _ r: BV) -> Int32 {
        c.and(c.sle(c.constant(1, width: 8), r), c.sle(r, c.constant(3, width: 8)))
    }

    @Test func aMapperThatCallsAnotherThroughExecuteIsRead() throws {
        #expect(try SILVerifier.prove(try ForwarderFixture.symbol("bonus"), in: ForwarderFixture.module) == .proved)
        // Planted bug in the inner body: 120 + 100 overflows for `.high` only.
        guard
            case .counterexample(let inputs) = try SILVerifier.prove(
                try ForwarderFixture.symbol("bonusBug"), in: ForwarderFixture.module)
        else {
            Issue.record("BonusBug.body overflows for .high")
            return
        }
        #expect(inputs == [2])
    }

    @Test func anEnsuresOverAnExecuteCallSeesTheConcreteBody() throws {
        let m = ForwarderFixture.module
        #expect(try SILVerifier.prove(try ForwarderFixture.symbol("score"), in: m, ensures: { c, _, r in Self.inRange(c, r) }) == .proved)
        guard
            case .counterexample(let inputs) = try SILVerifier.prove(
                try ForwarderFixture.symbol("scoreBug"), in: m, ensures: { c, _, r in Self.inRange(c, r) })
        else {
            Issue.record("scoreBug gives 120 for .high")
            return
        }
        #expect(inputs == [2])
        // A round trip through two mappers: `.mid` comes back as `.low`.
        guard
            case .counterexample(let back) = try SILVerifier.prove(
                try ForwarderFixture.symbol("thereAndBack"), in: m, ensures: { c, inputs, r in c.eq(inputs[0], r) })
        else {
            Issue.record("thereAndBack loses .mid")
            return
        }
        #expect(back == [1])
    }

    @Test func anExtensionMethodThatDoesMoreIsReadAtTheConcreteTypeToo() throws {
        let m = ForwarderFixture.module
        #expect(try SILVerifier.prove(try ForwarderFixture.symbol("doubled"), in: m) == .proved)
        let reason = try ForwarderFixture.unsupportedReason("doubledBug")
        #expect(reason == nil, "\(reason ?? "")")
        // `&*` wraps: 120 * 2 is -16, so the ensures (a positive result) fails for `.high`.
        let positive: (CNFBuilder, [BV], BV) -> Int32 = { c, _, r in c.slt(c.constant(0, width: 8), r) }
        #expect(try SILVerifier.prove(try ForwarderFixture.symbol("doubled"), in: m, ensures: positive) == .proved)
        guard case .counterexample(let inputs) = try SILVerifier.prove(try ForwarderFixture.symbol("doubledBug"), in: m, ensures: positive)
        else {
            Issue.record("doubledBug wraps for .high")
            return
        }
        #expect(inputs == [2])
    }

    @Test func aGenericConformanceStaysUnsupported() throws {
        // `Box<T>: Mapper` has a generic witness table: `Box<Int8>.Output` is not read from it.
        let reason = try #require(try ForwarderFixture.unsupportedReason("boxed"))
        #expect(reason.contains("Box<Int8>"), "\(reason)")
    }

    @Test func anAssociatedTypeIsOnlyWrittenWhenOneTableGivesItExactly() throws {
        func table(_ type: String, _ output: String) throws -> SILModule {
            try SILModule(
                text: "sil_stage canonical\n\nsil_witness_table \(type): Mapper module Fw {\n  associated_type Output: \(output)\n}\n")
        }
        var m = try table("A", "Int8")
        #expect(m.associatedType(of: "A", "Output") == "Int8")
        #expect(m.substitutingParameters(["Self": "A"], in: "$*Self.Output") == "$*Int8")
        // A nested associated type, an unknown one, or a member named `Output` stay as written.
        #expect(m.substitutingParameters(["Self": "A"], in: "$Self.Output.Element") == "$A.Output.Element")
        #expect(m.substitutingParameters(["Self": "A"], in: "$Self.Input") == "$A.Input")
        #expect(m.substitutingParameters(["Self": "A"], in: "#Mapper.Self.Output") == "#Mapper.Self.Output")
        // Two tables (same-named types in two modules) that disagree drop the entry for good.
        m.link(try table("A", "Int16"))
        m.link(try table("A", "Int8"))
        #expect(m.associatedType(of: "A", "Output") == nil)
    }
}
