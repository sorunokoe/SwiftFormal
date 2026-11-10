// Reading guide
// Floating-point calls into the standard library that `-Onone` code makes instead of using builtins (plan item
// R6-3): the generic `abs(_:)`, `magnitude`, the conversions `Double(Float)`, `Float(Double)` and `Double(n)`/`Float(n)`
// of an integer, and `_roundSlowPath(_:)`, which `rounded(_:)` calls for a rounding rule it does not know. Each is
// computed exactly with the circuits of `SILFloatArithmetic.swift`, from the Swift 6.4 source of the standard
// library (`FloatingPointTypes.swift.gyb`, `Integers.swift`), and pinned with the other summaries
// (`Scripts/check-summary-pin.py`). Also here: the two standard-library enums floating-point code passes around,
// `FloatingPointRoundingRule` and `FloatingPointSign`, which logic reads like an enum of the module.
// Tests: Tests/SFSILTests/SILFloatSummaryTests.swift.

import SFBV
import SFSemantics

/// A floating-point call logic computes exactly (`ComputedSummary.float`).
package enum FloatSummary: Sendable, Hashable {
    /// `abs<T>(_:)`. For `Double`, `Float` and `Float16` (`T.Magnitude == T`) the standard library returns
    /// `x.magnitude`, the value with its sign bit cleared (so `abs(-0.0)` is `+0.0` and `abs(-nan)` a positive NaN);
    /// for a signed standard integer `x < 0 ? -x : x`, which traps on the minimum. Other types are refused.
    case absolute
    /// `Double.magnitude`, `Float.magnitude`: `int_fabs`, the sign bit cleared.
    case magnitude
    /// `Double(Float)` (`fpext`, exact) and `Float(Double)` (`fptrunc`, rounded to nearest even).
    case convert
    /// `Double(n)` and `Float(n)` for an integer `n` of a standard type (`sitofp`/`uitofp`, rounded to nearest even).
    case fromInteger
    /// `Double._roundSlowPath(_:)`, `Float._roundSlowPath(_:)`: `self.round(rule)`, the same switch over the rule as the
    /// inlined `rounded(_:)` (`int_round`, `int_rint`, `int_ceil`, `int_floor`, `int_trunc`, and for `awayFromZero`
    /// `floor` of a negative value and `ceil` of a positive one). Reached only for a rule outside the six cases, so
    /// never for a real value; never traps.
    case roundSlowPath
    /// `Double.bitPattern`, `Double(bitPattern:)` and `Float`'s: the same bits.
    case bitPattern
}

extension StdlibSummary {
    static func addFloatingPoint(to table: inout [String: Entry]) {
        func add(_ symbol: String, _ name: String, _ summary: FloatSummary, generic: Bool = false) {
            table[symbol] = Entry(name: name, summary: .computed(.float(summary)), isGeneric: generic)
        }
        add("$ss3absyxxSLRzs13SignedNumericRzlF", "abs(_:)", .absolute, generic: true)
        add("$sSd9magnitudeSdvg", "Double.magnitude", .magnitude)
        add("$sSf9magnitudeSfvg", "Float.magnitude", .magnitude)
        add("$sSdySdSfcfC", "Double(Float)", .convert)
        add("$sSfySfSdcfC", "Float(Double)", .convert)
        add("$sSdySdxcSzRzlufC", "Double.init(_:) of an integer", .fromInteger, generic: true)
        add("$sSfySfxcSzRzlufC", "Float.init(_:) of an integer", .fromInteger, generic: true)
        // CoreGraphics, not the standard library: `native = Double(n)` (`SILCGFloat.swift`); pinned all the same.
        add("$s12CoreGraphics7CGFloatVyACxcSzRzlufC", "CGFloat.init(_:) of an integer", .fromInteger, generic: true)
        add("$sSd14_roundSlowPathyys25FloatingPointRoundingRuleOF", "Double._roundSlowPath(_:)", .roundSlowPath)
        add("$sSf14_roundSlowPathyys25FloatingPointRoundingRuleOF", "Float._roundSlowPath(_:)", .roundSlowPath)
        add("$sSd10bitPatterns6UInt64Vvg", "Double.bitPattern", .bitPattern)
        add("$sSd10bitPatternSds6UInt64V_tcfC", "Double(bitPattern:)", .bitPattern)
        add("$sSf10bitPatterns6UInt32Vvg", "Float.bitPattern", .bitPattern)
        add("$sSf10bitPatternSfs6UInt32V_tcfC", "Float(bitPattern:)", .bitPattern)
    }
}

