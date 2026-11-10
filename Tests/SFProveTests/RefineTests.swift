import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSAT
import SFTestSupport

private typealias Circuit = (CNFBuilder, [BV], MulAbstraction) throws -> Int32

private struct Claim {
    let name: String
    let widths: [Int]
    var signedBits: [Int?]? = nil
    let circuit: Circuit
    let holds: ([UInt64]) -> Bool
}

private func implies(_ c: CNFBuilder, _ pre: Int32, _ post: Int32) -> Int32 { c.or(-pre, post) }
private func isZero(_ c: CNFBuilder, _ v: BV) -> Int32 { c.eq(v, c.constant(0, width: v.width)) }
private func bit(_ c: CNFBuilder, _ b: Int32, width: Int) -> BV { BV(bits: [b] + Array(repeating: c.falseLit, count: width - 1)) }
private func signed(_ v: UInt64, _ n: Int) -> Int64 {
    v & (1 << UInt64(n - 1)) != 0 ? Int64(v) - (1 << Int64(n)) : Int64(v)
}

/// Claims over `n`-bit values, each with a native reference. A mix of true and false ones.
private func claims(_ n: Int) -> [Claim] {
    let mask: UInt64 = n >= 64 ? ~0 : (1 << UInt64(n)) - 1
    func shl(_ c: CNFBuilder, _ a: BV, _ k: Int) -> BV { c.shiftLeft(a, by: c.constant(UInt64(k), width: n)) }
    func slim(_ c: CNFBuilder, _ a: BV, _ lo: Int64, _ hi: Int64) -> Int32 {
        c.and(c.sle(c.constant(UInt64(bitPattern: lo) & mask, width: n), a), c.sle(a, c.constant(UInt64(bitPattern: hi) & mask, width: n)))
    }
    var list: [Claim] = []
    list.append(
        Claim(
            name: "commutativity", widths: [n, n], circuit: { c, v, m in c.eq(m.mul(v[0], v[1]), m.mul(v[1], v[0])) }, holds: { _ in true })
    )
    list.append(
        Claim(
            name: "associativity", widths: [n, n, n],
            circuit: { c, v, m in
                c.eq(m.mul(m.mul(v[0], v[1]), v[2]), m.mul(v[0], m.mul(v[1], v[2])))
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "assoc+comm mix", widths: [n, n, n],
            circuit: { c, v, m in
                c.eq(m.mul(m.mul(v[0], v[1]), v[2]), m.mul(m.mul(v[2], v[0]), v[1]))
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "distributivity", widths: [n, n, n],
            circuit: { c, v, m in
                c.eq(m.mul(v[0], c.add(v[1], v[2]).sum), c.add(m.mul(v[0], v[1]), m.mul(v[0], v[2])).sum)
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "distributivity over sub", widths: [n, n, n],
            circuit: { c, v, m in
                c.eq(m.mul(v[0], c.sub(v[1], v[2]).difference), c.sub(m.mul(v[0], v[1]), m.mul(v[0], v[2])).difference)
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "distributivity commuted", widths: [n, n, n],
            circuit: { c, v, m in
                c.eq(m.mul(c.add(v[1], v[2]).sum, v[0]), c.add(m.mul(v[2], v[0]), m.mul(v[1], v[0])).sum)
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "commutativity with shifted operand", widths: [n, n],
            circuit: { c, v, m in
                c.eq(m.mul(shl(c, v[0], 2), v[1]), m.mul(v[1], shl(c, v[0], 2)))
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "shift commutes with mul", widths: [n, n],
            circuit: { c, v, m in
                c.eq(m.mul(shl(c, v[0], 2), v[1]), shl(c, m.mul(v[0], v[1]), 2))
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "parity", widths: [n, n],
            circuit: { c, v, m in
                -c.xor(m.mul(v[0], v[1]).bits[0], c.and(v[0].bits[0], v[1].bits[0]))
            }, holds: { _ in true }))
    if n >= 2 {
        list.append(
            Claim(
                name: "a*3 == (a<<1)+a", widths: [n],
                circuit: { c, v, m in
                    c.eq(m.mul(v[0], c.constant(3, width: n)), c.add(shl(c, v[0], 1), v[0]).sum)
                }, holds: { _ in true }))
    }
    list.append(
        Claim(
            name: "odd*odd is odd", widths: [n, n],
            circuit: { c, v, m in
                implies(c, c.and(v[0].bits[0], v[1].bits[0]), m.mul(v[0], v[1]).bits[0])
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "a*(a+1) is even", widths: [n],
            circuit: { c, v, m in
                -m.mul(v[0], c.add(v[0], c.constant(1, width: n)).sum).bits[0]
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "zero annihilates", widths: [n, n],
            circuit: { c, v, m in
                implies(c, isZero(c, v[0]), isZero(c, m.mul(v[0], v[1])))
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "one is neutral", widths: [n, n],
            circuit: { c, v, m in
                implies(c, c.eq(v[0], c.constant(1, width: n)), c.eq(m.mul(v[0], v[1]), v[1]))
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "widened product >= factor", widths: [n, n],
            circuit: { c, v, m in
                let p = m.mul(c.zeroExtend(v[0], to: 2 * n), c.zeroExtend(v[1], to: 2 * n))
                return implies(c, -isZero(c, v[1]), c.ule(c.zeroExtend(v[0], to: 2 * n), p))
            }, holds: { _ in true }))
    list.append(
        Claim(
            name: "unsigned overflow flag", widths: [n, n],
            circuit: { c, v, m in
                let p = m.mul(c.zeroExtend(v[0], to: 2 * n), c.zeroExtend(v[1], to: 2 * n))
                return -c.xor(m.unsignedMulOverflows(v[0], v[1]), c.ult(c.constant(mask, width: 2 * n), p))
            }, holds: { _ in true }))
    if n >= 4 {
        list.append(
            Claim(
                name: "no signed overflow in small range", widths: [n, n],
                circuit: { c, v, m in
                    implies(c, c.and(slim(c, v[0], -4, 3), slim(c, v[1], -4, 3)), -m.signedMulOverflows(v[0], v[1]))
                },
                holds: { v in
                    let (a, b) = (signed(v[0], n), signed(v[1], n))
                    guard (-4...3).contains(a) && (-4...3).contains(b) else { return true }
                    return (-(1 << Int64(n - 1))..<(1 << Int64(n - 1))).contains(a * b)
                }))
    }
    if n >= 2 {
        list.append(
            Claim(
                name: "(a+1)^2 == a^2+2a+1", widths: [n],
                circuit: { c, v, m in
                    let one = c.constant(1, width: n)
                    let s = c.add(v[0], one).sum
                    let rhs = c.add(c.add(m.mul(v[0], v[0]), shl(c, v[0], 1)).sum, one).sum
                    return c.eq(m.mul(s, s), rhs)
                }, holds: { _ in true }))
    }
    list.append(
        Claim(
            name: "FALSE a*b == a+b", widths: [n, n], circuit: { c, v, m in c.eq(m.mul(v[0], v[1]), c.add(v[0], v[1]).sum) },
            holds: { ($0[0] &* $0[1]) & mask == ($0[0] &+ $0[1]) & mask }))
    list.append(
        Claim(
            name: "FALSE a*a == a", widths: [n], circuit: { c, v, m in c.eq(m.mul(v[0], v[0]), v[0]) },
            holds: { ($0[0] &* $0[0]) & mask == $0[0] }))
    list.append(
        Claim(
            name: "FALSE no zero divisors", widths: [n, n],
            circuit: { c, v, m in
                implies(c, isZero(c, m.mul(v[0], v[1])), c.or(isZero(c, v[0]), isZero(c, v[1])))
            }, holds: { ($0[0] &* $0[1]) & mask != 0 || $0[0] == 0 || $0[1] == 0 }))
    list.append(
        Claim(
            name: "FALSE product >= factor (wraps)", widths: [n, n],
            circuit: { c, v, m in
                implies(c, -isZero(c, v[1]), c.ule(v[0], m.mul(v[0], v[1])))
            }, holds: { $0[1] == 0 || $0[0] <= ($0[0] &* $0[1]) & mask }))
    list.append(
        Claim(
            name: "FALSE assoc off by one", widths: [n, n, n],
            circuit: { c, v, m in
                c.eq(m.mul(m.mul(v[0], v[1]), v[2]), c.add(m.mul(v[0], m.mul(v[1], v[2])), c.constant(1, width: n)).sum)
            }, holds: { _ in false }))
    list.append(
        Claim(
            name: "FALSE distributivity with extra term", widths: [n, n, n],
            circuit: { c, v, m in
                let extra = bit(c, c.and(v[0].bits[0], c.and(v[1].bits[0], v[2].bits[0])), width: n)
                let rhs = c.add(c.add(m.mul(v[0], v[1]), m.mul(v[0], v[2])).sum, extra).sum
                return c.eq(m.mul(v[0], c.add(v[1], v[2]).sum), rhs)
            }, holds: { !($0[0] & $0[1] & $0[2] & 1 == 1) }))
    if n >= 4 {
        list.append(
            Claim(
                name: "FALSE no signed overflow in [-8,7]", widths: [n, n],
                circuit: { c, v, m in
                    implies(c, c.and(slim(c, v[0], -8, 7), slim(c, v[1], -8, 7)), -m.signedMulOverflows(v[0], v[1]))
                },
                holds: { v in
                    let (a, b) = (signed(v[0], n), signed(v[1], n))
                    guard (-8...7).contains(a) && (-8...7).contains(b) else { return true }
                    let p = a * b
                    return p >= -(1 << Int64(n - 1)) && p < (1 << Int64(n - 1))
                }))
    }
    return list
}

private func domain(_ width: Int, signedBits: Int?) -> [UInt64] {
    let mask: UInt64 = width >= 64 ? ~0 : (1 << UInt64(width)) - 1
    if let k = signedBits, k < width {
        return (-(Int64(1) << Int64(k - 1))..<(Int64(1) << Int64(k - 1))).map { UInt64(bitPattern: $0) & mask }
    }
    return Array(0...mask)
}

private func forAll(_ domains: [[UInt64]], _ body: ([UInt64]) -> Bool) -> Bool {
    var point = [UInt64](repeating: 0, count: domains.count)
    func go(_ i: Int) -> Bool {
        if i == domains.count { return body(point) }
        for v in domains[i] { point[i] = v; if !go(i + 1) { return false } }
        return true
    }
    return go(0)
}

@Suite(.tags(.slow)) struct RefiningProveTests {
    private func plain(_ claim: Claim, budget: Int = 1_000_000) throws -> ProofVerdict {
        try prove(inputWidths: claim.widths, inputSignedBits: claim.signedBits, conflictBudget: budget) { c, v in
            try claim.circuit(c, v, MulAbstraction(cnf: c, mode: .exact))
        }
    }

    private func refining(_ claim: Claim, budget: Int = 1_000_000) throws -> RefineOutcome {
        try proveRefiningDetailed(
            inputWidths: claim.widths, inputSignedBits: claim.signedBits, conflictBudget: budget, claim: claim.circuit)
    }

    /// Every verdict must equal exhaustive evaluation at 6 bits, and every counterexample must replay natively.
    @Test func agreesWithBruteForceAt6Bits() throws {
        for claim in claims(6) {
            let domains = claim.widths.enumerated().map { domain($1, signedBits: claim.signedBits?[$0]) }
            let truth = forAll(domains, claim.holds)
            let outcome = try refining(claim)
            switch outcome.verdict {
            case .proved: #expect(truth, "\(claim.name): proved a false claim")
            case .counterexample(let values): #expect(!claim.holds(values), "\(claim.name): counterexample \(values) does not replay")
            case .unknown: Issue.record("\(claim.name): unknown at 6 bits")
            }
            if truth { #expect(outcome.verdict == .proved, "\(claim.name)") }
        }
    }

    @Test func agreesWithBruteForceAtOtherWidths() throws {
        for n in [1, 2, 3, 4, 5] {
            for claim in claims(n) {
                let truth = forAll(claim.widths.map { domain($0, signedBits: nil) }, claim.holds)
                let verdict = try refining(claim).verdict
                if truth {
                    #expect(verdict == .proved, "\(claim.name) n=\(n)")
                } else if case .counterexample(let v) = verdict {
                    #expect(!claim.holds(v), "\(claim.name) n=\(n) replay")
                } else {
                    Issue.record("\(claim.name) n=\(n): expected counterexample, got \(verdict)")
                }
            }
        }
    }

    @Test func narrowedInputsAgreeWithBruteForce() throws {
        let narrow: [Claim] = [
            Claim(
                name: "narrow range", widths: [6, 6], signedBits: [3, 3],
                circuit: { c, v, m in
                    let p = m.mul(v[0], v[1])
                    return c.and(c.sle(p, c.constant(16, width: 6)), c.sle(c.constant(UInt64(bitPattern: -12) & 63, width: 6), p))
                }, holds: { _ in true }),
            Claim(
                name: "FALSE narrow range", widths: [6, 6], signedBits: [3, 3],
                circuit: { c, v, m in
                    c.sle(m.mul(v[0], v[1]), c.constant(15, width: 6))
                }, holds: { signed($0[0], 6) * signed($0[1], 6) <= 15 }),
            Claim(
                name: "mixed narrow and full", widths: [6, 6], signedBits: [3, nil],
                circuit: { c, v, m in
                    c.eq(m.mul(v[0], v[1]), m.mul(v[1], v[0]))
                }, holds: { _ in true }),
            Claim(
                name: "FALSE mixed narrow and full", widths: [6, 6], signedBits: [3, nil],
                circuit: { c, v, m in
                    c.eq(m.mul(v[0], v[1]), c.add(v[0], v[1]).sum)
                }, holds: { ($0[0] &* $0[1]) & 63 == ($0[0] &+ $0[1]) & 63 }),
        ]
        for claim in narrow {
            let truth = forAll(claim.widths.enumerated().map { domain($1, signedBits: claim.signedBits?[$0]) }, claim.holds)
            let verdict = try refining(claim).verdict
            if truth {
                #expect(verdict == .proved, "\(claim.name)")
            } else if case .counterexample(let v) = verdict {
                #expect(!claim.holds(v), "\(claim.name) replay")
            } else {
                Issue.record("\(claim.name): got \(verdict)")
            }
        }
    }

    /// The lemmas are axioms for the checker, so audit them: with every product forced exact, the lemma clauses
    /// must be satisfiable for every input assignment (a false lemma would make some assignment UNSAT).
    @Test func lemmasHoldForTheRealMultiplier() {
        func audit(_ n: Int, samples: Int?) {
            let c = CNFBuilder()
            let m = MulAbstraction(cnf: c)
            let (a, b, d) = (c.input(width: n), c.input(width: n), c.input(width: n))
            let s = c.input(width: n, signedBits: max(1, n / 2))
            let wide = { (v: BV) in c.zeroExtend(v, to: 2 * n) }
            _ = [
                m.mul(a, b), m.mul(b, a), m.mul(m.mul(a, b), d), m.mul(a, m.mul(b, d)), m.mul(a, c.add(b, d).sum),
                m.mul(a, b), m.mul(a, d), m.mul(a, c.sub(b, d).difference), m.mul(d, b),
                m.mul(wide(a), wide(b)), m.mul(a, a), m.mul(s, s), m.mul(s, a), m.mul(s, b),
                m.mul(c.shiftLeft(a, by: c.constant(1, width: n)), b), m.mul(c.constant(3, width: n), a),
                m.mul(c.add(a, c.constant(1, width: n)).sum, c.add(a, c.constant(1, width: n)).sum),
            ]
            _ = (m.unsignedMulOverflows(a, b), m.signedMulOverflows(a, b), m.signedMulOverflows(s, a))
            m.finalize()
            m.refineAll()
            let base = c.cnf
            let free = [a, b, d]
            func check(_ values: [UInt64], _ sv: UInt64) {
                var cnf = base
                func pin(_ v: BV, _ value: UInt64) {
                    for (i, lit) in v.bits.enumerated() { cnf.clauses.append([(value >> UInt64(i)) & 1 == 1 ? lit : -lit]) }
                }
                for (v, x) in zip(free, values) { pin(v, x) }
                pin(s, sv)
                guard case .sat = Solver.solve(cnf, conflictBudget: 100_000) else {
                    Issue.record("lemma set inconsistent with exact multiplier at n=\(n), inputs \(values), s=\(sv)")
                    return
                }
            }
            let mask: UInt64 = (1 << UInt64(n)) - 1
            let sdomain = domain(n, signedBits: max(1, n / 2))
            if let samples {
                var state: UInt64 = 0x9E3779B97F4A7C15 ^ UInt64(n)
                func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 20 }
                for _ in 0..<samples { check([next() & mask, next() & mask, next() & mask], sdomain[Int(next() % UInt64(sdomain.count))]) }
            } else {
                for x in 0...mask { for y in 0...mask { for z in 0...mask { for sv in sdomain { check([x, y, z], sv) } } } }
            }
        }
        for n in 1...3 { audit(n, samples: nil) }
        audit(4, samples: 600)
        audit(6, samples: 300)
        audit(8, samples: 200)
    }

    /// Claims that need the real multiplier: the abstraction is satisfiable first, then refined to exact.
    @Test func refinementRecoversExactSemantics() throws {
        for n in [6, 8] {
            let claim = claims(n).first { $0.name == "(a+1)^2 == a^2+2a+1" }!
            let outcome = try refining(claim)
            #expect(outcome.verdict == .proved, "n=\(n)")
            #expect(outcome.stats.refinedNodes > 0 && outcome.stats.spuriousModels > 0, "\(outcome.stats)")
        }
    }

    @Test func falseClaimsGiveReplayableCounterexamples() throws {
        for (n, name) in [
            (8, "FALSE a*b == a+b"), (16, "FALSE a*b == a+b"), (32, "FALSE a*b == a+b"), (16, "FALSE assoc off by one"),
            (16, "FALSE no zero divisors"),
        ] {
            let claim = claims(n).first { $0.name == name }!
            guard case .counterexample(let values) = try refining(claim).verdict else { Issue.record("\(name) n=\(n)"); continue }
            #expect(!claim.holds(values), "\(name) n=\(n): \(values)")
        }
    }

    /// Plain and refining agree wherever plain decides, and refining never returns a verdict plain contradicts.
    @Test func agreesWithPlainProveAt8Bits() throws {
        for name in ["commutativity", "FALSE a*b == a+b", "parity", "shift commutes with mul"] {
            let claim = claims(8).first { $0.name == name }!
            let (p, r) = (try plain(claim), try refining(claim).verdict)
            switch (p, r) {
            case (.proved, .proved), (.counterexample, .counterexample): break
            default: Issue.record("\(name): plain \(p) vs refining \(r)")
            }
        }
    }

    @Test func provesMultiplierPropertiesThatPlainCannotAtWideWidths() throws {
        for (n, name) in [
            (16, "commutativity"), (32, "commutativity"), (16, "associativity"), (32, "associativity"), (16, "distributivity"),
            (16, "commutativity with shifted operand"), (32, "shift commutes with mul"), (16, "parity"), (32, "a*3 == (a<<1)+a"),
            (32, "odd*odd is odd"), (16, "widened product >= factor"), (16, "unsigned overflow flag"),
        ] {
            let claim = claims(n).first { $0.name == name }!
            let outcome = try refining(claim)
            #expect(outcome.verdict == .proved, "\(name) n=\(n): \(outcome.verdict) \(outcome.stats)")
        }
    }

    /// Prints plain vs refining timings. Plain runs only up to 6 bits unless SF_REFINE_PLAIN=1 (then with a 150k conflict budget per row, minutes in total).
    @Test func speedTable() throws {
        let plainWide = ProcessInfo.processInfo.environment["SF_REFINE_PLAIN"] == "1"
        let rows: [(String, Int)] = [
            ("commutativity", 6), ("commutativity", 8), ("commutativity", 10), ("commutativity", 12), ("commutativity", 16),
            ("commutativity", 32),
            ("associativity", 8), ("associativity", 16), ("distributivity", 8), ("distributivity", 16),
            ("commutativity with shifted operand", 16), ("shift commutes with mul", 16), ("parity", 16), ("a*3 == (a<<1)+a", 16),
            ("(a+1)^2 == a^2+2a+1", 6), ("(a+1)^2 == a^2+2a+1", 8), ("(a+1)^2 == a^2+2a+1", 10),
            ("FALSE a*b == a+b", 8), ("FALSE a*b == a+b", 16),
        ]
        print("claim | bits | plain | refining (verdict, s, rounds, nodes, refined)")
        for (name, n) in rows {
            let claim = claims(n).first { $0.name == name }!
            var plainText = "skipped"
            if n <= 6 || plainWide {
                let start = ContinuousClock.now
                let v = try plain(claim, budget: 150_000)
                plainText = "\(label(v)) \(seconds(ContinuousClock.now - start))"
            }
            let start = ContinuousClock.now
            let o = try refining(claim, budget: 1_000_000)
            let s = o.stats
            print(
                "\(name) | \(n) | \(plainText) | \(label(o.verdict)) \(seconds(ContinuousClock.now - start)) r=\(s.rounds) n=\(s.multiplierNodes) ref=\(s.refinedNodes)"
            )
        }
    }
}

private func label(_ v: ProofVerdict) -> String {
    switch v {
    case .proved: "proved"
    case .counterexample: "cex"
    case .unknown: "unknown"
    }
}

private func seconds(_ d: Duration) -> String {
    let (s, a) = d.components
    return String(format: "%.4fs", Double(s) + Double(a) / 1e18)
}
