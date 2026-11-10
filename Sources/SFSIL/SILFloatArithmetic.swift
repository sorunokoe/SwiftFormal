// Reading guide
// Exact IEEE 754 arithmetic for the floating-point builtins that `S0Float` leaves unknown (plan item R6-3): `fadd`,
// `fsub`, `fmul`, `fdiv`, the five roundings to an integral value (`int_trunc`, `int_floor`, `int_ceil`, `int_round`,
// `int_rint` and its synonyms), the value of `fptosi`/`fptoui`, `sitofp`/`uitofp` and `fpext`/`fptrunc`. Each is a
// circuit over the operands' bit patterns, written once for binary16, binary32 and binary64 (`FloatFormat`), that
// rounds to nearest, ties to even (the default floating-point environment: the only one Swift code runs in unless C
// code changes it, see TRUST.md). Subnormals are kept (no flush to zero), -0.0 is distinct from +0.0, and a result
// that IEEE 754 says is NaN is *any* NaN: its sign and payload are fresh, because LLVM leaves them unspecified (they
// differ between arm64 and x86, and between a folded constant and the hardware). Such results are recorded as an
// approximation, so a counterexample is kept only if it fails for every NaN the operation could return.
// `S0FloatInstance.encodeExactly` is the hook the encoder calls; `FloatSummaries` uses the same circuits.
// Tests: Tests/SFSILTests/SILFloatArithmeticTests.swift (bit for bit against the hardware, edge and random operands).

package import SFBV

