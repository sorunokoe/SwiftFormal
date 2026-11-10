package import SFBV
import SFCNF
import SFCheck
package import SFSAT

// Abstract-then-refine multiplication (backlog item C5).
//
// Each product `x * y` first becomes a fresh output vector (an uninterpreted function) constrained only by
// lemmas that are true facts about modular multiplication. If the solver proves the claim on that abstract
// problem, the claim holds for the real multiplier too, because every real product satisfies every lemma.
// A model of the abstract problem is only a candidate: nodes whose output disagrees with the real product are
// refined to the exact circuit, and a counterexample is reported only after the claim is replayed with exact
// multiplication on concrete inputs.
//
// Trust: the lemma clauses are axioms (the RUP checker accepts them as part of the formula). Everything the
// solver derives from them is checked as in `prove`. The lemma families are listed at `addLemmas(for:)`.

/// Multiplication that is abstract until refined. Claims call `mul` instead of `CNFBuilder.mul`.
package final class MulAbstraction {
    package enum Mode: Sendable { case abstract, exact }

    package let cnf: CNFBuilder
    package let mode: Mode

    struct Node {
        let x: BV
        let y: BV
        let out: BV
        var refined = false
    }

    private struct Key: Hashable { let x: [Int32], y: [Int32] }

    private(set) var nodes: [Node] = []
    private var index: [Key: Int] = [:]
    private var factorsOf: [[Int32]: [BV]] = [:]
    package private(set) var lemmaClauseCount = 0

    package init(cnf: CNFBuilder, mode: Mode = .abstract) {
        self.cnf = cnf
        self.mode = mode
    }

    /// Routes every non-constant multiplication, and the multiply-overflow flags, that is built through the
    /// builder (for example by a SIL or LLVM encoder) into this abstraction. No-op in `.exact` mode.
    package func install() {
        guard mode == .abstract else { return }
        cnf.mulHook = { [unowned self] a, b in self.mul(a, b) }
        cnf.unsignedMulOverflowHook = { [unowned self] a, b in self.unsignedMulOverflows(a, b) }
        cnf.signedMulOverflowHook = { [unowned self] a, b in self.signedMulOverflows(a, b) }
    }

    /// Runs `body` with the builder's multiplier hooks off, so internal exact circuits are really exact.
    private func exact<T>(_ body: () -> T) -> T {
        let saved = (cnf.mulHook, cnf.unsignedMulOverflowHook, cnf.signedMulOverflowHook)
        (cnf.mulHook, cnf.unsignedMulOverflowHook, cnf.signedMulOverflowHook) = (nil, nil, nil)
        defer { (cnf.mulHook, cnf.unsignedMulOverflowHook, cnf.signedMulOverflowHook) = saved }
        return body()
    }

    package var nodeCount: Int { nodes.count }
    package var refinedCount: Int { nodes.count { $0.refined } }

    // MARK: building products

    /// Wrapping multiply. Narrow operands, constants, shifts, commutativity and associativity are handled
    /// structurally; any other product is an abstract node until refined.
    package func mul(_ a: BV, _ b: BV) -> BV {
        guard mode == .abstract else { return exact { cnf.mul(a, b) } }
        let n = a.width
        if cnf.constantValue(a) != nil || cnf.constantValue(b) != nil { return exact { cnf.mul(a, b) } }
        let (ka, kb) = (cnf.signedWidth(a), cnf.signedWidth(b))
        if ka + kb <= n {
            let x = cnf.signExtend(BV(bits: Array(a.bits[0..<ka])), to: ka + kb)
            let y = cnf.signExtend(BV(bits: Array(b.bits[0..<kb])), to: ka + kb)
            return cnf.signExtend(product(x, y), to: n)
        }
        return product(a, b)
    }

    /// Same value as `CNFBuilder.unsignedMulOverflows`, through the abstract 2n-bit product.
    package func unsignedMulOverflows(_ a: BV, _ b: BV) -> Int32 {
        guard mode == .abstract else { return exact { cnf.unsignedMulOverflows(a, b) } }
        let n = a.width
        let p = product(cnf.zeroExtend(a, to: 2 * n), cnf.zeroExtend(b, to: 2 * n))
        return p.bits[n...].reduce(cnf.falseLit) { cnf.or($0, $1) }
    }

    /// Same value as `CNFBuilder.signedMulOverflows` (narrowing on), through an abstract product.
    package func signedMulOverflows(_ a: BV, _ b: BV) -> Int32 {
        guard mode == .abstract else { return exact { cnf.signedMulOverflows(a, b) } }
        let n = a.width
        let (ka, kb) = (cnf.signedWidth(a), cnf.signedWidth(b))
        if ka + kb <= n { return cnf.falseLit }
        let x = cnf.signExtend(BV(bits: Array(a.bits[0..<ka])), to: ka + kb)
        let y = cnf.signExtend(BV(bits: Array(b.bits[0..<kb])), to: ka + kb)
        let p = product(x, y)
        var allSame = cnf.trueLit
        for i in n..<p.width { allSame = cnf.and(allSame, -cnf.xor(p.bits[i], p.bits[n - 1])) }
        return -allSame
    }

    /// Product of two vectors of equal width.
    private func product(_ x: BV, _ y: BV) -> BV {
        let w = x.width
        if cnf.constantValue(x) != nil || cnf.constantValue(y) != nil { return exact { cnf.mul(x, y, narrowing: false) } }

        // x = x' << kx, y = y' << ky  =>  x * y = (x' * y' mod 2^(w-k)) << k.
        let (kx, ky) = (x.bits.prefix { $0 == cnf.falseLit }.count, y.bits.prefix { $0 == cnf.falseLit }.count)
        if kx + ky > 0 {
            let k = kx + ky
            if k >= w { return cnf.constant(0, width: w) }
            let xs = BV(bits: Array(x.bits[kx..<(w - ky)]))
            let ys = BV(bits: Array(y.bits[ky..<(w - kx)]))
            return BV(bits: Array(repeating: cnf.falseLit, count: k) + product(xs, ys).bits)
        }

        // Multiplication is commutative and associative modulo 2^w: use one chain per sorted multiset of factors.
        let factors = ((factorsOf[x.bits] ?? [x]) + (factorsOf[y.bits] ?? [y])).sorted { $0.bits.lexicographicallyPrecedes($1.bits) }
        var accumulator = node(factors[0], factors[1])
        for factor in factors.dropFirst(2) { accumulator = node(accumulator, factor) }
        if factors.count > 2 { factorsOf[accumulator.bits] = factors }
        return accumulator
    }

    private func node(_ a: BV, _ b: BV) -> BV {
        let (x, y) = b.bits.lexicographicallyPrecedes(a.bits) ? (b, a) : (a, b)
        let key = Key(x: x.bits, y: y.bits)
        if let known = index[key] { return nodes[known].out }
        let out = cnf.input(width: x.width)
        nodes.append(Node(x: x, y: y, out: out))
        index[key] = nodes.count - 1
        factorsOf[out.bits] = [x, y]
        addLemmas(for: nodes.count - 1)
        return out
    }

    // MARK: lemmas

    private func lemma(_ literals: [Int32]) {
        if literals.contains(cnf.trueLit) { return }
        cnf.addClause(literals.filter { $0 != cnf.falseLit })
        lemmaClauseCount += 1
    }

    private func equal(_ a: Int32, _ b: Int32) {
        lemma([-a, b])
        lemma([a, -b])
    }

    /// Lemmas for `m = x * y (mod 2^w)`. Each is a fact about the real product:
    /// 1. low `k` bits of `m` are the low `k` bits of the product of the low `k` bits of `x` and `y`;
    /// 2. trailing zeros: `x` divisible by 2^i and `y` by 2^j implies `m` divisible by 2^(i+j) (covers `x = 0` or `y = 0`);
    /// 3. `x = 1` gives `m = y`, `y = 1` gives `m = x`;
    /// 4. when the operands' leading zeros make the product fit in `w` bits: no high bits, and `m >= x` if `y != 0`, `m >= y` if `x != 0`.
    private func addLemmas(for id: Int) {
        let (x, y, m) = (nodes[id].x, nodes[id].y, nodes[id].out)
        let w = x.width
        let zeroPrefix = { (v: BV) -> [Int32] in
            var p = [self.cnf.trueLit]
            for bit in v.bits { p.append(self.cnf.and(p[p.count - 1], -bit)) }
            return p
        }
        let (px, py) = (zeroPrefix(x), zeroPrefix(y))

        let k = min(w, 4)
        let low = exact { cnf.mul(BV(bits: Array(x.bits[0..<k])), BV(bits: Array(y.bits[0..<k])), narrowing: false) }
        for t in 0..<k { equal(m.bits[t], low.bits[t]) }

        for i in 0...w {
            for j in 0...w where i + j >= 1 && i + j - 1 < w && i + j - 1 >= k {
                lemma([-m.bits[i + j - 1], -px[i], -py[j]])
            }
        }

        let isOne = { (v: BV) in v.bits.dropFirst().reduce(v.bits[0]) { self.cnf.and($0, -$1) } }
        let (isOneX, isOneY) = (isOne(x), isOne(y))
        for t in 0..<w {
            lemma([-isOneX, -m.bits[t], y.bits[t]])
            lemma([-isOneX, m.bits[t], -y.bits[t]])
            lemma([-isOneY, -m.bits[t], x.bits[t]])
            lemma([-isOneY, m.bits[t], -x.bits[t]])
        }

        let bx = w - x.bits.reversed().prefix { $0 == cnf.falseLit }.count
        let by = w - y.bits.reversed().prefix { $0 == cnf.falseLit }.count
        if bx + by <= w {
            for t in (bx + by)..<w { lemma([-m.bits[t]]) }
            lemma([-cnf.ult(m, x), py[w]])
            lemma([-cnf.ult(m, y), px[w]])
        }
    }

    /// Facts that relate several nodes. Call once, after the claim has been built.
    package func finalize() {
        linkPrefixes()
        linkDistributivity()
    }

    /// `x * y mod 2^w1` agrees on its low `w2` bits with the `w2`-bit product of the truncated operands.
    private func linkPrefixes() {
        for node in nodes {
            let w = node.x.width
            for w2 in stride(from: w - 1, through: 1, by: -1) {
                let (a, b) = (Array(node.x.bits[0..<w2]), Array(node.y.bits[0..<w2]))
                let key = b.lexicographicallyPrecedes(a) ? Key(x: b, y: a) : Key(x: a, y: b)
                guard let other = index[key] else { continue }
                for t in 0..<w2 { equal(node.out.bits[t], nodes[other].out.bits[t]) }
            }
        }
    }

    /// `a * (b + c) = a*b + a*c` and `a * (b - c) = a*b - a*c`, for nodes that share the operand `a`.
    private func linkDistributivity() {
        var byOperand: [[Int32]: [(node: Int, other: BV)]] = [:]
        for (i, node) in nodes.enumerated() {
            byOperand[node.x.bits, default: []].append((i, node.y))
            if node.x.bits != node.y.bits { byOperand[node.y.bits, default: []].append((i, node.x)) }
        }
        for (shared, users) in byOperand where users.count >= 2 && users.count <= 12 {
            let a = BV(bits: shared)
            for i in 0..<users.count {
                for j in i..<users.count {
                    let (u, v) = (users[i], users[j])
                    let sums = [
                        (cnf.add(u.other, v.other).sum, true), (cnf.sub(u.other, v.other).difference, false),
                        (cnf.sub(v.other, u.other).difference, false),
                    ]
                    for (n, (combined, isSum)) in sums.enumerated() {
                        if n == 2 && i == j { continue }
                        let key =
                            a.bits.lexicographicallyPrecedes(combined.bits)
                            ? Key(x: a.bits, y: combined.bits) : Key(x: combined.bits, y: a.bits)
                        guard let target = index[key] else { continue }
                        let (first, second) = n == 2 ? (v, u) : (u, v)
                        let (p, q) = (nodes[first.node].out, nodes[second.node].out)
                        let expected = isSum ? cnf.add(p, q).sum : cnf.sub(p, q).difference
                        for t in 0..<a.width { equal(nodes[target].out.bits[t], expected.bits[t]) }
                    }
                }
            }
        }
    }

    // MARK: refinement

    /// Node ids whose output differs from the real product under `model`.
    func spuriousNodes(in model: [Bool]) -> [Int] {
        nodes.indices.filter { id in
            let node = nodes[id]
            let w = node.x.width
            if w > 64 { return true }
            let mask: UInt64 = w >= 64 ? ~0 : (1 << UInt64(w)) - 1
            let real = (cnf.value(of: node.x, in: model) &* cnf.value(of: node.y, in: model)) & mask
            return cnf.value(of: node.out, in: model) != real
        }
    }

    /// Makes every product exact (the plain-circuit fallback).
    package func refineAll() { for id in nodes.indices { refine(id) } }

    /// Ties the node output to the exact shift-and-add circuit.
    func refine(_ id: Int) {
        guard !nodes[id].refined else { return }
        nodes[id].refined = true
        let exactProduct = exact { cnf.mul(nodes[id].x, nodes[id].y, narrowing: false) }
        for t in 0..<exactProduct.width {
            cnf.addClause([-nodes[id].out.bits[t], exactProduct.bits[t]])
            cnf.addClause([nodes[id].out.bits[t], -exactProduct.bits[t]])
        }
    }
}

