import SFBV
import SFCNF
import SFProve
import SFTestSupport
import SwiftFormal
import Testing

/// Tier 2: whole-range proofs about the bit-vector circuits at 32 bits. `prove` accepts an UNSAT answer only after the
/// independent checker (`SFCheck`) has accepted the solver's proof, so `.proved` here means the checker agreed.
///
/// The claims are algebraic identities of two's-complement arithmetic that hold in real Swift for all `UInt32` / `Int32`
/// (Hacker's Delight, ch. 2). They are the specification, not a guess: each is also checked against the language on
/// 64-bit samples in `SampledCircuitSelfSlowTests`.
@Suite struct ProofSelfTests {
    private func holds(
        _ widths: [Int], _ name: String, _ claim: @escaping (CNFBuilder, [BV]) -> Int32,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let verdict = try prove(inputWidths: widths, claim: claim)
        #expect(verdict == .proved, "\(name): \(verdict)", sourceLocation: sourceLocation)
    }

    @Test func additionIsCommutativeAt32Bits() throws {
        try holds([32, 32], "a + b == b + a") { c, v in c.eq(c.add(v[0], v[1]).sum, c.add(v[1], v[0]).sum) }
    }

    /// a + b == (a ^ b) + 2 * (a & b): the carry-save identity.
    @Test func carrySaveIdentityHoldsAt32Bits() throws {
        try holds([32, 32], "a + b == (a ^ b) + ((a & b) << 1)") { c, v in
            let sum = Circuit.bitwise(c, v[0], v[1]) { c.xor($0, $1) }
            let carries = Circuit.bitwise(c, v[0], v[1]) { c.and($0, $1) }
            let doubled = c.shiftLeft(carries, by: c.constant(1, width: 32))
            return c.eq(c.add(v[0], v[1]).sum, c.add(sum, doubled).sum)
        }
    }

    @Test func subtractionAndNegationAreTwosComplementAt32Bits() throws {
        try holds([32, 32], "a - b == a + ~b + 1") { c, v in
            c.eq(c.sub(v[0], v[1]).difference, c.add(c.add(v[0], c.not(v[1])).sum, c.constant(1, width: 32)).sum)
        }
        try holds([32], "-a == ~a + 1") { c, v in c.eq(c.negate(v[0]), c.add(c.not(v[0]), c.constant(1, width: 32)).sum) }
        try holds([32, 32], "(a - b) + b == a") { c, v in c.eq(c.add(c.sub(v[0], v[1]).difference, v[1]).sum, v[0]) }
    }

    @Test func comparisonsAgreeWithEachOtherAt32Bits() throws {
        try holds([32, 32], "ult(a, b) == !ule(b, a)") { c, v in
            c.eq(BV(bits: [c.ult(v[0], v[1])]), BV(bits: [-c.ule(v[1], v[0])]))
        }
        try holds([32, 32], "slt(a, b) == ult(a ^ sign, b ^ sign)") { c, v in
            let sign = c.constant(1 << 31, width: 32)
            let flipped = { (x: BV) in Circuit.bitwise(c, x, sign) { c.xor($0, $1) } }
            return c.eq(BV(bits: [c.slt(v[0], v[1])]), BV(bits: [c.ult(flipped(v[0]), flipped(v[1]))]))
        }
        try holds([32, 32], "a < b or a == b or a > b (unsigned), exactly one") { c, v in
            let (lt, eq, gt) = (c.ult(v[0], v[1]), c.eq(v[0], v[1]), c.ult(v[1], v[0]))
            let atLeastOne = c.or(lt, c.or(eq, gt))
            let atMostOne = c.and(-c.and(lt, eq), c.and(-c.and(lt, gt), -c.and(eq, gt)))
            return c.and(atLeastOne, atMostOne)
        }
    }

    @Test func shiftLeftByOneIsAdditionToItselfAt32Bits() throws {
        try holds([32], "a << 1 == a + a") { c, v in c.eq(c.shiftLeft(v[0], by: c.constant(1, width: 32)), c.add(v[0], v[0]).sum) }
        try holds([32, 32], "(a >>> n) is a >> n when the top bit is clear") { c, v in
            let small = c.ult(v[1], c.constant(32, width: 32))
            let nonNegative = -v[0].bits[31]
            let same = c.eq(c.logicalShiftRight(v[0], by: v[1]), c.arithmeticShiftRight(v[0], by: v[1]))
            return c.or(-c.and(small, nonNegative), same)
        }
    }

    /// The overflow flag of unsigned addition is the carry out, and equals "the wrapped sum is smaller than an operand".
    @Test func unsignedAddOverflowMeansTheSumWrapped() throws {
        try holds([32, 32], "overflow <=> a + b < a") { c, v in
            let wrapped = c.ult(c.add(v[0], v[1]).sum, v[0])
            return c.eq(BV(bits: [c.unsignedAddOverflows(v[0], v[1])]), BV(bits: [wrapped]))
        }
    }

}

