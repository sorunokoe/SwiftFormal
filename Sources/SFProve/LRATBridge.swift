import SFCheck
package import SFSAT

extension LRATProof {
    /// Converts the solver's untrusted log into the checker's input type (same shape, no logic).
    package init(_ log: LRATLog) {
        self.init(
            steps: log.steps.map { step in
                switch step {
                case .add(let id, let clause, let hints): return .add(id: id, clause: clause, hints: hints)
                case .delete(let ids): return .delete(ids: ids)
                }
            })
    }
}
