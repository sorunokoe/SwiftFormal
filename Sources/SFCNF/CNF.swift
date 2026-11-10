/// A clause is a list of DIMACS literals: variable `v` (1-based) is `v`, its negation is `-v`. Never 0.
public typealias Clause = [Int32]

package struct CNF: Sendable {
    package var numVars: Int
    package var clauses: [Clause]

    package init(numVars: Int, clauses: [Clause]) {
        self.numVars = numVars
        self.clauses = clauses
    }

    /// `model[i]` is the value of variable `i + 1`.
    package func isSatisfied(by model: [Bool]) -> Bool {
        clauses.allSatisfy { clause in
            clause.contains { lit in
                let value = model[Int(abs(lit)) - 1]
                return lit > 0 ? value : !value
            }
        }
    }
}

package enum SolveResult: Sendable {
    case sat(model: [Bool])
    /// Ordered clauses, each derivable by unit propagation from the formula plus earlier clauses; ends with `[]`.
    case unsat(proof: [Clause])
    case unknown
}
