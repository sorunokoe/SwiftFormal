import Foundation
import SFBV
import SFCNF
import SFProve
import SFSIL
import Testing

/// Integer ranges in real `swiftc -Onone` output. `..<`, `...` and `Range.contains` are inlined by the compiler;
/// `ClosedRange.contains`, `~=` (also behind `case lo...hi:`), `isEmpty` and `Array.indices` stay calls, which logic
/// answers exactly. Before, any `Range<…>` value made a function unsupported, so the idiomatic bounds check
/// `a.indices.contains(i) ? a[i] : x` could not be proved (app study round 5).
enum RangeFixture {
    static let source = """
        public enum Tab: CaseIterable { case first, second }
        public func pick(_ i: Int) -> Tab {
            let tabs = Tab.allCases
            return tabs.indices.contains(i) ? tabs[i] : .first
        }
        public func safeAt(_ a: [Int32], _ i: Int) -> Int32 { a.indices.contains(i) ? a[i] : 0 }
        public func offByOne(_ a: [Int32], _ i: Int) -> Int32 { (0...a.count).contains(i) ? a[i] : 0 }
        public func inClosed(_ i: Int, _ n: Int) -> Bool { (0...n).contains(i) }
        public func inHalfOpen(_ i: Int, _ lo: Int, _ n: Int) -> Bool { (lo..<n).contains(i) }
        public func tilde(_ i: Int, _ n: Int) -> Bool { 0..<n ~= i }
        public func caseRange(_ x: UInt8, _ hi: UInt8) -> Int8 {
            switch x {
            case 0...9: return 1
            case 10...hi: return 2
            default: return 3
            }
        }
        public func emptyRange(_ lo: Int, _ n: Int) -> Bool { (lo..<n).isEmpty }
        public func inClosedSafe(_ i: Int, _ n: Int) -> Bool { n >= 0 && (0...n).contains(i) }
        public func tildeSafe(_ i: Int, _ n: Int) -> Bool { n >= 0 && 0..<n ~= i }
        public func emptySafe(_ lo: Int, _ n: Int) -> Bool { lo <= n && (lo..<n).isEmpty }
        public func bounds(_ r: Range<Int32>) -> Int32 { r.upperBound &- r.lowerBound }
        public func width(_ r: ClosedRange<UInt8>) -> UInt8 { r.upperBound - r.lowerBound }
        public func doubles(_ x: Double) -> Bool { (0.0..<1.0).contains(x) }
        """
    static let onone = try! SILCompiler.module(source: source, name: "Rng", optimization: .none)
    static func symbol(_ name: String) throws -> String { try onone.symbol(module: "Rng", name: name) }
}

@Suite(.tags(.slow)) struct SILRangeTests {
    private static func verdict(
        _ name: String, ensures: @escaping (CNFBuilder, [BV], [BV]) -> Int32 = { c, _, _ in c.trueLit }
    ) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try RangeFixture.symbol(name), in: RangeFixture.onone, ensures: ensures)
    }

    @Test func idiomaticBoundsChecksAreProved() throws {
        for name in ["pick", "safeAt", "bounds", "inClosedSafe", "tildeSafe", "emptySafe"] {
            #expect(try Self.verdict(name) == .proved, "\(name)")
        }
    }

    @Test func containsIsExact() throws {
        let same = { (c: CNFBuilder, a: Int32, b: Int32) in -c.xor(a, b) }
        let zero = { (c: CNFBuilder) in c.constant(0, width: 64) }
        // n >= 0 && (0...n).contains(i) is n >= 0 && 0 <= i <= n.
        #expect(
            try Self.verdict("inClosedSafe") { c, a, r in
                same(c, r[0].bits[0], c.and(-c.slt(a[1], zero(c)), c.and(-c.slt(a[0], zero(c)), -c.slt(a[1], a[0]))))
            } == .proved)
        // A wrong claim is refuted: i == n is inside a closed range.
        #expect(
            try Self.verdict("inClosedSafe") { c, a, r in
                same(c, r[0].bits[0], c.and(-c.slt(a[1], zero(c)), c.and(-c.slt(a[0], zero(c)), c.slt(a[0], a[1]))))
            } != .proved)
        // n >= 0 && 0..<n ~= i is 0 <= i < n.
        #expect(
            try Self.verdict("tildeSafe") { c, a, r in
                same(c, r[0].bits[0], c.and(-c.slt(a[1], zero(c)), c.and(-c.slt(a[0], zero(c)), c.slt(a[0], a[1]))))
            } == .proved)
        // lo <= n && (lo..<n).isEmpty is lo == n.
        #expect(try Self.verdict("emptySafe") { c, a, r in same(c, r[0].bits[0], c.eq(a[0], a[1])) } == .proved)
    }

    @Test func trapsAreFoundWithTheInput() throws {
        // A range whose upper bound is below its lower bound traps when it is made.
        guard case .counterexample(let v) = try Self.verdict("inClosed") else { Issue.record("0...n traps for n < 0"); return }
        #expect(Int64(bitPattern: v[1]) < 0, "\(v)")
        guard case .counterexample(let h) = try Self.verdict("inHalfOpen") else { Issue.record("lo..<n traps for n < lo"); return }
        #expect(Int64(bitPattern: h[2]) < Int64(bitPattern: h[1]), "\(h)")
        // The off-by-one (`...` instead of `..<`) indexes one past the end: never proved.
        guard case .counterexample(let o) = try Self.verdict("offByOne") else { Issue.record("offByOne reads a[count]"); return }
        #expect(o[1] == o[0], "\(o)")
        // `case 10...hi:` traps when hi < 10, and only then.
        guard case .counterexample(let s) = try Self.verdict("caseRange") else { Issue.record("10...hi traps for hi < 10"); return }
        #expect(s[1] < 10 && s[0] >= 10, "\(s)")
    }

    @Test func rangeParametersKeepTheirInvariant() throws {
        // A Range always has lowerBound <= upperBound, so the unsigned difference of a ClosedRange<UInt8> cannot wrap.
        #expect(try Self.verdict("width") == .proved)
    }

    /// `(0.0..<1.0).contains(x)` never reaches a range summary: `contains` is `@_transparent`, so the compiler inlines
    /// it into `fcmp_ole`/`fcmp_olt` on the bit patterns, which logic reads with IEEE semantics since plan item L1. The
    /// summaries themselves still refuse a bound that is not an integer (`StdlibSummary.integerKind` in `SILRanges.swift`).
    @Test func aDoubleRangeIsReadAsTheCompilersFloatComparisons() throws {
        #expect(try Self.verdict("doubles") == .proved)
    }
}
