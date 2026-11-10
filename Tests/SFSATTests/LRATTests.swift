import Foundation
import Testing
import SFBV
import SFCNF
import SFSAT
import SFCheck
import SFProve
import SFTestSupport

// MARK: helpers

private struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

private func random3(_ n: Int, _ m: Int, _ rng: inout Rng) -> CNF {
    CNF(
        numVars: n,
        clauses: (0..<m).map { _ in
            var vars: [Int32] = []
            while vars.count < 3 {
                let v = Int32(rng.below(n)) + 1
                if !vars.contains(v) { vars.append(v) }
            }
            return vars.map { rng.next() & 1 == 0 ? $0 : -$0 }
        })
}

/// Units, binaries, ternaries, duplicate literals and tautologies.
private func mixed(_ n: Int, _ rng: inout Rng) -> CNF {
    CNF(
        numVars: n,
        clauses: (0..<(n + rng.below(3 * n))).map { _ in
            let r = rng.below(10)
            let length = r < 1 ? 1 : (r < 4 ? 2 : 3)
            return (0..<length).map { _ in
                let v = Int32(rng.below(n)) + 1
                return rng.next() & 1 == 0 ? v : -v
            }
        })
}

private func pigeonhole(_ pigeons: Int, _ holes: Int) -> CNF {
    var clauses: [Clause] = []
    for p in 0..<pigeons { clauses.append((0..<holes).map { Int32(p * holes + $0 + 1) }) }
    for h in 0..<holes {
        for p in 0..<pigeons {
            for q in (p + 1)..<pigeons {
                clauses.append([-Int32(p * holes + h + 1), -Int32(q * holes + h + 1)])
            }
        }
    }
    return CNF(numVars: pigeons * holes, clauses: clauses)
}

private func clamp64CNF() -> CNF {
    let c = CNFBuilder()
    let v = [c.input(width: 64), c.input(width: 64), c.input(width: 64)]
    let (x, lo, hi) = (v[0], v[1], v[2])
    let clamped = c.select(c.slt(x, lo), lo, c.select(c.slt(hi, x), hi, x))
    let goal = c.or(c.slt(hi, lo), c.and(c.sle(lo, clamped), c.sle(clamped, hi)))
    c.addClause([-goal])
    return c.cnf
}

private func mulCommutesCNF(_ width: Int) -> CNF {
    let c = CNFBuilder()
    let a = c.input(width: width), b = c.input(width: width)
    c.addClause([-c.eq(c.mul(a, b), c.mul(b, a))])
    return c.cnf
}

private func bruteForceSatisfiable(_ cnf: CNF) -> Bool {
    for bits in 0..<(1 << cnf.numVars) {
        if cnf.isSatisfied(by: (0..<cnf.numVars).map { (bits >> $0) & 1 == 1 }) { return true }
    }
    return false
}

private func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18 }

private func timed<T>(_ body: () -> T) -> (T, Double) {
    let start = ContinuousClock.now
    let value = body()
    return (value, seconds(ContinuousClock.now - start))
}

private func lratProof(_ cnf: CNF, budget: Int = 1_000_000) -> LRATProof? {
    if case .unsat(let log) = Solver.solveLRAT(cnf, conflictBudget: budget) { return LRATProof(log) }
    return nil
}

private func failure(_ cnf: CNF, _ steps: [LRATStep]) -> LRATError? {
    do {
        try LRATChecker.verify(cnf: cnf, proof: LRATProof(steps: steps))
        return nil
    } catch let error as LRATError {
        return error
    } catch {
        return nil
    }
}

private func rupClauses(_ steps: [LRATStep]) -> [Clause] {
    steps.compactMap { if case .add(_, let clause, _) = $0 { return clause } else { return nil } }
}

// MARK: tests

