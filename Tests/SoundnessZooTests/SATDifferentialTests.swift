import Foundation
import SFCNF
import SFCheck
import SFSAT
import SwiftFormal
import Testing

/// How many random formulas each differential test runs. The default keeps the fast lane fast; a run before a release raises it
/// (`SF_DIFFERENTIAL_SEEDS=20000`). Seeds are `0 ..< count`, so a failing seed printed in a report reproduces exactly:
/// `SF_SEED=<seed>` runs just that one (docs/TESTING.md).
private let seedCount: Int = ProcessInfo.processInfo.environment["SF_DIFFERENTIAL_SEEDS"].flatMap(Int.init) ?? 200

private let seeds: Range<Int> = ProcessInfo.processInfo.environment["SF_SEED"].flatMap(Int.init).map { $0..<($0 + 1) } ?? 0..<seedCount

private let chunkSize = 50

/// A small random formula: at most 12 variables, clauses of 1 to 4 literals (repeats and tautologies allowed), and now and
/// then an empty clause. Small enough to enumerate every assignment.
private func randomFormula(seed: UInt64) -> CNF {
    var rng = SplitMix64(seed: seed)
    let numVars = Int.random(in: 1...12, using: &rng)
    let clauseCount = Int.random(in: 0...numVars * 5, using: &rng)
    var clauses: [Clause] = []
    for _ in 0..<clauseCount {
        if Int.random(in: 0..<200, using: &rng) == 0 {
            clauses.append([])
            continue
        }
        let length = Int.random(in: 1...4, using: &rng)
        clauses.append(
            (0..<length).map { _ in
                let variable = Int32.random(in: 1...Int32(numVars), using: &rng)
                return Bool.random(using: &rng) ? variable : -variable
            })
    }
    return CNF(numVars: numVars, clauses: clauses)
}

/// Every assignment checked: the reference the solver is compared against.
private func bruteForceSatisfiable(_ cnf: CNF) -> Bool {
    let masks = cnf.clauses.map { clause -> (positive: UInt32, negative: UInt32) in
        var positive: UInt32 = 0
        var negative: UInt32 = 0
        for literal in clause {
            if literal > 0 { positive |= 1 << UInt32(literal - 1) } else { negative |= 1 << UInt32(-literal - 1) }
        }
        return (positive, negative)
    }
    for assignment in UInt32(0)..<(1 << UInt32(cnf.numVars)) {
        if masks.allSatisfy({ assignment & $0.positive != 0 || ~assignment & $0.negative != 0 }) { return true }
    }
    return false
}

private func describe(_ cnf: CNF, seed: UInt64) -> String {
    "seed \(seed), numVars \(cnf.numVars), clauses \(cnf.clauses)"
}

private enum Answer: Equatable { case sat, unsat, unknown }

/// Solves, and holds the solver's own claims to account: a model must satisfy the formula, an UNSAT proof must check.
private func answer(_ cnf: CNF, seed: UInt64, label: String = "") -> Answer {
    let context = label + describe(cnf, seed: seed)
    switch Solver.solve(cnf) {
    case .sat(let model):
        #expect(model.count >= cnf.numVars, "short model: \(context)")
        guard model.count >= cnf.numVars else { return .sat }
        #expect(cnf.isSatisfied(by: model), "the reported model does not satisfy the formula: \(context)")
        return .sat
    case .unsat(let proof):
        #expect(RUPChecker.check(cnf: cnf, proof: proof), "the RUP proof does not check: \(context)")
        if case .unsat(let log) = Solver.solveLRAT(cnf) {
            #expect(LRATChecker.check(cnf: cnf, proof: LRATProof(log)), "the LRAT proof does not check: \(context)")
        } else {
            Issue.record("solve and solveLRAT disagree: \(context)")
        }
        return .unsat
    case .unknown:
        return .unknown
    }
}

private func chunkRange(_ chunk: Int) -> Range<Int> {
    let lower = seeds.lowerBound + chunk * chunkSize
    return lower..<min(lower + chunkSize, seeds.upperBound)
}

private let chunks = Array(0..<max(1, (seeds.count + chunkSize - 1) / chunkSize))

/// The SAT solver against exhaustive enumeration. A wrong SAT/UNSAT answer here is a soundness bug in the engine.
@Suite struct SATDifferentialTests {
    @Test(arguments: chunks)
    func solverAgreesWithBruteForceAndItsCertificatesCheck(_ chunk: Int) {
        for index in chunkRange(chunk) {
            let seed = UInt64(index)
            let cnf = randomFormula(seed: seed)
            let expected = bruteForceSatisfiable(cnf)
            let got = answer(cnf, seed: seed)
            #expect(
                got == (expected ? .sat : .unsat),
                "solver said \(got), brute force said \(expected ? "sat" : "unsat"): \(describe(cnf, seed: seed))")
        }
    }

    @Test func theGeneratorProducesBothSatisfiableAndUnsatisfiableFormulas() {
        let verdicts = (0..<100).map { bruteForceSatisfiable(randomFormula(seed: UInt64($0))) }
        #expect(verdicts.contains(true))
        #expect(verdicts.contains(false))
    }
}

/// Changes to a formula that cannot change whether it is satisfiable. The solver's answer must not change either.
@Suite struct SATMetamorphicTests {
    enum Relation: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case clausePermutation, variableRenaming, polarityFlip, clauseDuplication

        var testDescription: String { rawValue }

        func apply(to cnf: CNF, using rng: inout SplitMix64) -> CNF {
            switch self {
            case .clausePermutation:
                return CNF(numVars: cnf.numVars, clauses: cnf.clauses.shuffled(using: &rng))
            case .variableRenaming:
                let renaming = (1...Int32(cnf.numVars)).shuffled(using: &rng)
                return CNF(
                    numVars: cnf.numVars, clauses: cnf.clauses.map { $0.map { $0 > 0 ? renaming[Int($0) - 1] : -renaming[Int(-$0) - 1] } })
            case .polarityFlip:
                let flipped = (0..<cnf.numVars).map { _ in Bool.random(using: &rng) }
                return CNF(numVars: cnf.numVars, clauses: cnf.clauses.map { $0.map { flipped[Int(abs($0)) - 1] ? -$0 : $0 } })
            case .clauseDuplication:
                let copies = cnf.clauses.filter { _ in Bool.random(using: &rng) }
                return CNF(numVars: cnf.numVars, clauses: (cnf.clauses + copies).shuffled(using: &rng))
            }
        }
    }

    @Test(arguments: Relation.allCases)
    func theAnswerSurvivesTheTransformation(_ relation: Relation) {
        for index in seeds {
            let seed = UInt64(index)
            let original = randomFormula(seed: seed)
            var rng = SplitMix64(seed: seed &+ 0x9E37_79B9)
            let transformed = relation.apply(to: original, using: &rng)
            let before = answer(original, seed: seed)
            let after = answer(transformed, seed: seed, label: "\(relation) ")
            #expect(
                before == after,
                "\(relation) changed the answer from \(before) to \(after): \(describe(original, seed: seed)) became \(transformed.clauses)"
            )
        }
    }
}
