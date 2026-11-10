import SFBV
import SFProve
import SFSIL
import SFSemantics
import Testing

/// Plan item R6-3: the exact floating-point circuits (`FloatCircuit`, through `S0FloatInstance.encodeExactly`) against
/// the hardware, bit for bit. On constant operands every gate folds to a constant, so the circuit is its own
/// interpreter. A result the hardware says is NaN must be a NaN of the circuit (the exponent constant all ones); its
/// sign and payload are fresh, so they are not compared. Operands: zeros, subnormals (the smallest and largest), the
/// smallest normal, ties, the largest finite number, infinities, quiet, signalling and negative NaNs, neighbours of
/// each, and random bit patterns biased towards the extreme exponents.
@Suite struct SILFloatArithmeticTests {
    /// What the circuit computes on constant operands: a bit pattern, or "some NaN".
    enum Outcome: Equatable, CustomStringConvertible {
        case bits(UInt64)
        case nan
        /// Neither a constant nor a NaN: a bug.
        case unknown

        var description: String {
            switch self {
            case .bits(let b): "0x" + String(b, radix: 16)
            case .nan: "NaN"
            case .unknown: "unknown"
            }
        }
    }

    static func circuit(_ name: String, _ args: [UInt64]) -> Outcome {
        guard let inst = S0FloatInstance(builtinName: name) else { return .unknown }
        let c = CNFBuilder()
        let result = inst.encodeExactly(c, zip(args, inst.operandWidths).map { c.constant($0, width: $1) })
        if let v = c.constantValue(result.value) { return .bits(v) }
        // A fresh NaN: exponent all ones, sign and fraction free (but never all zero, by construction).
        guard let format = FloatFormat(width: result.value.width) else { return .unknown }
        let f = format.fractionBits
        let exponent = result.value.bits[f..<(result.value.width - 1)]
        return exponent.allSatisfy { $0 == c.trueLit } && !result.exact ? .nan : .unknown
    }

    static func expected<T: BinaryFloatingPoint>(_ x: T) -> Outcome {
        x.isNaN ? .nan : .bits(UInt64(truncatingIfNeeded: bits(x)))
    }

    static func bits<T: BinaryFloatingPoint>(_ x: T) -> UInt64 {
        let f = UInt64(T.significandBitCount), e = UInt64(T.exponentBitCount)
        let sign: UInt64 = x.sign == .minus ? 1 : 0
        return sign << (e + f) | UInt64(x.exponentBitPattern) << f | UInt64(x.significandBitPattern)
    }

    /// Edge values of a format, then `count` random ones.
    static func values<T: BinaryFloatingPoint>(_: T.Type, random count: Int) -> [T] {
        var v: [T] = [
            0, -0.0, 1, -1, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5, 3.5, 0.25, 0.75, 10, -10, 1000, 0.1, -0.1,
            .infinity, -.infinity, .nan, -.nan, .signalingNaN, -.signalingNaN,
            .leastNonzeroMagnitude, -.leastNonzeroMagnitude, .leastNormalMagnitude, -.leastNormalMagnitude,
            .leastNormalMagnitude.nextDown, -.leastNormalMagnitude.nextDown, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
            .greatestFiniteMagnitude.nextDown, .ulpOfOne, T(1).nextUp, T(1).nextDown, T(0.5).nextDown, T(0.5).nextUp,
            T(2).squareRoot(), -T(3).squareRoot(),
        ]
        let f = T.Exponent(T.significandBitCount)
        v += [T(sign: .plus, exponent: f, significand: 1), T(sign: .minus, exponent: f, significand: 1).nextUp]
        v += [T(sign: .plus, exponent: f - 1, significand: 1.5), T(sign: .plus, exponent: f, significand: 1).nextDown]
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<count { v.append(randomValue(T.self, using: &rng)) }
        return v
    }

