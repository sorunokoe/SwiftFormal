import Testing
import SFCNF
import SFSAT
import SFCheck
import SFTestSupport

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func bruteForceSatisfiable(_ cnf: CNF) -> Bool {
    for bits in 0..<(1 << cnf.numVars) {
        let model = (0..<cnf.numVars).map { (bits >> $0) & 1 == 1 }
        if cnf.isSatisfied(by: model) { return true }
    }
    return false
}

@Suite(.tags(.slow)) struct SolverTests {
    @Test func trivialSat() {
        let cnf = CNF(numVars: 2, clauses: [[1, 2], [-1]])
        guard case .sat(let model) = Solver.solve(cnf) else { Issue.record("expected sat"); return }
        #expect(cnf.isSatisfied(by: model))
    }

    @Test func trivialUnsatWithProof() {
        let cnf = CNF(numVars: 2, clauses: [[1, 2], [-1, 2], [1, -2], [-1, -2]])
        guard case .unsat(let proof) = Solver.solve(cnf) else { Issue.record("expected unsat"); return }
        #expect(RUPChecker.check(cnf: cnf, proof: proof))
    }

    @Test func emptyClauseIsUnsat() {
        let cnf = CNF(numVars: 1, clauses: [[]])
        guard case .unsat(let proof) = Solver.solve(cnf) else { Issue.record("expected unsat"); return }
        #expect(RUPChecker.check(cnf: cnf, proof: proof))
    }

    /// Pigeonhole: 4 pigeons, 3 holes. Variable p*3 + h + 1 means pigeon p sits in hole h.
    @Test func pigeonhole() {
        var clauses: [Clause] = []
        for p in 0..<4 { clauses.append((0..<3).map { Int32(p * 3 + $0 + 1) }) }
        for h in 0..<3 {
            for p in 0..<4 {
                for q in (p + 1)..<4 where q < 4 {
                    clauses.append([-Int32(p * 3 + h + 1), -Int32(q * 3 + h + 1)])
                }
            }
        }
        let cnf = CNF(numVars: 12, clauses: clauses)
        guard case .unsat(let proof) = Solver.solve(cnf) else { Issue.record("expected unsat"); return }
        #expect(RUPChecker.check(cnf: cnf, proof: proof))
    }

    @Test func randomThreeSatAgreesWithBruteForce() {
        var rng = SplitMix64(state: 42)
        var satCount = 0
        var unsatCount = 0
        for _ in 0..<300 {
            let numVars = 10
            let clauses: [Clause] = (0..<43).map { _ in
                (0..<3).map { _ in
                    let v = Int32(rng.next() % UInt64(numVars)) + 1
                    return rng.next() & 1 == 0 ? v : -v
                }
            }
            let cnf = CNF(numVars: numVars, clauses: clauses)
            switch Solver.solve(cnf) {
            case .sat(let model):
                satCount += 1
                #expect(cnf.isSatisfied(by: model))
            case .unsat(let proof):
                unsatCount += 1
                #expect(RUPChecker.check(cnf: cnf, proof: proof))
                #expect(!bruteForceSatisfiable(cnf))
            case .unknown:
                Issue.record("unexpected unknown")
            }
        }
        #expect(satCount > 20 && unsatCount > 20)
    }

    /// Mixed clause lengths (units, binaries, ternaries, duplicates, tautologies) exercise level-0 simplification and the binary fast path.
    @Test func mixedLengthClausesAgreeWithBruteForce() {
        var rng = SplitMix64(state: 7)
        var satCount = 0
        var unsatCount = 0
        for _ in 0..<400 {
            let numVars = 12
            let clauses: [Clause] = (0..<(20 + Int(rng.next() % 30))).map { _ in
                let r = rng.next() % 10
                let length = r < 1 ? 1 : (r < 4 ? 2 : 3)
                return (0..<length).map { _ in
                    let v = Int32(rng.next() % UInt64(numVars)) + 1
                    return rng.next() & 1 == 0 ? v : -v
                }
            }
            let cnf = CNF(numVars: numVars, clauses: clauses)
            switch Solver.solve(cnf) {
            case .sat(let model):
                satCount += 1
                #expect(cnf.isSatisfied(by: model))
            case .unsat(let proof):
                unsatCount += 1
                #expect(RUPChecker.check(cnf: cnf, proof: proof))
                #expect(!bruteForceSatisfiable(cnf))
            case .unknown:
                Issue.record("unexpected unknown")
            }
        }
        #expect(satCount > 20 && unsatCount > 20)
    }

    /// Threshold-ratio instances need thousands of conflicts, so learned-clause reduction, restarts and
    /// level-0 simplification all run; every answer is validated (model or RUP proof).
    @Test func thresholdRandomThreeSatIsValidated() {
        var rng = SplitMix64(state: 2024)
        var satCount = 0
        var unsatCount = 0
        for _ in 0..<12 {
            let numVars = 130
            let clauses: [Clause] = (0..<554).map { _ in
                var vars: [Int32] = []
                while vars.count < 3 {
                    let v = Int32(rng.next() % UInt64(numVars)) + 1
                    if !vars.contains(v) { vars.append(v) }
                }
                return vars.map { rng.next() & 1 == 0 ? $0 : -$0 }
            }
            let cnf = CNF(numVars: numVars, clauses: clauses)
            switch Solver.solve(cnf) {
            case .sat(let model):
                satCount += 1
                #expect(cnf.isSatisfied(by: model))
            case .unsat(let proof):
                unsatCount += 1
                #expect(RUPChecker.check(cnf: cnf, proof: proof))
            case .unknown:
                Issue.record("unexpected unknown")
            }
        }
        #expect(satCount > 0 && unsatCount > 0)
    }

    @Test func largerPigeonholeProofIsValid() {
        let pigeons = 8, holes = 7
        var clauses: [Clause] = []
        for p in 0..<pigeons { clauses.append((0..<holes).map { Int32(p * holes + $0 + 1) }) }
        for h in 0..<holes {
            for p in 0..<pigeons {
                for q in (p + 1)..<pigeons {
                    clauses.append([-Int32(p * holes + h + 1), -Int32(q * holes + h + 1)])
                }
            }
        }
        let cnf = CNF(numVars: pigeons * holes, clauses: clauses)
        guard case .unsat(let proof) = Solver.solve(cnf) else { Issue.record("expected unsat"); return }
        #expect(proof.count > 2000)
        #expect(RUPChecker.check(cnf: cnf, proof: proof))
    }

    @Test func corruptedProofIsRejected() {
        let cnf = CNF(numVars: 2, clauses: [[1, 2], [-1, 2], [1, -2], [-1, -2]])
        guard case .unsat(let proof) = Solver.solve(cnf) else { Issue.record("expected unsat"); return }
        #expect(!RUPChecker.check(cnf: cnf, proof: Array(proof.dropLast())))
    }

    @Test func budgetYieldsUnknown() {
        var clauses: [Clause] = []
        for p in 0..<7 { clauses.append((0..<6).map { Int32(p * 6 + $0 + 1) }) }
        for h in 0..<6 {
            for p in 0..<7 {
                for q in (p + 1)..<7 where q < 7 {
                    clauses.append([-Int32(p * 6 + h + 1), -Int32(q * 6 + h + 1)])
                }
            }
        }
        let cnf = CNF(numVars: 42, clauses: clauses)
        guard case .unknown = Solver.solve(cnf, conflictBudget: 5) else { Issue.record("expected unknown"); return }
    }
}

