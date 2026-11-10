package import SFCNF

/// The part of a builder's formula that a refutation can need: every clause no gate owns (the constant `[1]`, the
/// negated goal, any assumption), and the clauses of each gate such a clause reaches through gate inputs. The gates
/// left out define variables nothing in the cone reads, so every assignment that satisfies the cone extends to the
/// whole formula (`CNFBuilder.extend`), and a refutation of the cone refutes the whole formula.
package struct CNFCone {
    /// The cone: the kept clauses in their original order, over the builder's variables.
    package let cnf: CNF
    /// The index in the whole formula of each kept clause, ascending.
    package let kept: [Int]
    /// Per variable: whether a kept clause mentions it.
    let reached: [Bool]
}

extension CNFBuilder {
    /// A Tseitin gate: `output = a ∧ b` (three clauses) or `output = a ⊕ b` (four), from clause `first` on.
    /// `first == 0` means the variable is no gate output (clause 0 is the constant `[1]`).
    struct Gate {
        var first: Int32 = 0
        var a: Int32 = 0
        var b: Int32 = 0
        var isXor = false
        var clauseCount: Int { isXor ? 4 : 3 }
    }

    /// Records that the next clauses define `output` from `a` and `b`. Called just before they are added.
    func recordGate(_ output: Int32, _ a: Int32, _ b: Int32, isXor: Bool) {
        let o = Int(output)
        if gates.count <= o { gates.append(contentsOf: repeatElement(Gate(), count: o + 1 - gates.count)) }
        gates[o] = Gate(first: Int32(clauses.count), a: a, b: b, isXor: isXor)
    }

    /// The cone of the formula built so far (see `CNFCone`).
    package func cone() -> CNFCone {
        var owned = [Bool](repeating: false, count: clauses.count)
        for gate in gates where gate.first != 0 {
            for k in Int(gate.first)..<(Int(gate.first) + gate.clauseCount) { owned[k] = true }
        }
        var keep = [Bool](repeating: false, count: clauses.count)
        var reached = [Bool](repeating: false, count: numVars + 1)
        var pending: [Int] = []
        func reach(_ lit: Int32) {
            let v = Int(lit.magnitude)
            if !reached[v] {
                reached[v] = true
                pending.append(v)
            }
        }
        for k in clauses.indices where !owned[k] {
            keep[k] = true
            for lit in clauses[k] { reach(lit) }
        }
        while let v = pending.popLast() {
            guard v < gates.count, gates[v].first != 0 else { continue }
            let gate = gates[v]
            for k in Int(gate.first)..<(Int(gate.first) + gate.clauseCount) { keep[k] = true }
            reach(gate.a)
            reach(gate.b)
        }
        let kept = clauses.indices.filter { keep[$0] }
        return CNFCone(cnf: CNF(numVars: numVars, clauses: kept.map { clauses[$0] }), kept: kept, reached: reached)
    }

    /// `model` (the value of variable `i + 1` at `i`, as the solver answers for the cone) with every gate outside the
    /// cone set to what its inputs give, in variable order: a gate's inputs are older than its output.
    package func extend(_ model: [Bool], outside cone: CNFCone) -> [Bool] {
        var model = model
        for v in gates.indices where gates[v].first != 0 && !cone.reached[v] {
            let gate = gates[v]
            let a = model[Int(gate.a.magnitude) - 1] == (gate.a > 0)
            let b = model[Int(gate.b.magnitude) - 1] == (gate.b > 0)
            model[v - 1] = gate.isXor ? a != b : a && b
        }
        return model
    }
}
