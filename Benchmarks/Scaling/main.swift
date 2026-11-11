// Scaling curves: how per-element time changes with input size (swift-collections-benchmark).
// Build: SWIFTFORMAL_BENCH=1 swift build -c release -Xswiftc -enable-testing --product SwiftFormalScaling
// Run:   SCALING_SIL_DIR=<dir with k<n>.sil and c<n>.sil> .build/release/SwiftFormalScaling run results.json --cycles 3
// Every task returns its setup outside `timer.measure`, so only the named operation is timed.
import CollectionsBenchmark
import Foundation
@testable import SFBV
@testable import SFCheck
@testable import SFCNF
@testable import SFSAT
@testable import SFSIL
@testable import SFVerifyKit
@testable import SwiftFormal
@testable import SwiftFormalTesting

var benchmark = Benchmark(title: "SwiftFormal scaling")

// MARK: - shared inputs

/// Deterministic, so every cycle and every machine measures the same input.
func rng(_ seed: Int) -> SplitMix64 { SplitMix64(seed: 0xC0FF_EE00 &+ UInt64(seed)) }

struct CNFInput { let cnf: CNF }

func random3SAT(vars n: Int, ratio: Double, seed: Int) -> CNF {
    var g = rng(seed)
    let m = Int(Double(n) * ratio)
    var clauses: [Clause] = []
    clauses.reserveCapacity(m)
    for _ in 0..<m {
        var c: Clause = []
        while c.count < 3 {
            let v = Int32(g.next() % UInt64(n)) + 1
            if c.contains(v) || c.contains(-v) { continue }
            c.append(g.next() & 1 == 0 ? v : -v)
        }
        clauses.append(c)
    }
    return CNF(numVars: n, clauses: clauses)
}

/// `(a + b) + c != a + (b + c)`: UNSAT, and the proof grows polynomially with the width.
func addAssociativityMiter(width w: Int) -> CNF {
    let c = CNFBuilder()
    let a = c.input(width: w), b = c.input(width: w), d = c.input(width: w)
    let left = c.add(c.add(a, b).sum, d).sum
    let right = c.add(a, c.add(b, d).sum).sum
    let differs = zip(left.bits, right.bits).reduce(c.falseLit) { c.or($0, c.xor($1.0, $1.1)) }
    c.addClause([differs])
    return c.cnf
}

/// `a * b != b * a` with the full shift-add multiplier: hard for CDCL, so it is run under a fixed conflict budget.
func mulCommutativityMiter(width w: Int) -> CNF {
    let c = CNFBuilder()
    let a = c.input(width: w), b = c.input(width: w)
    let left = c.mul(a, b, narrowing: false), right = c.mul(b, a, narrowing: false)
    let differs = zip(left.bits, right.bits).reduce(c.falseLit) { c.or($0, c.xor($1.0, $1.1)) }
    c.addClause([differs])
    return c.cnf
}

/// One long solver proof; checker tasks time a prefix of `size` steps (a prefix checks every step it has,
/// then fails on "no empty clause", which costs nothing).
nonisolated(unsafe) var bigProof: (cnf: CNF, lrat: LRATProof)? = nil
func longProof() -> (cnf: CNF, lrat: LRATProof) {
    if let p = bigProof { return p }
    var width = 64
    while true {
        let cnf = addAssociativityMiter(width: width)
        guard case .unsat(let log) = Solver.solveLRAT(cnf, conflictBudget: 10_000_000) else { fatalError("miter not unsat") }
        let proof = LRATProof(log)
        FileHandle.standardError.write(
            "associativity miter width \(width): \(cnf.numVars) vars, \(cnf.clauses.count) clauses, \(proof.steps.count) proof steps\n"
                .data(using: .utf8)!)
        if proof.steps.count >= 1 << 17 || width >= 4096 { bigProof = (cnf, proof); return (cnf, proof) }
        width *= 2
    }
}