/// Circuits for one format. Signed exponents on the way are two's complement integers of `exponentWidth` bits, wide
/// enough for every intermediate value of every format (a binary64 product's exponent is within ±2,200).
package struct FloatCircuit {
    let c: CNFBuilder
    let format: FloatFormat
    let exponentWidth = 18

    /// Circuits of `format`, built in `c`.
    package init(_ c: CNFBuilder, _ format: FloatFormat) {
        self.c = c
        self.format = format
    }

    /// The parts of a value.
    struct Unpacked {
        let sign: Int32
        /// Everything but the sign: exponent field and fraction, as one unsigned integer that orders magnitudes.
        let magnitude: BV
        let exponentField: BV
        /// The fraction with the hidden bit on top (0 for zero and subnormals).
        let significand: BV
        /// The exponent field, or 1 for zero and subnormals: the value is `significand × 2^(effective - bias - F)`.
        let effectiveExponent: BV
        let isZero: Int32
        let isInfinite: Int32
        let isNaN: Int32
        /// A NaN whose quiet bit (the top fraction bit) is clear.
        let isSignaling: Int32
    }

    func unpack(_ x: BV) -> Unpacked {
        let (e, f) = (format.exponentBits, format.fractionBits)
        let fraction = Array(x.bits[0..<f])
        let exponent = Array(x.bits[f..<(f + e)])
        let hidden = any(exponent[...])
        let allOnes = every(exponent[...])
        let fractionSet = any(fraction[...])
        return Unpacked(
            sign: x.bits[f + e], magnitude: BV(bits: Array(x.bits[0..<(f + e)])), exponentField: BV(bits: exponent),
            significand: BV(bits: fraction + [hidden]),
            effectiveExponent: BV(bits: [c.or(exponent[0], -hidden)] + exponent.dropFirst()),
            isZero: c.and(-hidden, -fractionSet), isInfinite: c.and(allOnes, -fractionSet), isNaN: c.and(allOnes, fractionSet),
            isSignaling: c.and(c.and(allOnes, fractionSet), -fraction[f - 1]))
    }

    // MARK: operations

    /// `fadd`, or `fsub` when `subtract`. The second boolean is true when the result is NaN (a fresh one).
    package func add(_ a: BV, _ b: BV, subtract: Bool = false) -> (value: BV, nan: Int32) {
        let f = format.fractionBits
        let b = subtract ? BV(bits: Array(b.bits.dropLast()) + [-b.bits[b.width - 1]]) : b
        let (ua, ub) = (unpack(a), unpack(b))
        // x is the operand of larger magnitude, so the difference of significands is never negative.
        let swap = c.ult(ua.magnitude, ub.magnitude)
        let (x, y) = (unpack(c.select(swap, b, a)), unpack(c.select(swap, a, b)))
        let distance = c.sub(x.effectiveExponent, y.effectiveExponent).difference
        // Three bits below the significand (guard, round, sticky) and a carry bit above it.
        let low = [Int32](repeating: c.falseLit, count: 3)
        let big = BV(bits: low + x.significand.bits + [c.falseLit])
        let (aligned, lost) = shiftRightSticky(BV(bits: low + y.significand.bits + [c.falseLit]), by: distance)
        let small = BV(bits: [c.or(aligned.bits[0], lost)] + aligned.bits.dropFirst())
        let sameSign = -c.xor(x.sign, y.sign)
        let sum = c.select(sameSign, c.add(big, small).sum, c.sub(big, small).difference)
        let lsb = minus(widen(x.effectiveExponent), constant(format.bias + f + 3))
        // An exact zero is +0, except for (-0) + (-0): only then are both signs negative.
        let zero = signedZero(c.and(ua.sign, ub.sign))
        let finite = c.select(-any(sum.bits[...]), zero, round(sign: x.sign, significand: sum, sticky: c.falseLit, exponent: lsb))
        let nan = c.or(c.or(ua.isNaN, ub.isNaN), c.and(c.and(ua.isInfinite, ub.isInfinite), c.xor(ua.sign, ub.sign)))
        let infinite = c.or(ua.isInfinite, ub.isInfinite)
        let infiniteValue = c.select(ua.isInfinite, infinity(ua.sign), infinity(ub.sign))
        return result(nan: nan, signaling: c.or(ua.isSignaling, ub.isSignaling), c.select(infinite, infiniteValue, finite))
    }

    /// `fmul`.
    package func multiply(_ a: BV, _ b: BV) -> (value: BV, nan: Int32) {
        let f = format.fractionBits
        let (ua, ub) = (unpack(a), unpack(b))
        let sign = c.xor(ua.sign, ub.sign)
        let product = multiplySignificands(ua.significand, ub.significand)
        let lsb = minus(plus(widen(ua.effectiveExponent), widen(ub.effectiveExponent)), constant(2 * (format.bias + f)))
        // A zero operand gives a zero product, which `round` returns as a zero of the product's sign.
        let finite = round(sign: sign, significand: product, sticky: c.falseLit, exponent: lsb)
        let nan = c.or(c.or(ua.isNaN, ub.isNaN), c.or(c.and(ua.isInfinite, ub.isZero), c.and(ua.isZero, ub.isInfinite)))
        let signaling = c.or(ua.isSignaling, ub.isSignaling)
        return result(nan: nan, signaling: signaling, c.select(c.or(ua.isInfinite, ub.isInfinite), infinity(sign), finite))
    }

    /// `fdiv`. Dividing a nonzero number by zero is an infinity, not a trap.
    package func divide(_ a: BV, _ b: BV) -> (value: BV, nan: Int32) {
        let f = format.fractionBits
        let (ua, ub) = (unpack(a), unpack(b))
        let sign = c.xor(ua.sign, ub.sign)
        // Normalized significands (subnormals too), so the quotient has f + 3 or f + 4 significant bits.
        let (na, shiftA) = normalize(ua.significand)
        let (nb, shiftB) = normalize(ub.significand)
        var remainder = c.zeroExtend(na, to: f + 2)
        let divisor = c.zeroExtend(nb, to: f + 2)
        var quotient = [Int32](repeating: c.falseLit, count: f + 4)
        for k in 0..<(f + 4) {
            let (difference, borrow) = c.sub(remainder, divisor)
            quotient[f + 3 - k] = -borrow
            remainder = c.select(-borrow, difference, remainder)
            if k < f + 3 { remainder = BV(bits: [c.falseLit] + remainder.bits.dropLast()) }
        }
        let exponentA = minus(widen(ua.effectiveExponent), shiftA)
        let exponentB = minus(widen(ub.effectiveExponent), shiftB)
        let lsb = minus(minus(exponentA, exponentB), constant(f + 3))
        let finite = round(sign: sign, significand: BV(bits: quotient), sticky: any(remainder.bits[...]), exponent: lsb)
        let nan = c.or(c.or(ua.isNaN, ub.isNaN), c.or(c.and(ua.isInfinite, ub.isInfinite), c.and(ua.isZero, ub.isZero)))
        let infinite = c.or(ua.isInfinite, ub.isZero)
        let zero = c.or(ua.isZero, ub.isInfinite)
        let value = c.select(infinite, infinity(sign), c.select(zero, signedZero(sign), finite))
        return result(nan: nan, signaling: c.or(ua.isSignaling, ub.isSignaling), value)
    }

    /// `int_trunc`, `int_floor`, `int_ceil`, `int_round` (ties away from zero) and `int_rint` (ties to even). The sign
    /// is kept (`(-0.4).rounded()` is -0.0), integers and infinities are returned unchanged.
    package func roundToIntegral(_ x: BV, _ rounding: FloatRounding) -> (value: BV, nan: Int32) {
        let (e, f) = (format.exponentBits, format.fractionBits)
        let u = unpack(x)
        let field = u.exponentField
        let integral = -c.ult(field, c.constant(UInt64(format.bias + f), width: e))
        let belowOne = c.ult(field, c.constant(UInt64(format.bias), width: e))
        // 1 <= |x| < 2^f: the low `k` bits of the magnitude are the fraction, 1 <= k <= f.
        let k = c.sub(c.constant(UInt64(format.bias + f), width: e), field).difference
        let high = shiftLeft(c.constant(~0, width: e + f), by: k)
        let lowMask = c.not(high).bits
        let mag = u.magnitude.bits
        let n = e + f
        let half = (0..<n).map { j in c.and(lowMask[j], j + 1 < n ? -lowMask[j + 1] : c.trueLit) }
        let unit = (0..<n).map { j in j == 0 ? c.falseLit : c.and(-lowMask[j], lowMask[j - 1]) }
        let fractionSet = any((0..<n).map { c.and(lowMask[$0], mag[$0]) }[...])
        let halfSet = any((0..<n).map { c.and(half[$0], mag[$0]) }[...])
        let restSet = any((0..<n).map { c.and(c.and(lowMask[$0], -half[$0]), mag[$0]) }[...])
        let odd = any((0..<n).map { c.and(unit[$0], mag[$0]) }[...])
        let up: Int32
        switch rounding {
        case .towardZero: up = c.falseLit
        case .down: up = c.and(u.sign, fractionSet)
        case .up: up = c.and(-u.sign, fractionSet)
        case .toNearestOrAwayFromZero: up = halfSet
        case .toNearestOrEven: up = c.and(halfSet, c.or(restSet, odd))
        }
        let truncated = BV(bits: (0..<n).map { c.and(high.bits[$0], mag[$0]) })
        let general = c.add(truncated, BV(bits: unit.map { c.and($0, up) })).sum
        // |x| < 1: the result is 0 or 1 in magnitude.
        let nonzero = -u.isZero
        let atLeastHalf = c.eq(field, c.constant(UInt64(format.bias - 1), width: e))
        let one: Int32
        switch rounding {
        case .towardZero: one = c.falseLit
        case .down: one = c.and(u.sign, nonzero)
        case .up: one = c.and(-u.sign, nonzero)
        case .toNearestOrAwayFromZero: one = atLeastHalf
        case .toNearestOrEven: one = c.and(atLeastHalf, any(u.significand.bits[0..<f]))
        }
        let unitMagnitude = c.select(one, c.constant(UInt64(format.bias) << UInt64(f), width: n), c.constant(0, width: n))
        let magnitude = c.select(integral, u.magnitude, c.select(belowOne, unitMagnitude, general))
        return result(nan: u.isNaN, signaling: u.isSignaling, BV(bits: magnitude.bits + [u.sign]))
    }

    /// The integer part of `x` in `width` bits, two's complement (`fptosi`, and `fptoui` where the value fits). Only
    /// meaningful where the conversion is defined (`S0FloatInstance` says when it is not).
    package func integerPart(_ x: BV, width: Int) -> BV {
        let (e, f) = (format.exponentBits, format.fractionBits)
        let u = unpack(x)
        let w = max(width, f + 1)
        let m = c.zeroExtend(u.significand, to: w)
        let field = u.exponentField
        let belowOne = c.ult(field, c.constant(UInt64(format.bias), width: e))
        let left = -c.ult(field, c.constant(UInt64(format.bias + f), width: e))
        let leftBy = c.sub(field, c.constant(UInt64(format.bias + f), width: e)).difference
        let rightBy = c.sub(c.constant(UInt64(format.bias + f), width: e), field).difference
        let shifted = c.truncate(c.select(left, shiftLeft(m, by: leftBy), shiftRight(m, by: rightBy)), to: width)
        let magnitude = c.select(belowOne, c.constant(0, width: width), shifted)
        return c.select(u.sign, c.negate(magnitude), magnitude)
    }

    /// `sitofp` (`signed`) or `uitofp` of `v`, rounded. Never NaN.
    package func fromInteger(_ v: BV, signed: Bool) -> BV {
        let negative = signed ? v.bits[v.width - 1] : c.falseLit
        let magnitude = c.select(negative, c.negate(v), v)
        return c.select(
            -any(v.bits[...]), signedZero(c.falseLit),
            round(sign: negative, significand: magnitude, sticky: c.falseLit, exponent: constant(0)))
    }

    /// `fpext` or `fptrunc` of `x`, a value of `source`, to this format.
    package func convert(_ x: BV, from source: FloatFormat) -> (value: BV, nan: Int32) {
        let u = FloatCircuit(c, source).unpack(x)
        let lsb = minus(widen(u.effectiveExponent), constant(source.bias + source.fractionBits))
        let finite = round(sign: u.sign, significand: u.significand, sticky: c.falseLit, exponent: lsb)
        return result(nan: u.isNaN, signaling: u.isSignaling, c.select(u.isInfinite, infinity(u.sign), finite))
    }

}

