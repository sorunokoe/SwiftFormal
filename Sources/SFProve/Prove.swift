public import SFBV
import SFCNF
import SFCheck
package import SFSAT

/// The result of a SAT proof: proved, a counterexample, or unknown.
public enum ProofVerdict: Sendable, Equatable {
    case proved
    /// Input values (one per input, in order) for which the claim is false.
    case counterexample([UInt64])
    case unknown
}

/// Why a proof was rejected after the solver answered.
public enum ProveError: Error {
    /// The solver's proof or model failed independent checking. This is an internal bug, never a verdict.
    case proofRejected
    case modelRejected
}

/// How an UNSAT answer is certified before `prove` returns `.proved`.
public enum ProofFormat: Sendable {
    /// The solver logs hints; `LRATChecker` follows them (near-linear time).
    case lrat
    /// The solver logs clauses only; `RUPChecker` rediscovers unit propagation (slow fallback).
    case rup
}

/// How `prove` builds the circuits it hands to the solver.
public enum ProofStrategy: Sendable {
    /// Builds every circuit exactly. Best for adders, comparisons and branches.
    case exact
    /// Abstracts each multiplication and refines it only when the solver needs the exact product.
    /// Far faster when a claim needs only algebraic facts about products, and no better when it needs the exact multiplier.
    /// The proof is always checked as `.lrat`, whatever `proofFormat` says.
    case refiningMultipliers
}

/// Proves that `claim` holds for all inputs of the given widths, or finds a counterexample.
/// UNSAT answers are accepted only after the independent checker for `proofFormat` accepts the solver's proof.
///
/// `inputSignedBits[i]`, when set, declares input `i` to be a sign-extended value of that many bits.
/// The solver then needs no assumption clause, and multiplications of such inputs shrink to their real width.
///
/// Both strategies give the same verdicts. A counterexample from `.refiningMultipliers` is returned only after the
/// claim has been replayed with exact multiplication on the concrete inputs.
public func prove(
    inputWidths: [Int],
    inputSignedBits: [Int?]? = nil,
    conflictBudget: Int = 1_000_000,
    strategy: ProofStrategy = .exact,
    proofFormat: ProofFormat = .lrat,
    claim: (CNFBuilder, [BV]) throws -> Int32
) throws -> ProofVerdict {
    try proveReporting(
        inputWidths: inputWidths, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget,
        strategy: strategy, proofFormat: proofFormat, claim: claim
    ).verdict
}

/// What a proof spent: its verdict and the solver's deterministic counts (`SolveStats`).
/// With `.refiningMultipliers`, `conflicts` is the sum over every solver round and `variables` and `clauses` describe the last formula.
package struct ProofOutcome: Sendable {
    package var verdict: ProofVerdict
    package var stats: ProofStats
}

/// The solver's deterministic counts for one proof (the front-end copy of `SolveStats`, so callers need not import `SFSAT`).
package struct ProofStats: Sendable, Equatable {
    package var conflicts: Int
    package var variables: Int
    package var clauses: Int

    package init(_ solve: SolveStats) {
        conflicts = solve.conflicts
        variables = solve.variables
        clauses = solve.clauses
    }
}

/// `prove`, and also reports what the solver spent. The verdict is the one `prove` returns.
package func proveReporting(
    inputWidths: [Int],
    inputSignedBits: [Int?]? = nil,
    conflictBudget: Int = 1_000_000,
    strategy: ProofStrategy = .exact,
    proofFormat: ProofFormat = .lrat,
    claim: (CNFBuilder, [BV]) throws -> Int32
) throws -> ProofOutcome {
    switch strategy {
    case .exact:
        return try proveExactly(
            inputWidths: inputWidths, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget,
            proofFormat: proofFormat, claim: claim
        )
    case .refiningMultipliers:
        let outcome = try proveRefiningDetailed(
            inputWidths: inputWidths, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget
        ) { c, inputs, multiplier in
            multiplier.install()
            return try claim(c, inputs)
        }
        return ProofOutcome(verdict: outcome.verdict, stats: ProofStats(outcome.stats.solve))
    }
}

