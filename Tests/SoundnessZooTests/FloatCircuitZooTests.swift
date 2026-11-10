import SFBV
import SFSIL
import SFSemantics
import Testing

/// The fast lane's share of plan item R6-3: the floating-point cases that a plausible bug in the circuits gets wrong,
/// each against the hardware. The full differential (random operands, every width, every `Float16`) is
/// `SILFloatArithmeticTests` in the slow lane; this keeps a broken circuit from reaching it.
@Suite struct FloatCircuitZooTests {
    /// The circuit on constant operands: its bits, or nil for "some NaN" (exponent all ones, sign and payload free).
    private static func circuit(_ name: String, _ args: [Double]) -> UInt64?? {
        guard let inst = S0FloatInstance(builtinName: name) else { return .none }
        let c = CNFBuilder()
        let r = inst.encodeExactly(c, args.map { c.constant($0.bitPattern, width: 64) })
        if let v = c.constantValue(r.value) { return .some(v) }
        return r.value.bits[52..<63].allSatisfy { $0 == c.trueLit } ? .some(nil) : .none
    }

    private static func check(_ name: String, _ args: [Double], _ native: Double) {
        let want: UInt64?? = native.isNaN ? .some(nil) : .some(native.bitPattern)
        let got = circuit(name, args)
        #expect(got == want, "\(name)\(args): circuit \(String(describing: got)), hardware \(native)")
    }

    @Test func signedZerosTiesSubnormalsOverflowAndNaN() {
        let tiny = Double.leastNonzeroMagnitude
        let max = Double.greatestFiniteMagnitude
        // Exact cancellation is +0, (-0) + (-0) is -0, a negative number times zero is -0.
        Self.check("fsub_FPIEEE64", [1.5, 1.5], 1.5 - 1.5)
        Self.check("fadd_FPIEEE64", [-0.0, -0.0], -0.0 + -0.0)
        Self.check("fsub_FPIEEE64", [-0.0, 0.0], -0.0 - 0.0)
        Self.check("fmul_FPIEEE64", [-3, 0], -3 * 0)
        // Ties to even, at the end of the significand and below the smallest subnormal.
        Self.check("fadd_FPIEEE64", [1, Double.ulpOfOne / 2], 1 + Double.ulpOfOne / 2)
        Self.check("fadd_FPIEEE64", [Double(1).nextUp, Double.ulpOfOne / 2], Double(1).nextUp + Double.ulpOfOne / 2)
        Self.check("fmul_FPIEEE64", [tiny, 0.5], tiny * 0.5)
        Self.check("fmul_FPIEEE64", [tiny * 3, 0.5], tiny * 3 * 0.5)
        Self.check("fdiv_FPIEEE64", [Double.leastNormalMagnitude, 3], Double.leastNormalMagnitude / 3)
        // Overflow, the halfway point above the largest finite number, division by zero and by infinity.
        Self.check("fadd_FPIEEE64", [max, max.ulp / 2], max + max.ulp / 2)
        Self.check("fadd_FPIEEE64", [max, max.ulp / 4], max + max.ulp / 4)
        Self.check("fmul_FPIEEE64", [1e300, 1e10], 1e300 * 1e10)
        Self.check("fdiv_FPIEEE64", [-1, 0], -1 / 0.0)
        Self.check("fdiv_FPIEEE64", [5, -.infinity], 5 / -Double.infinity)
        // NaN: inf - inf, 0 * inf, 0 / 0, and a NaN operand.
        Self.check("fsub_FPIEEE64", [.infinity, .infinity], Double.infinity - Double.infinity)
        Self.check("fmul_FPIEEE64", [0, .infinity], 0 * Double.infinity)
        Self.check("fdiv_FPIEEE64", [0, 0], 0.0 / 0.0)
        Self.check("fadd_FPIEEE64", [.nan, 1], Double.nan + 1)
        Self.check("fadd_FPIEEE64", [.infinity, -1e308], Double.infinity + -1e308)
    }

    @Test func roundingKeepsTheSignAndBreaksTiesByRule() {
        for x in [-0.4, 0.5, -0.5, 1.5, 2.5, -2.5, 0.49999999999999994, 4_503_599_627_370_495.5, -0.0, 1e300, .infinity] {
            Self.check("int_round_FPIEEE64", [x], x.rounded(.toNearestOrAwayFromZero))
            Self.check("int_rint_FPIEEE64", [x], x.rounded(.toNearestOrEven))
            Self.check("int_floor_FPIEEE64", [x], x.rounded(.down))
            Self.check("int_ceil_FPIEEE64", [x], x.rounded(.up))
            Self.check("int_trunc_FPIEEE64", [x], x.rounded(.towardZero))
        }
        Self.check("int_floor_FPIEEE64", [.nan], Double.nan)
    }
}
