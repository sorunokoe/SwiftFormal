public import SFBV
import SFCNF

/// Records Swift's integer semantics as a circuit while a function body is written in ordinary Swift syntax.
///
/// `SymbolicInt` uses the operators Swift code already has (`+`, `-`, `*`, `/`, `%`, comparisons). Where real Swift
/// would trap (overflow, divide by zero, `Int.min / -1`) the operator records a trap condition instead.
/// Conditions inside a branch that is not taken do not count: `&&`, `||` and `then(_:else:)` guard them.
public final class SymbolicContext {
    let builder: CNFBuilder
    private var path: Int32
    private(set) var trapped: Int32

    init(builder: CNFBuilder) {
        self.builder = builder
        path = builder.trueLit
        trapped = builder.falseLit
    }

    func recordTrap(_ condition: Int32) {
        trapped = builder.or(trapped, builder.and(path, condition))
    }

    func guarded<T>(by condition: Int32, _ body: () -> T) -> T {
        let saved = path
        path = builder.and(path, condition)
        defer { path = saved }
        return body()
    }

    /// A constant of `width` bits. Traps if `value` does not fit.
    public func literal(_ value: Int, width: Int) -> SymbolicInt {
        precondition(Self.fits(value, width: width), "\(value) does not fit in Int\(width)")
        return SymbolicInt(context: self, bits: builder.constant(UInt64(bitPattern: Int64(value)), width: width))
    }

    static func fits(_ value: Int, width: Int) -> Bool {
        width >= 64 || (value >= -(1 << (width - 1)) && value < (1 << (width - 1)))
    }
}

/// A Boolean whose value is unknown, as a circuit literal.
public struct SymbolicBool {
    let context: SymbolicContext
    let literal: Int32

    /// The logical negation of `value`.
    public static prefix func ! (value: SymbolicBool) -> SymbolicBool {
        SymbolicBool(context: value.context, literal: -value.literal)
    }

    /// Short circuits like Swift: the right side only counts where the left side is true.
    public static func && (lhs: SymbolicBool, rhs: @autoclosure () -> SymbolicBool) -> SymbolicBool {
        let right = lhs.context.guarded(by: lhs.literal) { rhs() }
        return SymbolicBool(context: lhs.context, literal: lhs.context.builder.and(lhs.literal, right.literal))
    }

    /// Short circuits like Swift: the right side only counts where the left side is false.
    public static func || (lhs: SymbolicBool, rhs: @autoclosure () -> SymbolicBool) -> SymbolicBool {
        let right = lhs.context.guarded(by: -lhs.literal) { rhs() }
        return SymbolicBool(context: lhs.context, literal: lhs.context.builder.or(lhs.literal, right.literal))
    }

    /// `condition ? a : b`. Only the taken branch can trap.
    public func then(_ whenTrue: @autoclosure () -> SymbolicInt, else whenFalse: @autoclosure () -> SymbolicInt) -> SymbolicInt {
        let a = context.guarded(by: literal) { whenTrue() }
        let b = context.guarded(by: -literal) { whenFalse() }
        return SymbolicInt(context: context, bits: context.builder.select(literal, a.bits, b.bits))
    }

    /// Whether `lhs` and `rhs` have the same value: true when both are true or both are false.
    public static func == (lhs: SymbolicBool, rhs: SymbolicBool) -> SymbolicBool {
        SymbolicBool(context: lhs.context, literal: -lhs.context.builder.xor(lhs.literal, rhs.literal))
    }

    /// Whether `lhs` and `rhs` have different values (exclusive or).
    public static func != (lhs: SymbolicBool, rhs: SymbolicBool) -> SymbolicBool {
        SymbolicBool(context: lhs.context, literal: lhs.context.builder.xor(lhs.literal, rhs.literal))
    }
}

/// A signed integer of a fixed width (8, 16, 32 or 64 bits) whose value is unknown.
public struct SymbolicInt {
    let context: SymbolicContext
    let bits: BV

    /// The width in bits.
    public var width: Int { bits.width }

    init(context: SymbolicContext, bits: BV) {
        self.context = context
        self.bits = bits
    }

    // MARK: converting between widths