    /// A random value: random sign and fraction, an exponent biased towards zero, one, the top and the middle.
    static func randomValue<T: BinaryFloatingPoint, G: RandomNumberGenerator>(_: T.Type, using rng: inout G) -> T {
        let width = 1 + T.exponentBitCount + T.significandBitCount
        let e = T.exponentBitCount, f = T.significandBitCount
        let maxExponent = UInt64(1) << UInt64(e) - 1
        let exponent: UInt64
        switch Int.random(in: 0..<8, using: &rng) {
        case 0: exponent = 0
        case 1: exponent = UInt64.random(in: 0...2, using: &rng)
        case 2: exponent = maxExponent - UInt64.random(in: 0...2, using: &rng)
        case 3: exponent = maxExponent / 2 + UInt64.random(in: 0...UInt64(f + 2), using: &rng) - 1
        default: exponent = UInt64.random(in: 0...maxExponent, using: &rng)
        }
        var fraction = UInt64.random(in: 0...UInt64.max, using: &rng) & (UInt64(1) << UInt64(f) - 1)
        switch Int.random(in: 0..<6, using: &rng) {
        case 0: fraction = 0
        case 1: fraction &= 0xFF
        case 2: fraction |= (UInt64(1) << UInt64(f) - 1) & ~0xFF
        default: break
        }
        let sign = UInt64.random(in: 0...1, using: &rng)
        return value(T.self, (sign << UInt64(width - 1)) | (exponent << UInt64(f)) | fraction)
    }

    static func value<T: BinaryFloatingPoint>(_: T.Type, _ bits: UInt64) -> T {
        let f = UInt64(T.significandBitCount), e = UInt64(T.exponentBitCount)
        return T(
            sign: bits >> (e + f) & 1 == 1 ? .minus : .plus, exponentBitPattern: T.RawExponent((bits >> f) & (1 << e - 1)),
            significandBitPattern: T.RawSignificand(bits & (1 << f - 1)))
    }

    static func suffix<T: BinaryFloatingPoint>(_: T.Type) -> String {
        "FPIEEE\(1 + T.exponentBitCount + T.significandBitCount)"
    }

    /// `+ - * /` of every pair of `values`, plus near-cancelling pairs. Returns the first mismatch.
    static func binaryMismatch<T: BinaryFloatingPoint>(_ values: [T]) -> String? {
        let ops: [(String, (T, T) -> T)] = [("fadd", { $0 + $1 }), ("fsub", { $0 - $1 }), ("fmul", { $0 * $1 }), ("fdiv", { $0 / $1 })]
        var pairs: [(T, T)] = []
        for a in values { for b in values { pairs.append((a, b)) } }
        for a in values where a.isFinite { pairs += [(a, -a.nextUp), (a, -a.nextDown), (a, a.nextUp), (a, a * 3)] }
        for (name, op) in ops {
            let builtin = "\(name)_\(suffix(T.self))"
            for (a, b) in pairs {
                let got = circuit(builtin, [bits(a), bits(b)])
                let want = expected(op(a, b))
                if got != want {
                    return "\(builtin)(\(a) [\(Outcome.bits(bits(a)))], \(b) [\(Outcome.bits(bits(b)))]) = \(got), hardware \(want)"
                }
            }
        }
        return nil
    }

    static func roundingMismatch<T: BinaryFloatingPoint>(_ values: [T]) -> String? {
        let rules: [(String, FloatingPointRoundingRule)] = [
            ("int_trunc", .towardZero), ("int_floor", .down), ("int_ceil", .up), ("int_round", .toNearestOrAwayFromZero),
            ("int_rint", .toNearestOrEven), ("int_nearbyint", .toNearestOrEven), ("int_roundeven", .toNearestOrEven),
        ]
        for (name, rule) in rules {
            let builtin = "\(name)_\(suffix(T.self))"
            for x in values {
                let got = circuit(builtin, [bits(x)])
                let want = expected(x.rounded(rule))
                if got != want { return "\(builtin)(\(x)) = \(got), hardware \(want)" }
            }
        }
        return nil
    }

    @Test func doubleArithmeticMatchesTheHardware() {
        if let problem = Self.binaryMismatch(Self.values(Double.self, random: 60)) { Issue.record(Comment(rawValue: problem)) }
    }

    @Test func floatArithmeticMatchesTheHardware() {
        if let problem = Self.binaryMismatch(Self.values(Float.self, random: 60)) { Issue.record(Comment(rawValue: problem)) }
    }

