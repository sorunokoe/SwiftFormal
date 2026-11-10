import Foundation
import SFBV
import SFProve
@testable import SFSIL
import SFSemantics
import Testing

/// Plan item R6-3 in real `swiftc -Onone` output: floating-point arithmetic, `rounded(_:)` (whose `@unknown default`
/// calls `_roundSlowPath`), the generic `abs`, `magnitude`, `sign` and the conversions, proved or refuted, and run on
/// constant inputs (the encoder folds to an interpreter) against the same functions run natively here.
enum FloatFixture {
    static let source = """
        public func scaledBound(_ input: Double) -> Int { Int((abs(input) * 10.0).rounded()) }
        public func guardedScaled(_ input: Double) -> Int {
            guard input.isFinite, input > -1000, input < 1000 else { return 0 }
            return Int((input < 0 ? 0 - input : input) * 10.0)
        }
        public func guardedRounded(_ input: Double) -> Int {
            guard input.isFinite, abs(input) < 1000 else { return 0 }
            return Int((abs(input) * 10.0).rounded())
        }
        public func doubled(_ x: Double) -> Bool { x * 2.0 > x }
        public func roundedBy(_ x: Double, _ rule: FloatingPointRoundingRule) -> Double { x.rounded(rule) }
        public func roundedFloat(_ x: Float, _ rule: FloatingPointRoundingRule) -> Float { x.rounded(rule) }
        public func nearest(_ x: Double) -> Double { x.rounded() }
        public func absolute(_ x: Double) -> Double { abs(x) }
        public func absoluteFloat(_ x: Float) -> Float { abs(x) }
        public func absoluteInt(_ x: Int16) -> Int16 { abs(x) }
        public func magnitude(_ x: Double) -> Double { x.magnitude }
        public func magnitudeFloat(_ x: Float) -> Float { x.magnitude }
        public func isMinus(_ x: Double) -> Bool { x.sign == .minus }
        public func widened(_ x: Float) -> Double { Double(x) }
        public func narrowed(_ x: Double) -> Float { Float(x) }
        public func fromInt32(_ n: Int32) -> Double { Double(n) }
        public func fromUInt8(_ n: UInt8) -> Float { Float(n) }
        public func fromInt(_ n: Int) -> Double { Double(n) }
        public func arithmetic(_ a: Double, _ b: Double) -> Double { (a + b) * (a - b) / b }
        public func bits(_ x: Double) -> UInt64 { x.bitPattern }
        public func fromBits(_ b: UInt32) -> Float { Float(bitPattern: b) }
        public func smaller(_ a: Double, _ b: Double) -> Double { min(a, b) }
        public func larger(_ a: Float, _ b: Float) -> Float { max(a, b) }
        """
    static let onone = try! SILCompiler.module(source: source, name: "Flt", optimization: .none)
    static func symbol(_ name: String) throws -> String { try onone.symbol(module: "Flt", name: name) }
}