struct ProofPrefix { let cnf: CNF; let lrat: LRATProof; let rup: [Clause] }
benchmark.registerInputGenerator(for: ProofPrefix.self) { size in
    let (cnf, proof) = longProof()
    let steps = Array(proof.steps.prefix(size))
    let rup = steps.compactMap { step -> Clause? in if case .add(_, let c, _) = step { return c } else { return nil } }
    return ProofPrefix(cnf: cnf, lrat: LRATProof(steps: steps), rup: rup + [[]])
}

/// A unit chain `x1, x1 → x2, …, x(n-1) → xn, ¬xn` with an LRAT proof of n steps of constant size, each deleting the
/// unit before it. Any per-step growth is the checker's own data structures.
struct ChainProof { let cnf: CNF; let proof: LRATProof }
benchmark.registerInputGenerator(for: ChainProof.self) { n in
    var clauses: [Clause] = [[1]]
    for i in 1..<n { clauses.append([-Int32(i), Int32(i + 1)]) }
    clauses.append([-Int32(n)])
    // ids: 1 = (x1), 1 + i = (¬xi ∨ xi+1), n + 1 = (¬xn)
    var steps: [LRATStep] = []
    var previousUnit = 1
    var next = n + 2
    for i in 1..<n {
        steps.append(.add(id: next, clause: [Int32(i + 1)], hints: [previousUnit, 1 + i]))
        if previousUnit != 1 { steps.append(.delete(ids: [previousUnit])) }
        previousUnit = next
        next += 1
    }
    steps.append(.add(id: next, clause: [], hints: [previousUnit, n + 1]))
    return ChainProof(cnf: CNF(numVars: n, clauses: clauses), proof: LRATProof(steps: steps))
}

// SIL from `swiftc -frontend -emit-sil -Onone -g -Xllvm -sil-print-debuginfo`: k<n> = n kernels of Scratch gen.py
// (with `_ensures` contracts), c<n> = a call chain chain_i -> chain_(i-1).
let silDirectory = ProcessInfo.processInfo.environment["SCALING_SIL_DIR"] ?? "sil"
func silText(_ kind: String, _ n: Int) -> String {
    let path = "\(silDirectory)/\(kind)\(n).sil"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fatalError("missing \(path)") }
    return text
}
struct KernelSIL { let raw: String; let prepared: SILText.Prepared }
benchmark.registerInputGenerator(for: KernelSIL.self) { n in
    let raw = silText("k", n)
    return KernelSIL(raw: raw, prepared: SILText.prepare(raw, module: "K"))
}
struct ChainSIL { let module: SILModule; let symbols: [String] }
benchmark.registerInputGenerator(for: ChainSIL.self) { n in
    let prepared = SILText.prepare(silText("c", n), module: "K")
    let module = try! SILModule(text: prepared.clean)
    return ChainSIL(module: module, symbols: prepared.functions.map(\.symbol))
}

// MARK: - SwiftFormal: domains

