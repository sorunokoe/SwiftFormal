import SFBV
import SFCNF
@testable import SFProve
import SFSAT
import Testing

/// An answer is reused only for a formula equal clause for clause, and only when it was costly.
@Suite struct FormulaMemoTests {
    private static let formula = CNF(numVars: 3, clauses: [[1], [-2, 3], [2, -3], [-3]])
    private static var inputs: [BV] { [BV(bits: [2]), BV(bits: [3])] }

    private static func outcome(_ verdict: ProofVerdict, conflicts: Int) -> ProofOutcome {
        ProofOutcome(verdict: verdict, stats: ProofStats(SolveStats(conflicts: conflicts, variables: 3, clauses: 4)))
    }

    private static func key(_ cnf: CNF, budget: Int = 100) -> FormulaMemo.Key {
        FormulaMemo.key(cnf, inputs: inputs, conflictBudget: budget, proofFormat: .lrat)
    }

    @Test func aCostlyAnswerIsFoundForAnEqualFormulaOnly() {
        let memo = FormulaMemo()
        let costly = Self.outcome(.proved, conflicts: FormulaMemo.minimumConflicts)
        memo.record(costly, of: Self.formula, key: Self.key(Self.formula))
        #expect(memo.outcome(of: Self.formula, key: Self.key(Self.formula))?.verdict == .proved)

        var other = Self.formula
        other.clauses[3] = [3]
        #expect(memo.outcome(of: other, key: Self.key(other)) == nil, "same shape, one literal differs")
        #expect(memo.outcome(of: Self.formula, key: Self.key(Self.formula, budget: 200)) == nil, "another budget")
        let otherInputs = FormulaMemo.key(Self.formula, inputs: [BV(bits: [3])], conflictBudget: 100, proofFormat: .lrat)
        #expect(memo.outcome(of: Self.formula, key: otherInputs) == nil, "other inputs")
    }

    @Test func cheapAnswersAreNotKeptButUnknownOnesAre() {
        let memo = FormulaMemo()
        memo.record(Self.outcome(.proved, conflicts: 3), of: Self.formula, key: Self.key(Self.formula))
        #expect(memo.outcome(of: Self.formula, key: Self.key(Self.formula)) == nil)
        memo.record(Self.outcome(.unknown, conflicts: 101), of: Self.formula, key: Self.key(Self.formula))
        #expect(memo.outcome(of: Self.formula, key: Self.key(Self.formula))?.verdict == .unknown)
    }

    @Test func anAnswerFromTheMemoIsTheOneSolvingGives() throws {
        let claim: (CNFBuilder, [BV]) -> Int32 = { c, v in c.eq(c.mul(v[0], v[1]), c.mul(v[1], v[0])) }
        let first = try proveReporting(inputWidths: [12, 12], conflictBudget: 50, claim: claim)
        let second = try proveReporting(inputWidths: [12, 12], conflictBudget: 50, claim: claim)
        #expect(first.verdict == .unknown)
        #expect(first.verdict == second.verdict && first.stats == second.stats)
    }
}