extension FloatCircuit {
    // MARK: rounding and packing

    /// `significand × 2^exponent` (plus some amount below its last bit when `sticky`), rounded to nearest, ties to
    /// even, with `sign`: a normal or subnormal number, a zero, or an infinity when it overflows.
    func round(sign: Int32, significand: BV, sticky stickyIn: Int32, exponent: BV) -> BV {
        let (e, f) = (format.exponentBits, format.fractionBits)
        var sig = significand
        var lsb = exponent
        if sig.width < f + 3 {
            let pad = f + 3 - sig.width
            sig = BV(bits: [Int32](repeating: c.falseLit, count: pad) + sig.bits)
            lsb = minus(lsb, constant(pad))
        }
        let w = sig.width
        precondition(w <= 128, "significand of \(w) bits")
        let isZero = c.and(-any(sig.bits[...]), -stickyIn)
        let (normalized, shift) = normalize(sig)
        // The biased exponent of the leading bit.
        let biased = minus(plus(lsb, constant(w - 1 + format.bias)), shift)
        let tiny = c.slt(biased, constant(1))
        let (denormal, lost) = shiftRightSticky(normalized, by: minus(constant(1), biased))
        let m = c.select(tiny, denormal, normalized)
        let sticky = c.or(stickyIn, c.and(tiny, lost))
        let guardPosition = w - 2 - f
        let window = BV(bits: Array(m.bits[(guardPosition + 1)..<w]))
        let rest = c.or(any(m.bits[0..<guardPosition]), sticky)
        let roundUp = c.and(m.bits[guardPosition], c.or(rest, window.bits[0]))
        // ((exponent - 1) << f) + window: the hidden bit adds the missing 1, a subnormal has none, and the rounding
        // carry moves into the exponent (a subnormal becomes normal, the largest finite number becomes infinity).
        let field = c.truncate(minus(c.select(tiny, constant(1), biased), constant(1)), to: e + 1)
        let packed = c.add(
            BV(bits: [Int32](repeating: c.falseLit, count: f) + field.bits), c.zeroExtend(window, to: e + f + 1), carryIn: roundUp
        ).sum
        let overflow = -c.slt(biased, constant(format.specialExponent))
        let magnitude = c.select(
            isZero, c.constant(0, width: e + f), c.select(overflow, infinity(c.falseLit).dropSign, c.truncate(packed, to: e + f)))
        return BV(bits: magnitude.bits + [sign])
    }