    @Test func randomPairsMatchTheHardware() {
        var rng = SystemRandomNumberGenerator()
        let doubles = (0..<3_000).map { _ in Self.randomValue(Double.self, using: &rng) }
        let floats = (0..<3_000).map { _ in Self.randomValue(Float.self, using: &rng) }
        for (name, op) in [
            ("fadd", { (a: Double, b: Double) in a + b }), ("fmul", { $0 * $1 }), ("fdiv", { $0 / $1 }), ("fsub", { $0 - $1 }),
        ] {
            for i in stride(from: 0, to: doubles.count - 1, by: 1) {
                let (a, b) = (doubles[i], doubles[i + 1])
                let got = Self.circuit("\(name)_FPIEEE64", [a.bitPattern, b.bitPattern])
                if got != Self.expected(op(a, b)) {
                    Issue.record("\(name)_FPIEEE64(\(a), \(b)) = \(got), hardware \(Self.expected(op(a, b)))")
                    return
                }
            }
        }
        for (name, op) in [
            ("fadd", { (a: Float, b: Float) in a + b }), ("fmul", { $0 * $1 }), ("fdiv", { $0 / $1 }), ("fsub", { $0 - $1 }),
        ] {
            for i in stride(from: 0, to: floats.count - 1, by: 1) {
                let (a, b) = (floats[i], floats[i + 1])
                let got = Self.circuit("\(name)_FPIEEE32", [UInt64(a.bitPattern), UInt64(b.bitPattern)])
                if got != Self.expected(op(a, b)) {
                    Issue.record("\(name)_FPIEEE32(\(a), \(b)) = \(got), hardware \(Self.expected(op(a, b)))")
                    return
                }
            }
        }
    }

    @Test func roundingToAnIntegralValueMatchesTheHardware() {
        if let problem = Self.roundingMismatch(Self.values(Double.self, random: 3_000)) { Issue.record(Comment(rawValue: problem)) }
        if let problem = Self.roundingMismatch(Self.values(Float.self, random: 3_000)) { Issue.record(Comment(rawValue: problem)) }
    }