@Suite struct SolveStatsTests {
    private func pigeonholeCNF(pigeons: Int, holes: Int) -> CNF {
        var clauses: [Clause] = []
        for p in 0..<pigeons { clauses.append((0..<holes).map { Int32(p * holes + $0 + 1) }) }
        for h in 0..<holes {
            for p in 0..<pigeons {
                for q in (p + 1)..<pigeons { clauses.append([-Int32(p * holes + h + 1), -Int32(q * holes + h + 1)]) }
            }
        }
        return CNF(numVars: pigeons * holes, clauses: clauses)
    }

    @Test func solverReportsWhatItSpent() {
        let cnf = pigeonholeCNF(pigeons: 5, holes: 4)
        let report = Solver.solveLRATReporting(cnf, conflictBudget: 100_000)
        guard case .unsat(let proof) = report.outcome else { Issue.record("expected UNSAT"); return }
        #expect(report.stats.conflicts > 0)
        #expect(report.stats.variables == cnf.numVars)
        #expect(report.stats.clauses == cnf.clauses.count)
        #expect(LRATChecker.check(cnf: cnf, proof: LRATProof(proof)))
    }

    @Test func statsAreDeterministicAndBudgetBoundsConflicts() {
        let cnf = pigeonholeCNF(pigeons: 7, holes: 6)
        let first = Solver.solveLRATReporting(cnf, conflictBudget: 5)
        let second = Solver.solveLRATReporting(cnf, conflictBudget: 5)
        guard case .unknown = first.outcome else { Issue.record("expected unknown"); return }
        #expect(first.stats == second.stats)
        #expect(first.stats.conflicts == 6)
    }

    @Test func reportingSolverGivesTheAnswerOfSolveLRAT() {
        let cnf = CNF(numVars: 2, clauses: [[1, 2], [-1]])
        guard case .sat(let model) = Solver.solveLRATReporting(cnf).outcome, case .sat(let plain) = Solver.solveLRAT(cnf) else {
            Issue.record("expected sat")
            return
        }
        #expect(model == plain)
        #expect(Solver.solveLRATReporting(cnf).stats.conflicts == 0)
    }
}