@Suite(.tags(.slow)) struct SILFloatSummaryTests {
    typealias Outcome = SILFloatArithmeticTests.Outcome

    private static func verdict(
        _ name: String, ensures: @escaping (CNFBuilder, [BV], [BV]) -> Int32 = { c, _, _ in c.trueLit }
    ) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try FloatFixture.symbol(name), in: FloatFixture.onone, ensures: ensures)
    }

    /// The function run by the encoder on constant arguments: each result leaf as bits or "some NaN", and whether it
    /// traps. A leaf that is not a constant must be a NaN for every choice of the fresh NaN bits (a signalling operand
    /// leaves the quiet bit of what follows free, so not every NaN folds), which the solver checks.
    private static func run(_ name: String, _ args: [UInt64]) throws -> (results: [Outcome], traps: Bool) {
        let symbol = try FloatFixture.symbol(name)
        let function = try FloatFixture.onone.function(symbol)
        func encode(_ c: CNFBuilder) throws -> EncodedFunction {
            try SILEncoder(module: FloatFixture.onone, builder: c).encode(
                symbol: symbol, arguments: zip(function.parameterWidths, args).map { c.constant($1, width: $0) })
        }
        let c = CNFBuilder()
        let encoded = try encode(c)
        let results = try encoded.results.enumerated().map { index, leaf -> Outcome in
            if let v = c.constantValue(leaf) { return .bits(v) }
            guard FloatFormat(width: leaf.width) != nil else { return .unknown }
            let alwaysNaN = try SFProve.prove(inputWidths: []) { c, _ in S0FloatClass.nan.encode(c, try encode(c).results[index]) }
            return alwaysNaN == .proved ? .nan : .unknown
        }
        return (results, c.constantValue(BV(bits: [encoded.trap])) == 1)
    }

    static let doubles = SILFloatArithmeticTests.values(Double.self, random: 200)
    static let floats = SILFloatArithmeticTests.values(Float.self, random: 200)

    @Test func theAppBoundTrapsOnlyWhereItReallyDoes() throws {
        guard case .counterexample(let v) = try Self.verdict("scaledBound") else {
            Issue.record("Int((abs(x) * 10.0).rounded()) traps for NaN, infinities and huge values")
            return
        }
        let x = Double(bitPattern: v[0])
        #expect(Int64(exactly: (abs(x) * 10.0).rounded()) == nil, "\(x) does not trap natively")
        #expect(try Self.verdict("guardedScaled") == .proved)
        #expect(try Self.verdict("guardedRounded") == .proved)
    }

    /// `x * 2.0 > x` is false for NaN, zero, negative numbers and the infinities: never proved.
    @Test func aFactFalseForNaNOrNegativeValuesIsNotProved() throws {
        guard case .counterexample(let v) = try Self.verdict("doubled", ensures: { _, _, r in r[0].bits[0] }) else {
            Issue.record("x * 2.0 > x must be refuted")
            return
        }
        let x = Double(bitPattern: v[0])
        #expect(!(x * 2.0 > x), "\(x)")
    }

    @Test func roundingByEveryRuleMatchesNativeExecution() throws {
        let rules: [FloatingPointRoundingRule] = [.toNearestOrAwayFromZero, .toNearestOrEven, .up, .down, .towardZero, .awayFromZero]
        #expect(try FloatFixture.onone.function(try FloatFixture.symbol("roundedBy")).parameterWidths == [64, 3])
        for x in Self.doubles {
            for (tag, rule) in rules.enumerated() {
                let got = try Self.run("roundedBy", [x.bitPattern, UInt64(tag)]).results
                #expect(got == [SILFloatArithmeticTests.expected(x.rounded(rule))], "\(x).rounded(.\(rule))")
            }
            #expect(try Self.run("nearest", [x.bitPattern]).results == [SILFloatArithmeticTests.expected(x.rounded())], "\(x).rounded()")
        }
        for x in Self.floats {
            for (tag, rule) in rules.enumerated() {
                let got = try Self.run("roundedFloat", [UInt64(x.bitPattern), UInt64(tag)]).results
                #expect(got == [SILFloatArithmeticTests.expected(x.rounded(rule))], "Float \(x).rounded(.\(rule))")
            }
        }
    }

    @Test func absMagnitudeAndSignMatchNativeExecution() throws {
        for x in Self.doubles {
            let bits = x.bitPattern
            // abs clears the sign bit, also of -0.0 and of a negative NaN: the very bits, not just "a NaN".
            #expect(try Self.run("absolute", [bits]).results == [.bits(abs(x).bitPattern)], "abs(\(x))")
            #expect(try Self.run("magnitude", [bits]).results == [.bits(x.magnitude.bitPattern)], "\(x).magnitude")
            #expect(try Self.run("isMinus", [bits]).results == [.bits(x.sign == .minus ? 1 : 0)], "\(x).sign")
            #expect(try Self.run("narrowed", [bits]).results == [SILFloatArithmeticTests.expected(Float(x))], "Float(\(x))")
        }
        for x in Self.floats {
            let bits = UInt64(x.bitPattern)
            #expect(try Self.run("absoluteFloat", [bits]).results == [.bits(UInt64(abs(x).bitPattern))], "abs(\(x))")
            #expect(try Self.run("magnitudeFloat", [bits]).results == [.bits(UInt64(x.magnitude.bitPattern))], "\(x).magnitude")
            #expect(try Self.run("widened", [bits]).results == [SILFloatArithmeticTests.expected(Double(x))], "Double(\(x))")
        }
        for n in [Int16.min, -1, 0, 1, Int16.max, -300] {
            let r = try Self.run("absoluteInt", [UInt64(UInt16(bitPattern: n))])
            #expect(r.traps == (n == .min), "abs(\(n))")
            if n != .min { #expect(r.results == [.bits(UInt64(UInt16(bitPattern: abs(n))))], "abs(\(n))") }
        }
    }

    @Test func conversionsAndArithmeticMatchNativeExecution() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let n = Int64.random(in: .min ... .max, using: &rng) >> Int64.random(in: 0...63, using: &rng)
            #expect(try Self.run("fromInt", [UInt64(bitPattern: n)]).results == [.bits(Double(n).bitPattern)], "Double(\(n))")
            let m = Int32(truncatingIfNeeded: n)
            #expect(try Self.run("fromInt32", [UInt64(UInt32(bitPattern: m))]).results == [.bits(Double(m).bitPattern)], "Double(\(m))")
            let u = UInt8(truncatingIfNeeded: n)
            #expect(try Self.run("fromUInt8", [UInt64(u)]).results == [.bits(UInt64(Float(u).bitPattern))], "Float(\(u))")
        }
        for (a, b) in zip(Self.doubles, Self.doubles.reversed()) {
            let got = try Self.run("arithmetic", [a.bitPattern, b.bitPattern]).results
            #expect(
                got == [SILFloatArithmeticTests.expected((a + b) * (a - b) / b)],
                "(\(a) + \(b)) * (\(a) - \(b)) / \(b) [\(String(a.bitPattern, radix: 16)), \(String(b.bitPattern, radix: 16))]")
        }
    }

    /// `min` and `max` compare with `<` and `>=` (NaN and signed zeros included: `min(.nan, 1)` is NaN, `min(1, .nan)`
    /// is 1, `min(0.0, -0.0)` is 0.0); `bitPattern` is the very bits.
    @Test func minMaxAndBitPatternsMatchNativeExecution() throws {
        let pairs = zip(Self.doubles, Self.doubles.shuffled()) + [(0.0, -0.0), (-0.0, 0.0), (.nan, 1), (1, .nan)]
        for (a, b) in pairs {
            #expect(try Self.run("smaller", [a.bitPattern, b.bitPattern]).results == [.bits(min(a, b).bitPattern)], "min(\(a), \(b))")
            #expect(try Self.run("bits", [a.bitPattern]).results == [.bits(a.bitPattern)], "\(a).bitPattern")
        }
        for (a, b) in zip(Self.floats, Self.floats.shuffled()) {
            let (x, y) = (UInt64(a.bitPattern), UInt64(b.bitPattern))
            #expect(try Self.run("larger", [x, y]).results == [.bits(UInt64(max(a, b).bitPattern))], "max(\(a), \(b))")
            #expect(try Self.run("fromBits", [x]).results == [.bits(x)], "Float(bitPattern: \(x))")
        }
    }

    /// `_roundSlowPath` is reached only for a rule outside the six cases, which no real value is, so the SIL above never
    /// takes it. Its summary is checked on its own: the same rounding as the inlined switch.
    @Test func theSlowPathRoundsLikeTheInlinedSwitch() throws {
        let rules: [FloatingPointRoundingRule] = [.toNearestOrAwayFromZero, .toNearestOrEven, .up, .down, .towardZero, .awayFromZero]
        for x in Self.doubles {
            for (tag, rule) in rules.enumerated() {
                let c = CNFBuilder()
                let call = ComputedCall(
                    name: "Double._roundSlowPath(_:)",
                    inputs: [[c.constant(UInt64(tag), width: 3)], [c.constant(x.bitPattern, width: 64)]],
                    conventions: [.indirect, .inout], substitutions: [], writtenTypes: [.scalar(64)],
                    resultType: .aggregate(name: "", fields: []))
                let effect = try FloatSummary.roundSlowPath.encode(call, in: c)
                #expect(effect.traps.isEmpty)
                let got: Outcome = c.constantValue(effect.writtenBack[0]).map { .bits($0) } ?? .nan
                #expect(got == SILFloatArithmeticTests.expected(x.rounded(rule)), "\(x).rounded(.\(rule))")
            }
        }
    }

    /// `abs` of a type outside the standard library could run that type's code: refused, never summarized.
    @Test func absOfAnotherTypeIsRefused() throws {
        let c = CNFBuilder()
        let call = ComputedCall(
            name: "abs(_:)", inputs: [[], [c.constant(0, width: 64)]], conventions: [.out, .indirect], substitutions: ["Money"],
            writtenTypes: [.scalar(64)], resultType: .aggregate(name: "", fields: []))
        #expect(throws: SILError.self) { try FloatSummary.absolute.encode(call, in: c) }
        let unsigned = ComputedCall(
            name: "Double.init(_:) of an integer", inputs: [[c.constant(0, width: 1)]], conventions: [.indirect], substitutions: ["Bool"],
            writtenTypes: [], resultType: .scalar(64))
        #expect(throws: SILError.self) { try FloatSummary.fromInteger.encode(unsigned, in: c) }
    }
}