// MARK: driver

package struct RefineStats: Sendable, Equatable {
    /// Solver runs on abstract (possibly partly refined) formulas.
    package var rounds = 0
    package var multiplierNodes = 0
    package var refinedNodes = 0
    package var spuriousModels = 0
    package var lemmaClauses = 0
    /// Solver spend summed over `rounds`; `variables` and `clauses` describe the last formula.
    package var solve = SolveStats(conflicts: 0, variables: 0, clauses: 0)
}

package struct RefineOutcome: Sendable {
    package var verdict: ProofVerdict
    package var stats: RefineStats
}

/// Like `prove`, but multiplications made with the `MulAbstraction` argument are abstract until refined.
/// `proved` is returned only when the solver refutes a formula whose multiplier constraints are all implied by
/// real multiplication, and the RUP checker accepts the proof. A counterexample is returned only after the
/// claim has been replayed with exact multiplication on the concrete inputs.
package func proveRefining(
    inputWidths: [Int],
    inputSignedBits: [Int?]? = nil,
    conflictBudget: Int = 1_000_000,
    claim: (CNFBuilder, [BV], MulAbstraction) throws -> Int32
) throws -> ProofVerdict {
    try proveRefiningDetailed(
        inputWidths: inputWidths, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget, claim: claim
    ).verdict
}

