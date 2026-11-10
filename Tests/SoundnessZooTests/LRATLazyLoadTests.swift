import Foundation
import SFCNF
import SFCheck
import SFSAT
import SwiftFormal
import Testing

/// `LRATChecker` reads an original clause when a step first names it (next-level plan item S2). It must accept and
/// reject exactly the proofs the checker that loaded every original clause first did, with the same error, on formulas
/// whose literals are all valid. The earlier checker is kept here, unchanged, as the reference.
@Suite struct LRATLazyLoadTests {
    private static let seedCount = ProcessInfo.processInfo.environment["SF_DIFFERENTIAL_SEEDS"].flatMap(Int.init) ?? 200

    @Test func acceptsAndRejectsWhatTheEagerCheckerDid() {
        var compared = 0
        for seed in 0..<UInt64(Self.seedCount) {
            var rng = SplitMix64(seed: seed &* 0x9E37_79B9 &+ 17)
            let cnf = Self.formula(&rng)
            guard case .unsat(let log) = Solver.solveLRAT(cnf) else { continue }
            let proof = LRATProof(log)
            var candidates = [proof]
            for _ in 0..<12 { candidates.append(Self.mutated(proof, cnf: cnf, &rng)) }
            for candidate in candidates {
                let eager = Self.eagerFailure(cnf, candidate)
                let lazy: LRATError?
                do {
                    try LRATChecker.verify(cnf: cnf, proof: candidate)
                    lazy = nil
                } catch {
                    lazy = error as? LRATError
                }
                #expect(eager == lazy, "seed \(seed): eager \(String(describing: eager)), lazy \(String(describing: lazy))")
                compared += 1
            }
        }
        #expect(compared > Self.seedCount)
    }

    /// The one documented difference: an invalid literal in an original clause the proof never names.
    @Test func anInvalidLiteralInAClauseTheProofNeverNamesIsNotAnError() throws {
        let cnf = CNF(numVars: 2, clauses: [[1, 2], [-1, 2], [1, -2], [-1, -2], [3]])
        let proof = LRATProof(steps: [.add(id: 6, clause: [2], hints: [1, 2]), .add(id: 7, clause: [], hints: [6, 4, 3])])
        #expect(Self.eagerFailure(cnf, proof) == .invalidLiteral(step: -1, literal: 3))
        try LRATChecker.verify(cnf: cnf, proof: proof)
        let naming = LRATProof(steps: [.add(id: 6, clause: [2], hints: [5, 1, 2])])
        #expect(throws: LRATError.invalidLiteral(step: 0, literal: 3)) { try LRATChecker.verify(cnf: cnf, proof: naming) }
    }

    @Test func deletingAnOriginalClauseNeverReadRetiresIt() {
        let cnf = CNF(numVars: 2, clauses: [[1, 2], [-1, 2], [1, -2], [-1, -2]])
        let twice = LRATProof(steps: [.delete(ids: [4]), .delete(ids: [4])])
        #expect(throws: LRATError.deletedClause(step: 1, id: 4)) { try LRATChecker.verify(cnf: cnf, proof: twice) }
        let reused = LRATProof(steps: [
            .delete(ids: [3]), .add(id: 5, clause: [2], hints: [1, 2]), .add(id: 6, clause: [], hints: [5, 4, 3]),
        ])
        #expect(throws: LRATError.deletedClause(step: 2, id: 3)) { try LRATChecker.verify(cnf: cnf, proof: reused) }
        let renamed = LRATProof(steps: [.add(id: 2, clause: [2], hints: [1, 3])])
        #expect(throws: LRATError.duplicateID(step: 0, id: 2)) { try LRATChecker.verify(cnf: cnf, proof: renamed) }
    }

    // MARK: inputs

    /// 2 to 9 variables, clauses of 1 to 4 valid literals, dense enough to be often unsatisfiable.
    private static func formula(_ rng: inout SplitMix64) -> CNF {
        let numVars = Int.random(in: 2...9, using: &rng)
        let clauses: [Clause] = (0..<Int.random(in: numVars * 3...numVars * 7, using: &rng)).map { _ in
            (0..<Int.random(in: 1...4, using: &rng)).map { _ in
                let v = Int32.random(in: 1...Int32(numVars), using: &rng)
                return Bool.random(using: &rng) ? v : -v
            }
        }
        return CNF(numVars: numVars, clauses: clauses)
    }