    /// `source` at `width` bits with the same value, as `Int(x)` converts an `Int32` or `Int32(x)` converts an `Int`.
    ///
    /// A wider `width` extends the sign and never traps. A narrower one records a trap where the value does not fit
    /// in `width` bits, as Swift's conversion traps; the result then holds the low `width` bits.
    ///
    /// ```swift
    /// // An `Int32` count widened to `Int` before it is doubled: the doubling cannot overflow.
    /// try proveSigned(widths: [32]) { v in
    ///     let count = SymbolicInt(v[0], width: 64)
    ///     return count * 2 >= count.literal(2 * Int(Int32.min))
    /// }   // .proved
    /// ```
    ///
    /// - Parameters:
    ///   - source: The value to convert.
    ///   - width: The width of the result, from 1 to 64 bits.
    public init(_ source: SymbolicInt, width: Int) {
        precondition(width >= 1 && width <= 64, "a SymbolicInt has 1 to 64 bits")
        let builder = source.context.builder
        if width >= source.width {
            self.init(context: source.context, bits: builder.signExtend(source.bits, to: width))
            return
        }
        let low = builder.truncate(source.bits, to: width)
        source.context.recordTrap(-builder.eq(builder.signExtend(low, to: source.width), source.bits))
        self.init(context: source.context, bits: low)
    }

    /// The low `width` bits of `source`, as `Int32(truncatingIfNeeded: x)` converts an `Int`. Never traps.
    ///
    /// A narrower `width` drops the high bits; a wider one extends the sign, as Swift does for a signed source.
    ///
    /// - Parameters:
    ///   - source: The value to convert.
    ///   - width: The width of the result, from 1 to 64 bits.
    public init(truncatingIfNeeded source: SymbolicInt, width: Int) {
        precondition(width >= 1 && width <= 64, "a SymbolicInt has 1 to 64 bits")
        let builder = source.context.builder
        let bits = width >= source.width ? builder.signExtend(source.bits, to: width) : builder.truncate(source.bits, to: width)
        self.init(context: source.context, bits: bits)
    }

    /// The bits of `source` read as an unsigned number, at a width at least as wide: the value of
    /// `Int64(UInt32(bitPattern: x))` for an `Int32` `x`. Never traps.
    ///
    /// The new high bits are zero, so a negative `source` becomes a large non-negative value when `width` is wider.
    ///
    /// - Parameters:
    ///   - source: The value whose bits are read as unsigned.
    ///   - width: The width of the result, from `source.width` to 64 bits.
    public init(zeroExtending source: SymbolicInt, width: Int) {
        precondition(width >= source.width && width <= 64, "zero extension needs a width from the source's to 64 bits")
        self.init(context: source.context, bits: source.context.builder.zeroExtend(source.bits, to: width))
    }

    /// A constant of the same width as `self`.
    public func literal(_ value: Int) -> SymbolicInt { context.literal(value, width: width) }

    private func lift(_ value: Int) -> SymbolicInt { literal(value) }

    private func flag(_ literal: Int32) -> SymbolicBool { SymbolicBool(context: context, literal: literal) }

    private func arithmetic(
        _ rhs: SymbolicInt,
        _ operation: (CNFBuilder, BV, BV) -> BV,
        trap: (CNFBuilder, BV, BV) -> Int32
    ) -> SymbolicInt {
        precondition(width == rhs.width, "operands must have the same width")
        context.recordTrap(trap(context.builder, bits, rhs.bits))
        return SymbolicInt(context: context, bits: operation(context.builder, bits, rhs.bits))
    }

    private func divisionTrap(_ c: CNFBuilder, _ a: BV, _ b: BV) -> Int32 {
        let isMin = c.eq(a, c.constant(1 << UInt64(a.width - 1), width: a.width))
        let minusOne = c.eq(b, c.constant(~0, width: b.width))
        return c.or(c.eq(b, c.constant(0, width: b.width)), c.and(isMin, minusOne))
    }

    // MARK: arithmetic that traps on overflow, like Swift

