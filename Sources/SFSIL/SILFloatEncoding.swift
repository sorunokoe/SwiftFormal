// Reading guide
// The formats and roundings of `SILFloatArithmetic.swift`, the hook the SIL encoder calls for a floating-point builtin
// (`S0FloatInstance.encodeExactly`: the exact circuits where there is one, `S0FloatInstance.encode` otherwise), and the
// circuits' part of the semantics digest.

package import SFBV
package import SFSemantics

/// An IEEE 754 binary interchange format: binary16 (`Float16`), binary32 (`Float`) or binary64 (`Double`).
package struct FloatFormat: Sendable, Equatable {
    package let exponentBits: Int
    package let fractionBits: Int

    package init?(width: Int) {
        switch width {
        case 16: (exponentBits, fractionBits) = (5, 10)
        case 32: (exponentBits, fractionBits) = (8, 23)
        case 64: (exponentBits, fractionBits) = (11, 52)
        default: return nil
        }
    }

    var width: Int { 1 + exponentBits + fractionBits }
    var bias: Int { (1 << (exponentBits - 1)) - 1 }
    /// The exponent field of infinities and NaNs (all ones).
    var specialExponent: Int { (1 << exponentBits) - 1 }
}

/// The rounding of `int_trunc`, `int_floor`, `int_ceil`, `int_round` and `int_rint` (`FloatingPointRoundingRule`
/// without `awayFromZero`, which the standard library builds from `floor` and `ceil`).
package enum FloatRounding: Sendable, Hashable {
    case towardZero, down, up, toNearestOrAwayFromZero, toNearestOrEven
}

/// What a floating-point builtin computes: its value, when it is undefined (an `fptosi` that does not fit), and
/// whether the value is exact; it is not when it may be a NaN with a fresh sign and payload, or is unknown.
package struct ExactFloatEncoding {
    /// The result's bits.
    package let value: BV
    /// True when the operation is undefined (LLVM poison).
    package let undefined: Int32
    /// False when the value may be a fresh NaN or is unknown.
    package let exact: Bool
}

extension S0FloatInstance {
    /// The encoding of this builtin: exact circuits (`FloatCircuit`) for arithmetic, rounding to an integral value and
    /// conversions, `S0FloatInstance.encode` for the rest (`int_sqrt`, `frem`, `int_fma`, `int_minnum`, ...).
    package func encodeExactly(_ c: CNFBuilder, _ args: [BV]) -> ExactFloatEncoding {
        guard let format = FloatFormat(width: floatWidth) else { return fallback(c, args) }
        let circuit = FloatCircuit(c, format)
        switch op {
        case .toInteger:
            let base = encode(c, args)
            return ExactFloatEncoding(value: circuit.integerPart(args[0], width: resultWidth), undefined: base.undefined, exact: true)
        case .unknown:
            return conversion(c, args, from: format) ?? operation(circuit, args) ?? fallback(c, args)
        default:
            return fallback(c, args)
        }
    }

    /// `sitofp`, `uitofp`, `fpext` and `fptrunc`; nil for anything else.
    private func conversion(_ c: CNFBuilder, _ args: [BV], from format: FloatFormat) -> ExactFloatEncoding? {
        let parts = builtinName.split(separator: "_").map(String.init)
        guard parts.count == 3, let target = FloatFormat(width: resultWidth) else { return nil }
        switch parts[0] {
        case "sitofp", "uitofp":
            let value = FloatCircuit(c, target).fromInteger(args[0], signed: parts[0] == "sitofp")
            return ExactFloatEncoding(value: value, undefined: c.falseLit, exact: true)
        case "fpext", "fptrunc": return exact(FloatCircuit(c, target).convert(args[0], from: format), c)
        default: return nil
        }
    }

    private static let roundings: [String: FloatRounding] = [
        "int_trunc": .towardZero, "int_floor": .down, "int_ceil": .up, "int_round": .toNearestOrAwayFromZero,
        "int_rint": .toNearestOrEven, "int_nearbyint": .toNearestOrEven, "int_roundeven": .toNearestOrEven,
    ]

    /// `fadd`, `fsub`, `fmul`, `fdiv` and the roundings; nil for anything else.
    private func operation(_ circuit: FloatCircuit, _ args: [BV]) -> ExactFloatEncoding? {
        let head = builtinName.split(separator: "_").dropLast().joined(separator: "_")
        switch head {
        case "fadd": return exact(circuit.add(args[0], args[1]), circuit.c)
        case "fsub": return exact(circuit.add(args[0], args[1], subtract: true), circuit.c)
        case "fmul": return exact(circuit.multiply(args[0], args[1]), circuit.c)
        case "fdiv": return exact(circuit.divide(args[0], args[1]), circuit.c)
        default: return Self.roundings[head].map { exact(circuit.roundToIntegral(args[0], $0), circuit.c) }
        }
    }

    private func exact(_ r: (value: BV, nan: Int32), _ c: CNFBuilder) -> ExactFloatEncoding {
        ExactFloatEncoding(value: r.value, undefined: c.falseLit, exact: r.nan == c.falseLit)
    }

    private func fallback(_ c: CNFBuilder, _ args: [BV]) -> ExactFloatEncoding {
        let r = encode(c, args)
        return ExactFloatEncoding(value: r.value, undefined: r.undefined, exact: r.exact)
    }
}

extension FloatCircuit {
    /// The exact circuits on `patterns` (binary64 bit patterns, also read as binary32 and as integers), for the
    /// semantics digest (`SemanticsDigest.floatReport`): a change to what they compute changes every cache key.
    package static func digestReport(_ patterns: [UInt64]) -> String {
        var text = "FloatCircuit\n"
        let binary = ["fadd", "fsub", "fmul", "fdiv"].flatMap { op in [64, 32].map { "\(op)_FPIEEE\($0)" } }
        let rounding = ["int_trunc", "int_floor", "int_ceil", "int_round", "int_rint"].map { "\($0)_FPIEEE64" }
        let conversions = ["sitofp_Int64_FPIEEE64", "uitofp_Int32_FPIEEE32", "fptrunc_FPIEEE64_FPIEEE32", "fpext_FPIEEE32_FPIEEE64"]
        for name in binary + rounding + conversions + ["fptosi_FPIEEE64_Int64", "fptoui_FPIEEE64_Int8"] {
            guard let instance = S0FloatInstance(builtinName: name) else {
                text += "\(name) missing\n"
                continue
            }
            for a in patterns {
                for b in instance.operandWidths.count == 2 ? patterns : [0] {
                    let c = CNFBuilder()
                    let args = zip([a, b], instance.operandWidths).map { c.constant($0, width: $1) }
                    let r = instance.encodeExactly(c, args)
                    let value = c.constantValue(r.value).map { String($0, radix: 16) } ?? "nan"
                    text += "\(name) \(a) \(b) \(value) \(c.constantValue(BV(bits: [r.undefined])).map(String.init) ?? "?")\n"
                }
            }
        }
        return text
    }
}
