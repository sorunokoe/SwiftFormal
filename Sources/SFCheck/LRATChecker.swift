package import SFCNF

/// One line of an LRAT proof. Original clauses of the formula have IDs `1...n` in input order.
package enum LRATStep: Sendable, Equatable {
    /// Adds `clause` under `id`. `hints` are IDs of live clauses, in the order unit propagation uses them.
    case add(id: Int, clause: Clause, hints: [Int])
    case delete(ids: [Int])
}

package struct LRATProof: Sendable, Equatable {
    package var steps: [LRATStep]

    package init(steps: [LRATStep]) {
        self.steps = steps
    }

    /// Standard text LRAT: `id lits 0 hints 0` and `id d ids 0`. A deletion line starts with the last added ID
    /// (`originalCount` before the first addition); the checker never reads that number.
    package func text(originalCount: Int = 0) -> String {
        var out = ""
        var lastID = originalCount
        for step in steps {
            switch step {
            case .add(let id, let clause, let hints):
                lastID = id
                out += ([id] + clause.map { Int($0) } + [0] + hints + [0]).map(String.init).joined(separator: " ") + "\n"
            case .delete(let ids):
                out += "\(lastID) d " + (ids + [0]).map(String.init).joined(separator: " ") + "\n"
            }
        }
        return out
    }

    /// Parses text LRAT. Blank lines and lines starting with `c` are skipped. RAT hints (negative IDs) parse fine
    /// and are rejected by the checker.
    package static func parse(_ text: String) throws -> LRATProof {
        var steps: [LRATStep] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            if tokens.isEmpty || tokens[0] == "c" { continue }
            func fail(_ reason: String) -> LRATError { .malformed(line: index + 1, reason: reason) }
            guard tokens.last == "0" else { throw fail("line does not end with 0") }
            guard let id = Int(tokens[0]), id > 0 else { throw fail("bad clause ID") }
            var numbers: [Int] = []
            if tokens.count > 1 && tokens[1] == "d" {
                for token in tokens[2...] {
                    guard let n = Int(token) else { throw fail("bad number \(token)") }
                    numbers.append(n)
                }
                guard numbers.filter({ $0 == 0 }).count == 1 else { throw fail("deletion must have one terminator") }
                steps.append(.delete(ids: Array(numbers.dropLast())))
                continue
            }
            for token in tokens[1...] {
                guard let n = Int(token) else { throw fail("bad number \(token)") }
                numbers.append(n)
            }
            guard numbers.filter({ $0 == 0 }).count == 2, let split = numbers.firstIndex(of: 0) else {
                throw fail("expected `lits 0 hints 0`")
            }
            let literals = numbers[..<split]
            guard literals.allSatisfy({ $0 >= Int(Int32.min) && $0 <= Int(Int32.max) }) else { throw fail("literal out of range") }
            steps.append(.add(id: id, clause: literals.map { Int32($0) }, hints: Array(numbers[(split + 1)..<(numbers.count - 1)])))
        }
        return LRATProof(steps: steps)
    }
}

/// Why a proof was rejected. `step` is the index into `LRATProof.steps`; -1 means the input formula.
package enum LRATError: Error, Equatable {
    case invalidLiteral(step: Int, literal: Int32)
    case duplicateID(step: Int, id: Int)
    case idNotIncreasing(step: Int, id: Int)
    case unknownClause(step: Int, id: Int)
    case deletedClause(step: Int, id: Int)
    /// The hint clause has a true literal under the current assignment.
    case hintSatisfied(step: Int, id: Int)
    /// The hint clause has two or more unassigned literals.
    case hintNotUnit(step: Int, id: Int)
    case hintAfterConflict(step: Int, id: Int)
    case missingConflict(step: Int)
    case stepAfterEmptyClause(step: Int)
    case emptyClauseNotDerived
    case malformed(line: Int, reason: String)
}