    /// `x` shifted left until its top bit is set (when it is not zero), and by how much.
    func normalize(_ x: BV) -> (value: BV, shift: BV) {
        let w = x.width
        precondition(w <= 128, "normalizing \(w) bits")
        var v = x
        var shift = [Int32](repeating: c.falseLit, count: exponentWidth)
        var (step, k) = (1, 0)
        while step * 2 < w { (step, k) = (step * 2, k + 1) }
        while step >= 1 {
            let topClear = -any(v.bits[(w - step)..<w])
            v = c.select(topClear, BV(bits: [Int32](repeating: c.falseLit, count: step) + v.bits[0..<(w - step)]), v)
            shift[k] = topClear
            (step, k) = (step / 2, k - 1)
        }
        return (v, BV(bits: shift))
    }

    /// `x >> amount` (logical; `amount` unsigned, any size) and whether a set bit was shifted out.
    func shiftRightSticky(_ x: BV, by amount: BV) -> (value: BV, sticky: Int32) {
        let w = x.width
        var v = x
        var sticky = c.falseLit
        var tooFar = c.falseLit
        for (k, bit) in amount.bits.enumerated() {
            guard k < 30, 1 << k < w else {
                tooFar = c.or(tooFar, bit)
                continue
            }
            let s = 1 << k
            sticky = c.or(sticky, c.and(bit, any(v.bits[0..<s])))
            v = c.select(bit, BV(bits: Array(v.bits[s..<w]) + [Int32](repeating: c.falseLit, count: s)), v)
        }
        return (
            c.select(tooFar, c.constant(0, width: w), v), c.mux(tooFar, any(x.bits[...]), sticky)
        )
    }