/// Proofs that take several seconds in a debug build (a 32-bit three-operand adder miter, an 8-bit divider): the slow lane.
@Suite(.tags(.slow)) struct ProofSelfSlowTests {
    private func holds(
        _ widths: [Int], _ name: String, _ claim: @escaping (CNFBuilder, [BV]) -> Int32,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let verdict = try prove(inputWidths: widths, claim: claim)
        #expect(verdict == .proved, "\(name): \(verdict)", sourceLocation: sourceLocation)
    }

    @Test func additionIsAssociativeAt32Bits() throws {
        try holds([32, 32, 32], "(a + b) + c == a + (b + c)") { c, v in
            c.eq(c.add(c.add(v[0], v[1]).sum, v[2]).sum, c.add(v[0], c.add(v[1], v[2]).sum).sum)
        }
    }

    /// Division at 8 bits (multiplication is slow to prove at larger widths, see docs/TRUST.md): q * b + r == a and r < b.
    @Test func divisionSatisfiesEuclidAt8Bits() throws {
        try holds([8, 8], "a == (a / b) * b + a % b, a % b < b") { c, v in
            let (q, r) = c.unsignedDivide(v[0], v[1])
            let identity = c.eq(c.add(c.mul(q, v[1]), r).sum, v[0])
            return c.or(c.eq(v[1], c.constant(0, width: 8)), c.and(identity, c.ult(r, v[1])))
        }
    }
}

/// The same operations on 64-bit values drawn from a fixed seed, compared with Swift's operators.
@Suite(.tags(.slow)) struct SampledCircuitSelfSlowTests {
    @Test(arguments: [0x5EED as UInt64, 0xC0FFEE, 0xBADC0DE])
    func wideCircuitsMatchSwiftOnSeededSamples(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        func draw() -> UInt64 {
            // A mix of uniform values and the boundary values where wide arithmetic goes wrong.
            switch rng.next() % 4 {
            case 0: return [0, 1, UInt64.max, UInt64(Int64.max), UInt64(bitPattern: Int64.min), UInt64(UInt32.max)][Int(rng.next() % 6)]
            default: return rng.next()
            }
        }
        for sample in 0..<400 {
            let (a, b) = (draw(), draw())
            let context = "seed \(seed), sample \(sample), a=\(a), b=\(b)"
            #expect(Circuit.fold(64, a, b) { $0.add($1, $2).sum } == a &+ b, "\(context): add")
            #expect(Circuit.fold(64, a, b) { $0.sub($1, $2).difference } == a &- b, "\(context): sub")
            #expect(Circuit.fold(64, a, b) { $0.mul($1, $2) } == a &* b, "\(context): mul")
            #expect(Circuit.foldFlag(64, a, b) { $0.ult($1, $2) } == (a < b), "\(context): ult")
            #expect(Circuit.foldFlag(64, a, b) { $0.slt($1, $2) } == (Int64(bitPattern: a) < Int64(bitPattern: b)), "\(context): slt")
            #expect(
                Circuit.foldFlag(64, a, b) { $0.signedAddOverflows($1, $2) }
                    == Int64(bitPattern: a).addingReportingOverflow(Int64(bitPattern: b)).overflow, "\(context): signed add overflow")
            #expect(
                Circuit.foldFlag(64, a, b) { $0.signedMulOverflows($1, $2) }
                    == Int64(bitPattern: a).multipliedReportingOverflow(by: Int64(bitPattern: b)).overflow,
                "\(context): signed mul overflow")
            #expect(
                Circuit.foldFlag(64, a, b) { $0.unsignedMulOverflows($1, $2) } == a.multipliedReportingOverflow(by: b).overflow,
                "\(context): unsigned mul overflow")
            let amount = b % 64
            #expect(Circuit.fold(64, a, amount) { $0.shiftLeft($1, by: $2) } == a << amount, "\(context): shl")
            #expect(Circuit.fold(64, a, amount) { $0.logicalShiftRight($1, by: $2) } == a >> amount, "\(context): lshr")
            #expect(
                Circuit.fold(64, a, amount) { $0.arithmeticShiftRight($1, by: $2) }
                    == UInt64(bitPattern: Int64(bitPattern: a) >> Int64(amount)), "\(context): ashr")
            if b != 0 {
                #expect(Circuit.fold(64, a, b) { $0.unsignedDivide($1, $2).quotient } == a / b, "\(context): udiv")
                #expect(Circuit.fold(64, a, b) { $0.unsignedDivide($1, $2).remainder } == a % b, "\(context): urem")
                let (sa, sb) = (Int64(bitPattern: a), Int64(bitPattern: b))
                if !(sa == .min && sb == -1) {
                    #expect(Circuit.fold(64, a, b) { $0.signedDivide($1, $2).quotient } == UInt64(bitPattern: sa / sb), "\(context): sdiv")
                    #expect(Circuit.fold(64, a, b) { $0.signedDivide($1, $2).remainder } == UInt64(bitPattern: sa % sb), "\(context): srem")
                }
            }
        }
    }
}
