import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL

/// Dictionaries and sets in real `swiftc -Onone` output (plan item L2): logic knows their counts exactly, keys and
/// values are unknown, and the three traps of the standard library (equal keys in a literal, in
/// `init(uniqueKeysWithValues:)`, and a key type whose `hash(into:)` and `==` disagree) are kept.
enum DictionaryFixture {
    static let source = """
        public enum Club: Hashable { case driver, iron, putter }
        public struct Bad: Hashable {
            public var v: Int8
            public func hash(into h: inout Hasher) { h.combine(v + 1) }
        }
        public struct Holder: Equatable { public var table: [String: Int]; public var n: Int8 }
        public final class Ref: Hashable {
            public static func == (a: Ref, b: Ref) -> Bool { a === b }
            public func hash(into h: inout Hasher) {}
        }

        public func cnt(_ d: [Int: Int]) -> Int { d.count }
        public func empty(_ s: Set<Int8>) -> Bool { s.isEmpty }
        public func getOr(_ d: [Int: Int], _ k: Int) -> Int { d[k] ?? 0 }
        public func fromEmpty(_ x: Int8) -> Int8 { let d: [Int8: Int8] = [:]; return d[x]! }
        public func valueTrap(_ d: [Int8: Int8], _ k: Int8) -> Int8 { (d[k] ?? 0) + 1 }
        public func literal(_ k: Int) -> Int { let d = [1: 10, 2: 20, 3: 30]; return d[k] ?? d.count }
        public func literalCount() -> Int { [1: 10, 2: 20, 3: 30].count }
        public func duplicateLiteral(_ x: Int8) -> Int { [x: 1, 0: 2].count }
        public func enumLiteral() -> Int { let d: [Club: Int] = [.driver: 1, .iron: 2]; return d.count }
        public func enumDuplicate() -> Int { let d: [Club: Int] = [.driver: 1, .driver: 2]; return d.count }
        public func unique(_ x: Int8) -> Int { Dictionary(uniqueKeysWithValues: [(x, 1), (0, 2)]).count }
        public func uniqueConstants() -> Int { Dictionary(uniqueKeysWithValues: [(1, 1), (0, 2)]).count }
        public func uniqueUnknown(_ pairs: [(Int8, Int8)]) -> Int { Dictionary(uniqueKeysWithValues: pairs).count }
        public func assignTwice(_ k: Int) -> Int { var d: [Int: Int] = [:]; d[k] = 1; d[k] = 2; return 10 / d.count }
        public func assign(_ d: [Int: Int], _ k: Int) -> Int { var e = d; e[k] = 1; return e.count }
        public func removed(_ k: Int) -> Int { var d: [Int: Int] = [:]; d[k] = 1; _ = d.removeValue(forKey: k); return d.count }
        public func removedByNil(_ k: Int) -> Int { var d = [k: 1]; d[k] = nil; return d.count }
        public func updated(_ k: Int) -> Int { var d: [Int: Int] = [:]; return d.updateValue(1, forKey: k) == nil ? d.count : -1 }
        public func insertOnce(_ x: Int8) -> Int8 { var s = Set<Int8>(); s.insert(x); return x / Int8(s.count - 1) }
        public func insertOnceSafe(_ x: Int8) -> Int8 { var s = Set<Int8>(); s.insert(x); return x / Int8(s.count) }
        public func setLiteral() -> Int { let s: Set<Int> = [1, 2, 2]; return 10 / (s.count - 1) }
        public func setLiteralDuplicates() -> Int { let s: Set<Int> = [2, 2]; return 10 / (s.count - 1) }
        public func has(_ s: Set<Int>, _ x: Int) -> Bool { s.contains(x) }
        public func hasNothing(_ x: Int8) -> Int8 { let s = Set<Int8>(); return s.contains(x) ? x + 1 : x &+ 1 }
        public func cleared(_ d: [Int: Int]) -> Int { var e = d; e.removeAll(); return e.count }
        public func same(_ a: [Int: Int], _ b: [Int: Int]) -> Bool { a == b }
        public func holders(_ a: Holder, _ b: Holder) -> Bool { a == b }
        public func badKey(_ k: Bad) -> Int { var d: [Bad: Int] = [:]; d[k] = 1; return d.count }
        public func badKeys(_ a: Bad, _ b: Bad) -> Int { var d: [Bad: Int] = [:]; d[a] = 1; d[b] = 2; return d.count }
        public func refs(_ d: [Ref: Int]) -> Int { d.count }
        public func refLookup(_ d: [Ref: Int], _ r: Ref) -> Int { d[r] ?? 0 }
        public func keysOf(_ d: [Int: Int]) -> Int { d.keys.count }
        """
    static let onone = try! SILCompiler.module(source: source, name: "Dict", optimization: .none)
    static func symbol(_ name: String) throws -> String { try onone.symbol(module: "Dict", name: name) }
}

