package import SFCNF

/// An LRAT refutation as the solver writes it. Original clauses have IDs `1...n` in input order.
/// This is untrusted data; `SFCheck.LRATChecker` decides whether it proves anything.
package struct LRATLog: Sendable, Equatable {
    package enum Step: Sendable, Equatable {
        /// Adds `clause` (DIMACS literals) under `id`. `hints` are clause IDs in unit-propagation order.
        case add(id: Int, clause: Clause, hints: [Int])
        case delete(ids: [Int])
    }

    package var steps: [Step]

    package init(steps: [Step]) {
        self.steps = steps
    }

    /// The added clauses in order (ending with `[]`): a RUP proof, since each one follows by unit propagation from
    /// the formula and the clauses before it.
    package var rupProof: [Clause] {
        steps.compactMap { step in
            if case .add(_, let clause, _) = step { return clause }
            return nil
        }
    }
}

package enum LRATSolveResult: Sendable {
    case sat(model: [Bool])
    /// Ends with the empty clause.
    case unsat(proof: LRATLog)
    case unknown
}

/// What one solver run spent. Every field is a deterministic count, so it can be compared across runs and machines.
package struct SolveStats: Sendable, Equatable {
    /// Conflicts the search reached, including the one that exhausted the budget (`unknown`).
    package var conflicts: Int
    /// Variables of the formula that was solved.
    package var variables: Int
    /// Original clauses of the formula that was solved (learned clauses are not counted).
    package var clauses: Int

    package init(conflicts: Int, variables: Int, clauses: Int) {
        self.conflicts = conflicts
        self.variables = variables
        self.clauses = clauses
    }
}

/// An LRAT solver answer together with what the run spent. See `Solver.solveLRATReporting`.
package struct LRATSolveReport: Sendable {
    package var outcome: LRATSolveResult
    package var stats: SolveStats

    package init(outcome: LRATSolveResult, stats: SolveStats) {
        self.outcome = outcome
        self.stats = stats
    }
}
