import Foundation
import Testing
import SFProve
import SFSIL

/// `CGFloat` read as the `Double` it wraps on 64-bit Apple platforms (`SILCGFloat.swift`), in real `swiftc` output.
enum CGFloatFixture {
    static let source = """
        import CoreGraphics
        public func sum(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + b }
        public func toInt(_ x: CGFloat) -> Int { Int(x) }
        public func guardedToInt(_ x: CGFloat) -> Int { x.isFinite && abs(x) < 1e9 ? Int(x) : 0 }
        public func fromDouble(_ d: Double) -> Int { let c = CGFloat(d); return c > -1e9 && c < 1e9 ? Int(c) : 0 }
        public func backToDouble(_ x: CGFloat) -> Double { Double(x) }
        public func scaledCount(_ n: Int8) -> Int { Int(CGFloat(n) * 2) }
        public func scaledWord(_ n: Int) -> Int { Int(CGFloat(n) * 2) }
        public func exactHalf(_ n: Int8) -> Int8 { CGFloat(n) / 2 * 2 == CGFloat(n) ? n &+ 1 : n + 1 }
        public func clamped(_ x: CGFloat) -> Int { Int(min(max(x, -100), 100)) }
        public func clampedNaNAway(_ x: CGFloat) -> Int { Int(max(-100, min(100, x))) }
        public func halve(_ x: inout CGFloat) { x /= 2 }
        public func rounded(_ x: CGFloat) -> Int { x.isFinite && abs(x) < 1e6 ? Int(x.rounded()) : 0 }
        public func narrowed(_ x: CGFloat) -> Int { x.isFinite && x.magnitude < 1e6 ? Int(Float(x)) : 0 }
        """

    static func module(confirmed: [String] = ["CGFloat"]) throws -> SILModule {
        var module = try SILCompiler.module(source: source, name: "Cg", optimization: .none)
        module.confirmPackageTypes(confirmed)
        return module
    }
    static let confirmed = try! module()

    static func verdict(_ name: String, in module: SILModule = confirmed) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try module.symbol(module: "Cg", name: name), in: module)
    }
}

@Suite(.tags(.slow)) struct SILCGFloatTests {
    @Test func arithmeticConversionsAndComparisonsAreExact() throws {
        for name in ["sum", "guardedToInt", "fromDouble", "backToDouble", "scaledCount", "exactHalf", "clampedNaNAway", "halve"] {
            #expect(try CGFloatFixture.verdict(name) == .proved, "\(name)")
        }
        for name in ["rounded", "narrowed"] { #expect(try CGFloatFixture.verdict(name) == .proved, "\(name)") }
    }

    @Test func aTrapThroughCGFloatIsFound() throws {
        // `Int(x)` traps on NaN, an infinity or a large value; `min(max(x, -100), 100)` keeps a NaN.
        for name in ["toInt", "clamped"] {
            guard case .counterexample = try CGFloatFixture.verdict(name) else {
                Issue.record("\(name) traps for NaN")
                continue
            }
        }
        // `CGFloat(Int.max) * 2` is far above Int.max: `CGFloat.init<A: BinaryInteger>` is computed like `Double(n)`.
        guard case .counterexample = try CGFloatFixture.verdict("scaledWord") else {
            Issue.record("scaledWord traps for a large n")
            return
        }
    }

    @Test func cgFloatIsReadOnlyWhenTheProbeConfirmedTheName() throws {
        let module = try CGFloatFixture.module(confirmed: [])
        do {
            _ = try CGFloatFixture.verdict("sum", in: module)
            Issue.record("an unconfirmed CGFloat must not be read")
        } catch {
            #expect("\(error)".contains("CGFloat"), "\(error)")
        }
    }
}