extension StdlibSummary.Entry {
    /// `Swift.min(x, y)` is `y < x ? y : x` and `Swift.max(x, y)` is `y >= x ? y : x` (`Comparable`'s witnesses for
    /// `Double`, `Float` and `Float16` are `fcmp_olt` and `fcmp_oge`): so `min(.nan, 1)` is NaN and `min(1, .nan)` is 1.
    /// Nil for any other type (integers are `extremum`'s).
    func floatExtremum(of values: [[BV]], subject: String?, in c: CNFBuilder) -> BV? {
        guard let subject,
            ["Double", "Float", "Float16", "CGFloat"].contains(subject.hasPrefix("Swift.") ? String(subject.dropFirst(6)) : subject),
            values.count == 2, values.allSatisfy({ $0.count == 1 }), values[0][0].width == values[1][0].width,
            let compare = S0FloatInstance(builtinName: "fcmp_\(summary == .minimum ? "olt" : "oge")_FPIEEE\(values[0][0].width)")
        else { return nil }
        let (x, y) = (values[0][0], values[1][0])
        return c.select(compare.encode(c, [y, x]).value.bits[0], y, x)
    }
}

extension FloatSummary {
    /// The cases of `FloatingPointRoundingRule`, in the order of its declaration (`FloatingPoint.swift`): the tag of
    /// a value is its index here.
    static let roundingRules = ["toNearestOrAwayFromZero", "toNearestOrEven", "up", "down", "towardZero", "awayFromZero"]

    func encode(_ call: ComputedCall, in c: CNFBuilder) throws -> ComputedEffect {
        // The operands that carry data, in order: a `@thin` metatype has no leaves, the `@out` address none either.
        let operands = zip(call.inputs, call.conventions).filter { $1 != .out && !$0.isEmpty }.map(\.0)
        func shape(_ ok: Bool) throws {
            guard ok else { throw SILError.invalid("\(call.name): operands of unexpected shape") }
        }
        try shape(operands.allSatisfy { $0.count == 1 })
        let values = operands.map { $0[0] }
        switch self {
        case .bitPattern:
            try shape(values.count == 1 && call.writtenTypes.isEmpty && call.resultType.leafWidths == [values[0].width])
            return ComputedEffect(result: [values[0]])
        case .magnitude:
            try shape(values.count == 1 && FloatFormat(width: values[0].width) != nil && call.writtenTypes.isEmpty)
            try shape(call.resultType.leafWidths == [values[0].width])
            return ComputedEffect(result: [Self.clearingSign(values[0], c)])
        case .absolute:
            try shape(values.count == 1 && call.substitutions.count == 1 && call.resultType.leafWidths.isEmpty)
            try shape(call.writtenTypes.map(\.leafWidths) == [[values[0].width]])
            return try Self.absolute(values[0], of: call.substitutions[0], c)
        case .convert:
            try shape(values.count == 1 && call.writtenTypes.isEmpty && call.resultType.leafWidths.count == 1)
            guard let source = FloatFormat(width: values[0].width), let target = FloatFormat(width: call.resultType.leafWidths[0]) else {
                throw SILError.invalid("\(call.name): not a floating-point conversion")
            }
            let r = FloatCircuit(c, target).convert(values[0], from: source)
            return ComputedEffect(result: [r.value], approximations: r.nan == c.falseLit ? [] : ["floating point"])
        case .fromInteger:
            try shape(values.count == 1 && call.substitutions.count == 1 && call.writtenTypes.isEmpty)
            try shape(call.resultType.leafWidths.count == 1)
            let subject = call.substitutions[0]
            guard let kind = StdlibSummary.integerKind(subject), subject != "Bool",
                let target = FloatFormat(width: call.resultType.leafWidths[0])
            else { throw SILError.unsupported("\(call.name) on \(subject), which is not a standard integer type") }
            return ComputedEffect(result: [FloatCircuit(c, target).fromInteger(values[0], signed: kind == .signed)])
        case .roundSlowPath:
            try shape(values.count == 2 && call.conventions == [.indirect, .inout] && call.resultType.leafWidths.isEmpty)
            return try Self.roundSlowPath(rule: values[0], values[1], call, c)
        }
    }