    /// `x << amount` with zeros shifted in; zero once `amount` reaches the width.
    func shiftLeft(_ x: BV, by amount: BV) -> BV {
        shift(x, by: amount, left: true)
    }

    /// `x >> amount` with zeros shifted in.
    func shiftRight(_ x: BV, by amount: BV) -> BV {
        shift(x, by: amount, left: false)
    }

    private func shift(_ x: BV, by amount: BV, left: Bool) -> BV {
        let w = x.width
        var v = x
        var tooFar = c.falseLit
        for (k, bit) in amount.bits.enumerated() {
            guard k < 30, 1 << k < w else {
                tooFar = c.or(tooFar, bit)
                continue
            }
            let s = 1 << k
            let zeros = [Int32](repeating: c.falseLit, count: s)
            v = c.select(bit, BV(bits: left ? zeros + v.bits[0..<(w - s)] : Array(v.bits[s..<w]) + zeros), v)
        }
        return c.select(tooFar, c.constant(0, width: w), v)
    }

    /// The full product of two unsigned integers (`a.width + b.width` bits), by rows: row `i` adds `a` at bit `i`,
    /// where the sum so far has no bit set yet above `i + a.width`.
    func multiplySignificands(_ a: BV, _ b: BV) -> BV {
        let n = a.width
        var sum = [Int32](repeating: c.falseLit, count: n + b.width)
        for (i, multiplier) in b.bits.enumerated() {
            var carry = c.falseLit
            for j in 0..<n {
                let addend = c.and(a.bits[j], multiplier)
                let p = c.xor(sum[i + j], addend)
                (sum[i + j], carry) = (c.xor(p, carry), c.or(c.and(sum[i + j], addend), c.and(carry, p)))
            }
            sum[i + n] = carry
        }
        return BV(bits: sum)
    }

    // MARK: values

    /// A NaN with a fresh sign and payload. LLVM's rules for a NaN result (LangRef, "Behavior of Floating-Point NaN
    /// values"): the sign is unspecified, and the quiet bit and payload come from the preferred NaN, a quieted input
    /// NaN, a target-specific quiet NaN, or an input NaN unchanged. So the result is quiet unless an operand is a
    /// signalling NaN (`signalingInput`), and then it may be any NaN. The fraction is never all zero, which would be
    /// an infinity: when the quiet bit is clear, the lowest bit is forced on if the other fresh bits are all zero.
    /// The quiet bit is a constant when no operand can be signalling, so `isNaN` of the result folds and a chain of
    /// operations on a NaN stays a NaN on constant inputs.
    func anyNaN(signalingInput: Int32) -> BV {
        let (e, f) = (format.exponentBits, format.fractionBits)
        var fraction = c.input(width: f - 1).bits
        let quiet = c.or(-signalingInput, c.fresh())
        fraction[0] = c.or(fraction[0], c.and(-quiet, -any(fraction[1...])))
        return BV(bits: fraction + [quiet] + [Int32](repeating: c.trueLit, count: e) + [c.fresh()])
    }

    func infinity(_ sign: Int32) -> BV {
        let (e, f) = (format.exponentBits, format.fractionBits)
        return BV(bits: [Int32](repeating: c.falseLit, count: f) + [Int32](repeating: c.trueLit, count: e) + [sign])
    }

    func signedZero(_ sign: Int32) -> BV {
        BV(bits: [Int32](repeating: c.falseLit, count: format.exponentBits + format.fractionBits) + [sign])
    }

    private func result(nan: Int32, signaling: Int32, _ value: BV) -> (value: BV, nan: Int32) {
        nan == c.falseLit ? (value, nan) : (c.select(nan, anyNaN(signalingInput: signaling), value), nan)
    }

    // MARK: gates

    private func any(_ bits: ArraySlice<Int32>) -> Int32 { bits.reduce(c.falseLit) { c.or($0, $1) } }
    private func every(_ bits: ArraySlice<Int32>) -> Int32 { bits.reduce(c.trueLit) { c.and($0, $1) } }
    private func constant(_ value: Int) -> BV { c.constant(UInt64(bitPattern: Int64(value)), width: exponentWidth) }
    private func widen(_ field: BV) -> BV { c.zeroExtend(field, to: exponentWidth) }
    private func plus(_ a: BV, _ b: BV) -> BV { c.add(a, b).sum }
    private func minus(_ a: BV, _ b: BV) -> BV { c.sub(a, b).difference }
}

extension BV {
    /// Every bit but the last (the sign of a floating-point value).
    fileprivate var dropSign: BV { BV(bits: Array(bits.dropLast())) }
}
