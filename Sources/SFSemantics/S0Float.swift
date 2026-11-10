package import SFBV
import SFCNF

/// Floating-point builtins (`Builtin.FPIEEE16/32/64`), on their IEEE 754 bit patterns (plan item L1).
///
/// Exact: bit casts, `fneg`, `fabs`, `copysign`, the 16 `fcmp` predicates, and when a conversion to an integer is
/// undefined (NaN, or a value whose integer part does not fit). Every other operation (arithmetic, rounding, square
/// root, conversions from integers or between widths) gives an unknown value: logic does not compute floating-point
/// results, but none of these operations can trap or be undefined, so an unknown result is sound. Callers record such
/// results as approximations, so that a counterexample resting on one is not reported as a bug. The SIL encoder
/// computes arithmetic, rounding and conversions exactly instead (`FloatCircuit` in SFSIL, plan item R6-3).
package enum S0FloatOp: Hashable, Sendable {
    /// `bitcast_FPIEEE64_Int64` (`toInteger`) and `bitcast_Int64_FPIEEE64`: the same bits.
    case bitcast(toInteger: Bool)
    case negate, absolute, copySign
    /// `fcmp_<predicate>`: `oeq`, `ogt`, `oge`, `olt`, `ole`, `one`, `ord`, `ueq`, `ugt`, `uge`, `ult`, `ule`, `une`,
    /// `uno`, `true`, `false`.
    case compare(String)
    /// `fptosi` / `fptoui`: the integer part; undefined when it does not fit (or the value is NaN or infinite).
    case toInteger(signed: Bool)
    /// Everything else: the operands are read, the result is unknown.
    case unknown(arity: Int)

    static let predicates: Set<String> = [
        "oeq", "ogt", "oge", "olt", "ole", "one", "ord", "ueq", "ugt", "uge", "ult", "ule", "une", "uno", "true", "false",
    ]
    static let unaryUnknown: Set<String> = [
        "int_floor", "int_ceil", "int_trunc", "int_round", "int_rint", "int_nearbyint", "int_sqrt", "int_roundeven",
    ]
    static let binaryUnknown: Set<String> = [
        "fadd", "fsub", "fmul", "fdiv", "frem", "int_minnum", "int_maxnum", "int_minimum", "int_maximum",
    ]
}

/// What an operation gives on concrete bits: a value, undefined, or a value logic does not compute.
package enum S0FloatOutcome: Equatable, Sendable {
    case values([UInt64])
    case undefined
    case unknown
}

