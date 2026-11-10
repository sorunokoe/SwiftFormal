// Reading guide
// Entry points: `Solver.solve` (RUP proof on unsat) and `Solver.solveLRAT` (LRAT proof), both with a conflict budget.
// One algorithm, read in file order: literals, loading, propagation, variable order, conflict analysis,
// database maintenance, proof log, then `run`, the search loop that ties them together.
// Proofs are never trusted here: `SFCheck` re-checks them with its own code.
// Tests: Tests/SFSATTests (SolverTests, LRATTests, CheckerTests).

package import SFCNF

/// Deterministic CDCL solver: two watched literals with blockers over a flat clause arena, first-UIP learning
/// with recursive minimization, VSIDS on a binary heap, phase saving, glucose-style EMA restarts, LBD-based
/// learned-clause reduction and level-0 simplification.
///
/// Every learned clause is logged together with its LRAT hint chain: the IDs of the clauses that unit propagation uses,
/// in trail order, to reach a conflict once the learned clause is assumed false. Original clauses have IDs `1...n` in input
/// order. Level-0 facts get their own unit clauses, so hints never need to chase level-0 reasons. The log is trimmed to
/// the clauses the refutation needs, and the RUP proof is its list of added clauses.
package struct Solver {
    private struct Watch {
        var cref: Int32
        var blocker: Int32
    }

    private struct EMA {
        let alpha: Double
        var value = 0.0
        var decay = 1.0
        init(alpha: Double) { self.alpha = alpha }
        mutating func update(_ x: Double) {
            value += alpha * (x - value)
            decay *= 1 - alpha
        }
        /// Bias-corrected estimate, so early samples are not dragged toward the zero start value.
        var estimate: Double { decay < 1 ? value / (1 - decay) : 0 }
    }

    private static let headerSize = 3
    private static let learntFlag: Int32 = 1
    private static let garbageFlag: Int32 = 2
    private static let usedShift: Int32 = 2
    private static let usedMask: Int32 = 3 << 2
    private static let lbdShift: Int32 = 4
    private static let lbdShiftMask: Int32 = (1 << 4) - 1

    private let numVars: Int
    private let decay = 0.95
    /// Clause at `cref`: `[size, flags, lratID, lit0, lit1, ...]`.
    /// Literals are `2 * var + (negated ? 1 : 0)`.
    private var arena: ContiguousArray<Int32> = []
    // LRAT bookkeeping. `unitID[v]` is the ID of a unit clause that fixes variable `v` at level 0 (0 if none).
    private var nextID: Int32
    private var unitID: [Int32]
    private var trailPos: ContiguousArray<Int32>
    /// Variables the first-UIP walk resolved, in strictly descending trail order.
    private var hintVars: [Int32] = []
    /// Variables that clause minimization had to derive, in no particular order.
    private var minimizedVars: [Int32] = []
    /// Reused by `isRedundant`, which runs for most literals of every learned clause.
    private var redundantStack: [Int32] = []
    private var zeroVars: [Int32] = []
    private var hintKeys: [UInt64] = []
    private var depStamp: UInt32 = 0
    private var nodeStamp: [UInt32]
    private var levelZeroDone = 0
    // Flat proof log. A step with `logID > 0` adds that clause; `logID == 0` deletes the IDs stored in its hint range.
    private var logID: [Int32] = []
    private var logLitEnd: [Int] = []
    private var logHintEnd: [Int] = []
    private var logLits: [Int32] = []
    private var logHints: [Int32] = []
    private var learnts: [Int32] = []
    private var watches: [ContiguousArray<Watch>]
    private var values: ContiguousArray<Int8>  // per literal: 1 true, -1 false, 0 unassigned
    private var level: ContiguousArray<Int32>
    private var reason: ContiguousArray<Int32>
    private var trail: ContiguousArray<Int32>
    private var trailSize = 0
    private var trailLimits: [Int] = []
    private var queueHead = 0
    private var activity: [Double]
    private var activityIncrement = 1.0
    private var heap: [Int32] = []
    private var heapPos: [Int32]
    private var phase: [Bool]
    private var seen: [UInt8]
    private var toClear: [Int32] = []
    private var levelStamp: [UInt32]
    private var stampCounter: UInt32 = 0
    private var unsatAtLoad = false
    private var conflictsSeen = 0

    package init(cnf: CNF) {
        numVars = cnf.numVars
        watches = Array(repeating: [], count: 2 * cnf.numVars)
        values = ContiguousArray(repeating: 0, count: 2 * cnf.numVars)
        level = ContiguousArray(repeating: 0, count: cnf.numVars)
        reason = ContiguousArray(repeating: -1, count: cnf.numVars)
        activity = Array(repeating: 0, count: cnf.numVars)
        heapPos = Array(repeating: -1, count: cnf.numVars)
        phase = Array(repeating: false, count: cnf.numVars)
        seen = Array(repeating: 0, count: cnf.numVars)
        levelStamp = Array(repeating: 0, count: cnf.numVars + 2)
        nodeStamp = Array(repeating: 0, count: cnf.numVars)
        trail = ContiguousArray(repeating: 0, count: cnf.numVars)
        trailPos = ContiguousArray(repeating: 0, count: cnf.numVars)
        unitID = Array(repeating: 0, count: cnf.numVars)
        nextID = Int32(cnf.clauses.count) + 1
        for (index, clause) in cnf.clauses.enumerated() { addOriginal(clause, id: Int32(index + 1)) }
        for v in 0..<cnf.numVars { heapInsert(v) }
    }

    private enum Outcome {
        case sat([Bool])
        case unsat
        case unknown
    }

    /// Solves with a deterministic budget on the number of conflicts. An `unsat` answer carries a RUP proof.
    package static func solve(_ cnf: CNF, conflictBudget: Int = 1_000_000) -> SolveResult {
        var solver = Solver(cnf: cnf)
        switch solver.run(conflictBudget: conflictBudget) {
        case .sat(let model): return .sat(model: model)
        case .unsat: return .unsat(proof: LRATLog(steps: solver.trimmedLog()).rupProof)
        case .unknown: return .unknown
        }
    }

    /// Like `solve`, but an `unsat` answer carries an LRAT proof (see `LRATLog`).
    package static func solveLRAT(_ cnf: CNF, conflictBudget: Int = 1_000_000) -> LRATSolveResult {
        solveLRATReporting(cnf, conflictBudget: conflictBudget).outcome
    }

    /// Like `solveLRAT`, and also reports what the run spent (`SolveStats`). The answer is the one `solveLRAT` gives.
    package static func solveLRATReporting(_ cnf: CNF, conflictBudget: Int = 1_000_000) -> LRATSolveReport {
        var solver = Solver(cnf: cnf)
        let outcome: LRATSolveResult
        switch solver.run(conflictBudget: conflictBudget) {
        case .sat(let model): outcome = .sat(model: model)
        case .unsat: outcome = .unsat(proof: LRATLog(steps: solver.trimmedLog()))
        case .unknown: outcome = .unknown
        }
        let stats = SolveStats(conflicts: solver.conflictsSeen, variables: cnf.numVars, clauses: cnf.clauses.count)
        return LRATSolveReport(outcome: outcome, stats: stats)
    }

    // MARK: literals

    private static func internalLit(_ lit: Int32) -> Int32 { lit > 0 ? 2 * (lit - 1) : 2 * (-lit - 1) + 1 }
    private static func externalLit(_ lit: Int32) -> Int32 { lit & 1 == 0 ? (lit >> 1) + 1 : -((lit >> 1) + 1) }
    private var decisionLevel: Int { trailLimits.count }

    private mutating func enqueue(_ lit: Int32, reason r: Int32) {
        let v = Int(lit >> 1)
        values[Int(lit)] = 1
        values[Int(lit ^ 1)] = -1
        level[v] = Int32(decisionLevel)
        reason[v] = r
        trailPos[v] = Int32(trailSize)
        trail[trailSize] = lit
        trailSize += 1
    }

    // MARK: loading

    private mutating func addOriginal(_ clause: Clause, id: Int32) {
        if unsatAtLoad { return }
        var lits: [Int32] = []
        for ext in clause {
            let lit = Solver.internalLit(ext)
            if lits.contains(lit) { continue }
            if lits.contains(lit ^ 1) { return }  // tautology
            lits.append(lit)
        }
        switch lits.count {
        case 0:
            unsatAtLoad = true
            logAdd(id: newID(), lits: [], hints: [id])
        case 1:
            let v = Int(lits[0] >> 1)
            if values[Int(lits[0])] == -1 {
                unsatAtLoad = true
                logAdd(id: newID(), lits: [], hints: [unitID[v], id])
            } else if values[Int(lits[0])] == 0 {
                enqueue(lits[0], reason: -1)
                unitID[v] = id
            }
        default: attach(lits, learnt: false, lbd: 0, id: id)
        }
    }

    @discardableResult
    private mutating func attach(_ lits: [Int32], learnt: Bool, lbd: Int, id: Int32) -> Int32 {
        let cref = Int32(arena.count)
        arena.append(Int32(lits.count))
        arena.append((learnt ? Solver.learntFlag : 0) | (Int32(lbd) << Solver.lbdShift))
        arena.append(id)
        arena.append(contentsOf: lits)
        let tag = lits.count == 2 ? ~cref : cref
        watches[Int(lits[0])].append(Watch(cref: tag, blocker: lits[1]))
        watches[Int(lits[1])].append(Watch(cref: tag, blocker: lits[0]))
        if learnt { learnts.append(cref) }
        return cref
    }

    // MARK: propagation

    // Static: a debug build copies `self` to call a method, which made `watches` shared and copied every watch list.
    private static func take<T>(_ array: inout [T]) -> [T] {
        var result: [T] = []
        swap(&result, &array)
        return result
    }

    private static func take<T>(_ array: inout ContiguousArray<T>) -> ContiguousArray<T> {
        var result: ContiguousArray<T> = []
        swap(&result, &array)
        return result
    }

    /// Returns the conflicting clause reference, or -1.
    private mutating func propagate() -> Int32 {
        var conflict: Int32 = -1
        // Moving the hot arrays into locals keeps the inner loop free of copy-on-write and exclusivity checks; their
        // mutable spans are bounds-checked but need no unsafe pointers. A span stays local: as a parameter or a stored
        // property it would link libswiftCompatibilitySpan.dylib, which macOS 13 to 15 do not ship
        // (Scripts/check-portability.py checks sfverify, which links this solver).
        var mem = Self.take(&arena)
        var val = Self.take(&values)
        var tr = Self.take(&trail)
        var lv = Self.take(&level)
        var rs = Self.take(&reason)
        var tp = Self.take(&trailPos)
        var head = queueHead
        var size = trailSize
        defer {
            arena = mem
            values = val
            trail = tr
            level = lv
            reason = rs
            trailPos = tp
            queueHead = head
            trailSize = size
        }
        let currentLevel = Int32(decisionLevel)
        do {
            var m = mem.mutableSpan
            var vals = val.mutableSpan
            var t = tr.mutableSpan
            var levels = lv.mutableSpan
            var reasons = rs.mutableSpan
            var positions = tp.mutableSpan
            while head < size && conflict < 0 {
                let falseLit = t[head] ^ 1
                head += 1
                var ws = Self.take(&watches[Int(falseLit)])
                let count = ws.count
                var i = 0, j = 0
                do {
                    var w = ws.mutableSpan
                    while i < count {
                        let watch = w[i]
                        i += 1
                        if vals[Int(watch.blocker)] == 1 {
                            w[j] = watch
                            j += 1
                            continue
                        }
                        if watch.cref < 0 {
                            w[j] = watch
                            j += 1
                            let other = watch.blocker
                            if vals[Int(other)] == -1 {
                                conflict = ~watch.cref
                                while i < count {
                                    w[j] = w[i]
                                    i += 1
                                    j += 1
                                }
                            } else {
                                let v = Int(other >> 1)
                                vals[Int(other)] = 1
                                vals[Int(other ^ 1)] = -1
                                levels[v] = currentLevel
                                reasons[v] = ~watch.cref
                                positions[v] = Int32(size)
                                t[size] = other
                                size += 1
                            }
                            continue
                        }
                        let base = Int(watch.cref) + Solver.headerSize
                        if m[base] == falseLit {
                            m[base] = m[base + 1]
                            m[base + 1] = falseLit
                        }
                        let first = m[base]
                        if first != watch.blocker && vals[Int(first)] == 1 {
                            w[j] = Watch(cref: watch.cref, blocker: first)
                            j += 1
                            continue
                        }
                        let end = base + Int(m[Int(watch.cref)])
                        var k = base + 2
                        while k < end && vals[Int(m[k])] == -1 { k += 1 }
                        if k < end {
                            let replacement = m[k]
                            m[base + 1] = replacement
                            m[k] = falseLit
                            watches[Int(replacement)].append(Watch(cref: watch.cref, blocker: first))
                            continue
                        }
                        w[j] = Watch(cref: watch.cref, blocker: first)
                        j += 1
                        if vals[Int(first)] == -1 {
                            conflict = watch.cref
                            while i < count {
                                w[j] = w[i]
                                i += 1
                                j += 1
                            }
                        } else {
                            let v = Int(first >> 1)
                            vals[Int(first)] = 1
                            vals[Int(first ^ 1)] = -1
                            levels[v] = currentLevel
                            reasons[v] = watch.cref
                            positions[v] = Int32(size)
                            t[size] = first
                            size += 1
                        }
                    }
                }
                ws.removeLast(count - j)
                watches[Int(falseLit)] = ws
            }
        }
        if conflict >= 0 { head = size }
        return conflict
    }

    // MARK: variable order

    private func heapBefore(_ a: Int32, _ b: Int32) -> Bool {
        let x = activity[Int(a)], y = activity[Int(b)]
        return x > y || (x == y && a < b)
    }

    private mutating func heapUp(_ start: Int) {
        var i = start
        let x = heap[i]
        while i > 0 {
            let parent = (i - 1) >> 1
            let px = heap[parent]
            if !heapBefore(x, px) { break }
            heap[i] = px
            heapPos[Int(px)] = Int32(i)
            i = parent
        }
        heap[i] = x
        heapPos[Int(x)] = Int32(i)
    }

    private mutating func heapDown(_ start: Int) {
        var i = start
        let x = heap[i]
        let n = heap.count
        while true {
            var child = 2 * i + 1
            if child >= n { break }
            if child + 1 < n && heapBefore(heap[child + 1], heap[child]) { child += 1 }
            if !heapBefore(heap[child], x) { break }
            heap[i] = heap[child]
            heapPos[Int(heap[i])] = Int32(i)
            i = child
        }
        heap[i] = x
        heapPos[Int(x)] = Int32(i)
    }

    private mutating func heapInsert(_ v: Int) {
        if heapPos[v] >= 0 { return }
        heap.append(Int32(v))
        heapPos[v] = Int32(heap.count - 1)
        heapUp(heap.count - 1)
    }

    private mutating func heapPop() -> Int {
        let top = heap[0]
        let last = heap.removeLast()
        heapPos[Int(top)] = -1
        if !heap.isEmpty {
            heap[0] = last
            heapPos[Int(last)] = 0
            heapDown(0)
        }
        return Int(top)
    }

    private mutating func bump(_ v: Int) {
        activity[v] += activityIncrement
        if activity[v] > 1e100 {
            for i in activity.indices { activity[i] *= 1e-100 }
            activityIncrement *= 1e-100
        }
        if heapPos[v] >= 0 { heapUp(Int(heapPos[v])) }
    }

    private mutating func pickBranchVariable() -> Int? {
        while !heap.isEmpty {
            let v = heapPop()
            if values[2 * v] == 0 { return v }
        }
        return nil
    }

    // MARK: conflict analysis

    private mutating func lbd(of lits: ArraySlice<Int32>) -> Int {
        stampCounter &+= 1
        var count = 0
        for lit in lits {
            let l = Int(level[Int(lit >> 1)])
            if levelStamp[l] != stampCounter {
                levelStamp[l] = stampCounter
                count += 1
            }
        }
        return count
    }

    /// Refreshes the quality data of a learned clause that took part in a conflict.
    private mutating func touch(_ cref: Int32) {
        let c = Int(cref)
        let flags = arena[c + 1]
        guard flags & Solver.learntFlag != 0 else { return }
        var newFlags = flags
        let oldLBD = Int(flags >> Solver.lbdShift)
        if oldLBD > 2 {
            let size = Int(arena[c])
            let fresh = lbd(of: arena[(c + Solver.headerSize)..<(c + Solver.headerSize + size)])
            if fresh < oldLBD {
                newFlags = (newFlags & Solver.lbdShiftMask) | (Int32(fresh) << Solver.lbdShift)
            }
        }
        let usedLevel: Int32 = Int(newFlags >> Solver.lbdShift) <= 6 ? 2 : 1
        newFlags = (newFlags & ~Solver.usedMask) | (usedLevel << Solver.usedShift)
        arena[c + 1] = newFlags
    }

    private mutating func recordLevelZero(_ v: Int) {
        if nodeStamp[v] != depStamp {
            nodeStamp[v] = depStamp
            zeroVars.append(Int32(v))
        }
    }

    /// True if `lit` is implied by the other literals marked in `seen` (recursive minimization).
    /// On success the variables it had to derive are left in `minimizedVars`; on failure all its bookkeeping is undone.
    private mutating func isRedundant(_ lit: Int32, abstractLevels: UInt32) -> Bool {
        var stack = Self.take(&redundantStack)
        defer { redundantStack = stack }
        stack.removeAll(keepingCapacity: true)
        stack.append(lit)
        let top = toClear.count
        let hintTop = minimizedVars.count
        let zeroTop = zeroVars.count
        while let q = stack.popLast() {
            let c = Int(reason[Int(q >> 1)])
            minimizedVars.append(q >> 1)
            let size = Int(arena[c])
            var k = Solver.headerSize
            while k < Solver.headerSize + size {
                let l = arena[c + k]
                k += 1
                let v = Int(l >> 1)
                if v == Int(q >> 1) { continue }
                if level[v] == 0 {
                    recordLevelZero(v)
                    continue
                }
                if seen[v] != 0 { continue }
                if reason[v] >= 0 && (1 << UInt32(level[v] & 31)) & abstractLevels != 0 {
                    seen[v] = 1
                    stack.append(l)
                    toClear.append(l)
                } else {
                    for m in top..<toClear.count { seen[Int(toClear[m] >> 1)] = 0 }
                    for z in zeroVars[zeroTop...] { nodeStamp[Int(z)] = 0 }
                    zeroVars.removeSubrange(zeroTop...)
                    minimizedVars.removeSubrange(hintTop...)
                    toClear.removeSubrange(top...)
                    return false
                }
            }
        }
        return true
    }

    /// First-UIP learning. Returns the learned clause (asserting literal first), the backjump level and its LBD.
    /// `hints` receives the LRAT chain: level-0 unit IDs, then the reason clauses of every implied variable in trail
    /// order, then the conflict clause.
    private mutating func analyze(_ conflictClause: Int32, hints: inout [Int32]) -> ([Int32], Int, Int) {
        var learnt: [Int32] = [0]
        var pathCount = 0
        var p: Int32 = -1
        var cursor = trailSize - 1
        var current = conflictClause
        let currentLevel = Int32(decisionLevel)
        depStamp &+= 1
        hintVars.removeAll(keepingCapacity: true)
        minimizedVars.removeAll(keepingCapacity: true)
        zeroVars.removeAll(keepingCapacity: true)
        repeat {
            touch(current)
            let c = Int(current)
            let size = Int(arena[c])
            var k = Solver.headerSize
            let skipVar = p < 0 ? -1 : Int(p >> 1)
            if p >= 0 { hintVars.append(p >> 1) }
            while k < Solver.headerSize + size {
                let q = arena[c + k]
                k += 1
                let v = Int(q >> 1)
                if v == skipVar { continue }
                if level[v] == 0 {
                    recordLevelZero(v)
                } else if seen[v] == 0 {
                    seen[v] = 1
                    bump(v)
                    if level[v] >= currentLevel { pathCount += 1 } else { learnt.append(q) }
                }
            }
            while seen[Int(trail[cursor] >> 1)] == 0 { cursor -= 1 }
            p = trail[cursor]
            cursor -= 1
            current = reason[Int(p >> 1)]
            seen[Int(p >> 1)] = 0
            pathCount -= 1
        } while pathCount > 0
        learnt[0] = p ^ 1

        // Drop literals implied by the others. Each drop keeps the clause RUP.
        toClear = learnt
        var kept = 1
        var abstractLevels: UInt32 = 0
        for i in 1..<learnt.count { abstractLevels |= 1 << UInt32(level[Int(learnt[i] >> 1)] & 31) }
        for i in 1..<learnt.count {
            let lit = learnt[i]
            if reason[Int(lit >> 1)] < 0 || !isRedundant(lit, abstractLevels: abstractLevels) {
                learnt[kept] = lit
                kept += 1
            }
        }
        learnt.removeLast(learnt.count - kept)
        for lit in toClear { seen[Int(lit >> 1)] = 0 }

        hints.removeAll(keepingCapacity: true)
        for z in zeroVars { hints.append(unitID[Int(z)]) }
        appendReasonsInTrailOrder(to: &hints)
        hints.append(arena[Int(conflictClause) + 2])

        var backjump = 0
        if learnt.count > 1 {
            var best = 1
            for i in 2..<learnt.count where level[Int(learnt[i] >> 1)] > level[Int(learnt[best] >> 1)] {
                best = i
            }
            learnt.swapAt(1, best)
            backjump = Int(level[Int(learnt[1] >> 1)])
        }
        let glue = lbd(of: learnt[...])
        activityIncrement /= decay
        return (learnt, backjump, glue)
    }

    /// Appends the reason clause IDs of `hintVars` and `minimizedVars` in ascending trail order. `hintVars` is already
    /// in descending order, so only `minimizedVars` is sorted and the two are merged. No two variables share a trail
    /// position, so this is the order a sort of both lists gives.
    private mutating func appendReasonsInTrailOrder(to hints: inout [Int32]) {
        hintKeys.removeAll(keepingCapacity: true)
        for v in minimizedVars {
            hintKeys.append(UInt64(trailPos[Int(v)]) << 32 | UInt64(UInt32(bitPattern: arena[Int(reason[Int(v)]) + 2])))
        }
        hintKeys.sort()
        var walked = hintVars.count - 1
        var minimized = 0
        while walked >= 0 || minimized < hintKeys.count {
            let next = walked >= 0 ? Int(hintVars[walked]) : -1
            if minimized < hintKeys.count && (next < 0 || hintKeys[minimized] >> 32 < UInt64(trailPos[next])) {
                hints.append(Int32(truncatingIfNeeded: hintKeys[minimized]))
                minimized += 1
            } else {
                hints.append(arena[Int(reason[next]) + 2])
                walked -= 1
            }
        }
    }

    private mutating func backtrack(to target: Int) {
        guard decisionLevel > target else { return }
        let limit = trailLimits[target]
        var i = trailSize - 1
        while i >= limit {
            let lit = trail[i]
            let v = Int(lit >> 1)
            phase[v] = lit & 1 == 0
            values[Int(lit)] = 0
            values[Int(lit ^ 1)] = 0
            reason[v] = -1
            heapInsert(v)
            i -= 1
        }
        trailSize = limit
        trailLimits.removeSubrange(target...)
        queueHead = trailSize
    }

    // MARK: database maintenance

    private func isLocked(_ cref: Int32) -> Bool {
        // Binary clauses may propagate either of their two literals.
        let first = arena[Int(cref) + Solver.headerSize]
        let second = arena[Int(cref) + Solver.headerSize + 1]
        return (values[Int(first)] == 1 && reason[Int(first >> 1)] == cref)
            || (values[Int(second)] == 1 && reason[Int(second >> 1)] == cref)
    }

    /// Deletes about half of the learned clauses that are not glue clauses, recently used, or reasons.
    private mutating func reduceLearnts() {
        var candidates: [(key: Int, cref: Int32)] = []
        for cref in learnts {
            let c = Int(cref)
            var flags = arena[c + 1]
            let glue = Int(flags >> Solver.lbdShift)
            if glue <= 2 || isLocked(cref) { continue }
            let used = (flags & Solver.usedMask) >> Solver.usedShift
            if used > 0 {
                flags = (flags & ~Solver.usedMask) | ((used - 1) << Solver.usedShift)
                arena[c + 1] = flags
                continue
            }
            candidates.append((glue << 32 | Int(arena[c]), cref))
        }
        candidates.sort { $0.key != $1.key ? $0.key > $1.key : $0.cref < $1.cref }
        for (_, cref) in candidates.prefix(candidates.count / 2) {
            arena[Int(cref) + 1] |= Solver.garbageFlag
        }
        compact(simplifying: false)
    }

    /// Rebuilds the arena without garbage clauses and re-creates all watch lists.
    /// With `simplifying` (decision level 0, fully propagated) satisfied clauses go and false literals are dropped.
    private mutating func compact(simplifying: Bool) {
        var fresh: ContiguousArray<Int32> = []
        fresh.reserveCapacity(arena.count)
        var freshLearnts: [Int32] = []
        var deleted: [Int32] = []
        var cref = 0
        while cref < arena.count {
            let size = Int(arena[cref])
            let flags = arena[cref + 1]
            let start = cref + Solver.headerSize
            defer { cref = start + size }
            if flags & Solver.garbageFlag != 0 || (simplifying && arena[start..<(start + size)].contains(where: { values[Int($0)] == 1 })) {
                deleted.append(arena[cref + 2])
                continue
            }
            let new = Int32(fresh.count)
            fresh.append(contentsOf: arena[cref..<(start + size)])
            arena[cref + 1] = new
            if flags & Solver.learntFlag != 0 { freshLearnts.append(new) }
        }
        for lit in trail[0..<trailSize] {
            let v = Int(lit >> 1)
            let r = reason[v]
            if r >= 0 { reason[v] = simplifying ? -1 : arena[Int(r) + 1] }
        }
        logDelete(deleted)
        arena = fresh
        learnts = freshLearnts
        for i in watches.indices { watches[i].removeAll(keepingCapacity: true) }
        var c = 0
        while c < arena.count {
            let size = Int(arena[c])
            let l0 = arena[c + Solver.headerSize], l1 = arena[c + Solver.headerSize + 1]
            let tag = size == 2 ? ~Int32(c) : Int32(c)
            watches[Int(l0)].append(Watch(cref: tag, blocker: l1))
            watches[Int(l1)].append(Watch(cref: tag, blocker: l0))
            c += Solver.headerSize + size
        }
    }

    // MARK: proof log

    private mutating func newID() -> Int32 {
        defer { nextID += 1 }
        return nextID
    }

    private mutating func logAdd(id: Int32, lits: [Int32], hints: [Int32]) {
        logID.append(id)
        logLits.append(contentsOf: lits)
        logHints.append(contentsOf: hints)
        logLitEnd.append(logLits.count)
        logHintEnd.append(logHints.count)
    }

    private mutating func logDelete(_ ids: [Int32]) {
        if ids.isEmpty { return }
        logID.append(0)
        logHints.append(contentsOf: ids)
        logLitEnd.append(logLits.count)
        logHintEnd.append(logHints.count)
    }

    /// Gives each new level-0 literal that was propagated its own unit clause, before any simplification discards the
    /// reason clauses. Later hints refer to these unit IDs instead of chasing level-0 reasons.
    private mutating func finalizeLevelZero() {
        var hints: [Int32] = []
        while levelZeroDone < trailSize {
            let lit = trail[levelZeroDone]
            let v = Int(lit >> 1)
            levelZeroDone += 1
            let r = Int(reason[v])
            if r < 0 { continue }
            hints.removeAll(keepingCapacity: true)
            for k in 0..<Int(arena[r]) {
                let other = Int(arena[r + Solver.headerSize + k] >> 1)
                if other != v { hints.append(unitID[other]) }
            }
            hints.append(arena[r + 2])
            let id = newID()
            logAdd(id: id, lits: [lit], hints: hints)
            unitID[v] = id
        }
    }

    /// The log reduced to the clauses the refutation needs, in derivation order, ending with the empty clause.
    /// Deletions of clauses that are not needed are dropped too.
    private func trimmedLog() -> [LRATLog.Step] {
        let count = logID.count
        func hintRange(_ step: Int) -> Range<Int> { (step == 0 ? 0 : logHintEnd[step - 1])..<logHintEnd[step] }
        func litRange(_ step: Int) -> Range<Int> { (step == 0 ? 0 : logLitEnd[step - 1])..<logLitEnd[step] }
        var needed = [Bool](repeating: false, count: Int(nextID))
        needed[Int(logID[count - 1])] = true
        for step in stride(from: count - 1, through: 0, by: -1) where logID[step] > 0 && needed[Int(logID[step])] {
            for h in logHints[hintRange(step)] { needed[Int(h)] = true }
        }
        var steps: [LRATLog.Step] = []
        for step in 0..<count {
            if logID[step] > 0 {
                guard needed[Int(logID[step])] else { continue }
                steps.append(
                    .add(
                        id: Int(logID[step]),
                        clause: logLits[litRange(step)].map(Solver.externalLit),
                        hints: logHints[hintRange(step)].map { Int($0) }))
            } else {
                let ids = logHints[hintRange(step)].filter { needed[Int($0)] }.map { Int($0) }
                if !ids.isEmpty { steps.append(.delete(ids: ids)) }
            }
        }
        return steps
    }

    // MARK: search

    private mutating func run(conflictBudget: Int) -> Outcome {
        if unsatAtLoad { return .unsat }
        conflictsSeen = 0
        var sinceRestart = 0
        var fast = EMA(alpha: 1.0 / 32), slow = EMA(alpha: 1.0 / 4096)
        let margin = 1.1
        let reduceFirst = 2000, reduceStep = 300
        var nextReduce = reduceFirst
        var reduceIncrement = reduceStep
        var simplifiedTrail = 0
        var hints: [Int32] = []
        while true {
            let conflict = propagate()
            if decisionLevel == 0 { finalizeLevelZero() }
            if conflict >= 0 {
                if decisionLevel == 0 {
                    var hints: [Int32] = []
                    let c = Int(conflict)
                    for k in 0..<Int(arena[c]) { hints.append(unitID[Int(arena[c + Solver.headerSize + k] >> 1)]) }
                    hints.append(arena[c + 2])
                    logAdd(id: newID(), lits: [], hints: hints)
                    return .unsat
                }
                conflictsSeen += 1
                sinceRestart += 1
                if conflictsSeen > conflictBudget { return .unknown }
                let (learnt, backjump, glue) = analyze(conflict, hints: &hints)
                let id = newID()
                logAdd(id: id, lits: learnt, hints: hints)
                fast.update(Double(glue))
                slow.update(Double(glue))
                backtrack(to: backjump)
                if learnt.count == 1 {
                    enqueue(learnt[0], reason: -1)
                    unitID[Int(learnt[0] >> 1)] = id
                } else {
                    let cref = attach(learnt, learnt: true, lbd: glue, id: id)
                    enqueue(learnt[0], reason: cref)
                }
            } else {
                if sinceRestart >= 2 && fast.estimate > margin * slow.estimate {
                    sinceRestart = 0
                    backtrack(to: 0)
                    if trailSize > simplifiedTrail {
                        compact(simplifying: true)
                        simplifiedTrail = trailSize
                    }
                    continue
                }
                if conflictsSeen >= nextReduce {
                    nextReduce = conflictsSeen + reduceFirst + reduceIncrement
                    reduceIncrement += reduceStep
                    reduceLearnts()
                }
                if let v = pickBranchVariable() {
                    trailLimits.append(trailSize)
                    enqueue(phase[v] ? 2 * Int32(v) : 2 * Int32(v) + 1, reason: -1)
                } else {
                    return .sat((0..<numVars).map { values[2 * $0] == 1 })
                }
            }
        }
    }
}
