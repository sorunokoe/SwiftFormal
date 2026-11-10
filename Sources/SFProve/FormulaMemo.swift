import Foundation
import SFBV
import SFCNF

/// The answers to formulas that cost the solver many conflicts, so that the same formula met again in this process
/// (the same function in the second build configuration, say) is not solved again (next-level plan item S3).
///
/// A formula is found again only when it is equal clause for clause, with the same inputs, budget and proof format: a
/// hash only narrows the search. A stored `proved` was accepted by the checker for an equal formula, a stored
/// counterexample satisfied an equal formula, and the solver is deterministic, so an answer from here is the answer
/// solving again would give, statistics included.
final class FormulaMemo: @unchecked Sendable {
    struct Key: Hashable {
        var numVars: Int
        var clauseCount: Int
        var inputs: [[Int32]]
        var conflictBudget: Int
        var proofFormat: ProofFormat
    }

    /// Answers that took fewer conflicts are cheaper to find again than to keep.
    static let minimumConflicts = 2_000
    /// At most this many clauses are kept, over all formulas.
    static let capacity = 20_000_000

    static let shared = FormulaMemo()

    private let lock = NSLock()
    private var entries: [Key: [(clauses: [Clause], outcome: ProofOutcome)]] = [:]
    private var stored = 0

    static func key(_ cnf: CNF, inputs: [BV], conflictBudget: Int, proofFormat: ProofFormat) -> Key {
        Key(
            numVars: cnf.numVars, clauseCount: cnf.clauses.count, inputs: inputs.map(\.bits),
            conflictBudget: conflictBudget, proofFormat: proofFormat)
    }

    /// The answer kept for a formula equal to `cnf`, if any.
    func outcome(of cnf: CNF, key: Key) -> ProofOutcome? {
        lock.lock()
        let candidates = entries[key] ?? []
        lock.unlock()
        return candidates.first { $0.clauses == cnf.clauses }?.outcome
    }

    /// Keeps `outcome` for `cnf` when it was costly and there is room.
    func record(_ outcome: ProofOutcome, of cnf: CNF, key: Key) {
        guard outcome.verdict == .unknown || outcome.stats.conflicts >= Self.minimumConflicts else { return }
        lock.lock()
        defer { lock.unlock() }
        guard stored + cnf.clauses.count <= Self.capacity else { return }
        if entries[key]?.contains(where: { $0.clauses == cnf.clauses }) == true { return }
        entries[key, default: []].append((cnf.clauses, outcome))
        stored += cnf.clauses.count
    }
}