benchmark.addSimple(title: "Domain.int enumerate", input: Int.self) { n in
    let d = Domain.int(0...(n - 1))
    var sum = 0
    for i in 0..<d.count { sum &+= d[i] }
    blackHole(sum)
}
benchmark.addSimple(title: "Domain.int sample (random)", input: Int.self) { n in
    let d = Domain.int(0...Int.max - 1)
    var g = rng(1)
    var sum = 0
    for _ in 0..<n { sum &+= d.random(&g) }
    blackHole(sum)
}
benchmark.addSimple(title: "Domain.product 2 enumerate", input: Int.self) { n in
    let d = Domain.product(Domain.int(0...max(n / 16, 1) - 1), Domain.int(0...15))
    var sum = 0
    for i in 0..<d.count { let (a, b) = d[i]; sum &+= a &+ b }
    blackHole(sum)
}
benchmark.addSimple(title: "Domain.product 3 enumerate", input: Int.self) { n in
    let d = Domain.product(Domain.int(0...max(n / 64, 1) - 1), Domain.int(0...3), Domain.int(0...15))
    var sum = 0
    for i in 0..<d.count { let (a, b, c) = d[i]; sum &+= a &+ b &+ c }
    blackHole(sum)
}
benchmark.addSimple(title: "Domain.product 4 enumerate", input: Int.self) { n in
    let d = Domain.product(Domain.int(0...max(n / 256, 1) - 1), Domain.int(0...3), Domain.int(0...7), Domain.int(0...7))
    var sum = 0
    for i in 0..<d.count { let (a, b, c, e) = d[i]; sum &+= a &+ b &+ c &+ e }
    blackHole(sum)
}
benchmark.addSimple(title: "Domain.product nested 4 levels + map", input: Int.self) { n in
    let inner = Domain.product(Domain.product(Domain.int(0...3), Domain.int(0...3)), Domain.int(0...3)).map { $0.0.0 + $0.0.1 + $0.1 }
    let d = Domain.product(Domain.int(0...max(n / 64, 1) - 1), inner).map { $0.0 &+ $0.1 }
    var sum = 0
    for i in 0..<d.count { sum &+= d[i] }
    blackHole(sum)
}
benchmark.addSimple(title: "Domain.arrays of bool enumerate (size = values)", input: Int.self) { n in
    // count = 2^(L+1) - 1
    let length = max(0, Int.bitWidth - n.leadingZeroBitCount - 2)
    let d = Domain.arrays(of: Domain.bool, maxLength: length)
    var sum = 0
    for i in 0..<d.count { sum &+= d[i].count }
    blackHole(sum)
}
benchmark.addSimple(title: "Domain.union 16 parts enumerate", input: Int.self) { n in
    let per = max(n / 16, 1)
    let d = Domain.union((0..<16).map { k in Domain.int((k * per)...(k * per + per - 1)) })
    var sum = 0
    for i in 0..<d.count { sum &+= d[i] }
    blackHole(sum)
}
benchmark.addSimple(title: "Domain.union n÷16 parts enumerate", input: Int.self, maxSize: 1 << 15) { n in
    let parts = max(n / 16, 1)
    let d = Domain.union((0..<parts).map { k in Domain.int((k * 16)...(k * 16 + 15)) })
    var sum = 0
    for i in 0..<d.count { sum &+= d[i] }
    blackHole(sum)
}
benchmark.addSimple(title: "Domain.combinations full enumerate", input: Int.self) { n in
    let d = Domain<Int>.combinations(levels: [max(n / 16, 1), 4, 4], complete: true, fullProductLimit: Int.max) { $0[0] &+ $0[1] &+ $0[2] }
    var sum = 0
    for i in 0..<d.count { sum &+= d[i] }
    blackHole(sum)
}
benchmark.addSimple(title: "Pairwise.rows (size = factors, 3 levels)", input: Int.self) { n in
    blackHole(Pairwise.rows(levels: Array(repeating: 3, count: n)))
}
benchmark.addSimple(title: "Pairwise.rows (size = levels, 4 factors)", input: Int.self) { n in
    blackHole(Pairwise.rows(levels: Array(repeating: n, count: 4)))
}
benchmark.addSimple(title: "Domain.combinations pairwise build (size = factors, 4 levels)", input: Int.self) { n in
    let d = Domain<Int>.combinations(levels: Array(repeating: 4, count: n), complete: false) { $0.count }
    blackHole(d.count)
}

