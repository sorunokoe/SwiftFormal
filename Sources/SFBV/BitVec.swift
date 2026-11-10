/// A fixed-width bit vector as CNF literals, least significant bit first.
public struct BV {
    public var bits: [Int32]
    public var width: Int { bits.count }
    public init(bits: [Int32]) { self.bits = bits }
}

extension CNFBuilder {
    public func constant(_ value: UInt64, width: Int) -> BV {
        BV(bits: (0..<width).map { constant(($0 < 64) && (value >> UInt64($0)) & 1 == 1) })
    }

    public func input(width: Int) -> BV {
        BV(bits: (0..<width).map { _ in fresh() })
    }

    /// The value of `bv` if every bit is a constant (a named one too, see `namedConstant`).
    public func constantValue(_ bv: BV) -> UInt64? {
        var result: UInt64 = 0
        for (i, bit) in bv.bits.enumerated() {
            let b = folded(bit)
            if b == trueLit { result |= 1 << UInt64(i) } else if b != falseLit { return nil }
        }
        return result
    }

    public func value(of bv: BV, in model: [Bool]) -> UInt64 {
        var result: UInt64 = 0
        for (i, bit) in bv.bits.enumerated() {
            let v = model[Int(abs(bit)) - 1]
            if bit > 0 ? v : !v { result |= 1 << UInt64(i) }
        }
        return result
    }

    // MARK: arithmetic (wrapping)

    public func add(_ a: BV, _ b: BV, carryIn: Int32? = nil) -> (sum: BV, carryOut: Int32) {
        var carry = carryIn ?? falseLit
        var out: [Int32] = []
        for i in 0..<a.width {
            let p = xor(a.bits[i], b.bits[i])
            out.append(xor(p, carry))
            carry = or(and(a.bits[i], b.bits[i]), and(carry, p))
        }
        return (BV(bits: out), carry)
    }

    public func not(_ a: BV) -> BV { BV(bits: a.bits.map { -$0 }) }

    /// Returns `a - b` and a flag that is true when `a < b` unsigned.
    public func sub(_ a: BV, _ b: BV) -> (difference: BV, borrow: Int32) {
        let r = add(a, not(b), carryIn: trueLit)
        return (r.sum, -r.carryOut)
    }

    /// Wrapping multiply. When both operands are sign extensions of narrower values, the product is
    /// built at the width the operands need and sign extended, which is exact and much smaller.
    public func mul(_ a: BV, _ b: BV, narrowing: Bool = true) -> BV {
        if narrowing {
            let (ka, kb) = (signedWidth(a), signedWidth(b))
            if ka + kb <= a.width { return signExtend(exactSignedProduct(a, b, ka, kb), to: a.width) }
        }
        if let hook = mulHook, constantValue(a) == nil, constantValue(b) == nil { return hook(a, b) }
        return shiftAddMultiply(a, b)
    }

    private func shiftAddMultiply(_ a: BV, _ b: BV) -> BV {
        var accumulator = constant(0, width: a.width)
        for i in 0..<a.width {
            let shifted = (0..<a.width).map { j in j < i ? falseLit : and(a.bits[j - i], b.bits[i]) }
            accumulator = add(accumulator, BV(bits: shifted)).sum
        }
        return accumulator
    }

    /// The exact signed product, `ka + kb` bits wide, of operands that are sign extensions of their low `ka` / `kb` bits.
    private func exactSignedProduct(_ a: BV, _ b: BV, _ ka: Int, _ kb: Int) -> BV {
        let width = ka + kb
        let x = signExtend(BV(bits: Array(a.bits[0..<ka])), to: width)
        let y = signExtend(BV(bits: Array(b.bits[0..<kb])), to: width)
        return shiftAddMultiply(x, y)
    }

    // MARK: structural range facts

    /// The smallest `k` such that `a` is the sign extension of its low `k` bits. Read directly off the
    /// literals, so it can never disagree with the circuit.
    public func signedWidth(_ a: BV) -> Int {
        var k = a.width
        while k > 1 && a.bits[k - 1] == a.bits[k - 2] { k -= 1 }
        return k
    }

