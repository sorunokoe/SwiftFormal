package import SFBV
import SFCNF

/// S0: the bit-vector core of Swift's lowered semantics. Each case is one family of `Builtin.*`
/// operations as they appear in SIL (`builtin "sadd_with_overflow_Int8"(...)`), with LLVM's meaning.
///
/// This file is the single declaration of that meaning. The reference interpreter (`evaluate`) and the
/// circuit encoder (`encode`) both live here, are keyed by the same table, and are cross-checked against
/// each other and against native Swift in the tests.
package enum S0Op: CaseIterable, Sendable {
    case add, sub, mul, sdiv, udiv, srem, urem
    case and, or, xor, shl, lshr, ashr
    case saddOverflow, uaddOverflow, ssubOverflow, usubOverflow, smulOverflow, umulOverflow
    case eq, ne, slt, sle, sgt, sge, ult, ule, ugt, uge
    case trunc, zext, sext
    case intExpect
    /// Bit counting and byte order (`int_ctlz`, `int_cttz` take a second `Int1`: is a zero input undefined).
    case ctlz, cttz, ctpop, bswap
    /// `assumeNonNegative`: the value itself; undefined when it is negative (the optimizer may assume it is not).
    case assumeNonNegative

    /// The SIL builtin name without its type suffix.
    package var base: String {
        switch self {
        case .add: "add"
        case .sub: "sub"
        case .mul: "mul"
        case .sdiv: "sdiv"
        case .udiv: "udiv"
        case .srem: "srem"
        case .urem: "urem"
        case .and: "and"
        case .or: "or"
        case .xor: "xor"
        case .shl: "shl"
        case .lshr: "lshr"
        case .ashr: "ashr"
        case .saddOverflow: "sadd_with_overflow"
        case .uaddOverflow: "uadd_with_overflow"
        case .ssubOverflow: "ssub_with_overflow"
        case .usubOverflow: "usub_with_overflow"
        case .smulOverflow: "smul_with_overflow"
        case .umulOverflow: "umul_with_overflow"
        case .eq: "cmp_eq"
        case .ne: "cmp_ne"
        case .slt: "cmp_slt"
        case .sle: "cmp_sle"
        case .sgt: "cmp_sgt"
        case .sge: "cmp_sge"
        case .ult: "cmp_ult"
        case .ule: "cmp_ule"
        case .ugt: "cmp_ugt"
        case .uge: "cmp_uge"
        case .trunc: "truncOrBitCast"
        case .zext: "zextOrBitCast"
        case .sext: "sextOrBitCast"
        case .intExpect: "int_expect"
        case .ctlz: "int_ctlz"
        case .cttz: "int_cttz"
        case .ctpop: "int_ctpop"
        case .bswap: "int_bswap"
        case .assumeNonNegative: "assumeNonNegative"
        }
    }

    /// Other spellings of the same operation: `trunc_Int64_Int32` is `truncOrBitCast_Int64_Int32` once the widths
    /// are known to differ, which `S0Instance` checks.
    var aliases: [String] {
        switch self {
        case .trunc: ["trunc"]
        case .zext: ["zext"]
        case .sext: ["sext"]
        default: []
        }
    }

    /// One operand of the instance's width, nothing else (casts too, at their source width).
    var isUnary: Bool { isCast || self == .ctpop || self == .bswap || self == .assumeNonNegative }

    var isCast: Bool { self == .trunc || self == .zext || self == .sext }
    var isSigned: Bool {
        switch self {
        case .sdiv, .srem, .saddOverflow, .ssubOverflow, .smulOverflow, .assumeNonNegative: true
        default: false
        }
    }
    var isOverflow: Bool {
        switch self {
        case .saddOverflow, .uaddOverflow, .ssubOverflow, .usubOverflow, .smulOverflow, .umulOverflow: true
        default: false
        }
    }
    var isComparison: Bool {
        switch self {
        case .eq, .ne, .slt, .sle, .sgt, .sge, .ult, .ule, .ugt, .uge: true
        default: false
        }
    }
}

package enum S0Outcome: Equatable, Sendable {
    /// Result values as zero-extended raw bits. Overflow operations return `[value, flag]`.
    case values([UInt64])
    /// The operation's precondition failed (zero divisor, `INT_MIN / -1`, shift amount >= width).
    /// A program that reaches this has no meaning, so a verifier must prove it unreachable.
    case undefined
}