// Sampling: `n` draws through `random` from each combinator (what a walk does when the domain exceeds the budget).
@MainActor func sample<T>(_ title: String, _ domain: @escaping (Int) -> Domain<T>, maxSize: Int? = nil) {
    benchmark.add(title: "sample " + title, input: Int.self, maxSize: maxSize) { n in
        let d = domain(n)
        return { timer in
            var g = rng(3)
            timer.measure { for _ in 0..<n { blackHole(d.random(&g)) } }
        }
    }
}
let big = Domain.int(0...(1 << 40))
sample("product 2") { _ in Domain.product(big, big) }
sample("product 3") { _ in Domain.product(big, big, big) }
sample("product 4") { _ in Domain.product(big, big, big, big) }
sample("product nested 4 levels + map") { _ in Domain.product(Domain.product(Domain.product(big, big), big), big).map { $0.0.0.0 &+ $0.1 } }
sample("arrays of int, maxLength 16") { _ in Domain.arrays(of: big, maxLength: 16) }
sample("union 16 parts") { _ in Domain.union(Array(repeating: big, count: 16)) }
sample("union n÷16 parts") { n in Domain.union(Array(repeating: big, count: max(n / 16, 1))) }
sample("combinations full, 3 factors") { _ in
    Domain<Int>.combinations(levels: [1 << 20, 64, 64], complete: true, fullProductLimit: Int.max) { $0[0] &+ $0[1] }
}
sample("combinations pairwise, 12 factors of 5 (rows built once)") { _ in
    Domain<Int>.combinations(levels: Array(repeating: 5, count: 12), complete: false) { $0[0] }
}

// MARK: - SwiftFormal: the walk, grouping outputs

benchmark.addSimple(title: "verify walk, 2 per-input properties", input: Int.self) { n in
    let report = runWalk("double", { (x: Int) in x &* 2 }, over: .int(0...(n - 1))) {
        Property.satisfies("even") { _, y in y & 1 == 0 }
        Property.matches { $0 &+ $0 }
    }
    blackHole(report)
}
benchmark.addSimple(title: "verify walk, injective", input: Int.self) { n in
    blackHole(runWalk("double", { (x: Int) in x &* 2 }, over: .int(0...(n - 1))) { Property.injective() })
}
benchmark.addSimple(title: "verify walk, deterministic", input: Int.self) { n in
    blackHole(runWalk("double", { (x: Int) in x &* 2 }, over: .int(0...(n - 1))) { Property.deterministic() })
}
benchmark.addSimple(title: "verify walk, image(equals:) 4 values", input: Int.self) { n in
    blackHole(runWalk("mod4", { (x: Int) in x & 3 }, over: .int(0...(n - 1))) { Property.image(equals: [0, 1, 2, 3]) })
}
benchmark.add(title: "verify walk, table with one row per input", input: Int.self, maxSize: 1 << 13) { n in
    // KeyValuePairs has no public initializer but a literal; it is a single array of pairs, so build it from one.
    let rows = unsafeBitCast((0..<n).map { ($0, $0 &* 2) }, to: KeyValuePairs<Int, Int>.self)
    return { timer in
        timer.measure { blackHole(runWalk("double", { (x: Int) in x &* 2 }, over: .int(0...(n - 1))) { Property.table(rows) }) }
    }
}
benchmark.addSimple(title: "verify sampled (budget = size, domain 2^62)", input: Int.self) { n in
    blackHole(
        runWalk("double", { (x: Int) in x &* 2 }, over: .int(0...(1 << 62)), budget: Budget(maxEvaluations: n)) {
            Property.satisfies("even") { _, y in y & 1 == 0 }
        })
}

struct OnlyEquatable: Equatable { let value: Int }
benchmark.addSimple(title: "partition Hashable, all outputs distinct", input: Int.self) { n in
    blackHole(runPartition({ (x: Int) in x &* 3 }, over: .int(0...(n - 1)), limit: Int.max).groups.count)
}
benchmark.addSimple(title: "partition Equatable, all outputs distinct", input: Int.self, maxSize: 1 << 14) { n in
    blackHole(runPartition({ (x: Int) in OnlyEquatable(value: x &* 3) }, over: .int(0...(n - 1)), limit: Int.max).groups.count)
}
benchmark.addSimple(title: "partition Hashable, 8 groups", input: Int.self) { n in
    blackHole(runPartition({ (x: Int) in x & 7 }, over: .int(0...(n - 1)), limit: Int.max).groups.count)
}
benchmark.addSimple(title: "partition Equatable, 8 groups", input: Int.self) { n in
    blackHole(runPartition({ (x: Int) in OnlyEquatable(value: x & 7) }, over: .int(0...(n - 1)), limit: Int.max).groups.count)
}