/// `prove` with the strategy chosen by a flag, for callers that carry a `refining: Bool` option.
package func proveMaybeRefining(
    inputWidths: [Int],
    inputSignedBits: [Int?]? = nil,
    conflictBudget: Int = 1_000_000,
    refining: Bool,
    claim: (CNFBuilder, [BV]) throws -> Int32
) throws -> ProofVerdict {
    try prove(
        inputWidths: inputWidths, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget,
        strategy: refining ? .refiningMultipliers : .exact, claim: claim
    )
}

/// `conflictBudget` applies to each solver run; refinement stops after at most one round per multiplier node.
package func proveRefiningDetailed(
    inputWidths: [Int],
    inputSignedBits: [Int?]? = nil,
    conflictBudget: Int = 1_000_000,
    claim: (CNFBuilder, [BV], MulAbstraction) throws -> Int32
) throws -> RefineOutcome {
    let builder = CNFBuilder()
    let multiplier = MulAbstraction(cnf: builder)
    let inputs = inputWidths.enumerated().map { i, width in
        if let bits = inputSignedBits?[i], bits < width { return builder.input(width: width, signedBits: bits) }
        return builder.input(width: width)
    }
    let goal = try claim(builder, inputs, multiplier)
    multiplier.finalize()
    builder.addClause([-goal])

    var stats = RefineStats()
    stats.multiplierNodes = multiplier.nodeCount
    func finish(_ verdict: ProofVerdict) -> RefineOutcome {
        stats.refinedNodes = multiplier.refinedCount
        stats.lemmaClauses = multiplier.lemmaClauseCount
        return RefineOutcome(verdict: verdict, stats: stats)
    }

    while true {
        let cnf = builder.cnf
        stats.rounds += 1
        let report = Solver.solveLRATReporting(cnf, conflictBudget: conflictBudget)
        stats.solve = SolveStats(
            conflicts: stats.solve.conflicts + report.stats.conflicts, variables: report.stats.variables, clauses: report.stats.clauses
        )
        switch report.outcome {
        case .unsat(let log):
            guard LRATChecker.check(cnf: cnf, proof: LRATProof(log)) else { throw ProveError.proofRejected }
            return finish(.proved)
        case .unknown:
            return finish(.unknown)
        case .sat(let model):
            guard cnf.isSatisfied(by: model) else { throw ProveError.modelRejected }
            let spurious = multiplier.spuriousNodes(in: model).filter { !multiplier.nodes[$0].refined }
            if spurious.isEmpty {
                let values = inputs.map { builder.value(of: $0, in: model) }
                if try replayRefutes(inputWidths: inputWidths, values: values, claim: claim) {
                    return finish(.counterexample(values))
                }
                // The claim holds on these inputs under exact multiplication: the abstraction disagreed somewhere
                // it should not have. Fall back to the exact circuit everywhere.
                guard multiplier.refinedCount < multiplier.nodeCount else { throw ProveError.modelRejected }
                multiplier.refineAll()
            } else {
                stats.spuriousModels += 1
                for id in spurious { multiplier.refine(id) }
            }
        }
    }
}

/// Evaluates the claim on constant inputs with exact multiplication. True when the claim is false there.
private func replayRefutes(
    inputWidths: [Int], values: [UInt64], claim: (CNFBuilder, [BV], MulAbstraction) throws -> Int32
) throws -> Bool {
    let builder = CNFBuilder()
    let inputs = zip(inputWidths, values).map { builder.constant($1, width: $0) }
    let goal = try claim(builder, inputs, MulAbstraction(cnf: builder, mode: .exact))
    return goal == builder.falseLit
}