/// Independent LRAT checker. It shares no code with the solver and does no search: for each added clause it
/// assigns the clause false, then follows the hints, each of which must be unit under the current assignment
/// (its one open literal becomes true) or, as the last hint, falsified. Accepted iff the empty clause is derived
/// and every step checks.
///
/// Rules: added IDs are strictly increasing and above all original IDs; hints and deletions may only name live
/// clauses; hints after a conflict, satisfied hints and hints with two open literals are errors; nothing may
/// follow the empty clause. A clause containing both `x` and `-x` is a tautology and is accepted without hints.
/// Variables are limited to those of the formula (no extension variables). RAT steps are not supported.
/// An original clause is read when a step first names it, so an invalid literal in a clause the proof never names is
/// not an error: a proof that refutes some of the clauses refutes all of them.
package enum LRATChecker {
    package static func check(cnf: CNF, proof: LRATProof) -> Bool {
        (try? verify(cnf: cnf, proof: proof)) != nil
    }

    package static func verify(cnf: CNF, proof: LRATProof) throws {
        var db = Database(numVars: cnf.numVars, originals: cnf.clauses)
        var derivedEmpty = false
        for (index, step) in proof.steps.enumerated() {
            if derivedEmpty { throw LRATError.stepAfterEmptyClause(step: index) }
            switch step {
            case .delete(let ids):
                for id in ids { try db.remove(id, step: index) }
            case .add(let id, let clause, let hints):
                if id <= db.largestID {
                    throw db.originals.indices.contains(id - 1) || db.clauses[id] != nil || db.retired.contains(id)
                        ? LRATError.duplicateID(step: index, id: id) : LRATError.idNotIncreasing(step: index, id: id)
                }
                try db.checkDerivation(of: clause, hints: hints, step: index)
                try db.insert(id: id, clause, step: index)
                derivedEmpty = clause.isEmpty
            }
        }
        if !derivedEmpty { throw LRATError.emptyClauseNotDerived }
    }

    private struct Database {
        let numVars: Int
        /// The formula's clauses, IDs `1...originals.count`; each is stored in `clauses` when a step first names it.
        let originals: [Clause]
        var clauses: [Int: [Int32]] = [:]
        var retired: Set<Int> = []
        var largestID: Int
        var values: [Int8]  // per variable: 1 true, -1 false, 0 open
        var assigned: [Int] = []
        var stamp: [Int]
        var stampCounter = 0

        init(numVars: Int, originals: [Clause]) {
            self.numVars = numVars
            self.originals = originals
            largestID = originals.count
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

        /// Stores the clause as a set of distinct literals, and returns them.
        @discardableResult mutating func insert(id: Int, _ clause: Clause, step: Int) throws -> [Int32] {
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
            return lits
        }

        /// The live clause `id`, an original one read in on first use.
        mutating func live(_ id: Int, step: Int) throws -> [Int32] {
            if let lits = clauses[id] { return lits }
            guard id >= 1, id <= originals.count, !retired.contains(id) else {
                throw retired.contains(id) ? LRATError.deletedClause(step: step, id: id) : LRATError.unknownClause(step: step, id: id)
            }
            return try insert(id: id, originals[id - 1], step: step)
        }

        mutating func remove(_ id: Int, step: Int) throws {
            _ = try live(id, step: step)
            clauses[id] = nil
            retired.insert(id)
        }

        mutating func checkDerivation(of clause: Clause, hints: [Int], step: Int) throws {
            defer {
                for v in assigned { values[v] = 0 }
                assigned.removeAll(keepingCapacity: true)
            }
            for lit in clause {
                try validate(lit, step: step)
                if value(lit) == 1 { return }  // tautology
                if value(lit) == 0 { set(-lit) }
            }
            var conflict = false
            for id in hints {
                if conflict { throw LRATError.hintAfterConflict(step: step, id: id) }
                let lits = try live(id, step: step)
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