    /// One random change: a hint, an ID, a literal, a dropped or swapped step, or a deletion of a random clause.
    private static func mutated(_ proof: LRATProof, cnf: CNF, _ rng: inout SplitMix64) -> LRATProof {
        var steps = proof.steps
        guard !steps.isEmpty else { return proof }
        let i = Int.random(in: 0..<steps.count, using: &rng)
        let anyID = Int.random(in: -1...(cnf.clauses.count + steps.count + 2), using: &rng)
        switch (Int.random(in: 0..<7, using: &rng), steps[i]) {
        case (0, .add(let id, let clause, var hints)) where !hints.isEmpty:
            hints[Int.random(in: 0..<hints.count, using: &rng)] = anyID
            steps[i] = .add(id: id, clause: clause, hints: hints)
        case (1, .add(_, let clause, let hints)):
            steps[i] = .add(id: anyID, clause: clause, hints: hints)
        case (2, .add(let id, var clause, let hints)) where !clause.isEmpty:
            clause.remove(at: Int.random(in: 0..<clause.count, using: &rng))
            steps[i] = .add(id: id, clause: clause, hints: hints)
        case (3, _):
            steps.remove(at: i)
        case (4, _) where i + 1 < steps.count:
            steps.swapAt(i, i + 1)
        case (5, .add(let id, let clause, var hints)) where hints.count > 1:
            hints.swapAt(0, hints.count - 1)
            steps[i] = .add(id: id, clause: clause, hints: hints)
        default:
            steps.insert(.delete(ids: [anyID]), at: i)
        }
        return LRATProof(steps: steps)
    }

    // MARK: the reference: LRATChecker before S2, which loaded every original clause first

    private static func eagerFailure(_ cnf: CNF, _ proof: LRATProof) -> LRATError? {
        do {
            try eagerVerify(cnf: cnf, proof: proof)
            return nil
        } catch {
            return error as? LRATError
        }
    }

    private static func eagerVerify(cnf: CNF, proof: LRATProof) throws {
        var db = EagerDatabase(numVars: cnf.numVars)
        for (index, clause) in cnf.clauses.enumerated() { try db.insert(id: index + 1, clause, step: -1) }
        var derivedEmpty = false
        for (index, step) in proof.steps.enumerated() {
            if derivedEmpty { throw LRATError.stepAfterEmptyClause(step: index) }
            switch step {
            case .delete(let ids):
                for id in ids { try db.remove(id, step: index) }
            case .add(let id, let clause, let hints):
                if id <= db.largestID {
                    throw db.clauses[id] != nil || db.retired.contains(id)
                        ? LRATError.duplicateID(step: index, id: id) : LRATError.idNotIncreasing(step: index, id: id)
                }
                try db.checkDerivation(of: clause, hints: hints, step: index)
                try db.insert(id: id, clause, step: index)
                derivedEmpty = clause.isEmpty
            }
        }
        if !derivedEmpty { throw LRATError.emptyClauseNotDerived }
    }

    private struct EagerDatabase {
        let numVars: Int
        var clauses: [Int: [Int32]] = [:]
        var retired: Set<Int> = []
        var largestID = 0
        var values: [Int8]
        var assigned: [Int] = []
        var stamp: [Int]
        var stampCounter = 0

        init(numVars: Int) {
            self.numVars = numVars
            values = Array(repeating: 0, count: numVars + 1)
            stamp = Array(repeating: 0, count: 2 * numVars + 2)
        }

        func value(_ lit: Int32) -> Int8 { lit > 0 ? values[Int(lit)] : -values[Int(-lit)] }

        mutating func set(_ lit: Int32) {
            values[Int(lit.magnitude)] = lit > 0 ? 1 : -1
            assigned.append(Int(lit.magnitude))
        }

        func validate(_ lit: Int32, step: Int) throws {
            if lit == 0 || Int(lit.magnitude) > numVars { throw LRATError.invalidLiteral(step: step, literal: lit) }
        }

        mutating func insert(id: Int, _ clause: Clause, step: Int) throws {
            stampCounter += 1
            var lits: [Int32] = []
            for lit in clause {
                try validate(lit, step: step)
                let slot = 2 * Int(lit.magnitude) + (lit < 0 ? 1 : 0)
                if stamp[slot] != stampCounter {
                    stamp[slot] = stampCounter
                    lits.append(lit)
                }
            }
            clauses[id] = lits
            largestID = max(largestID, id)
        }

        mutating func remove(_ id: Int, step: Int) throws {
            guard clauses.removeValue(forKey: id) != nil else {
                throw retired.contains(id) ? LRATError.deletedClause(step: step, id: id) : LRATError.unknownClause(step: step, id: id)
            }
            retired.insert(id)
        }

        // swiftlint:disable:next cyclomatic_complexity
        mutating func checkDerivation(of clause: Clause, hints: [Int], step: Int) throws {
            defer {
                for v in assigned { values[v] = 0 }
                assigned.removeAll(keepingCapacity: true)
            }
            for lit in clause {
                try validate(lit, step: step)
                if value(lit) == 1 { return }
                if value(lit) == 0 { set(-lit) }
            }
            var conflict = false
            for id in hints {
                if conflict { throw LRATError.hintAfterConflict(step: step, id: id) }
                guard let lits = clauses[id] else {
                    throw retired.contains(id) ? LRATError.deletedClause(step: step, id: id) : LRATError.unknownClause(step: step, id: id)
                }
                var open: Int32 = 0
                var openCount = 0
                for lit in lits {
                    switch value(lit) {
                    case 1: throw LRATError.hintSatisfied(step: step, id: id)
                    case 0: open = lit; openCount += 1
                    default: break
                    }
                }
                switch openCount {
                case 0: conflict = true
                case 1: set(open)
                default: throw LRATError.hintNotUnit(step: step, id: id)
                }
            }
            if !conflict { throw LRATError.missingConflict(step: step) }
        }
    }
}
