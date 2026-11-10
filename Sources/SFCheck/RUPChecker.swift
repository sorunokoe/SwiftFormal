package import SFCNF

/// Independent checker for refutations given as RUP clause lists.
/// It shares no code with the solver: it has its own watched-literal unit propagation.
/// A clause is accepted if assuming all its literals false makes unit propagation reach a conflict.
package enum RUPChecker {
    package static func check(cnf: CNF, proof: [Clause]) -> Bool {
        guard proof.last?.isEmpty == true else { return false }
        func valid(_ clause: Clause) -> Bool {
            clause.allSatisfy { $0 != 0 && Int(abs($0)) <= cnf.numVars }
        }
        guard cnf.clauses.allSatisfy(valid), proof.allSatisfy(valid) else { return false }

        var state = State(numVars: cnf.numVars)
        for clause in cnf.clauses { state.addAtBase(clause) }
        for clause in proof {
            guard state.isRUP(clause) else { return false }
            state.addAtBase(clause)
        }
        return true
    }

    /// Invariant: the base assignment (decided by unit clauses) is fully propagated unless `inconsistent`.
    private struct State {
        var values: [Int8]  // per variable: 0 unassigned, 1 true, -1 false
        var watches: [[Int]]
        var database: [Clause] = []
        var trail: [Int32] = []
        var head = 0
        var inconsistent = false

        init(numVars: Int) {
            values = Array(repeating: 0, count: numVars + 1)
            watches = Array(repeating: [], count: 2 * numVars + 2)
        }

        func index(_ lit: Int32) -> Int { lit > 0 ? 2 * Int(lit) : 2 * Int(-lit) + 1 }
        func value(_ lit: Int32) -> Int8 {
            let v = values[Int(abs(lit))]
            return lit > 0 ? v : -v
        }

        mutating func assign(_ lit: Int32) {
            values[Int(abs(lit))] = lit > 0 ? 1 : -1
            trail.append(lit)
        }

        /// Adds a clause under the permanent base assignment.
        mutating func addAtBase(_ clause: Clause) {
            if inconsistent { return }
            var lits: [Int32] = []
            for lit in clause {
                switch value(lit) {
                case 1: return  // already satisfied forever
                case -1: continue  // false forever
                default:
                    if lits.contains(-lit) { return }  // tautology
                    if !lits.contains(lit) { lits.append(lit) }
                }
            }
            switch lits.count {
            case 0: inconsistent = true
            case 1:
                assign(lits[0])
                if propagate() { inconsistent = true }
            default:
                let ci = database.count
                database.append(lits)
                watches[index(lits[0])].append(ci)
                watches[index(lits[1])].append(ci)
            }
        }

        mutating func isRUP(_ clause: Clause) -> Bool {
            if inconsistent { return true }
            let mark = trail.count
            defer {
                for lit in trail[mark...] { values[Int(abs(lit))] = 0 }
                trail.removeSubrange(mark...)
                head = mark
            }
            for lit in clause {
                // A true literal means the clause is implied by the base units or is a tautology.
                if value(lit) == 1 { return true }
                if value(lit) == 0 { assign(-lit) }
            }
            return propagate()
        }

        /// Propagates the pending trail. Returns true on conflict.
        mutating func propagate() -> Bool {
            while head < trail.count {
                let falseLit = -trail[head]
                head += 1
                let wi = index(falseLit)
                let list = watches[wi]
                watches[wi] = []
                var conflict = false
                for ci in list {
                    if conflict {
                        watches[wi].append(ci)
                        continue
                    }
                    if database[ci][0] == falseLit { database[ci].swapAt(0, 1) }
                    let first = database[ci][0]
                    if value(first) == 1 {
                        watches[wi].append(ci)
                        continue
                    }
                    var moved = false
                    for m in 2..<max(2, database[ci].count) where value(database[ci][m]) != -1 {
                        database[ci].swapAt(1, m)
                        watches[index(database[ci][1])].append(ci)
                        moved = true
                        break
                    }
                    if moved { continue }
                    watches[wi].append(ci)
                    if value(first) == -1 { conflict = true } else { assign(first) }
                }
                if conflict { return true }
            }
            return false
        }
    }
}
