import SFCNF

/// Shifts, negation and division, built on the gates in `BitVec.swift`.
extension CNFBuilder {
    /// True when `amount >= a.width` (unsigned). LLVM treats such shifts as poison.
    public func shiftAmountOutOfRange(_ a: BV, _ amount: BV) -> Int32 {
        -ult(amount, constant(UInt64(a.width), width: amount.width))
    }

    private func shift(_ a: BV, by amount: BV, fill: Int32, left: Bool) -> BV {
        var current = a
        let n = a.width
        for (stage, selectBit) in amount.bits.enumerated() {
            guard stage < 7, (1 << stage) < n else { break }
            let distance = 1 << stage
            let moved = BV(
                bits: (0..<n).map { i in
                    if left { return i >= distance ? current.bits[i - distance] : falseLit }
                    return i + distance < n ? current.bits[i + distance] : fill
                })
            current = select(selectBit, moved, current)
        }
        return current
    }

    /// Result is meaningful only when `shiftAmountOutOfRange` is false.
    public func shiftLeft(_ a: BV, by amount: BV) -> BV { shift(a, by: amount, fill: falseLit, left: true) }
    public func logicalShiftRight(_ a: BV, by amount: BV) -> BV { shift(a, by: amount, fill: falseLit, left: false) }
    public func arithmeticShiftRight(_ a: BV, by amount: BV) -> BV {
        shift(a, by: amount, fill: a.bits[a.width - 1], left: false)
    }

    public func negate(_ a: BV) -> BV { add(not(a), constant(0, width: a.width), carryIn: trueLit).sum }

    public func truncate(_ a: BV, to width: Int) -> BV { BV(bits: Array(a.bits[0..<width])) }

    public func zeroExtend(_ a: BV, to width: Int) -> BV {
        BV(bits: a.bits + Array(repeating: falseLit, count: width - a.width))
    }

    /// Restoring division. For a zero divisor the outputs are arbitrary; callers guard with their own flag.
    public func unsignedDivide(_ a: BV, _ b: BV) -> (quotient: BV, remainder: BV) {
        let n = a.width
        let divisor = zeroExtend(b, to: n + 1)
        var remainder = constant(0, width: n + 1)
        var quotient = [Int32](repeating: falseLit, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            let shifted = BV(bits: [a.bits[i]] + remainder.bits.dropLast())
            let (difference, borrow) = sub(shifted, divisor)
            quotient[i] = -borrow
            remainder = select(-borrow, difference, shifted)
        }
        return (BV(bits: quotient), truncate(remainder, to: n))
    }

    /// Truncating signed division, the remainder takes the dividend's sign (LLVM `sdiv` / `srem`).
    public func signedDivide(_ a: BV, _ b: BV) -> (quotient: BV, remainder: BV) {
        let (signA, signB) = (a.bits[a.width - 1], b.bits[b.width - 1])
        let (q, r) = unsignedDivide(select(signA, negate(a), a), select(signB, negate(b), b))
        return (select(xor(signA, signB), negate(q), q), select(signA, negate(r), r))
    }

    // MARK: unsigned overflow flags

    public func unsignedAddOverflows(_ a: BV, _ b: BV) -> Int32 { add(a, b).carryOut }
    public func unsignedSubOverflows(_ a: BV, _ b: BV) -> Int32 { ult(a, b) }
    public func unsignedMulOverflows(_ a: BV, _ b: BV) -> Int32 {
        if let hook = unsignedMulOverflowHook { return hook(a, b) }
        let n = a.width
        let product = mul(zeroExtend(a, to: 2 * n), zeroExtend(b, to: 2 * n), narrowing: false)
        return product.bits[n...].reduce(falseLit) { or($0, $1) }
    }
}