/// Proves `claim` with exact circuits.
/// Keeps the signature `prove` had before `strategy:` existed, so code that compiled against it still does.
@_disfavoredOverload
public func prove(
    inputWidths: [Int],
    inputSignedBits: [Int?]? = nil,
    conflictBudget: Int = 1_000_000,
    proofFormat: ProofFormat = .lrat,
    claim: (CNFBuilder, [BV]) throws -> Int32
) throws -> ProofVerdict {
    try proveExactly(
        inputWidths: inputWidths, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget,
        proofFormat: proofFormat, claim: claim
    ).verdict
}

private func proveExactly(
    inputWidths: [Int],
    inputSignedBits: [Int?]?,
    conflictBudget: Int,
    proofFormat: ProofFormat,
    claim: (CNFBuilder, [BV]) throws -> Int32
) throws -> ProofOutcome {
    let builder = CNFBuilder()
    let inputs = inputWidths.enumerated().map { i, width in
        if let bits = inputSignedBits?[i], bits < width { return builder.input(width: width, signedBits: bits) }
        return builder.input(width: width)
    }
    let goal = try claim(builder, inputs)
    builder.addClause([-goal])
    let cnf = builder.cnf
    let memoKey = FormulaMemo.key(cnf, inputs: inputs, conflictBudget: conflictBudget, proofFormat: proofFormat)
    if let known = FormulaMemo.shared.outcome(of: cnf, key: memoKey) { return known }
    // The solver gets only the clauses the negated goal depends on (`CNFCone`); its proof is renumbered and its model
    // extended to the whole formula, and both are checked against the whole formula.
    let cone = builder.cone()
    let report = Solver.solveLRATReporting(cone.cnf, conflictBudget: conflictBudget)
    func outcome(_ verdict: ProofVerdict) -> ProofOutcome {
        var stats = ProofStats(report.stats)
        stats.clauses = cnf.clauses.count
        let outcome = ProofOutcome(verdict: verdict, stats: stats)
        FormulaMemo.shared.record(outcome, of: cnf, key: memoKey)
        return outcome
    }
    switch report.outcome {
    case .unsat(let coneLog):
        let log = coneLog.renumbered(from: cone, formulaClauses: cnf.clauses.count)
        let accepted: Bool
        switch proofFormat {
        case .lrat: accepted = LRATChecker.check(cnf: cnf, proof: LRATProof(log))
        case .rup: accepted = RUPChecker.check(cnf: cnf, proof: log.rupProof)
        }
        guard accepted else { throw ProveError.proofRejected }
        return outcome(.proved)
    case .sat(let coneModel):
        let model = builder.extend(coneModel, outside: cone)
        guard cnf.isSatisfied(by: model) else { throw ProveError.modelRejected }
        return outcome(.counterexample(inputs.map { builder.value(of: $0, in: model) }))
    case .unknown:
        return outcome(.unknown)
    }
}

extension LRATLog {
    /// This proof of `cone.cnf` with the clause IDs of the whole formula: kept clause `i` is the formula's clause
    /// `cone.kept[i - 1] + 1`, and each derived ID moves past the formula's last clause, in the same order.
    func renumbered(from cone: CNFCone, formulaClauses n: Int) -> LRATLog {
        let m = cone.kept.count
        guard m < n else { return self }
        func id(_ k: Int) -> Int { k <= m ? cone.kept[k - 1] + 1 : k - m + n }
        return LRATLog(
            steps: steps.map { step in
                switch step {
                case .add(let k, let clause, let hints): .add(id: id(k), clause: clause, hints: hints.map(id))
                case .delete(let ids): .delete(ids: ids.map(id))
                }
            })
    }
}
