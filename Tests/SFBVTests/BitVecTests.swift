import Testing
import SFBV
import SFCNF
import SFSAT
import SFTestSupport

/// Reference semantics computed with plain Int arithmetic at width `w`.
private struct Reference {
    let w: Int
    var mask: Int { (1 << w) - 1 }
    func signed(_ x: Int) -> Int { x >= (1 << (w - 1)) ? x - (1 << w) : x }
    func fits(_ x: Int) -> Bool { x >= -(1 << (w - 1)) && x < (1 << (w - 1)) }
}

private struct Outputs: Equatable {
    var add, sub, mul: UInt64
    var eq, ult, slt, addOv, subOv, mulOv: Bool
}

private func expected(_ a: Int, _ b: Int, _ r: Reference) -> Outputs {
    let sa = r.signed(a), sb = r.signed(b)
    return Outputs(
        add: UInt64((a + b) & r.mask), sub: UInt64((a - b) & r.mask), mul: UInt64((a * b) & r.mask),
        eq: a == b, ult: a < b, slt: sa < sb,
        addOv: !r.fits(sa + sb), subOv: !r.fits(sa - sb), mulOv: !r.fits(sa * sb))
}

private func circuits(_ c: CNFBuilder, _ x: BV, _ y: BV) -> (values: [BV], flags: [Int32]) {
    (
        [c.add(x, y).sum, c.sub(x, y).difference, c.mul(x, y)],
        [
            c.eq(x, y), c.ult(x, y), c.slt(x, y),
            c.signedAddOverflows(x, y), c.signedSubOverflows(x, y), c.signedMulOverflows(x, y),
        ]
    )
}

@Suite(.tags(.slow)) struct BitVecTests {
    /// Exhaustive 8-bit check using constant folding, plus native Int8 cross-checks.
    @Test func exhaustiveEightBitConstantFolding() throws {
        let r = Reference(w: 8)
        for a in 0..<256 {
            for b in 0..<256 {
                let c = CNFBuilder()
                let (values, flags) = circuits(c, c.constant(UInt64(a), width: 8), c.constant(UInt64(b), width: 8))
                let v = try values.map { try #require(c.constantValue($0)) }
                let f = flags.map { $0 == c.trueLit }
                #expect(flags.allSatisfy { $0 == c.trueLit || $0 == c.falseLit })
                let got = Outputs(
                    add: v[0], sub: v[1], mul: v[2], eq: f[0], ult: f[1], slt: f[2],
                    addOv: f[3], subOv: f[4], mulOv: f[5])
                #expect(got == expected(a, b, r))

                let x = Int8(truncatingIfNeeded: a), y = Int8(truncatingIfNeeded: b)
                #expect(got.addOv == x.addingReportingOverflow(y).overflow)
                #expect(got.subOv == x.subtractingReportingOverflow(y).overflow)
                #expect(got.mulOv == x.multipliedReportingOverflow(by: y).overflow)
                #expect(got.slt == (x < y))
            }
        }
    }

    /// Exhaustive 4-bit check through the real solver, so the generated clauses are exercised.
    @Test func exhaustiveFourBitThroughSolver() throws {
        let r = Reference(w: 4)
        let c = CNFBuilder()
        let x = c.input(width: 4), y = c.input(width: 4)
        let (values, flags) = circuits(c, x, y)
        let base = c.cnf
        for a in 0..<16 {
            for b in 0..<16 {
                var cnf = base
                for i in 0..<4 {
                    cnf.clauses.append([(a >> i) & 1 == 1 ? x.bits[i] : -x.bits[i]])
                    cnf.clauses.append([(b >> i) & 1 == 1 ? y.bits[i] : -y.bits[i]])
                }
                guard case .sat(let model) = Solver.solve(cnf) else { Issue.record("expected sat"); return }
                let v = values.map { c.value(of: $0, in: model) }
                let f = flags.map { lit in model[Int(abs(lit)) - 1] == (lit > 0) }
                let got = Outputs(
                    add: v[0], sub: v[1], mul: v[2], eq: f[0], ult: f[1], slt: f[2],
                    addOv: f[3], subOv: f[4], mulOv: f[5])
                #expect(got == expected(a, b, r))
            }
        }
    }
}