    @Test func conversionsMatchTheHardware() throws {
        var rng = SystemRandomNumberGenerator()
        for d in Self.values(Double.self, random: 2_000) {
            #expect(Self.circuit("fptrunc_FPIEEE64_FPIEEE32", [d.bitPattern]) == Self.expected(Float(d)), "Float(\(d))")
        }
        for f in Self.values(Float.self, random: 2_000) {
            #expect(Self.circuit("fpext_FPIEEE32_FPIEEE64", [UInt64(f.bitPattern)]) == Self.expected(Double(f)), "Double(\(f))")
        }
        var integers: [UInt64] = [0, 1, 2, 3, 0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, ~0, 1 << 53, (1 << 53) + 1, (1 << 54) + 2]
        integers += (0..<2_000).map { _ in UInt64.random(in: 0...UInt64.max, using: &rng) >> UInt64.random(in: 0...63, using: &rng) }
        for v in integers {
            let s = Int64(bitPattern: v)
            #expect(Self.circuit("sitofp_Int64_FPIEEE64", [v]) == Self.expected(Double(s)), "Double(\(s))")
            #expect(Self.circuit("uitofp_Int64_FPIEEE64", [v]) == Self.expected(Double(v)), "Double(\(v) as UInt64)")
            #expect(Self.circuit("sitofp_Int64_FPIEEE32", [v]) == Self.expected(Float(s)), "Float(\(s))")
            let s32 = Int32(truncatingIfNeeded: s), s8 = Int8(truncatingIfNeeded: s)
            #expect(
                Self.circuit("sitofp_Int32_FPIEEE64", [UInt64(UInt32(bitPattern: s32))]) == Self.expected(Double(s32)), "Double(\(s32))")
            #expect(Self.circuit("sitofp_Int8_FPIEEE32", [UInt64(UInt8(bitPattern: s8))]) == Self.expected(Float(s8)), "Float(\(s8))")
        }
    }

    @Test func theIntegerPartMatchesTheHardwareWhereItFits() throws {
        for x in Self.values(Double.self, random: 3_000) where x.isFinite {
            let t = x.rounded(.towardZero)
            if let i = Int64(exactly: t) {
                #expect(Self.circuit("fptosi_FPIEEE64_Int64", [x.bitPattern]) == .bits(UInt64(bitPattern: i)), "Int64(\(x))")
            }
            if let i = Int8(exactly: t) {
                #expect(Self.circuit("fptosi_FPIEEE64_Int8", [x.bitPattern]) == .bits(UInt64(UInt8(bitPattern: i))), "Int8(\(x))")
            }
            if let u = UInt64(exactly: t) {
                #expect(Self.circuit("fptoui_FPIEEE64_Int64", [x.bitPattern]) == .bits(u), "UInt64(\(x))")
            }
            if let u = UInt32(exactly: t) {
                #expect(Self.circuit("fptoui_FPIEEE64_Int32", [x.bitPattern]) == .bits(UInt64(u)), "UInt32(\(x))")
            }
        }
        for x in Self.values(Float.self, random: 2_000) where x.isFinite {
            if let i = Int32(exactly: x.rounded(.towardZero)) {
                #expect(
                    Self.circuit("fptosi_FPIEEE32_Int32", [UInt64(x.bitPattern)]) == .bits(UInt64(UInt32(bitPattern: i))), "Int32(\(x))")
            }
        }
    }

    /// A NaN result has a free sign and payload (the hardware and LLVM's constant folder disagree on them), is quiet
    /// unless an operand is a signalling NaN (which LLVM may pass on unchanged), and is never an infinity.
    @Test func aNaNResultIsAnyNaNAndNothingElse() throws {
        let c = CNFBuilder()
        let inst = try #require(S0FloatInstance(builtinName: "fsub_FPIEEE64"))
        let inf = c.constant(Double.infinity.bitPattern, width: 64)
        let r = inst.encodeExactly(c, [inf, inf])
        #expect(!r.exact)
        #expect(r.value.bits[52..<63].allSatisfy { $0 == c.trueLit })
        // Quiet (bit 51 set), with the other fraction bits and the sign free.
        #expect(r.value.bits[51] == c.trueLit)
        #expect(r.value.bits[0..<51].allSatisfy { $0 != c.trueLit && $0 != c.falseLit })
        #expect(r.value.bits[63] != c.trueLit && r.value.bits[63] != c.falseLit)
        // A signalling operand: the quiet bit is free too, and an all-zero fraction is still excluded.
        let signalling = inst.encodeExactly(c, [c.constant(Double.signalingNaN.bitPattern, width: 64), inf])
        #expect(signalling.value.bits[52..<63].allSatisfy { $0 == c.trueLit })
        #expect(signalling.value.bits[51] != c.trueLit && signalling.value.bits[51] != c.falseLit)
        // No choice of the fresh bits makes the fraction zero (an infinity), even with the quiet bit clear.
        let verdict = try SFProve.prove(inputWidths: []) { c, _ in
            let r = inst.encodeExactly(
                c, [c.constant(Double.signalingNaN.bitPattern, width: 64), c.constant(Double.infinity.bitPattern, width: 64)])
            return -r.value.bits[0..<52].reduce(c.trueLit) { c.and($0, -$1) }
        }
        #expect(verdict == .proved)
    }
}

/// Dense checks at binary16, where the hardware is at hand (arm64): every value through the roundings and conversions,
/// and many random pairs through the arithmetic. Several seconds in a debug build.
@Suite struct SILFloat16ArithmeticSlowTests {
    #if arch(arm64)
        @Test func everyFloat16RoundsAndConvertsLikeTheHardware() {
            let all = (0...UInt16.max).map { Float16(bitPattern: $0) }
            if let problem = SILFloatArithmeticTests.roundingMismatch(all) { Issue.record(Comment(rawValue: problem)) }
            for h in all {
                let want = SILFloatArithmeticTests.expected(Double(h))
                let got = SILFloatArithmeticTests.circuit("fpext_FPIEEE16_FPIEEE64", [UInt64(h.bitPattern)])
                if got != want {
                    Issue.record("Double(\(h)) = \(got), hardware \(want)")
                    return
                }
            }
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<20_000 {
                let d = SILFloatArithmeticTests.randomValue(Double.self, using: &rng)
                let got = SILFloatArithmeticTests.circuit("fptrunc_FPIEEE64_FPIEEE16", [d.bitPattern])
                if got != SILFloatArithmeticTests.expected(Float16(d)) {
                    Issue.record("Float16(\(d)) = \(got), hardware \(SILFloatArithmeticTests.expected(Float16(d)))")
                    return
                }
            }
        }

        @Test func float16ArithmeticMatchesTheHardware() {
            if let problem = SILFloatArithmeticTests.binaryMismatch(SILFloatArithmeticTests.values(Float16.self, random: 150)) {
                Issue.record(Comment(rawValue: problem))
            }
        }
    #endif
}