    /// `_roundSlowPath(rule)` on `x` (see `FloatSummary.roundSlowPath`), written back to the `@inout` value.
    static func roundSlowPath(rule: BV, _ x: BV, _ call: ComputedCall, _ c: CNFBuilder) throws -> ComputedEffect {
        guard let format = FloatFormat(width: x.width), call.writtenTypes.map(\.leafWidths) == [[x.width]],
            rule.width == ValueType.tagWidth(Self.roundingRules.count)
        else { throw SILError.invalid("\(call.name): operands of unexpected shape") }
        let circuit = FloatCircuit(c, format)
        let sign = x.bits[x.width - 1]
        let (down, up) = (circuit.roundToIntegral(x, .down), circuit.roundToIntegral(x, .up))
        let byRule: [(value: BV, nan: Int32)] = [
            circuit.roundToIntegral(x, .toNearestOrAwayFromZero), circuit.roundToIntegral(x, .toNearestOrEven), up, down,
            circuit.roundToIntegral(x, .towardZero), (c.select(sign, down.value, up.value), c.or(down.nan, up.nan)),
        ]
        var rounded = x  // a tag outside the six cases: no real value has one
        var nan = c.falseLit
        for (tag, r) in byRule.enumerated() {
            let chosen = c.eq(rule, c.constant(UInt64(tag), width: rule.width))
            rounded = c.select(chosen, r.value, rounded)
            nan = c.or(nan, c.and(chosen, r.nan))
        }
        return ComputedEffect(writtenBack: [rounded], approximations: nan == c.falseLit ? [] : ["floating point"])
    }

    static func clearingSign(_ x: BV, _ c: CNFBuilder) -> BV { BV(bits: Array(x.bits.dropLast()) + [c.falseLit]) }

    /// `abs(x)` at `subject` (see `FloatSummary.absolute`), written back to the `@out` result.
    static func absolute(_ x: BV, of subject: String, _ c: CNFBuilder) throws -> ComputedEffect {
        let name = subject.hasPrefix("Swift.") ? String(subject.dropFirst(6)) : subject
        if ["Double", "Float", "Float16", "CGFloat"].contains(name), FloatFormat(width: x.width) != nil {
            return ComputedEffect(writtenBack: [clearingSign(x, c)])
        }
        guard StdlibSummary.integerKind(name) == .signed else {
            throw SILError.unsupported("abs(_:) on \(subject), which is neither a standard floating-point nor a signed integer type")
        }
        let negative = x.bits[x.width - 1]
        let minimum = c.eq(x, c.constant(1 << UInt64(x.width - 1), width: x.width))
        return ComputedEffect(traps: [(minimum, "arithmetic overflow")], writtenBack: [c.select(negative, c.negate(x), x)])
    }
}

extension TypeContext {
    /// `FloatingPointRoundingRule` and `FloatingPointSign` of the standard library, with their cases in declaration
    /// order (`FloatingPoint.swift`); nil for any other name, and for a name a read module declares (one that is
    /// declared in both places is ambiguous, see `TypeNameCheck`).
    func standardFloatEnum(_ text: String) -> ValueType? {
        guard structs[text] == nil, enums[text] == nil, rejected[text] == nil else { return nil }
        let name = text.hasPrefix("Swift.") ? String(text.dropFirst(6)) : text
        let cases: [String]
        switch name {
        case "FloatingPointRoundingRule": cases = FloatSummary.roundingRules
        case "FloatingPointSign": cases = ["plus", "minus"]
        default: return nil
        }
        return .enumeration(name: name, cases: cases.map { ValueType.Case(name: $0, payload: nil) })
    }
}
