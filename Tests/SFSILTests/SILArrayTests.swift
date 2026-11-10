import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL

/// Arrays in real `swiftc -Onone` output: logic knows an array's count exactly and treats its elements as unknown.
enum ArrayFixture {
    static let source = """
        public enum Club: CaseIterable { case driver, iron, putter }
        public struct Row: Equatable {
            public var v: Int32
            public static func == (a: Row, b: Row) -> Bool { a.v + 1 == b.v }
        }
        public struct Bag { public var clubs: [Club]; public var n: Int32 }
        public final class Ref {}

        public func cnt(_ a: [Int32]) -> Int { a.count }
        public func countPlus(_ a: [Int32]) -> Int { a.count + 1 }
        public func safeAt(_ a: [Int32], _ i: Int) -> Int32 { i >= 0 && i < a.count ? a[i] : 0 }
        public func at(_ a: [Int32], _ i: Int) -> Int32 { a[i] }
        public func head(_ a: [Int32]) -> Int32 { a[0] }
        public func lit(_ x: Int32) -> Int { [x, x, x].count }
        public func app(_ a: [Int32], _ x: Int32) -> Int { var b = a; b.append(x); return b.count }
        public func mkBag(_ n: Int32) -> Bag { Bag(clubs: [.driver, .iron], n: n) }
        public func emptyList() -> [Int32] { [] }
        public func firstOr(_ a: [Int32]) -> Int32 { a.first ?? 0 }
        public func lastOr(_ a: [Club]) -> Club { a.last ?? .putter }
        public func elementTrap(_ a: [Int32]) -> Int32 { a.isEmpty ? 0 : a[0] + 1 }
        public func eqRows(_ a: [Row], _ b: [Row]) -> Bool { a == b }
        public func eqInts(_ a: [Int32], _ b: [Int32]) -> Bool { a == b }
        public func allClubs() -> Int { Club.allCases.count }
        public func setAt(_ a: [Int32], _ i: Int, _ x: Int32) -> [Int32] { var b = a; b[i] = x; return b }
        public func bump(_ a: inout [Int32]) { if !a.isEmpty { a[0] += 1 } }
        public func bumpWrapping(_ a: inout [Int32]) { if !a.isEmpty { a[0] &+= 1 } }
        public func refs(_ a: [Ref]) -> Int { a.count }
        public func pop(_ a: [Int32]) -> Int { var b = a; _ = b.popLast(); return b.count }
        public func removeLastOf(_ a: [Int32]) -> Int32 { var b = a; return b.removeLast() }
        public func plus(_ a: [Int32], _ b: [Int32]) -> Int { (a + b).count }
        public func plusEq(_ a: [Int32], _ b: [Int32]) -> Int { var c = a; c += b; return c.count }
        public func has(_ a: [Int32], _ x: Int32) -> Bool { a.contains(x) }
        public func hasRow(_ a: [Row], _ x: Row) -> Bool { a.contains(x) }
        public func index(_ a: [Int32], _ x: Int32) -> Int { a.firstIndex(of: x) ?? -1 }
        public func found(_ a: [Int32], _ x: Int32) -> Int32 { if let i = a.firstIndex(of: x) { return a[i] }; return 0 }
        public func repeated(_ n: Int) -> Int { [Int32](repeating: 0, count: n).count }
        public func removeAt(_ a: [Int32], _ i: Int) -> Int { var b = a; b.remove(at: i); return b.count }
        public func insertAt(_ a: [Int32], _ i: Int) -> Int { var b = a; b.insert(7, at: i); return b.count }
        public func cleared(_ a: [Int32]) -> Int { var b = a; b.removeAll(); return b.count }
        public func ends(_ a: [Int32]) -> Int { a.endIndex - a.startIndex }
        public func clubsOf(_ b: Bag) -> Int { b.clubs.count }
        public func optionalArray(_ a: [Int32]?) -> Int { a?.count ?? 0 }
        public func loopSum(_ a: [Int32]) -> Int32 { var s: Int32 = 0; for x in a { s &+= x }; return s }
        """
    static let onone = try! SILCompiler.module(source: source, name: "Arr", optimization: .none)
    static func symbol(_ name: String) throws -> String { try onone.symbol(module: "Arr", name: name) }
}