package struct S0FloatInstance: Hashable, Sendable {
    package let op: S0FloatOp
    package let operandWidths: [Int]
    package let resultWidth: Int
    /// The floating-point width the operation is about (the source of a conversion to an integer).
    package let floatWidth: Int
    /// The builtin's name (`fadd_FPIEEE64`). SFSIL computes arithmetic and rounding exactly from it (`FloatCircuit`).
    package let builtinName: String

    /// Fail closed: any name outside the table returns nil.
    package init?(builtinName name: String) {
        let parts = name.split(separator: "_").map(String.init)
        guard let parsed = Self.conversion(parts) ?? Self.operation(parts) else { return nil }
        (op, operandWidths, resultWidth, floatWidth) = (parsed.op, parsed.operands, parsed.result, parsed.float)
        builtinName = name
    }

    private struct Parsed {
        let op: S0FloatOp
        let operands: [Int]
        let result: Int
        let float: Int

        init(_ op: S0FloatOp, _ operands: [Int], _ result: Int, _ float: Int) {
            (self.op, self.operands, self.result, self.float) = (op, operands, result, float)
        }
    }

    private static func float(_ text: String) -> Int? {
        guard text.hasPrefix("FPIEEE"), let w = Int(text.dropFirst(6)), [16, 32, 64].contains(w) else { return nil }
        return w
    }

    private static func integer(_ text: String) -> Int? {
        guard text.hasPrefix("Int"), let w = Int(text.dropFirst(3)), [8, 16, 32, 64].contains(w) else { return nil }
        return w
    }

    /// `bitcast_A_B`, `fptosi_F_I`, `sitofp_I_F`, `fpext_F_G`, ...: two widths in the name.
    private static func conversion(_ parts: [String]) -> Parsed? {
        guard parts.count == 3 else { return nil }
        let (kind, from, to) = (parts[0], parts[1], parts[2])
        if kind == "bitcast" {
            if let f = float(from), let i = integer(to), f == i { return Parsed(.bitcast(toInteger: true), [f], i, f) }
            if let i = integer(from), let f = float(to), f == i { return Parsed(.bitcast(toInteger: false), [i], f, f) }
            return nil
        }
        if kind == "fptosi" || kind == "fptoui", let f = float(from), let i = integer(to) {
            return Parsed(.toInteger(signed: kind == "fptosi"), [f], i, f)
        }
        if kind == "sitofp" || kind == "uitofp", let i = integer(from), let f = float(to) { return Parsed(.unknown(arity: 1), [i], f, f) }
        guard kind == "fpext" || kind == "fptrunc", let a = float(from), let b = float(to), kind == "fpext" ? a < b : a > b else {
            return nil
        }
        return Parsed(.unknown(arity: 1), [a], b, a)
    }

    /// `fadd_FPIEEE64`, `fcmp_olt_FPIEEE64`, `int_fabs_FPIEEE32`, ...: one width, last.
    private static func operation(_ parts: [String]) -> Parsed? {
        guard let last = parts.last, let w = float(last) else { return nil }
        let head = parts.dropLast().joined(separator: "_")
        if head.hasPrefix("fcmp_"), S0FloatOp.predicates.contains(String(head.dropFirst(5))) {
            return Parsed(.compare(String(head.dropFirst(5))), [w, w], 1, w)
        }
        let named: [String: (S0FloatOp, Int)] = ["fneg": (.negate, 1), "int_fabs": (.absolute, 1), "int_copysign": (.copySign, 2)]
        if let (op, arity) = named[head] { return Parsed(op, Array(repeating: w, count: arity), w, w) }
        let arity = head == "int_fma" ? 3 : (S0FloatOp.unaryUnknown.contains(head) ? 1 : (S0FloatOp.binaryUnknown.contains(head) ? 2 : 0))
        return arity == 0 ? nil : Parsed(.unknown(arity: arity), Array(repeating: w, count: arity), w, w)
    }

    /// Exponent and fraction field widths of the IEEE format.
    private var fields: (exponent: Int, fraction: Int) {
        switch floatWidth {
        case 16: (5, 10)
        case 32: (8, 23)
        default: (11, 52)
        }
    }

    // MARK: reference interpreter (integer arithmetic on the bit patterns)

    private static func mask(_ width: Int) -> UInt64 { width == 64 ? ~0 : (1 << UInt64(width)) - 1 }

    private func isNaN(_ x: UInt64) -> Bool {
        let (e, f) = fields
        return (x >> UInt64(f)) & Self.mask(e) == Self.mask(e) && x & Self.mask(f) != 0
    }

    /// `|x|` as an integer: for non-NaN values, the order of magnitudes is the order of these integers.
    private func magnitude(_ x: UInt64) -> UInt64 { x & Self.mask(floatWidth - 1) }
    private func sign(_ x: UInt64) -> Bool { (x >> UInt64(floatWidth - 1)) & 1 == 1 }

    private func orderedLess(_ a: UInt64, _ b: UInt64) -> Bool {
        let (ma, mb) = (magnitude(a), magnitude(b))
        if ma == 0 && mb == 0 { return false }
        switch (sign(a), sign(b)) {
        case (true, false): return true
        case (false, true): return false
        case (false, false): return ma < mb
        case (true, true): return mb < ma
        }
    }

    private func orderedEqual(_ a: UInt64, _ b: UInt64) -> Bool { a == b || (magnitude(a) == 0 && magnitude(b) == 0) }

    package func evaluate(_ args: [UInt64]) -> S0FloatOutcome {
        precondition(args.count == operandWidths.count)
        let x = args[0] & Self.mask(operandWidths[0])
        switch op {
        case .bitcast: return .values([x])
        case .negate: return .values([x ^ (1 << UInt64(floatWidth - 1))])
        case .absolute: return .values([magnitude(x)])
        case .copySign: return .values([magnitude(x) | (args[1] & (1 << UInt64(floatWidth - 1)))])
        case .compare(let predicate): return .values([evaluateCompare(predicate, x, args[1] & Self.mask(floatWidth)) ? 1 : 0])
        case .toInteger(let signed):
            let limits = integerLimits(signed: signed)
            let m = magnitude(x)
            let out = isNaN(x) || (sign(x) ? m >= limits.negative : m >= limits.positive)
            return out ? .undefined : .unknown
        case .unknown: return .unknown
        }
    }

    private func evaluateCompare(_ predicate: String, _ x: UInt64, _ y: UInt64) -> Bool {
        let relations = Relations(
            unordered: isNaN(x) || isNaN(y), less: orderedLess(x, y), greater: orderedLess(y, x), equal: orderedEqual(x, y))
        return relations.decide(predicate, not: { !$0 }, and: { $0 && $1 }, or: { $0 || $1 }, constant: { $0 })
    }

    /// Magnitudes (as bit patterns) from which the integer part no longer fits: `positive` for `x >= 0`, `negative` for
    /// `x < 0`. The integer part of `x` fits a signed n-bit integer when `-2^(n-1) - 1 < x < 2^(n-1)`, an unsigned one when
    /// `-1 < x < 2^n`. A limit above the largest finite value is infinity's bit pattern, so only infinity reaches it.
    func integerLimits(signed: Bool) -> (positive: UInt64, negative: UInt64) {
        let (e, f) = fields
        let bias = (1 << (e - 1)) - 1
        let infinity = Self.mask(e) << UInt64(f)
        /// The bit pattern of the smallest value of the format that is `>= 2^k + (plusOne ? 1 : 0)`.
        func atLeast(_ k: Int, plusOne: Bool) -> UInt64 {
            guard k + bias < (1 << e) - 1 else { return infinity }
            let exponent = UInt64(k + bias) << UInt64(f)
            guard plusOne else { return exponent }
            // 2^k + 1 needs a fraction of 2^(f-k); with fewer fraction bits the next value up is fraction 1.
            let fraction: UInt64 = k <= f ? 1 << UInt64(f - k) : 1
            return exponent | fraction
        }
        let n = resultWidth
        if signed { return (atLeast(n - 1, plusOne: false), atLeast(n - 1, plusOne: true)) }
        return (atLeast(n, plusOne: false), atLeast(0, plusOne: false))
    }

    // MARK: circuit encoder

    /// Result bits, a literal true exactly when the operation is undefined, and whether the result is exact (false: the
    /// result is a fresh, unconstrained value).
    package func encode(_ c: CNFBuilder, _ args: [BV]) -> S0FloatEncoding {
        precondition(args.map(\.width) == operandWidths)
        let x = args[0]
        let top = floatWidth - 1
        switch op {
        case .bitcast: return S0FloatEncoding(x, c.falseLit, exact: true)
        case .negate: return S0FloatEncoding(BV(bits: Array(x.bits[0..<top]) + [-x.bits[top]]), c.falseLit, exact: true)
        case .absolute: return S0FloatEncoding(BV(bits: Array(x.bits[0..<top]) + [c.falseLit]), c.falseLit, exact: true)
        case .copySign: return S0FloatEncoding(BV(bits: Array(x.bits[0..<top]) + [args[1].bits[top]]), c.falseLit, exact: true)
        case .compare(let predicate): return S0FloatEncoding(BV(bits: [compare(c, predicate, x, args[1])]), c.falseLit, exact: true)
        case .toInteger(let signed):
            let limits = integerLimits(signed: signed)
            let m = BV(bits: Array(x.bits[0..<top]))
            let negativeTooBig = c.and(x.bits[top], c.ule(c.constant(limits.negative, width: top), m))
            let positiveTooBig = c.and(-x.bits[top], c.ule(c.constant(limits.positive, width: top), m))
            let tooBig = c.or(negativeTooBig, positiveTooBig)
            return S0FloatEncoding(c.input(width: resultWidth), c.or(isNaN(c, x), tooBig), exact: false)
        case .unknown: return S0FloatEncoding(c.input(width: resultWidth), c.falseLit, exact: false)
        }
    }

    private func isNaN(_ c: CNFBuilder, _ x: BV) -> Int32 {
        let (e, f) = fields
        let exponent = x.bits[f..<(f + e)].reduce(c.trueLit) { c.and($0, $1) }
        let fraction = x.bits[0..<f].reduce(c.falseLit) { c.or($0, $1) }
        return c.and(exponent, fraction)
    }

    private func compare(_ c: CNFBuilder, _ predicate: String, _ a: BV, _ b: BV) -> Int32 {
        let top = floatWidth - 1
        let (ma, mb) = (BV(bits: Array(a.bits[0..<top])), BV(bits: Array(b.bits[0..<top])))
        let (sa, sb) = (a.bits[top], b.bits[top])
        let zero = c.constant(0, width: top)
        let bothZero = c.and(c.eq(ma, zero), c.eq(mb, zero))
        let unordered = c.or(isNaN(c, a), isNaN(c, b))
        // a < b on non-NaN values: negative below positive (unless both are zeros), magnitudes otherwise.
        func less(_ sx: Int32, _ mx: BV, _ sy: Int32, _ my: BV) -> Int32 {
            let mixed = c.and(sx, -sy)
            let positive = c.and(c.and(-sx, -sy), c.ult(mx, my))
            let negative = c.and(c.and(sx, sy), c.ult(my, mx))
            return c.and(-bothZero, c.or(mixed, c.or(positive, negative)))
        }
        let relations = Relations(
            unordered: unordered, less: less(sa, ma, sb, mb), greater: less(sb, mb, sa, ma), equal: c.or(c.eq(a, b), bothZero))
        return relations.decide(predicate, not: { -$0 }, and: { c.and($0, $1) }, or: { c.or($0, $1) }, constant: { c.constant($0) })
    }
}