@Suite(.serialized, .tags(.slow)) struct LRATTests {
    // (a ∨ b) (¬a ∨ b) (a ∨ ¬b) (¬a ∨ ¬b): IDs 1...4.
    static let square = CNF(numVars: 2, clauses: [[1, 2], [-1, 2], [1, -2], [-1, -2]])

    // MARK: checker, hand-written proofs

    @Test func acceptsHandWrittenProof() throws {
        let proof = LRATProof(steps: [
            .add(id: 5, clause: [2], hints: [1, 2]),  // assume ¬b: (a ∨ b) forces a, then (¬a ∨ b) is falsified
            .add(id: 6, clause: [], hints: [5, 4, 3]),  // b holds: (¬a ∨ ¬b) forces ¬a, then (a ∨ ¬b) is falsified
        ])
        try LRATChecker.verify(cnf: Self.square, proof: proof)
    }

    @Test func rejectsEachMalformation() {
        let sq = Self.square
        let good: [LRATStep] = [.add(id: 5, clause: [2], hints: [1, 2]), .add(id: 6, clause: [], hints: [5, 4, 3])]
        #expect(failure(sq, good) == nil)
        #expect(failure(sq, [.add(id: 5, clause: [2], hints: [1, 9])]) == .unknownClause(step: 0, id: 9))
        #expect(failure(sq, [good[0], .delete(ids: [3]), .add(id: 6, clause: [], hints: [5, 4, 3])]) == .deletedClause(step: 2, id: 3))
        #expect(failure(sq, [.delete(ids: [7])]) == .unknownClause(step: 0, id: 7))
        #expect(failure(sq, [.delete(ids: [1]), .delete(ids: [1])]) == .deletedClause(step: 1, id: 1))
        #expect(failure(sq, [.add(id: 4, clause: [2], hints: [1, 2])]) == .duplicateID(step: 0, id: 4))
        #expect(failure(sq, [.delete(ids: [1]), .add(id: 1, clause: [2], hints: [1, 2])]) == .duplicateID(step: 1, id: 1))
        #expect(failure(sq, [good[0], .add(id: 5, clause: [], hints: [5, 4, 3])]) == .duplicateID(step: 1, id: 5))
        #expect(
            failure(sq, [.add(id: 9, clause: [2], hints: [1, 2]), .add(id: 7, clause: [], hints: [9, 4, 3])])
                == .idNotIncreasing(step: 1, id: 7))
        #expect(failure(sq, [.add(id: 5, clause: [], hints: [1])]) == .hintNotUnit(step: 0, id: 1))
        #expect(failure(sq, [.add(id: 5, clause: [2], hints: [3])]) == .hintSatisfied(step: 0, id: 3))
        #expect(failure(sq, [.add(id: 5, clause: [2], hints: [1, 2, 3])]) == .hintAfterConflict(step: 0, id: 3))
        #expect(failure(sq, [.add(id: 5, clause: [2], hints: [1])]) == .missingConflict(step: 0))
        #expect(failure(sq, [.add(id: 5, clause: [2], hints: [])]) == .missingConflict(step: 0))
        #expect(failure(sq, [good[0], good[1], .add(id: 7, clause: [], hints: [1])]) == .stepAfterEmptyClause(step: 2))
        #expect(failure(sq, [good[0]]) == .emptyClauseNotDerived)
        #expect(failure(sq, []) == .emptyClauseNotDerived)
        #expect(failure(sq, [.add(id: 5, clause: [3], hints: [1])]) == .invalidLiteral(step: 0, literal: 3))
        #expect(failure(sq, [.add(id: 5, clause: [0], hints: [1])]) == .invalidLiteral(step: 0, literal: 0))
        #expect(failure(sq, [.add(id: 5, clause: [2], hints: [-1, 2])]) == .unknownClause(step: 0, id: -1))
    }

    @Test func satisfiableFormulaCannotBeRefuted() {
        let sat = CNF(numVars: 2, clauses: [[1, 2], [-1, 2]])
        #expect(failure(sat, [.add(id: 3, clause: [], hints: [1, 2])]) != nil)
        #expect(failure(sat, [.add(id: 3, clause: [], hints: [])]) != nil)
    }

    @Test func tautologyIsAcceptedWithoutHints() {
        let steps: [LRATStep] = [
            .add(id: 5, clause: [1, -1], hints: []), .add(id: 6, clause: [2], hints: [1, 2]),
            .add(id: 7, clause: [], hints: [6, 4, 3]),
        ]
        #expect(failure(Self.square, steps) == nil)
    }

    @Test func duplicateLiteralsInClausesBehaveAsSets() {
        let cnf = CNF(numVars: 2, clauses: [[1, 1], [-1, 2, 2], [-2]])
        #expect(failure(cnf, [.add(id: 4, clause: [], hints: [1, 2, 3])]) == nil)
    }

    @Test func textRoundTrip() throws {
        let cnf = Self.square
        guard let proof = lratProof(cnf) else { Issue.record("expected unsat"); return }
        let text = proof.text(originalCount: cnf.clauses.count)
        let parsed = try LRATProof.parse(text)
        #expect(parsed == proof)
        try LRATChecker.verify(cnf: cnf, proof: parsed)
        #expect(
            try LRATProof.parse("c comment\n5 2 0 3 1 0\n5 d 3 0\n").steps
                == [.add(id: 5, clause: [2], hints: [3, 1]), .delete(ids: [3])])
        #expect(throws: LRATError.self) { try LRATProof.parse("5 2 0 3 1\n") }
        #expect(throws: LRATError.self) { try LRATProof.parse("5 2 3 0\n") }
        #expect(throws: LRATError.self) { try LRATProof.parse("x 2 0 3 0\n") }
        #expect(throws: LRATError.self) { try LRATProof.parse("5 d 3\n") }
    }

    // MARK: solver proofs

    @Test func degenerateFormulas() throws {
        let cases: [CNF] = [
            CNF(numVars: 1, clauses: [[]]),
            CNF(numVars: 1, clauses: [[1], [-1]]),
            CNF(numVars: 1, clauses: [[1, -1], [1], [1, 1], [-1, -1]]),
            CNF(numVars: 3, clauses: [[1], [-1, 2], [-2, 3], [-3]]),
            CNF(numVars: 3, clauses: [[1, 2], [-1], [-2], [3]]),
            Self.square,
        ]
        for cnf in cases {
            guard let proof = lratProof(cnf) else { Issue.record("expected unsat"); continue }
            try LRATChecker.verify(cnf: cnf, proof: proof)
            guard case .unsat(let rup) = Solver.solve(cnf) else { Issue.record("expected unsat"); continue }
            #expect(RUPChecker.check(cnf: cnf, proof: rup))
        }
    }

    @Test func randomSmallInstancesAgreeWithBruteForce() throws {
        var rng = Rng(state: 11)
        var unsat = 0, sat = 0
        for i in 0..<500 {
            let n = 8 + rng.below(6)
            let cnf = i % 2 == 0 ? random3(n, Int(Double(n) * 4.6), &rng) : mixed(n, &rng)
            switch Solver.solveLRAT(cnf) {
            case .sat(let model):
                sat += 1
                #expect(cnf.isSatisfied(by: model))
                #expect(bruteForceSatisfiable(cnf))
            case .unsat(let log):
                unsat += 1
                #expect(!bruteForceSatisfiable(cnf))
                let proof = LRATProof(log)
                do { try LRATChecker.verify(cnf: cnf, proof: proof) } catch { Issue.record("rejected: \(error)") }
                #expect(RUPChecker.check(cnf: cnf, proof: log.rupProof))
                #expect(try LRATProof.parse(proof.text(originalCount: cnf.clauses.count)) == proof)
            case .unknown:
                Issue.record("unexpected unknown")
            }
        }
        #expect(sat > 50 && unsat > 50)
    }

    @Test func pigeonholeProofsAreAccepted() throws {
        for (p, h) in [(4, 3), (6, 5), (8, 7)] {
            let cnf = pigeonhole(p, h)
            guard let proof = lratProof(cnf) else { Issue.record("expected unsat"); continue }
            try LRATChecker.verify(cnf: cnf, proof: proof)
        }
    }

    /// Learned-clause reduction (deletions), restarts and level-0 simplification all run on these.
    @Test func proofsWithDeletionsAreAccepted() throws {
        let cnf = pigeonhole(9, 8)
        guard let proof = lratProof(cnf) else { Issue.record("expected unsat"); return }
        let deletions = proof.steps.filter { if case .delete = $0 { return true } else { return false } }.count
        #expect(deletions > 0)
        try LRATChecker.verify(cnf: cnf, proof: proof)
    }

    @Test func thresholdStressEveryUnsatHasAcceptedProof() throws {
        var rng = Rng(state: 2026)
        var unsat = 0, sat = 0, steps = 0
        for _ in 0..<240 {
            let n = 30 + rng.below(31)
            let cnf = random3(n, Int((Double(n) * 4.26).rounded()), &rng)
            switch Solver.solveLRAT(cnf) {
            case .sat(let model):
                sat += 1
                #expect(cnf.isSatisfied(by: model))
            case .unsat(let log):
                unsat += 1
                steps += log.steps.count
                do { try LRATChecker.verify(cnf: cnf, proof: LRATProof(log)) } catch { Issue.record("rejected: \(error)") }
                #expect(RUPChecker.check(cnf: cnf, proof: log.rupProof))
            case .unknown:
                Issue.record("unexpected unknown")
            }
        }
        print("LRAT stress: \(sat) sat, \(unsat) unsat (all LRAT- and RUP-checked), \(steps) proof steps")
        #expect(sat + unsat == 240 && unsat >= 50 && sat >= 50)
    }

    // MARK: mutations

    private static func mutationBase() -> (CNF, [LRATStep]) {
        var rng = Rng(state: 5)
        while true {
            let cnf = random3(45, 192, &rng)
            if let proof = lratProof(cnf), proof.steps.count > 150 { return (cnf, proof.steps) }
        }
    }

    @Test func mutatedProofsAreRejected() throws {
        let (cnf, steps) = Self.mutationBase()
        #expect(failure(cnf, steps) == nil)
        let adds = steps.indices.filter { if case .add(_, _, let h) = steps[$0] { return !h.isEmpty } else { return false } }
        var rng = Rng(state: 77)
        var counts: [String: Int] = [:]
        func mutate(_ name: String, _ transform: (inout [LRATStep], Int) -> Void) {
            for _ in 0..<60 {
                let index = adds[rng.below(adds.count)]
                var copy = steps
                transform(&copy, index)
                #expect(failure(cnf, copy) != nil, "\(name) at step \(index) was accepted")
                counts[name, default: 0] += 1
            }
        }
        func edit(_ copy: inout [LRATStep], _ index: Int, _ change: (inout Int, inout Clause, inout [Int]) -> Void) {
            if case .add(var id, var clause, var hints) = copy[index] {
                change(&id, &clause, &hints)
                copy[index] = .add(id: id, clause: clause, hints: hints)
            }
        }
        mutate("drop last hint") { copy, i in edit(&copy, i) { _, _, h in h.removeLast() } }
        mutate("hint -> unknown ID") { copy, i in edit(&copy, i) { _, _, h in h[h.count / 2] = 1 << 40 } }
        mutate("hint -> negative (RAT) ID") { copy, i in edit(&copy, i) { _, _, h in h[0] = -h[0] } }
        mutate("hint -> clause not yet added") { copy, i in
            edit(&copy, i) { id, _, h in h[h.count - 1] = id + 1 }
        }
        mutate("duplicate ID") { copy, i in
            edit(&copy, i) { id, _, _ in id = cnf.clauses.count }
        }
        mutate("ID not increasing") { copy, i in
            edit(&copy, i) { id, _, _ in id = 0 }
        }
        mutate("delete a needed clause early") { copy, i in
            guard case .add(_, _, let h) = copy[i] else { return }
            copy.insert(.delete(ids: [h[h.count / 2]]), at: i)
        }
        mutate("truncate") { copy, i in copy.removeSubrange(i...) }
        mutate("drop the empty clause") { copy, _ in copy.removeLast() }
        mutate("clause literal out of range") { copy, i in edit(&copy, i) { _, c, _ in c.append(Int32(cnf.numVars + 1)) } }
        mutate("stray step after the empty clause") { copy, _ in
            copy.append(.add(id: 1 << 30, clause: [], hints: [1]))
        }
        print("LRAT mutations rejected: \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
    }

    /// Mutations that may by chance still be valid derivations. The checker must stay sound: whenever it accepts one,
    /// the independent RUP checker must accept the same clause list.
    @Test func orderMutationsNeverAcceptWhatRUPRejects() {
        let (cnf, steps) = Self.mutationBase()
        let adds = steps.indices.filter { if case .add(_, _, let h) = steps[$0] { return h.count >= 3 } else { return false } }
        var rng = Rng(state: 99)
        var accepted = 0, rejected = 0
        for round in 0..<300 {
            var copy = steps
            let index = adds[rng.below(adds.count)]
            guard case .add(let id, let clause, var hints) = copy[index] else { continue }
            let a = rng.below(hints.count)
            var b = rng.below(hints.count)
            if b == a { b = (a + 1) % hints.count }
            switch round % 3 {
            case 0: hints.swapAt(a, b)
            case 1: hints.remove(at: a)
            default: hints[a] = hints[b]
            }
            copy[index] = .add(id: id, clause: clause, hints: hints)
            if failure(cnf, copy) == nil {
                accepted += 1
                #expect(RUPChecker.check(cnf: cnf, proof: rupClauses(copy)))
            } else {
                rejected += 1
            }
        }
        print("LRAT hint swap/drop/duplicate mutations: \(rejected) rejected, \(accepted) still valid derivations")
        #expect(rejected > accepted)
    }

    /// Replaces one original clause by a tautology so that the formula becomes satisfiable, keeping all IDs.
    /// No proof, original or mutated, may then be accepted.
    @Test func nothingIsProvedForSatisfiableFormulas() {
        var rng = Rng(state: 123)
        var tested = 0
        while tested < 12 {
            let cnf = random3(40, 170, &rng)
            guard let proof = lratProof(cnf) else { continue }
            var clauseIndex = 0
            var weakened: CNF?
            for _ in 0..<40 {
                clauseIndex = rng.below(cnf.clauses.count)
                var clauses = cnf.clauses
                clauses[clauseIndex] = [1, -1]
                let candidate = CNF(numVars: cnf.numVars, clauses: clauses)
                if case .sat = Solver.solve(candidate) { weakened = candidate; break }
            }
            guard let sat = weakened else { continue }
            tested += 1
            #expect(failure(sat, proof.steps) != nil)
            for _ in 0..<40 {
                var copy = proof.steps
                let index = rng.below(copy.count)
                if case .add(let id, let clause, var hints) = copy[index], !hints.isEmpty {
                    hints.remove(at: rng.below(hints.count))
                    copy[index] = .add(id: id, clause: clause, hints: hints)
                }
                #expect(failure(sat, copy) != nil)
            }
            // Even claiming the empty clause with every clause as hint must fail.
            let all = Array(1...sat.clauses.count)
            #expect(failure(sat, [.add(id: sat.clauses.count + 1, clause: [], hints: all)]) != nil)
        }
    }

    // MARK: prove()

    @Test func proveUsesLRATByDefaultAndRUPOnRequest() throws {
        let claim: (CNFBuilder, [BV]) throws -> Int32 = { c, v in c.eq(c.add(v[0], v[1]).sum, c.add(v[1], v[0]).sum) }
        #expect(try prove(inputWidths: [12, 12], claim: claim) == .proved)
        #expect(try prove(inputWidths: [12, 12], proofFormat: .rup, claim: claim) == .proved)
        #expect(try prove(inputWidths: [12, 12], proofFormat: .lrat, claim: claim) == .proved)
        let wrong: (CNFBuilder, [BV]) throws -> Int32 = { c, v in c.eq(c.add(v[0], v[1]).sum, v[0]) }
        guard case .counterexample = try prove(inputWidths: [8, 8], claim: wrong) else { Issue.record("expected counterexample"); return }
    }

    // MARK: timing

    @Test func timingTable() throws {
        var rng = Rng(state: 99)
        let random = (0..<10).map { _ in random3(200, 852, &rng) }
        var rows: [(String, [CNF])] = [
            ("clamp64", [clamp64CNF()]), ("mul8 commutes", [mulCommutesCNF(8)]), ("pigeonhole 8 (9 into 8)", [pigeonhole(9, 8)]),
            ("random 3-SAT n=200 x10", random),
        ]
        if ProcessInfo.processInfo.environment["SF_LRAT_BIG"] != nil {
            rows += [("mul9 commutes", [mulCommutesCNF(9)]), ("pigeonhole 9 (10 into 9)", [pigeonhole(10, 9)])]
        }
        print("LRAT TIMING (release, shared machine, noisy): solve | RUP check | LRAT check | steps | hints | text KB")
        for (name, cnfs) in rows {
            var solveTime = 0.0, rupTime = 0.0, lratTime = 0.0, stepCount = 0, hintCount = 0, bytes = 0, proofs = 0
            for cnf in cnfs {
                let (result, t) = timed { Solver.solveLRAT(cnf, conflictBudget: 5_000_000) }
                solveTime += t
                guard case .unsat(let log) = result else { continue }
                proofs += 1
                let proof = LRATProof(log)
                let (lratOK, tl) = timed { LRATChecker.check(cnf: cnf, proof: proof) }
                #expect(lratOK, "LRAT rejected \(name)")
                lratTime += tl
                let clauses = log.rupProof
                let (rupOK, tr) = timed { RUPChecker.check(cnf: cnf, proof: clauses) }
                #expect(rupOK, "RUP rejected \(name)")
                rupTime += tr
                stepCount += log.steps.count
                for case .add(_, _, let h) in log.steps { hintCount += h.count }
                bytes += proof.text(originalCount: cnf.clauses.count).utf8.count
            }
            print(
                String(
                    format:
                        "LRAT TIMING %@: %d proofs | solve %.3f s | RUP %.3f s | LRAT %.3f s | speedup %.1fx | %d steps | %d hints | %d KB",
                    name, proofs, solveTime, rupTime, lratTime, lratTime > 0 ? rupTime / lratTime : 0, stepCount, hintCount, bytes / 1024))
        }
    }
}
