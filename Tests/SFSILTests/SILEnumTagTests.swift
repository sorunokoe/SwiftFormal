import Foundation
import Testing
import SFProve
import SFSIL

/// `==`, `!=` and `~=` on an enum with raw values, which `-Onone` code writes with the generic builtin
/// `getEnumTag<T>` on two stack slots (`SILEnumTags.swift`), in real `swiftc` output.
enum EnumTagFixture {
    static let source = """
        import Foundation
        @objc public enum Lamp: Int { case off, on }
        public func lampOn(_ l: Lamp) -> Bool { l == .on }
        public enum Club: String { case driver, iron, putter }
        public enum Rank: Int { case low = 10, mid = 20, high = 30 }
        public struct Row: Equatable { public var club: Club; public var n: Int8 }

        public func isIron(_ c: Club) -> Bool { c == .iron }
        public func ironBump(_ n: Int8) -> Int8 { (n == 5 ? Club.iron : .putter) == .iron ? n + 123 : n }
        public func ironGuarded(_ n: Int8) -> Int8 { let c: Club = n > 100 ? .driver : .iron; return c == .iron ? n + 27 : n }
        public func notPutter(_ n: Int8) -> Int8 { let c: Club = n > 100 ? .putter : .driver; return c != .putter ? n + 27 : n }
        public func rawPick(_ n: Int8) -> Int8 { Club(rawValue: n == 1 ? "iron" : "wood") == .iron ? n + 127 : n }
        public func rawMiss(_ n: Int8) -> Int8 { Club(rawValue: "wood") == .iron ? n + 127 : n }
        public func pattern(_ n: Int8) -> Int8 {
            let target = Club.putter
            switch n > 0 ? Club.putter : .iron { case target: return n &+ 1; default: return n + 1 }
        }
        public func rankHigh(_ n: Int8) -> Int8 { (n > 0 ? Rank.high : .low) == .high ? n - 100 : n }
        public func rowsEqual(_ n: Int8) -> Int8 { Row(club: .iron, n: 1) == Row(club: n > 0 ? .iron : .driver, n: 1) ? n + 1 : n }
        public func optionalTag(_ c: Club?, _ n: Int8) -> Int8 { c == .iron ? n + 1 : n }
        """
    static let module = try! SILCompiler.module(source: source, name: "Et", optimization: .none)

    static func verdict(_ name: String) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try module.symbol(module: "Et", name: name), in: module)
    }
}

@Suite(.tags(.slow)) struct SILEnumTagTests {
    @Test func equalityOnARawValueEnumIsRead() throws {
        #expect(try EnumTagFixture.verdict("isIron") == .proved)
        // Exact: the guarded forms are safe, and the overflow behind `== .iron` is reached only for the right case.
        #expect(try EnumTagFixture.verdict("ironGuarded") == .proved)
        #expect(try EnumTagFixture.verdict("notPutter") == .proved)
        #expect(try EnumTagFixture.verdict("rankHigh") == .proved)
        guard case .counterexample(let inputs) = try EnumTagFixture.verdict("ironBump") else {
            Issue.record("ironBump overflows for 5")
            return
        }
        #expect(inputs == [5])
    }

    @Test func initFromARawValueComparedWithACaseIsRead() throws {
        guard case .counterexample(let inputs) = try EnumTagFixture.verdict("rawPick") else {
            Issue.record("rawPick overflows for 1")
            return
        }
        #expect(inputs == [1])
        #expect(try EnumTagFixture.verdict("rawMiss") == .proved)
    }

    @Test func anExpressionPatternAndASynthesizedEqualsAreRead() throws {
        // `case target:` runs `~=`, which is `==` on the two tags: only n <= 0 reaches `n + 1`, which cannot overflow.
        #expect(try EnumTagFixture.verdict("pattern") == .proved)
        guard case .counterexample(let inputs) = try EnumTagFixture.verdict("rowsEqual") else {
            Issue.record("rowsEqual overflows for 127")
            return
        }
        #expect(inputs == [127])
        guard case .counterexample = try EnumTagFixture.verdict("optionalTag") else {
            Issue.record("optionalTag overflows for .iron and 127")
            return
        }
    }

    @Test func anObjCEnumIsNotRead() throws {
        // An `@objc` enum holds its raw value in memory: its tags are not logic's case indices, so it stays unsupported.
        #expect(throws: SILError.self) { try EnumTagFixture.verdict("lampOn") }
        do {
            _ = try EnumTagFixture.verdict("lampOn")
        } catch {
            #expect("\(error)".contains("@objc enum Lamp"), "\(error)")
        }
    }
}