/// The four facts every `fcmp` predicate is made of, as booleans (interpreter) or literals (circuit).
private struct Relations<T> {
    let unordered: T
    let less: T
    let greater: T
    let equal: T

    /// The value of `predicate`: `o…` holds when neither operand is NaN and the relation holds, `u…` when either is NaN or
    /// the relation holds.
    func decide(_ predicate: String, not: (T) -> T, and: (T, T) -> T, or: (T, T) -> T, constant: (Bool) -> T) -> T {
        switch predicate {
        case "false", "true": return constant(predicate == "true")
        case "ord": return not(unordered)
        case "uno": return unordered
        default:
            let relation = self.relation(String(predicate.dropFirst()), not: not, or: or)
            return predicate.hasPrefix("o") ? and(not(unordered), relation) : or(unordered, relation)
        }
    }

    private func relation(_ name: String, not: (T) -> T, or: (T, T) -> T) -> T {
        switch name {
        case "eq": equal
        case "gt": greater
        case "ge": or(greater, equal)
        case "lt": less
        case "le": or(less, equal)
        default: not(equal)  // "ne"
        }
    }
}

/// What `S0FloatInstance.encode` gives: the result, when it is undefined, and whether the result is exact (false: a
/// fresh, unconstrained value).
package struct S0FloatEncoding {
    /// The result bits.
    package let value: BV
    /// True exactly when the operation is undefined.
    package let undefined: Int32
    /// False when `value` is a fresh input standing for a result logic does not compute.
    package let exact: Bool

    init(_ value: BV, _ undefined: Int32, exact: Bool) {
        self.value = value
        self.undefined = undefined
        self.exact = exact
    }
}

