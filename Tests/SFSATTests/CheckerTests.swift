import Testing
import SFCNF
import SFCheck

@Suite struct CheckerTests {
    // (a ∨ b) (¬a ∨ b) (a ∨ ¬b) (¬a ∨ ¬b) is unsatisfiable.
    let cnf = CNF(numVars: 2, clauses: [[1, 2], [-1, 2], [1, -2], [-1, -2]])

    @Test func acceptsValidRefutation() {
        #expect(RUPChecker.check(cnf: cnf, proof: [[2], []]))
    }

    @Test func rejectsProofWithoutEmptyClause() {
        #expect(!RUPChecker.check(cnf: cnf, proof: [[2]]))
    }

    @Test func rejectsNonRUPClause() {
        let satisfiable = CNF(numVars: 2, clauses: [[1, 2]])
        #expect(!RUPChecker.check(cnf: satisfiable, proof: [[1], []]))
    }

    @Test func propagatesThroughClausesWithRepeatedLiterals() {
        let dup = CNF(numVars: 2, clauses: [[1, 1], [-1, 2, 2], [-2]])
        #expect(RUPChecker.check(cnf: dup, proof: [[]]))
    }

    @Test func rejectsEmptyProofOnSatisfiableFormula() {
        #expect(!RUPChecker.check(cnf: CNF(numVars: 1, clauses: [[1]]), proof: [[]]))
    }
}