@Suite(.tags(.slow)) struct SILDictionaryTests {
    private static func verdict(
        _ name: String,
        ensures: @escaping (CNFBuilder, [BV], [BV]) -> Int32 = { c, _, _ in c.trueLit },
        requires: @escaping (CNFBuilder, [BV]) -> Int32 = { c, _ in c.trueLit }
    ) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(
            try DictionaryFixture.symbol(name), in: DictionaryFixture.onone, requires: requires, ensures: ensures)
    }

    @Test func codeThatCannotTrapIsProved() throws {
        for name in [
            "cnt", "empty", "getOr", "literal", "literalCount", "enumLiteral", "uniqueConstants", "assignTwice", "removed",
            "removedByNil", "updated", "insertOnceSafe", "setLiteral", "has", "hasNothing", "cleared", "same", "holders",
        ] {
            #expect(try Self.verdict(name) == .proved, "\(name)")
        }
    }

    @Test func countsAreExact() throws {
        let three = { (c: CNFBuilder) in c.constant(3, width: 64) }
        #expect(try Self.verdict("literalCount") { c, _, r in c.eq(r[0], three(c)) } == .proved)
        // Keys are not stored, so removing the key just inserted may or may not find it: 0 or 1 entries remain.
        #expect(try Self.verdict("removed") { c, _, r in c.ule(r[0], c.constant(1, width: 64)) } == .proved)
        #expect(try Self.verdict("removed") { c, _, r in c.eq(r[0], c.constant(0, width: 64)) } != .proved)
        #expect(try Self.verdict("updated") { c, _, r in c.eq(r[0], c.constant(1, width: 64)) } == .proved)
        #expect(try Self.verdict("cleared") { c, _, r in c.eq(r[0], c.constant(0, width: 64)) } == .proved)
        #expect(try Self.verdict("cnt") { c, a, r in c.eq(r[0], a[0]) } == .proved)
        // Whether a key is in a dictionary that is not empty is unknown, so its count after an assignment is too.
        #expect(try Self.verdict("assign") { c, a, r in c.eq(r[0], a[0]) } != .proved)
    }

    @Test func aTrapThatDoesNotDependOnUnknownContentsIsFound() throws {
        for (name, input) in [("fromEmpty", nil), ("insertOnce", nil), ("duplicateLiteral", UInt64(0)), ("unique", UInt64(0))] {
            guard case .counterexample(let values) = try Self.verdict(name) else {
                Issue.record("\(name) traps")
                continue
            }
            if let input { #expect(values == [input], "\(name): \(values)") }
        }
        // Equal elements of a set literal are kept once: `[2, 2]` has one element, and 10 / 0 traps.
        guard case .counterexample = try Self.verdict("setLiteralDuplicates") else { Issue.record("[2, 2] has one element"); return }
    }

    /// The three traps that make a summary that drops them give a false `safe`. With unknown keys, or a key type of the
    /// module whose `hash(into:)` and `==` may disagree, they are unknown: never `proved`.
    @Test func trapsOnEqualKeysAreNeverHidden() throws {
        for name in ["enumDuplicate", "uniqueUnknown", "badKeys", "valueTrap", "assign"] {
            #expect(try Self.verdict(name) == .unknown, "\(name)")
        }
    }

    @Test func hashingRunsTheKeyTypesOwnCode() throws {
        // `d[k] = 1` hashes `k` with Bad.hash(into:), whose `v + 1` overflows at 127.
        guard case .counterexample(let values) = try Self.verdict("badKey") else { Issue.record("Bad.hash(into:) traps"); return }
        #expect(values == [127], "\(values)")
    }

    @Test func outsideTheModelIsRefused() throws {
        // Keys of a class are compared by identity, which is not modelled: reading one is refused.
        #expect(throws: SILError.self) { try Self.verdict("refLookup") }
        #expect(throws: SILError.self) { try Self.verdict("keysOf") }
    }

    @Test func aDictionaryOfObjectsIsDestroyedWithoutCodeWhenNoDeinitRunsCode() throws {
        // `Ref` has no deinit, so destroying the dictionary runs no code of the module; its keys are never read.
        #expect(try Self.verdict("refs") == .proved)
    }

    @Test func dictionaryTypesAreReadInEverySpelling() throws {
        for text in ["[Int : String]", "Dictionary<Int, String>", "Swift.Dictionary<Int, [Int8]>", "Set<Int8>", "Swift.Set<Int8>"] {
            #expect(HashedCollection.parse(text) != nil, "\(text)")
        }
        for text in ["[Int]", "Array<Int>", "[(Int, Int)]", "Set<Int, Int>"] {
            #expect(HashedCollection.parse(text) == nil, "\(text)")
        }
    }
}