/// A floating-point classification (`Double.isFinite`, `isNaN`, ...), exact on the bit pattern.
package enum S0FloatClass: Hashable, Sendable {
    case finite, nan, infinite, zero, normal, subnormal

    /// Whether `bits` (a value of the IEEE format of that width) is in this class.
    package func evaluate(_ bits: UInt64, width: Int) -> Bool {
        let (e, f) = S0FloatClass.fields(width)
        let exponent = (bits >> UInt64(f)) & ((1 << UInt64(e)) - 1), fraction = bits & ((1 << UInt64(f)) - 1)
        let (allOnes, zeroExponent, zeroFraction) = (exponent == (1 << UInt64(e)) - 1, exponent == 0, fraction == 0)
        return decide(allOnes: allOnes, zeroExponent: zeroExponent, zeroFraction: zeroFraction)
    }

    package func encode(_ c: CNFBuilder, _ x: BV) -> Int32 {
        let (e, f) = S0FloatClass.fields(x.width)
        let exponent = x.bits[f..<(f + e)], fraction = x.bits[0..<f]
        let allOnes = exponent.reduce(c.trueLit) { c.and($0, $1) }
        let zeroExponent = -exponent.reduce(c.falseLit) { c.or($0, $1) }
        let zeroFraction = -fraction.reduce(c.falseLit) { c.or($0, $1) }
        switch self {
        case .finite: return -allOnes
        case .nan: return c.and(allOnes, -zeroFraction)
        case .infinite: return c.and(allOnes, zeroFraction)
        case .zero: return c.and(zeroExponent, zeroFraction)
        case .normal: return c.and(-zeroExponent, -allOnes)
        case .subnormal: return c.and(zeroExponent, -zeroFraction)
        }
    }

    private func decide(allOnes: Bool, zeroExponent: Bool, zeroFraction: Bool) -> Bool {
        switch self {
        case .finite: !allOnes
        case .nan: allOnes && !zeroFraction
        case .infinite: allOnes && zeroFraction
        case .zero: zeroExponent && zeroFraction
        case .normal: !zeroExponent && !allOnes
        case .subnormal: zeroExponent && !zeroFraction
        }
    }

    static func fields(_ width: Int) -> (exponent: Int, fraction: Int) {
        switch width {
        case 16: (5, 10)
        case 32: (8, 23)
        default: (11, 52)
        }
    }
}