    /// An input of `width` bits whose value is a signed `signedBits`-bit number, sign extended.
    /// The range is part of the circuit, so a proof about it needs no separate assumption.
    public func input(width: Int, signedBits: Int) -> BV {
        precondition(signedBits >= 1 && signedBits <= width)
        return signExtend(input(width: signedBits), to: width)
    }

    /// Wrapping add that is computed at the width the operands need when they are sign extensions.
    public func addSigned(_ a: BV, _ b: BV, narrowing: Bool = true) -> BV {
        guard narrowing else { return add(a, b).sum }
        let (ka, kb) = (signedWidth(a), signedWidth(b))
        let k = max(ka, kb) + 1
        guard k < a.width else { return add(a, b).sum }
        let x = signExtend(BV(bits: Array(a.bits[0..<ka])), to: k)
        let y = signExtend(BV(bits: Array(b.bits[0..<kb])), to: k)
        return signExtend(add(x, y).sum, to: a.width)
    }

    /// Wrapping subtract, narrowed like `addSigned`.
    public func subSigned(_ a: BV, _ b: BV, narrowing: Bool = true) -> BV {
        guard narrowing else { return sub(a, b).difference }
        let (ka, kb) = (signedWidth(a), signedWidth(b))
        let k = max(ka, kb) + 1
        guard k < a.width else { return sub(a, b).difference }
        let x = signExtend(BV(bits: Array(a.bits[0..<ka])), to: k)
        let y = signExtend(BV(bits: Array(b.bits[0..<kb])), to: k)
        return signExtend(sub(x, y).difference, to: a.width)
    }

    // MARK: comparison

    public func eq(_ a: BV, _ b: BV) -> Int32 {
        var result = trueLit
        for i in 0..<a.width { result = and(result, -xor(a.bits[i], b.bits[i])) }
        return result
    }

    public func ult(_ a: BV, _ b: BV) -> Int32 { sub(a, b).borrow }
    public func ule(_ a: BV, _ b: BV) -> Int32 { -ult(b, a) }

    public func slt(_ a: BV, _ b: BV) -> Int32 {
        var x = a, y = b
        x.bits[x.width - 1] = -x.bits[x.width - 1]
        y.bits[y.width - 1] = -y.bits[y.width - 1]
        return ult(x, y)
    }
    public func sle(_ a: BV, _ b: BV) -> Int32 { -slt(b, a) }

    public func select(_ condition: Int32, _ a: BV, _ b: BV) -> BV {
        BV(bits: zip(a.bits, b.bits).map { mux(condition, $0, $1) })
    }

    // MARK: signed overflow flags (Swift traps on these)

    public func signedAddOverflows(_ a: BV, _ b: BV, narrowing: Bool = true) -> Int32 {
        if narrowing && max(signedWidth(a), signedWidth(b)) + 1 <= a.width { return falseLit }
        let s = add(a, b).sum
        let top = a.width - 1
        return and(-xor(a.bits[top], b.bits[top]), xor(a.bits[top], s.bits[top]))
    }

    public func signedSubOverflows(_ a: BV, _ b: BV, narrowing: Bool = true) -> Int32 {
        if narrowing && max(signedWidth(a), signedWidth(b)) + 1 <= a.width { return falseLit }
        let d = sub(a, b).difference
        let top = a.width - 1
        return and(xor(a.bits[top], b.bits[top]), xor(a.bits[top], d.bits[top]))
    }

    public func signExtend(_ a: BV, to width: Int) -> BV {
        BV(bits: a.bits + Array(repeating: a.bits[a.width - 1], count: width - a.width))
    }

    public func signedMulOverflows(_ a: BV, _ b: BV, narrowing: Bool = true) -> Int32 {
        if narrowing, let hook = signedMulOverflowHook { return hook(a, b) }
        let n = a.width
        let product: BV
        if narrowing {
            let (ka, kb) = (signedWidth(a), signedWidth(b))
            if ka + kb <= n { return falseLit }
            product = exactSignedProduct(a, b, ka, kb)
        } else {
            product = shiftAddMultiply(signExtend(a, to: 2 * n), signExtend(b, to: 2 * n))
        }
        var allSame = trueLit
        for i in n..<product.width { allSame = and(allSame, -xor(product.bits[i], product.bits[n - 1])) }
        return -allSame
    }
}