// MARK: - SwiftFormalTesting: behaviour lock masking (size = bytes of output text)

benchmark.add(title: "BehaviorLock.mask, text with addresses and UUIDs (size = bytes)", input: Int.self) { n in
    let unit = "Box(at: 0x0000600001a2b3c4, id: 123e4567-e89b-12d3-a456-426614174000) "  // 70 bytes
    let text = String(String(repeating: unit, count: n / unit.utf8.count + 1).prefix(n))
    return { timer in timer.measure { blackHole(BehaviorLock.mask(text)) } }
}
benchmark.add(title: "BehaviorLock.mask, plain text (size = bytes)", input: Int.self) { n in
    let text = String(repeating: "a", count: n)
    return { timer in timer.measure { blackHole(BehaviorLock.mask(text)) } }
}
benchmark.add(title: "BehaviorLock.render+parse (size = entries)", input: Int.self) { n in
    let entries = (0..<n).map { i in (hash: BehaviorLock.hash("\(i)"), text: "Result(value: \(i), name: \"item\(i)\")") }
    return { timer in timer.measure { blackHole(BehaviorLock.parse(BehaviorLock.render(name: "bench", entries: entries)).count) } }
}

// MARK: - SFBV

benchmark.add(title: "CNFBuilder.and on random pairs (size = gates)", input: Int.self) { n in
    var g = rng(2)
    let inputs = max(64, Int(Double(n).squareRoot()) * 4)
    let pairs = (0..<n).map { _ in (Int32(g.next() % UInt64(inputs)) + 2, Int32(g.next() % UInt64(inputs)) + 2) }
    return { timer in
        let c = CNFBuilder()
        _ = c.input(width: inputs)
        timer.measure {
            for (a, b) in pairs { blackHole(c.and(a, -b)) }
        }
        blackHole(c.clauses.count)
    }
}
benchmark.add(title: "CNFBuilder.and chain, all new gates (size = gates)", input: Int.self) { n in
    return { timer in
        let c = CNFBuilder()
        let x = c.input(width: n)
        timer.measure {
            var acc = x.bits[0]
            for i in 1..<n { acc = c.and(acc, x.bits[i]) }
            blackHole(acc)
        }
    }
}
benchmark.add(title: "CNFBuilder.add width (size = bits)", input: Int.self) { n in
    return { timer in
        let c = CNFBuilder()
        let a = c.input(width: n), b = c.input(width: n)
        timer.measure { blackHole(c.add(a, b).sum) }
    }
}
benchmark.add(title: "CNFBuilder.mul width (size = bits; O(w²) gates expected)", input: Int.self) { n in
    return { timer in
        let c = CNFBuilder()
        let a = c.input(width: n), b = c.input(width: n)
        timer.measure { blackHole(c.mul(a, b, narrowing: false)) }
    }
}
benchmark.add(title: "CNFBuilder.unsignedDivide width (size = bits; O(w²) gates expected)", input: Int.self) { n in
    return { timer in
        let c = CNFBuilder()
        let a = c.input(width: n), b = c.input(width: n)
        timer.measure { blackHole(c.unsignedDivide(a, b)) }
    }
}

// MARK: - SFSAT

