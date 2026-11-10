import SFBV
import SFSemantics
import Testing

/// Plan item L1: the floating-point builtins' exact parts against Swift's own `Double` and `Float`, and the circuit
/// against the interpreter. Values: zeros, infinities, NaNs (quiet, signalling, negative), subnormals, the limits of
/// each integer width and their neighbours, and random bit patterns.
@Suite struct S0FloatTests {
    private static func doubles() -> [Double] {
        var values: [Double] = [
            0, -0.0, 1, -1, 0.5, -0.5, .infinity, -.infinity, .nan, -.nan, .signalingNaN, .ulpOfOne,
            .leastNonzeroMagnitude, -.leastNonzeroMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        ]
        for k in [7, 8, 15, 16, 31, 32, 63, 64] {
            let p = Double(sign: .plus, exponent: k, significand: 1)
            values += [p, -p, p - 1, -p + 1, p + 1, -p - 1, p.nextUp, p.nextDown, -p.nextUp, -p.nextDown, p - 0.5, -p - 0.5]
        }
        var rng = SystemRandomNumberGenerator()
        values += (0..<400).map { _ in Double(bitPattern: rng.next()) }
        return values
    }

    private static let predicates = ["oeq", "ogt", "oge", "olt", "ole", "one", "ord", "ueq", "ugt", "uge", "ult", "ule", "une", "uno"]

    /// Swift's own comparisons, and NaN checks for the unordered predicates.
    private static let swift: [String: @Sendable (Double, Double) -> Bool] = [
        "oeq": { $0 == $1 }, "ogt": { $0 > $1 }, "oge": { $0 >= $1 }, "olt": { $0 < $1 }, "ole": { $0 <= $1 },
        "one": { !$0.isNaN && !$1.isNaN && $0 != $1 }, "ord": { !$0.isNaN && !$1.isNaN },
        "ueq": { $0.isNaN || $1.isNaN || $0 == $1 }, "ugt": { $0.isNaN || $1.isNaN || $0 > $1 },
        "uge": { $0.isNaN || $1.isNaN || $0 >= $1 }, "ult": { $0.isNaN || $1.isNaN || $0 < $1 },
        "ule": { $0.isNaN || $1.isNaN || $0 <= $1 }, "une": { $0 != $1 }, "uno": { $0.isNaN || $1.isNaN },
    ]

    private static func native(_ p: String, _ a: Double, _ b: Double) -> Bool { swift[p]!(a, b) }

    private static func circuit(_ inst: S0FloatInstance, _ args: [UInt64]) -> S0FloatOutcome {
        let c = CNFBuilder()
        let result = inst.encode(c, zip(args, inst.operandWidths).map { c.constant($0, width: $1) })
        if result.undefined == c.trueLit { return .undefined }
        guard result.exact, let v = c.constantValue(result.value) else { return .unknown }
        return .values([v])
    }

    /// Why `fcmp_<p>` disagrees with Swift on `(a, b)` at 64 or 32 bits, or nil when the interpreter and the circuit agree.
    private static func compareMismatch(_ p: String, _ a: Double, _ b: Double) -> String? {
        guard let d = S0FloatInstance(builtinName: "fcmp_\(p)_FPIEEE64"), let f = S0FloatInstance(builtinName: "fcmp_\(p)_FPIEEE32") else {
            return "fcmp_\(p) missing"
        }
        let want: S0FloatOutcome = .values([native(p, a, b) ? 1 : 0])
        let args = [a.bitPattern, b.bitPattern]
        if d.evaluate(args) != want || circuit(d, args) != want {
            return "fcmp_\(p)_FPIEEE64(\(a), \(b)): \(d.evaluate(args)), Swift \(want)"
        }
        let (fa, fb) = (Float(a), Float(b))
        let fargs = [UInt64(fa.bitPattern), UInt64(fb.bitPattern)]
        let fwant: S0FloatOutcome = .values([native(p, Double(fa), Double(fb)) ? 1 : 0])
        if f.evaluate(fargs) != fwant || circuit(f, fargs) != fwant { return "fcmp_\(p)_FPIEEE32(\(fa), \(fb)): \(f.evaluate(fargs))" }
        return nil
    }

    @Test func comparisonsMatchSwiftAtDoubleAndFloat() {
        let values = Array(Self.doubles().prefix(120))
        for p in Self.predicates {
            for a in values {
                for b in values {
                    if let problem = Self.compareMismatch(p, a, b) {
                        Issue.record(Comment(rawValue: problem))
                        return
                    }
                }
            }
        }
    }