    /// The sum of `lhs` and `rhs`. Where Swift would trap, the context records a trap condition.
    public static func + (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicInt {
        lhs.arithmetic(rhs, { $0.addSigned($1, $2) }, trap: { $0.signedAddOverflows($1, $2) })
    }

    /// The difference of `lhs` and `rhs`. Where Swift would trap, the context records a trap condition.
    public static func - (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicInt {
        lhs.arithmetic(rhs, { $0.subSigned($1, $2) }, trap: { $0.signedSubOverflows($1, $2) })
    }

    /// The product of `lhs` and `rhs`. Where Swift would trap, the context records a trap condition.
    public static func * (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicInt {
        lhs.arithmetic(rhs, { $0.mul($1, $2) }, trap: { $0.signedMulOverflows($1, $2) })
    }

    /// The quotient of `lhs` and `rhs`. Where Swift would trap, the context records a trap condition.
    public static func / (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicInt {
        lhs.arithmetic(rhs, { $0.signedDivide($1, $2).quotient }, trap: lhs.divisionTrap)
    }

    /// The remainder of `lhs` and `rhs`. Where Swift would trap, the context records a trap condition.
    public static func % (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicInt {
        lhs.arithmetic(rhs, { $0.signedDivide($1, $2).remainder }, trap: lhs.divisionTrap)
    }

    /// The negation of `value`. Traps on the minimum value, like Swift.
    public static prefix func - (value: SymbolicInt) -> SymbolicInt { value.context.literal(0, width: value.width) - value }

    // MARK: wrapping arithmetic (`&+`, `&-`, `&*`) never traps

    /// The wrapping sum of `lhs` and `rhs`. Wraps around instead of trapping on overflow.
    public static func &+ (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicInt {
        lhs.arithmetic(rhs, { $0.addSigned($1, $2) }, trap: { c, _, _ in c.falseLit })
    }

    /// The wrapping difference of `lhs` and `rhs`. Wraps around instead of trapping on overflow.
    public static func &- (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicInt {
        lhs.arithmetic(rhs, { $0.subSigned($1, $2) }, trap: { c, _, _ in c.falseLit })
    }

    /// The wrapping product of `lhs` and `rhs`. Wraps around instead of trapping on overflow.
    public static func &* (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicInt {
        lhs.arithmetic(rhs, { $0.mul($1, $2) }, trap: { c, _, _ in c.falseLit })
    }

    // MARK: comparison

    /// Whether `lhs` is equal to `rhs`.
    public static func == (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicBool { lhs.flag(lhs.context.builder.eq(lhs.bits, rhs.bits)) }
    /// Whether `lhs` is not equal to `rhs`.
    public static func != (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicBool { !(lhs == rhs) }
    /// Whether `lhs` is less than `rhs`, as a signed comparison.
    public static func < (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicBool { lhs.flag(lhs.context.builder.slt(lhs.bits, rhs.bits)) }
    /// Whether `lhs` is less than or equal to `rhs`, as a signed comparison.
    public static func <= (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicBool { lhs.flag(lhs.context.builder.sle(lhs.bits, rhs.bits)) }
    /// Whether `lhs` is greater than `rhs`, as a signed comparison.
    public static func > (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicBool { rhs < lhs }
    /// Whether `lhs` is greater than or equal to `rhs`, as a signed comparison.
    public static func >= (lhs: SymbolicInt, rhs: SymbolicInt) -> SymbolicBool { rhs <= lhs }

    // MARK: integer literals on the right-hand side

    /// The sum of `lhs` and the integer `rhs`, taken at the width of `lhs`. Where Swift would trap, the context records a trap condition.
    public static func + (lhs: SymbolicInt, rhs: Int) -> SymbolicInt { lhs + lhs.lift(rhs) }
    /// The difference of `lhs` and the integer `rhs`, taken at the width of `lhs`. Where Swift would trap, the context records a trap condition.
    public static func - (lhs: SymbolicInt, rhs: Int) -> SymbolicInt { lhs - lhs.lift(rhs) }
    /// The product of `lhs` and the integer `rhs`, taken at the width of `lhs`. Where Swift would trap, the context records a trap condition.
    public static func * (lhs: SymbolicInt, rhs: Int) -> SymbolicInt { lhs * lhs.lift(rhs) }
    /// The quotient of `lhs` and the integer `rhs`, taken at the width of `lhs`. Where Swift would trap, the context records a trap condition.
    public static func / (lhs: SymbolicInt, rhs: Int) -> SymbolicInt { lhs / lhs.lift(rhs) }
    /// The remainder of `lhs` and the integer `rhs`, taken at the width of `lhs`. Where Swift would trap, the context records a trap condition.
    public static func % (lhs: SymbolicInt, rhs: Int) -> SymbolicInt { lhs % lhs.lift(rhs) }
    /// Whether `lhs` is equal to the integer `rhs`, taken at the width of `lhs`.
    public static func == (lhs: SymbolicInt, rhs: Int) -> SymbolicBool { lhs == lhs.lift(rhs) }
    /// Whether `lhs` is not equal to the integer `rhs`, taken at the width of `lhs`.
    public static func != (lhs: SymbolicInt, rhs: Int) -> SymbolicBool { lhs != lhs.lift(rhs) }
    /// Whether `lhs` is less than the integer `rhs`, taken at the width of `lhs`, as a signed comparison.
    public static func < (lhs: SymbolicInt, rhs: Int) -> SymbolicBool { lhs < lhs.lift(rhs) }
    /// Whether `lhs` is less than or equal to the integer `rhs`, taken at the width of `lhs`, as a signed comparison.
    public static func <= (lhs: SymbolicInt, rhs: Int) -> SymbolicBool { lhs <= lhs.lift(rhs) }
    /// Whether `lhs` is greater than the integer `rhs`, taken at the width of `lhs`, as a signed comparison.
    public static func > (lhs: SymbolicInt, rhs: Int) -> SymbolicBool { lhs > lhs.lift(rhs) }
    /// Whether `lhs` is greater than or equal to the integer `rhs`, taken at the width of `lhs`, as a signed comparison.
    public static func >= (lhs: SymbolicInt, rhs: Int) -> SymbolicBool { lhs >= lhs.lift(rhs) }
}

/// The smaller of `x` and `y`, as Swift's `min(_:_:)`. Never traps.
///
/// Both values must have the same width.
public func min(_ x: SymbolicInt, _ y: SymbolicInt) -> SymbolicInt {
    precondition(x.width == y.width, "operands must have the same width")
    return SymbolicInt(context: x.context, bits: x.context.builder.select((y < x).literal, y.bits, x.bits))
}

/// The smaller of `x` and the integer `y`, taken at the width of `x`. Never traps.
public func min(_ x: SymbolicInt, _ y: Int) -> SymbolicInt { min(x, x.literal(y)) }

/// The larger of `x` and `y`, as Swift's `max(_:_:)`. Never traps.
///
/// Both values must have the same width.
public func max(_ x: SymbolicInt, _ y: SymbolicInt) -> SymbolicInt {
    precondition(x.width == y.width, "operands must have the same width")
    return SymbolicInt(context: x.context, bits: x.context.builder.select((y >= x).literal, y.bits, x.bits))
}

/// The larger of `x` and the integer `y`, taken at the width of `x`. Never traps.
public func max(_ x: SymbolicInt, _ y: Int) -> SymbolicInt { max(x, x.literal(y)) }

/// What `proveSigned` found.
public enum SymbolicVerdict: Equatable, Sendable {
    /// For every input that meets `requires`: no trap, and the claim holds.
    case proved
    /// Real Swift would trap on these inputs (signed, one per input). Replay them.
    case mayTrap([Int64])
    /// No trap, but the claim is false for these inputs.
    case claimFails([Int64])
    case unknown
}

/// Proves, for every value of the given signed widths, that `body` never traps and its claim holds.
///
/// Write `body` with `SymbolicInt` the way you would write the function. `requires` narrows the inputs
/// like `#requires`. Two proofs run (no trap, then the claim), each accepted only after the proof checker agrees,
/// so a verdict tells you which of the two failed.
public func proveSigned(
    widths: [Int],
    conflictBudget: Int = 1_000_000,
    requires: (([SymbolicInt]) -> SymbolicBool)? = nil,
    claim body: @escaping ([SymbolicInt]) -> SymbolicBool
) throws -> SymbolicVerdict {
    func signed(_ raw: [UInt64]) -> [Int64] {
        zip(raw, widths).map { value, width in
            width == 64
                ? Int64(bitPattern: value)
                : (value >> UInt64(width - 1)) & 1 == 1 ? Int64(bitPattern: value | ~((1 << UInt64(width)) - 1)) : Int64(value)
        }
    }

    // Phase 1: reachable traps. The goal is "no trap while `requires` holds".
    let noTrap = try prove(inputWidths: widths, conflictBudget: conflictBudget) { c, raw in
        let context = SymbolicContext(builder: c)
        let inputs = raw.map { SymbolicInt(context: context, bits: $0) }
        let allowed = requires?(inputs).literal ?? c.trueLit
        _ = body(inputs)
        return c.or(-allowed, -context.trapped)
    }
    switch noTrap {
    case .counterexample(let values): return .mayTrap(signed(values))
    case .unknown: return .unknown
    case .proved: break
    }

    // Phase 2: the claim, for the inputs that do not trap.
    let claim = try prove(inputWidths: widths, conflictBudget: conflictBudget) { c, raw in
        let context = SymbolicContext(builder: c)
        let inputs = raw.map { SymbolicInt(context: context, bits: $0) }
        let allowed = requires?(inputs).literal ?? c.trueLit
        return c.or(-allowed, body(inputs).literal)
    }
    switch claim {
    case .proved: return .proved
    case .counterexample(let values): return .claimFails(signed(values))
    case .unknown: return .unknown
    }
}