benchmark.registerInputGenerator(for: CNFInput.self) { n in CNFInput(cnf: random3SAT(vars: n, ratio: 3.5, seed: n)) }
benchmark.add(title: "Solver random 3-SAT ratio 3.5 (size = vars)", input: CNFInput.self) { input in
    return { timer in timer.measure { blackHole(Solver.solve(input.cnf, conflictBudget: 200_000)) } }
}
benchmark.add(title: "Solver random 3-SAT ratio 6 (unsat), 2000 conflicts (size = vars)", input: Int.self) { n in
    let cnf = random3SAT(vars: n, ratio: 6, seed: n)
    return { timer in timer.measure { blackHole(Solver.solveLRAT(cnf, conflictBudget: 2000)) } }
}
benchmark.add(title: "Solver add-associativity miter LRAT (size = width)", input: Int.self) { n in
    let cnf = addAssociativityMiter(width: n)
    return { timer in timer.measure { blackHole(Solver.solveLRAT(cnf, conflictBudget: 10_000_000)) } }
}
benchmark.add(title: "Solver mul-commutativity miter, 2000 conflicts (size = width)", input: Int.self) { n in
    let cnf = mulCommutativityMiter(width: n)
    return { timer in timer.measure { blackHole(Solver.solveLRAT(cnf, conflictBudget: 2000)) } }
}

// MARK: - SFCheck

benchmark.add(title: "LRATChecker unit chain (size = steps)", input: ChainProof.self) { input in
    return { timer in timer.measure { blackHole(LRATChecker.check(cnf: input.cnf, proof: input.proof)) } }
}
benchmark.add(title: "LRATChecker dense-ID variant unit chain (size = steps)", input: ChainProof.self) { input in
    return { timer in timer.measure { blackHole(DenseLRATChecker.check(cnf: input.cnf, proof: input.proof)) } }
}
benchmark.add(title: "LRATChecker solver proof prefix (size = steps)", input: ProofPrefix.self) { input in
    return { timer in timer.measure { blackHole(LRATChecker.check(cnf: input.cnf, proof: input.lrat)) } }
}
benchmark.add(title: "LRATChecker dense-ID variant solver proof prefix (size = steps)", input: ProofPrefix.self) { input in
    return { timer in timer.measure { blackHole(DenseLRATChecker.check(cnf: input.cnf, proof: input.lrat)) } }
}
benchmark.add(title: "RUPChecker solver proof prefix (size = steps)", input: ProofPrefix.self) { input in
    return { timer in timer.measure { blackHole(RUPChecker.check(cnf: input.cnf, proof: input.rup)) } }
}
benchmark.add(title: "LRATProof text+parse solver proof prefix (size = steps)", input: ProofPrefix.self) { input in
    return { timer in timer.measure { blackHole(try! LRATProof.parse(input.lrat.text(originalCount: input.cnf.clauses.count)).steps.count) }
    }
}

// MARK: - SFSIL, SFVerifyKit (size = functions in the generated file)