    @Test func conversionToAnIntegerIsUndefinedExactlyWhenTheIntegerPartDoesNotFit() throws {
        func fits(_ x: Double, width: Int, signed: Bool) -> Bool {
            guard x.isFinite else { return false }
            let t = x.rounded(.towardZero)
            switch (width, signed) {
            case (8, true): return Int8(exactly: t) != nil
            case (16, true): return Int16(exactly: t) != nil
            case (32, true): return Int32(exactly: t) != nil
            case (64, true): return Int64(exactly: t) != nil
            case (8, false): return UInt8(exactly: t) != nil
            case (16, false): return UInt16(exactly: t) != nil
            case (32, false): return UInt32(exactly: t) != nil
            default: return UInt64(exactly: t) != nil
            }
        }
        for signed in [true, false] {
            for width in [8, 16, 32, 64] {
                let name = "\(signed ? "fptosi" : "fptoui")_FPIEEE64_Int\(width)"
                let inst = try #require(S0FloatInstance(builtinName: name))
                for x in Self.doubles() {
                    let want: S0FloatOutcome = fits(x, width: width, signed: signed) ? .unknown : .undefined
                    guard inst.evaluate([x.bitPattern]) == want, Self.circuit(inst, [x.bitPattern]) == want else {
                        Issue.record(
                            "\(name)(\(x)): \(inst.evaluate([x.bitPattern])), circuit \(Self.circuit(inst, [x.bitPattern])), Swift \(want)")
                        return
                    }
                }
            }
        }
    }

    @Test func signOperationsAndBitcastsMatchSwift() throws {
        let neg = try #require(S0FloatInstance(builtinName: "fneg_FPIEEE64"))
        let abs = try #require(S0FloatInstance(builtinName: "int_fabs_FPIEEE64"))
        let copy = try #require(S0FloatInstance(builtinName: "int_copysign_FPIEEE64"))
        let cast = try #require(S0FloatInstance(builtinName: "bitcast_FPIEEE64_Int64"))
        for x in Self.doubles() {
            for (inst, want) in [(neg, (-x).bitPattern), (abs, x.magnitude.bitPattern), (cast, x.bitPattern)] {
                #expect(inst.evaluate([x.bitPattern]) == .values([want]) && Self.circuit(inst, [x.bitPattern]) == .values([want]))
            }
            let y = -x
            let want = Double(signOf: y, magnitudeOf: x).bitPattern
            #expect(copy.evaluate([x.bitPattern, y.bitPattern]) == .values([want]))
            #expect(Self.circuit(copy, [x.bitPattern, y.bitPattern]) == .values([want]))
        }
        for name in ["fadd_FPIEEE64", "int_sqrt_FPIEEE32", "sitofp_Int64_FPIEEE64", "fpext_FPIEEE32_FPIEEE64", "int_fma_FPIEEE64"] {
            let inst = try #require(S0FloatInstance(builtinName: name), "\(name)")
            #expect(inst.evaluate(inst.operandWidths.map { _ in 0 }) == .unknown)
        }
        for name in ["fadd_FPIEEE80", "fcmp_xyz_FPIEEE64", "bitcast_FPIEEE64_Int32", "fpext_FPIEEE64_FPIEEE32", "fptosi_FPIEEE64_Int128"] {
            #expect(S0FloatInstance(builtinName: name) == nil, "\(name) must be rejected")
        }
    }

    @Test func classificationMatchesSwift() {
        let classes: [(S0FloatClass, (Double) -> Bool)] = [
            (.finite, \.isFinite), (.nan, \.isNaN), (.infinite, \.isInfinite), (.zero, \.isZero), (.normal, \.isNormal),
            (.subnormal, \.isSubnormal),
        ]
        for x in Self.doubles() + [Double.leastNormalMagnitude, Double.leastNormalMagnitude.nextDown] {
            for (kind, swift) in classes {
                let c = CNFBuilder()
                let encoded = c.constantValue(BV(bits: [kind.encode(c, c.constant(x.bitPattern, width: 64))]))
                #expect(kind.evaluate(x.bitPattern, width: 64) == swift(x) && encoded == (swift(x) ? 1 : 0), "\(kind) \(x)")
                let f = Float(x)
                let fc = CNFBuilder()
                let fEncoded = fc.constantValue(BV(bits: [kind.encode(fc, fc.constant(UInt64(f.bitPattern), width: 32))]))
                let fWant: Bool
                switch kind {
                case .finite: fWant = f.isFinite
                case .nan: fWant = f.isNaN
                case .infinite: fWant = f.isInfinite
                case .zero: fWant = f.isZero
                case .normal: fWant = f.isNormal
                case .subnormal: fWant = f.isSubnormal
                }
                #expect(fEncoded == (fWant ? 1 : 0), "\(kind) Float \(f)")
            }
        }
    }
}