@Suite(.tags(.slow)) struct SILArrayTests {
    private static func verdict(
        _ name: String,
        ensures: @escaping (CNFBuilder, [BV], [BV]) -> Int32 = { c, _, _ in c.trueLit },
        requires: @escaping (CNFBuilder, [BV]) -> Int32 = { c, _ in c.trueLit }
    ) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try ArrayFixture.symbol(name), in: ArrayFixture.onone, requires: requires, ensures: ensures)
    }

    /// Every array input below 2^47 elements: the counts an `append` or `+` computes stay below the 2^48 at which the
    /// allocation fails (plan item R4).
    private static func small(_ c: CNFBuilder, _ inputs: [BV]) -> Int32 {
        inputs.filter { $0.width == 64 }.reduce(c.trueLit) { c.and($0, c.ult($1, c.constant(1 << 47, width: 64))) }
    }

    @Test func codeThatCannotTrapIsProved() throws {
        for name in [
            "cnt", "countPlus", "safeAt", "lit", "mkBag", "emptyList", "firstOr", "lastOr", "eqInts", "allClubs",
            "bumpWrapping", "pop", "has", "index", "found", "cleared", "ends", "clubsOf", "optionalArray",
        ] {
            #expect(try Self.verdict(name) == .proved, "\(name)")
        }
    }

    /// Plan item R4: a count an operation computes traps when it reaches 2^48 (the allocation fails), and only then.
    @Test func growingAnArrayTrapsOnlyAtTheAllocationBound() throws {
        for name in ["app", "plus", "plusEq"] {
            #expect(try Self.verdict(name, requires: Self.small) == .proved, "\(name) below the bound")
            guard case .counterexample(let values) = try Self.verdict(name) else {
                Issue.record("\(name) must trap at the bound")
                continue
            }
            let counts = values.filter { $0 >= 1 << 40 }
            #expect(!counts.isEmpty && counts.reduce(0, +) + 1 >= 1 << 48, "\(name): \(values)")
        }
    }

    @Test func countsAreExact() throws {
        #expect(try Self.verdict("lit") { c, _, r in c.eq(r[0], c.constant(3, width: 64)) } == .proved)
        #expect(try Self.verdict("allClubs") { c, _, r in c.eq(r[0], c.constant(3, width: 64)) } == .proved)
        #expect(
            try Self.verdict("app", ensures: { c, a, r in c.eq(r[0], c.add(a[0], c.constant(1, width: 64)).sum) }, requires: Self.small)
                == .proved)
        #expect(try Self.verdict("plus", ensures: { c, a, r in c.eq(r[0], c.add(a[0], a[1]).sum) }, requires: Self.small) == .proved)
        let one = { (c: CNFBuilder) in c.constant(1, width: 64) }
        #expect(
            try Self.verdict("pop") { c, a, r in
                c.eq(r[0], c.select(c.eq(a[0], c.constant(0, width: 64)), a[0], c.sub(a[0], one(c)).difference))
            } == .proved)
        // A wrong claim is refuted: appending makes the array longer.
        #expect(try Self.verdict("app") { c, a, r in c.eq(r[0], a[0]) } != .proved)
    }

    @Test func indexOutOfRangeIsFound() throws {
        // `a[i]` on an empty array, or with a negative index.
        guard case .counterexample(let v) = try Self.verdict("at") else { Issue.record("a[i] traps for i >= count"); return }
        #expect(Int64(bitPattern: v[1]) < 0 || v[1] >= v[0], "\(v)")
        #expect(try Self.verdict("head") == .counterexample([0]))
        #expect(try Self.verdict("removeLastOf") == .counterexample([0]))
        for name in ["setAt", "removeAt", "insertAt", "repeated"] {
            guard case .counterexample = try Self.verdict(name) else { Issue.record("\(name) traps for a bad index or count"); continue }
        }
        guard case .counterexample(let r) = try Self.verdict("repeated") else { return }
        #expect(Int64(bitPattern: r[0]) < 0)
    }

    @Test func aTrapThatDependsOnElementsIsUnknownNotABug() throws {
        // Elements are unknown: `a[0] + 1` overflows only for some element values.
        for name in ["elementTrap", "bump"] {
            #expect(try Self.verdict(name) == .unknown, "\(name)")
        }
    }

    @Test func userEqualityBehindArrayCallsIsChecked() throws {
        // Row.== traps at Int32.max. Array.== and contains may call it, so neither is proved.
        for name in ["eqRows", "hasRow"] {
            #expect(try Self.verdict(name) != .proved, "\(name)")
        }
    }

    /// No deinit of the module runs code, so destroying an array of objects runs none; the elements are not read.
    /// A deinit that runs code keeps it out, or is an assumption (`SILDeinitTests`).
    @Test func elementsWhoseDestructionRunsNoModuleCodeAreAccepted() throws {
        #expect(try Self.verdict("refs") == .proved)
    }
}
