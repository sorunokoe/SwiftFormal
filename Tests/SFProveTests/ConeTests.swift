import SFBV
import SFCNF
import SFProve
import SFSAT
import Testing

/// The solver gets only the goal's cone (`CNFCone`): proofs are renumbered and models extended to the whole formula,
/// and both are checked against the whole formula.
@Suite struct ConeTests {
    /// A builder with a 16-bit product nothing reads, next to the goal `x + y == y + x` (or `x * 3 == x + x`).
    private static func formula(commutes: Bool) -> (builder: CNFBuilder, inputs: [BV]) {
        let c = CNFBuilder()
        let x = c.input(width: 16), y = c.input(width: 16)
        _ = c.mul(x, y)
        let goal =
            commutes
            ? c.eq(c.add(x, y).sum, c.add(y, x).sum)
            : c.eq(c.mul(x, c.constant(3, width: 16)), c.add(x, x).sum)
        c.addClause([-goal])
        return (c, [x, y])
    }

    @Test func theConeLeavesOutGatesTheGoalDoesNotRead() {
        let c = Self.formula(commutes: true).builder
        let cone = c.cone()
        #expect(cone.kept.count < c.cnf.clauses.count / 2)
        #expect(cone.kept.first == 0)
        #expect(cone.kept.last == c.cnf.clauses.count - 1)
        #expect(cone.kept == cone.kept.sorted())
        #expect(cone.cnf.numVars == c.numVars)
    }

    @Test func aModelOfTheConeExtendsToTheWholeFormula() throws {
        let (c, inputs) = Self.formula(commutes: false)
        let cone = c.cone()
        let report = Solver.solveLRATReporting(cone.cnf, conflictBudget: 100_000)
        guard case .sat(let model) = report.outcome else { Issue.record("expected sat"); return }
        let whole = c.extend(model, outside: cone)
        #expect(c.cnf.isSatisfied(by: whole))
        let x = c.value(of: inputs[0], in: whole)
        #expect((x &* 3) & 0xFFFF != (x &+ x) & 0xFFFF)
    }

    @Test func proofsAndCounterexamplesThroughTheConeAreCheckedAgainstTheWholeFormula() throws {
        for format in [ProofFormat.lrat, .rup] {
            let proved = try prove(inputWidths: [16, 16], proofFormat: format) { c, v in
                _ = c.mul(v[0], v[1])
                return c.eq(c.add(v[0], v[1]).sum, c.add(v[1], v[0]).sum)
            }
            #expect(proved == .proved)
        }
        let refuted = try prove(inputWidths: [16, 16]) { c, v in
            _ = c.mul(v[0], v[1])
            return c.eq(c.mul(v[0], c.constant(3, width: 16)), c.add(v[0], v[0]).sum)
        }
        guard case .counterexample(let values) = refuted else { Issue.record("expected counterexample"); return }
        #expect((values[0] &* 3) & 0xFFFF != (values[0] &+ values[0]) & 0xFFFF)
    }
}