/// One operation at concrete widths, as named in SIL, for example `sadd_with_overflow_Int8`.
package struct S0Instance: Equatable, Sendable {
    package let op: S0Op
    /// Operand width. For casts, the source width.
    package let width: Int
    /// Result width for casts, otherwise equal to `width`.
    package let resultWidth: Int

    package static let supportedWidths: Set<Int> = [1, 8, 16, 32, 64]

    package init?(op: S0Op, width: Int, resultWidth: Int? = nil) {
        let target = resultWidth ?? width
        guard Self.supportedWidths.contains(width), Self.supportedWidths.contains(target) else { return nil }
        switch op {
        case .trunc: guard target < width else { return nil }
        case .zext, .sext: guard target > width else { return nil }
        default: guard target == width else { return nil }
        }
        // Signed operations on a single bit are never emitted by Swift and are not modelled.
        if width == 1 && op.isSigned { return nil }
        // A byte swap needs whole bytes, and at least two of them.
        if op == .bswap && (width < 16 || width % 8 != 0) { return nil }
        self.op = op
        self.width = width
        self.resultWidth = target
    }

    /// Fail closed: any name outside the table returns nil. Names look like `cmp_slt_Int64`
    /// or `sextOrBitCast_Int8_Int64`.
    package init?(builtinName: String) {
        for op in S0Op.allCases {
            guard let base = ([op.base] + op.aliases).first(where: { builtinName.hasPrefix($0 + "_Int") }) else { continue }
            let suffix = builtinName.dropFirst(base.count + 1)
            let parts = suffix.split(separator: "_", omittingEmptySubsequences: false)
            let widths = parts.map { $0.hasPrefix("Int") ? Int($0.dropFirst(3)) : nil }
            guard widths.allSatisfy({ $0 != nil }) else { continue }
            let w = widths.compactMap { $0 }
            if op.isCast {
                guard w.count == 2, let i = S0Instance(op: op, width: w[0], resultWidth: w[1]) else { return nil }
                self = i
            } else {
                guard w.count == 1, let i = S0Instance(op: op, width: w[0]) else { return nil }
                self = i
            }
            return
        }
        return nil
    }

    package var builtinName: String {
        op.isCast ? "\(op.base)_Int\(width)_Int\(resultWidth)" : "\(op.base)_Int\(width)"
    }

    /// Number of operands. Overflow operations take a third `Int1` that only controls compile-time diagnostics.
    package var arity: Int { operandWidths.count }

    /// The width of each operand: `[width]` for one-operand operations, `[width, 1]` for `ctlz`/`cttz` (the flag says
    /// whether a zero input is undefined), `[width, width, 1]` for the overflow family, else `[width, width]`.
    package var operandWidths: [Int] {
        if op.isUnary { return [width] }
        if op == .ctlz || op == .cttz { return [width, 1] }
        return op.isOverflow ? [width, width, 1] : [width, width]
    }

    package var resultWidths: [Int] { op.isOverflow ? [width, 1] : (op.isComparison ? [1] : [resultWidth]) }

    // MARK: reference interpreter

    private static func mask(_ width: Int) -> UInt64 { width == 64 ? ~0 : (1 << UInt64(width)) - 1 }

    private func signed(_ x: UInt64) -> Int64 {
        let m = Self.mask(width)
        return (x >> UInt64(width - 1)) & 1 == 1 ? Int64(bitPattern: x | ~m) : Int64(bitPattern: x)
    }

    private func fits(_ x: Int64) -> Bool {
        width == 64 || (x >= -(1 << Int64(width - 1)) && x < (1 << Int64(width - 1)))
    }

    package func evaluate(_ args: [UInt64]) -> S0Outcome {
        precondition(args.count == arity)
        let m = Self.mask(width)
        let a = args[0] & m
        let b = arity > 1 ? args[1] & Self.mask(operandWidths[1]) : 0
        let (sa, sb) = (signed(a), signed(b))
        func bit(_ p: Bool) -> UInt64 { p ? 1 : 0 }
        switch op {
        case .add: return .values([(a &+ b) & m])
        case .sub: return .values([(a &- b) & m])
        case .mul: return .values([(a &* b) & m])
        case .and: return .values([a & b])
        case .or: return .values([a | b])
        case .xor: return .values([a ^ b])
        case .udiv: return b == 0 ? .undefined : .values([a / b])
        case .urem: return b == 0 ? .undefined : .values([a % b])
        case .sdiv, .srem:
            if b == 0 || (a == 1 << UInt64(width - 1) && sb == -1) { return .undefined }
            return .values([UInt64(bitPattern: op == .sdiv ? sa / sb : sa % sb) & m])
        case .shl: return b >= UInt64(width) ? .undefined : .values([(a << b) & m])
        case .lshr: return b >= UInt64(width) ? .undefined : .values([a >> b])
        case .ashr: return b >= UInt64(width) ? .undefined : .values([UInt64(bitPattern: sa >> Int64(b)) & m])
        case .uaddOverflow:
            let s = a &+ b
            return .values([s & m, bit(width == 64 ? s < a : s > m)])
        case .usubOverflow: return .values([(a &- b) & m, bit(a < b)])
        case .umulOverflow:
            let (p, o) = a.multipliedReportingOverflow(by: b)
            return .values([p & m, bit(o || p > m)])
        case .saddOverflow:
            let (r, o) = sa.addingReportingOverflow(sb)
            return .values([UInt64(bitPattern: r) & m, bit(o || !fits(r))])
        case .ssubOverflow:
            let (r, o) = sa.subtractingReportingOverflow(sb)
            return .values([UInt64(bitPattern: r) & m, bit(o || !fits(r))])
        case .smulOverflow:
            let (r, o) = sa.multipliedReportingOverflow(by: sb)
            return .values([UInt64(bitPattern: r) & m, bit(o || !fits(r))])
        case .eq: return .values([bit(a == b)])
        case .ne: return .values([bit(a != b)])
        case .slt: return .values([bit(sa < sb)])
        case .sle: return .values([bit(sa <= sb)])
        case .sgt: return .values([bit(sa > sb)])
        case .sge: return .values([bit(sa >= sb)])
        case .ult: return .values([bit(a < b)])
        case .ule: return .values([bit(a <= b)])
        case .ugt: return .values([bit(a > b)])
        case .uge: return .values([bit(a >= b)])
        case .trunc: return .values([a & Self.mask(resultWidth)])
        case .zext: return .values([a])
        case .sext: return .values([UInt64(bitPattern: sa) & Self.mask(resultWidth)])
        case .intExpect: return .values([a])
        case .ctlz, .cttz, .ctpop, .bswap, .assumeNonNegative: return evaluateBits(a, flag: b, signed: sa)
        }
    }

    // MARK: circuit encoder

    /// Result bits plus a literal that is true exactly when the operation is undefined.
    package func encode(_ c: CNFBuilder, _ args: [BV]) -> (values: [BV], undefined: Int32) {
        precondition(args.count == arity)
        let a = args[0]
        let b = arity > 1 ? args[1] : a
        func flag(_ lit: Int32) -> BV { BV(bits: [lit]) }
        let none = c.falseLit
        switch op {
        case .add: return ([c.addSigned(a, b)], none)
        case .sub: return ([c.subSigned(a, b)], none)
        case .mul: return ([c.mul(a, b)], none)
        case .and: return ([BV(bits: zip(a.bits, b.bits).map { c.and($0, $1) })], none)
        case .or: return ([BV(bits: zip(a.bits, b.bits).map { c.or($0, $1) })], none)
        case .xor: return ([BV(bits: zip(a.bits, b.bits).map { c.xor($0, $1) })], none)
        case .udiv, .urem:
            let (q, r) = c.unsignedDivide(a, b)
            return ([op == .udiv ? q : r], c.eq(b, c.constant(0, width: width)))
        case .sdiv, .srem:
            let (q, r) = c.signedDivide(a, b)
            let isMin = c.eq(a, c.constant(1 << UInt64(width - 1), width: width))
            let minusOne = c.eq(b, c.constant(~0, width: width))
            let bad = c.or(c.eq(b, c.constant(0, width: width)), c.and(isMin, minusOne))
            return ([op == .sdiv ? q : r], bad)
        case .shl: return ([c.shiftLeft(a, by: b)], c.shiftAmountOutOfRange(a, b))
        case .lshr: return ([c.logicalShiftRight(a, by: b)], c.shiftAmountOutOfRange(a, b))
        case .ashr: return ([c.arithmeticShiftRight(a, by: b)], c.shiftAmountOutOfRange(a, b))
        case .uaddOverflow: return ([c.add(a, b).sum, flag(c.unsignedAddOverflows(a, b))], none)
        case .usubOverflow: return ([c.sub(a, b).difference, flag(c.unsignedSubOverflows(a, b))], none)
        case .umulOverflow: return ([c.mul(a, b, narrowing: false), flag(c.unsignedMulOverflows(a, b))], none)
        case .saddOverflow: return ([c.addSigned(a, b), flag(c.signedAddOverflows(a, b))], none)
        case .ssubOverflow: return ([c.subSigned(a, b), flag(c.signedSubOverflows(a, b))], none)
        case .smulOverflow: return ([c.mul(a, b), flag(c.signedMulOverflows(a, b))], none)
        case .eq: return ([flag(c.eq(a, b))], none)
        case .ne: return ([flag(-c.eq(a, b))], none)
        case .slt: return ([flag(c.slt(a, b))], none)
        case .sle: return ([flag(c.sle(a, b))], none)
        case .sgt: return ([flag(c.slt(b, a))], none)
        case .sge: return ([flag(c.sle(b, a))], none)
        case .ult: return ([flag(c.ult(a, b))], none)
        case .ule: return ([flag(c.ule(a, b))], none)
        case .ugt: return ([flag(c.ult(b, a))], none)
        case .uge: return ([flag(c.ule(b, a))], none)
        case .trunc: return ([c.truncate(a, to: resultWidth)], none)
        case .zext: return ([c.zeroExtend(a, to: resultWidth)], none)
        case .sext: return ([c.signExtend(a, to: resultWidth)], none)
        case .intExpect: return ([a], none)
        case .ctlz, .cttz, .ctpop, .bswap, .assumeNonNegative: return encodeBits(c, a, flag: b)
        }
    }

    // MARK: bit counting, byte order, assumptions

    private func evaluateBits(_ a: UInt64, flag b: UInt64, signed sa: Int64) -> S0Outcome {
        switch op {
        case .ctlz, .cttz:
            if a == 0 { return b == 1 ? .undefined : .values([UInt64(width)]) }
            let count = op == .ctlz ? a.leadingZeroBitCount - (64 - width) : a.trailingZeroBitCount
            return .values([UInt64(count)])
        case .ctpop: return .values([UInt64(a.nonzeroBitCount)])
        case .bswap:
            var r: UInt64 = 0
            for byte in 0..<(width / 8) { r |= ((a >> UInt64(8 * byte)) & 0xFF) << UInt64(width - 8 - 8 * byte) }
            return .values([r])
        case .assumeNonNegative: return sa < 0 ? .undefined : .values([a])
        default: preconditionFailure("not a bit operation")
        }
    }

    private func encodeBits(_ c: CNFBuilder, _ a: BV, flag b: BV) -> (values: [BV], undefined: Int32) {
        let none = c.falseLit
        switch op {
        case .ctlz, .cttz:
            // Count the run of zero bits from the top (ctlz) or the bottom (cttz): bit k of the run is set when it and
            // every bit before it are zero, and the count is the number of such bits.
            let order = op == .ctlz ? Array(a.bits.reversed()) : a.bits
            var allZero = c.trueLit
            var count = c.constant(0, width: width)
            for bit in order {
                allZero = c.and(allZero, -bit)
                count = c.add(count, c.zeroExtend(BV(bits: [allZero]), to: width)).sum
            }
            let zero = c.eq(a, c.constant(0, width: width))
            return ([count], c.and(zero, b.bits[0]))
        case .ctpop:
            var count = c.constant(0, width: width)
            for bit in a.bits { count = c.add(count, c.zeroExtend(BV(bits: [bit]), to: width)).sum }
            return ([count], none)
        case .bswap:
            let bytes = stride(from: 0, to: width, by: 8).map { Array(a.bits[$0..<($0 + 8)]) }
            return ([BV(bits: bytes.reversed().flatMap { $0 })], none)
        case .assumeNonNegative: return ([a], a.bits[width - 1])
        default: preconditionFailure("not a bit operation")
        }
    }
}