benchmark.add(title: "SILText.prepare (size = functions)", input: KernelSIL.self) { input in
    return { timer in timer.measure { blackHole(SILText.prepare(input.raw, module: "K").functions.count) } }
}
benchmark.add(title: "SILModule(text:) (size = functions)", input: KernelSIL.self) { input in
    return { timer in timer.measure { blackHole(try! SILModule(text: input.prepared.clean)) } }
}
benchmark.add(title: "SILModule.function for every function (size = functions)", input: KernelSIL.self) { input in
    let module = try! SILModule(text: input.prepared.clean)
    return { timer in timer.measure { for f in input.prepared.functions { blackHole(try? module.function(f.symbol)) } } }
}
benchmark.add(title: "SpecIndex init (size = functions)", input: KernelSIL.self, maxSize: 1 << 12) { input in
    return { timer in timer.measure { blackHole(SpecIndex(input.prepared.functions).isSpec("x")) } }
}
benchmark.add(title: "SILModule.symbol(module:name:) for every function (size = functions)", input: ChainSIL.self, maxSize: 1 << 12) {
    input in
    return { timer in
        timer.measure { for i in 0..<input.symbols.count { blackHole(try? input.module.symbol(module: "K", name: "chain\(i)")) } }
    }
}
benchmark.add(title: "ProofCache.key for every function of a call chain (size = functions)", input: ChainSIL.self, maxSize: 1 << 10) {
    input in
    let fingerprint = CompilerFingerprint(swiftcVersion: "bench", sdkVersion: "bench", optimization: "-Onone", semanticsDigest: "bench")
    return { timer in
        timer.measure {
            for s in input.symbols { blackHole(try! ProofCache.key(symbol: s, in: input.module, claimID: "c", fingerprint: fingerprint)) }
        }
    }
}
benchmark.add(title: "ProofCache.key for the deepest function of a call chain (size = functions)", input: ChainSIL.self) { input in
    let fingerprint = CompilerFingerprint(swiftcVersion: "bench", sdkVersion: "bench", optimization: "-Onone", semanticsDigest: "bench")
    let deepest = input.symbols.last!
    return { timer in
        timer.measure { blackHole(try! ProofCache.key(symbol: deepest, in: input.module, claimID: "c", fingerprint: fingerprint)) }
    }
}
benchmark.add(title: "ProofDigest.hash (size = bytes)", input: Int.self) { n in
    let text = String(repeating: "x", count: n)
    return { timer in timer.measure { blackHole(ProofDigest.hash(text)) } }
}
benchmark.add(title: "ProofCache store+lookup (size = entries)", input: Int.self) { n in
    let fingerprint = CompilerFingerprint(swiftcVersion: "bench", sdkVersion: "bench", optimization: "-Onone", semanticsDigest: "bench")
    return { timer in
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sf-scaling-cache-\(UUID().uuidString)")
        let cache = ProofCache(directory: dir)
        defer { cache.clear() }
        timer.measure {
            for i in 0..<n { try! cache.store(verdict: .proved, key: "k\(i)", fingerprint: fingerprint, symbol: "s", claimID: "c") }
            for i in 0..<n { blackHole(cache.lookup(key: "k\(i)", fingerprint: fingerprint)) }
        }
    }
}

// `SCALING_PROBE=1`: print the deterministic counts behind the solver curves, then exit.
if ProcessInfo.processInfo.environment["SCALING_PROBE"] != nil {
    func show(_ name: String, _ cnf: CNF, budget: Int) {
        let start = Date()
        let report = Solver.solveLRATReporting(cnf, conflictBudget: budget)
        let seconds = Date().timeIntervalSince(start)
        var outcome = "unknown"
        switch report.outcome {
        case .sat: outcome = "sat"
        case .unsat(let log): outcome = "unsat, \(log.steps.count) proof steps"
        case .unknown: break
        }
        print(
            "\(name): \(cnf.numVars) vars \(cnf.clauses.count) clauses -> \(outcome), \(report.stats.conflicts) conflicts, "
                + String(format: "%.3fs, %.1fµs/conflict", seconds, seconds * 1e6 / Double(max(report.stats.conflicts, 1))))
    }
    // A sampled walk draws with replacement: does `injective` report one input colliding with itself?
    let sampled = runWalk("double", { (x: Int) in x &* 2 }, over: .int(0...(1 << 21))) { Property.injective() }
    print("injective over 2^21+1 values of x*2 (budget 1M, sampled):", sampled.results.map { "\($0.name): \($0.verdict)" })
    if ProcessInfo.processInfo.environment["SCALING_PROBE"] == "injective" { fflush(stdout); _exit(0) }
    for seed in [1, 2, 3] {
        for n in [1024, 2048] {
            show("3sat3.5 seed=\(seed) n=\(n)", random3SAT(vars: n, ratio: 3.5, seed: n &* 31 &+ seed), budget: 200_000)
        }
    }
    if ProcessInfo.processInfo.environment["SCALING_PROBE"] == "sat" { fflush(stdout); _exit(0) }
    for w in [8, 16, 32, 64, 128, 256, 512] { show("assoc w=\(w)", addAssociativityMiter(width: w), budget: 10_000_000) }
    for n in [256, 512, 1024, 2048, 4096, 8192] { show("3sat3.5 n=\(n)", random3SAT(vars: n, ratio: 3.5, seed: n), budget: 200_000) }
    for n in [256, 1024, 4096] { show("3sat6 n=\(n)", random3SAT(vars: n, ratio: 6, seed: n), budget: 2000) }
    for w in [8, 16, 32, 64] { show("mul w=\(w)", mulCommutativityMiter(width: w), budget: 2000) }
    fflush(stdout)
    _exit(0)  // the harness traps at exit when `main()` never ran
}

benchmark.main()

// MARK: - the dense-ID idea (E5), for comparison only

/// `LRATChecker` with clause storage indexed by ID instead of hashed: IDs are dense (1...n originals, then increasing).
/// Same work otherwise: literal validation, duplicate-literal removal with stamps, and the retired-ID bookkeeping.
enum DenseLRATChecker {
    static func check(cnf: CNF, proof: LRATProof) -> Bool {
        let numVars = cnf.numVars
        var clauses: [[Int32]?] = [nil]
        var retired: [Bool] = [false]
        clauses.reserveCapacity(cnf.clauses.count + proof.steps.count + 1)
        var values = [Int8](repeating: 0, count: numVars + 1)
        var stamp = [Int](repeating: 0, count: 2 * numVars + 2)
        var stampCounter = 0
        var assigned: [Int] = []
        func value(_ lit: Int32) -> Int8 { lit > 0 ? values[Int(lit)] : -values[Int(-lit)] }
        func valid(_ lit: Int32) -> Bool { lit != 0 && Int(lit.magnitude) <= numVars }
        func put(_ id: Int, _ clause: Clause) -> Bool {
            stampCounter += 1
            var lits: [Int32] = []
            for lit in clause {
                guard valid(lit) else { return false }
                let slot = 2 * Int(lit.magnitude) + (lit < 0 ? 1 : 0)
                if stamp[slot] != stampCounter { stamp[slot] = stampCounter; lits.append(lit) }
            }
            while clauses.count <= id { clauses.append(nil); retired.append(false) }
            clauses[id] = lits
            return true
        }
        for (i, c) in cnf.clauses.enumerated() { guard put(i + 1, c) else { return false } }
        var largest = cnf.clauses.count
        for step in proof.steps {
            switch step {
            case .delete(let ids):
                for id in ids {
                    guard id < clauses.count, clauses[id] != nil else { return false }  // unknown or retired: both errors
                    clauses[id] = nil
                    retired[id] = true
                }
            case .add(let id, let clause, let hints):
                guard id > largest else { return false }  // duplicate (retired[id]) or not increasing
                defer {
                    for v in assigned { values[v] = 0 }
                    assigned.removeAll(keepingCapacity: true)
                }
                var tautology = false
                for lit in clause {
                    guard valid(lit) else { return false }
                    if value(lit) == 1 { tautology = true; break }
                    if value(lit) == 0 { values[Int(lit.magnitude)] = lit > 0 ? -1 : 1; assigned.append(Int(lit.magnitude)) }
                }
                if !tautology {
                    var conflict = false
                    for h in hints {
                        if conflict { return false }
                        guard h > 0, h < clauses.count, let lits = clauses[h] else { return false }
                        var open: Int32 = 0, openCount = 0
                        for lit in lits {
                            switch value(lit) {
                            case 1: return false
                            case 0: open = lit; openCount += 1
                            default: break
                            }
                        }
                        if openCount == 0 {
                            conflict = true
                        } else if openCount == 1 {
                            values[Int(open.magnitude)] = open > 0 ? 1 : -1
                            assigned.append(Int(open.magnitude))
                        } else {
                            return false
                        }
                    }
                    if !conflict { return false }
                }
                guard put(id, clause) else { return false }
                largest = id
                if clause.isEmpty { return true }
            }
        }
        return false
    }
}
