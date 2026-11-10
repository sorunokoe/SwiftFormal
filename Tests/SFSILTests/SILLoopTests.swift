import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL
import SFTestSupport

/// Loops verified with user-supplied invariants on real `swiftc` output.
enum LoopFixture {
    static let source = """
        public func mulLoop(_ x: Int8, _ n: Int8) -> Int8 {
            var s: Int8 = 0
            var i: Int8 = 0
            while i < n { s = s &+ x; i += 1 }
            return s
        }
        public func countdown(_ n: UInt8) -> UInt8 {
            var i = n
            var c: UInt8 = 0
            while i > 0 { i -= 1; c = c &+ 2 }
            return c
        }
        public func gcd(_ a: UInt8, _ b: UInt8) -> UInt8 {
            var a = a, b = b
            while b != 0 { (a, b) = (b, a % b) }
            return a
        }
        public func modSub(_ x: UInt8, _ m: UInt8) -> UInt8 {
            var r = x
            while r >= m { r -= m }
            return r
        }
        public func sumChecked(_ n: Int8) -> Int8 {
            var s: Int8 = 0
            var i: Int8 = 0
            while i < n { s += i; i += 1 }
            return s
        }
        public func fixedSum() -> Int32 {
            var s: Int32 = 0
            var i: Int32 = 0
            while i < 4 { s &+= i &* i; i += 1 }
            return s
        }
        public func nested(_ a: UInt8, _ b: UInt8) -> UInt8 {
            var t: UInt8 = 0
            var i: UInt8 = 0
            while i < a {
                var j: UInt8 = 0
                while j < b { t = t &+ 1; j += 1 }
                i += 1
            }
            return t
        }
        public func condLoops(_ n: UInt8, _ f: Bool) -> UInt8 {
            var a: UInt8 = 0
            if f { while a < n { a += 1 } }
            var b: UInt8 = 0
            while b < n { b += 1 }
            return a &+ b
        }
        public func twoLoops(_ n: UInt8) -> UInt8 {
            var a: UInt8 = 0
            while a < n { a += 1 }
            var b: UInt8 = 0
            while b < a { b += 1 }
            return b
        }
        """
    static let onone = try! SILCompiler.module(source: source, name: "Lp", optimization: .none)
    static let speed = try! SILCompiler.module(source: source, name: "Lp", optimization: .speed)

    static func module(_ o: Optimization) -> SILModule { o == .none ? onone : speed }
    static func symbol(_ name: String, _ o: Optimization) throws -> String {
        try module(o).symbol(module: "Lp", name: name)
    }
}

private func failed(_ r: LoopProofResult) -> [String] { r.failures.map(\.name) }

@Suite(.tags(.slow)) struct SILLoopTests {
    private static let optimizations: [Optimization] = [.none, .speed]

    // MARK: multiplication by repeated addition

    /// The loop state is (s, i) in both optimization levels (at -Onone followed by dead stack cells).
    private static func mulInvariant(
        _ header: String, _ o: Optimization, weak: Bool = false, nonInductive: Bool = false,
        falseAtEntry: Bool = false
    ) -> LoopInvariant {
        LoopInvariant(header: header) { c, st in
            let (x, n) = (st.arguments[0], st.arguments[1])
            let (s, i) = (st.variables[0], st.variables[1])
            let zero = c.constant(0, width: 8)
            // -O is rotated (the header runs the body, so i < n); -Onone tests at the header (i <= n).
            var f = c.and(c.sle(zero, i), o == .speed ? c.slt(i, n) : c.sle(i, n))
            if !weak { f = c.and(f, c.eq(s, c.mul(x, i, narrowing: false))) }
            if nonInductive { f = c.and(f, c.eq(i, zero)) }
            if falseAtEntry { f = c.and(f, c.sle(c.constant(1, width: 8), i)) }
            return f
        }
    }

    private static let mulRequires: @Sendable (CNFBuilder, [BV]) -> Int32 = { c, a in c.sle(c.constant(0, width: 8), a[1]) }
    private static let mulEnsures: @Sendable (CNFBuilder, [BV], [BV]) -> Int32 = { c, a, r in
        c.eq(r[0], c.mul(a[0], a[1], narrowing: false))
    }

    private static func proveMul(
        _ o: Optimization, _ invariant: LoopInvariant? = nil, variant: LoopVariant? = nil,
        requires: Bool = true
    ) throws -> LoopProofResult {
        let module = LoopFixture.module(o)
        let symbol = try LoopFixture.symbol("mulLoop", o)
        let header = try SILVerifier.loops(of: symbol, in: module)[0].header
        return try SILVerifier.proveLoopFunction(
            symbol, in: module, loopInvariants: [invariant ?? mulInvariant(header, o)],
            variants: variant.map { [$0] } ?? [],
            requires: requires ? mulRequires : { c, _ in c.trueLit }, ensures: mulEnsures)
    }

    @Test(arguments: optimizations)
    func repeatedAdditionIsMultiplication(_ o: Optimization) throws {
        let r = try Self.proveMul(o)
        #expect(r.partialCorrectnessProved, "\(r.summary) \(failed(r))")
        #expect(!r.terminationProved)
        #expect(r.summary.contains("termination not proved"))
    }

    @Test(arguments: optimizations)
    func aRankingFunctionProvesTermination(_ o: Optimization) throws {
        let module = LoopFixture.module(o)
        let header = try SILVerifier.loops(of: try LoopFixture.symbol("mulLoop", o), in: module)[0].header
        let r = try Self.proveMul(o, variant: LoopVariant(header: header) { c, st in c.sub(st.arguments[1], st.variables[1]).difference })
        #expect(r.provedTotalCorrectness, "\(r.summary) \(failed(r))")
        #expect(r.obligations.contains { $0.kind == .termination })
        // A rank that never decreases fails its own obligation and leaves partial correctness untouched.
        let bad = try Self.proveMul(o, variant: LoopVariant(header: header) { _, st in st.arguments[1] })
        #expect(bad.partialCorrectnessProved && !bad.terminationProved)
        #expect(failed(bad) == ["TERMINATION(\(header))"])
        #expect(bad.summary.contains("partial correctness proved; termination not proved"))
    }

    @Test(arguments: optimizations)
    func aTooWeakInvariantFailsOnlyTheExitObligation(_ o: Optimization) throws {
        let header = try SILVerifier.loops(of: try LoopFixture.symbol("mulLoop", o), in: LoopFixture.module(o))[0].header
        let r = try Self.proveMul(o, Self.mulInvariant(header, o, weak: true))
        #expect(failed(r) == ["EXIT(\(header))"], "\(failed(r))")
        #expect(!r.partialCorrectnessProved)
        #expect(r.summary.contains("NOT proved"))
        // The counterexample is a state the weak invariant admits but with s != x * i.
        let ce = try #require(r.failures.first?.counterexample)
        let state = try #require(ce.states[header])
        #expect(Int8(truncatingIfNeeded: state[0]) != Int8(truncatingIfNeeded: ce.arguments[0]) &* Int8(truncatingIfNeeded: state[1]))
    }

    @Test(arguments: optimizations)
    func aNonInductiveInvariantFailsTheStepObligation(_ o: Optimization) throws {
        let header = try SILVerifier.loops(of: try LoopFixture.symbol("mulLoop", o), in: LoopFixture.module(o))[0].header
        let r = try Self.proveMul(o, Self.mulInvariant(header, o, nonInductive: true))
        #expect(failed(r) == ["STEP(\(header))"], "\(failed(r))")
    }

    @Test(arguments: optimizations)
    func aFalseInvariantAtEntryFailsTheInitObligation(_ o: Optimization) throws {
        let header = try SILVerifier.loops(of: try LoopFixture.symbol("mulLoop", o), in: LoopFixture.module(o))[0].header
        let r = try Self.proveMul(o, Self.mulInvariant(header, o, falseAtEntry: true))
        #expect(failed(r) == ["INIT(\(header))"], "\(failed(r))")
        let ce = try #require(r.failures.first?.counterexample)
        // At -O the loop is entered only when n > 0; at -Onone the header is reached for every n.
        if o == .speed { #expect(Int8(truncatingIfNeeded: ce.arguments[1]) > 0) }
    }

    @Test(arguments: optimizations)
    func withoutThePreconditionTheSpecificationFails(_ o: Optimization) throws {
        let r = try Self.proveMul(o, requires: false)
        // n < 0 skips the loop and returns 0, which is not x * n.
        #expect(!r.partialCorrectnessProved)
        let ce = try #require(r.failures.first?.counterexample)
        #expect(Int8(truncatingIfNeeded: ce.arguments[1]) < 0)
    }

    // MARK: traps inside loops

    @Test(arguments: optimizations)
    func aCheckedOverflowInTheBodyIsReported(_ o: Optimization) throws {
        let module = LoopFixture.module(o)
        let symbol = try LoopFixture.symbol("sumChecked", o)
        let info = try SILVerifier.loops(of: symbol, in: module)[0]
        // -Onone carries s twice (as the struct and as its builtin value) and then i; the two copies are one value.
        let (si, ii) = o == .none ? (1, 2) : (0, 1)
        let tied: (CNFBuilder, LoopState) -> Int32 = { c, st in o == .none ? c.eq(st.variables[0], st.variables[1]) : c.trueLit }
        // Without a bound on the sum, `s += i` can overflow: that is a trap and must fail the proof.
        let r = try SILVerifier.proveLoopFunction(
            symbol, in: module,
            loopInvariants: [
                LoopInvariant(header: info.header) { c, st in
                    c.and(tied(c, st), c.and(c.sle(c.constant(0, width: 8), st.variables[ii]), c.sle(st.variables[ii], st.arguments[0])))
                }
            ])
        #expect(!r.partialCorrectnessProved)
        let step = try #require(r.failures.first { $0.kind == .step })
        let state = try #require(step.counterexample?.states[info.header])
        let (s, i) = (Int8(truncatingIfNeeded: state[si]), Int8(truncatingIfNeeded: state[ii]))
        #expect(s.addingReportingOverflow(i).overflow || i.addingReportingOverflow(1).overflow, "s=\(s) i=\(i)")

        // For 0 <= n <= 15 the sum 0 + 1 + ... + (n-1) = n(n-1)/2 <= 105 fits, and the loop is proved free of traps.
        let proved = try SILVerifier.proveLoopFunction(
            symbol, in: module,
            loopInvariants: [
                LoopInvariant(header: info.header) { c, st in
                    let (s, i, n) = (st.variables[si], st.variables[ii], st.arguments[0])
                    let zero = c.constant(0, width: 8)
                    // The rotated -O header is entered only with i < n; -Onone tests at the top, so i == n is reachable there.
                    let upper = o == .speed ? c.slt(i, n) : c.sle(i, n)
                    let f = c.and(tied(c, st), c.and(c.and(c.sle(zero, i), upper), c.sle(zero, s)))
                    let twice = c.mul(s, c.constant(2, width: 8), narrowing: false)
                    let pairs = c.mul(i, c.sub(i, c.constant(1, width: 8)).difference, narrowing: false)
                    return c.and(f, c.eq(twice, pairs))
                }
            ],
            requires: { c, a in c.and(c.sle(c.constant(0, width: 8), a[0]), c.sle(a[0], c.constant(15, width: 8))) },
            ensures: { c, a, r in
                c.eq(
                    c.mul(r[0], c.constant(2, width: 8), narrowing: false),
                    c.mul(a[0], c.sub(a[0], c.constant(1, width: 8)).difference, narrowing: false))
            })
        #expect(proved.partialCorrectnessProved, "\(proved.summary) \(failed(proved))")
    }

    @Test func aDivisionInsideTheLoopNeedsItsGuardInTheInvariant() throws {
        // -O gcd: the header divides by its third variable, so the invariant must exclude zero or STEP reports the trap.
        let o = Optimization.speed
        let module = LoopFixture.module(o)
        let symbol = try LoopFixture.symbol("gcd", o)
        let header = try SILVerifier.loops(of: symbol, in: module)[0].header
        func run(_ inv: @escaping (CNFBuilder, LoopState) -> Int32) throws -> LoopProofResult {
            try SILVerifier.proveLoopFunction(
                symbol, in: module, loopInvariants: [LoopInvariant(header: header, holds: inv)],
                requires: { c, a in -c.and(c.eq(a[0], c.constant(0, width: 8)), c.eq(a[1], c.constant(0, width: 8))) },
                ensures: { c, _, r in -c.eq(r[0], c.constant(0, width: 8)) })
        }
        let good = try run { c, st in
            c.and(c.eq(st.variables[1], st.variables[2]), -c.eq(st.variables[2], c.constant(0, width: 8)))
        }
        #expect(good.partialCorrectnessProved, "\(good.summary) \(failed(good))")
        let weak = try run { c, _ in c.trueLit }
        #expect(!weak.partialCorrectnessProved)
        let step = try #require(weak.failures.first { $0.kind == .step })
        #expect(step.counterexample?.states[header]?[2] == 0, "the division by zero is the failing event")
    }

    @Test(arguments: optimizations)
    func gcdNeverReturnsZeroForNonzeroInputs(_ o: Optimization) throws {
        let module = LoopFixture.module(o)
        let symbol = try LoopFixture.symbol("gcd", o)
        let header = try SILVerifier.loops(of: symbol, in: module)[0].header
        let zero = { (c: CNFBuilder) in c.constant(0, width: 8) }
        let inv: (CNFBuilder, LoopState) -> Int32 =
            o == .none
            ? { c, st in c.or(-c.eq(st.variables[0], zero(c)), -c.eq(st.variables[1], zero(c))) }
            : { c, st in c.and(c.eq(st.variables[1], st.variables[2]), -c.eq(st.variables[2], zero(c))) }
        let r = try SILVerifier.proveLoopFunction(
            symbol, in: module, loopInvariants: [LoopInvariant(header: header, holds: inv)],
            requires: { c, a in c.or(-c.eq(a[0], zero(c)), -c.eq(a[1], zero(c))) },
            ensures: { c, _, r in -c.eq(r[0], zero(c)) })
        #expect(r.partialCorrectnessProved, "\(r.summary) \(failed(r))")
    }

    // MARK: countdown, remainder by subtraction

    @Test(arguments: optimizations)
    func countdownAddsTwoPerStep(_ o: Optimization) throws {
        let module = LoopFixture.module(o)
        let symbol = try LoopFixture.symbol("countdown", o)
        let header = try SILVerifier.loops(of: symbol, in: module)[0].header
        let two = { (c: CNFBuilder) in c.constant(2, width: 8) }
        // (c, i): c == 2 * (n - i), i <= n. At -O the header already runs the body, so i >= 1 as well.
        let inv: (CNFBuilder, LoopState) -> Int32 = { c, st in
            let (acc, i, n) = (st.variables[0], st.variables[1], st.arguments[0])
            var f = c.and(c.ule(i, n), c.eq(acc, c.mul(c.sub(n, i).difference, two(c), narrowing: false)))
            if o == .speed { f = c.and(f, -c.eq(i, c.constant(0, width: 8))) }
            return f
        }
        let r = try SILVerifier.proveLoopFunction(
            symbol, in: module, loopInvariants: [LoopInvariant(header: header, holds: inv)],
            variants: [LoopVariant(header: header) { _, st in st.variables[1] }],
            ensures: { c, a, r in c.eq(r[0], c.mul(a[0], two(c), narrowing: false)) })
        #expect(r.provedTotalCorrectness, "\(r.summary) \(failed(r))")
    }

    @Test(arguments: optimizations)
    func repeatedSubtractionComputesTheRemainder(_ o: Optimization) throws {
        let module = LoopFixture.module(o)
        let symbol = try LoopFixture.symbol("modSub", o)
        let header = try SILVerifier.loops(of: symbol, in: module)[0].header
        func remainder(_ c: CNFBuilder, _ a: BV, _ m: BV) -> BV { c.unsignedDivide(a, m).remainder }
        let positive: (CNFBuilder, [BV]) -> Int32 = { c, a in -c.eq(a[1], c.constant(0, width: 8)) }
        let congruent: (CNFBuilder, LoopState) -> Int32 = { c, st in
            let r = st.variables[0]
            var f = c.eq(remainder(c, r, st.arguments[1]), remainder(c, st.arguments[0], st.arguments[1]))
            if o == .speed { f = c.and(f, c.ule(st.arguments[1], r)) }  // entered only when x >= m
            return f
        }
        let spec: (CNFBuilder, [BV], [BV]) -> Int32 = { c, a, r in c.eq(r[0], remainder(c, a[0], a[1])) }
        let r = try SILVerifier.proveLoopFunction(
            symbol, in: module, loopInvariants: [LoopInvariant(header: header, holds: congruent)],
            variants: [LoopVariant(header: header) { _, st in st.variables[0] }], requires: positive, ensures: spec)
        #expect(r.provedTotalCorrectness, "\(r.summary) \(failed(r))")

        // Remembering only the guard says nothing about the result: EXIT fails, and STEP does not.
        let weak = try SILVerifier.proveLoopFunction(
            symbol, in: module,
            loopInvariants: [
                LoopInvariant(header: header) { c, st in
                    o == .speed ? c.ule(st.arguments[1], st.variables[0]) : c.trueLit
                }
            ], requires: positive, ensures: spec)
        #expect(failed(weak).contains("EXIT(\(header))") && !failed(weak).contains("STEP(\(header))"), "\(failed(weak))")
    }

    // MARK: constant-bound loops

    @Test func aConstantBoundLoopIsUnrolledAtOptimizationAndNeedsAnInvariantWithout() throws {
        let fast = LoopFixture.speed
        let fastSymbol = try LoopFixture.symbol("fixedSum", .speed)
        #expect(try SILVerifier.loops(of: fastSymbol, in: fast).isEmpty)
        // Fully unrolled at -O: the existing loop-free prover applies, no invariant.
        #expect(try SILVerifier.prove(fastSymbol, in: fast, ensures: { c, _, r in c.eq(r, c.constant(14, width: 32)) }) == .proved)
        let wrong = try SILVerifier.prove(fastSymbol, in: fast, ensures: { c, _, r in c.eq(r, c.constant(15, width: 32)) })
        #expect(wrong != .proved)

        let slow = LoopFixture.onone
        let slowSymbol = try LoopFixture.symbol("fixedSum", .none)
        let error = #expect(throws: SILError.self) { try SILVerifier.prove(slowSymbol, in: slow) }
        #expect(error.map { "\($0)".contains("proveLoopFunction") } == true)
        let info = try SILVerifier.loops(of: slowSymbol, in: slow)
        #expect(info.count == 1)
        // s == sum of squares below i, as a table over the five possible values of i.
        let table: [UInt64] = [0, 0, 1, 5, 14]
        let r = try SILVerifier.proveLoopFunction(
            slowSymbol, in: slow,
            loopInvariants: [
                LoopInvariant(header: info[0].header) { c, st in
                    let (s, i) = (st.variables[0], st.variables[1])
                    var f = c.and(c.sle(i, c.constant(4, width: 32)), c.sle(c.constant(0, width: 32), i))
                    for (k, v) in table.enumerated() {
                        f = c.and(f, c.or(-c.eq(i, c.constant(UInt64(k), width: 32)), c.eq(s, c.constant(v, width: 32))))
                    }
                    return f
                }
            ],
            ensures: { c, _, r in c.eq(r[0], c.constant(14, width: 32)) })
        #expect(r.partialCorrectnessProved, "\(r.summary) \(failed(r))")
    }

    // MARK: structure

    @Test func loopsAreListedWithTheirStateAndRequireInvariants() throws {
        let module = LoopFixture.onone
        let symbol = try LoopFixture.symbol("mulLoop", .none)
        let info = try SILVerifier.loops(of: symbol, in: module)
        #expect(info.count == 1 && info[0].header == "bb1" && info[0].isInnermost && info[0].enclosing.isEmpty)
        #expect(info[0].variables.map(\.width) == [8, 8, 8, 8])
        #expect(info[0].variables.map(\.isStackCell) == [false, false, true, true])

        #expect(throws: SILError.self) { try SILVerifier.proveLoopFunction(symbol, in: module, loopInvariants: []) }
        #expect(throws: SILError.self) {
            try SILVerifier.proveLoopFunction(
                symbol, in: module,
                loopInvariants: [
                    LoopInvariant(header: "bb1") { c, _ in c.trueLit }, LoopInvariant(header: "bb0") { c, _ in c.trueLit },
                ])
        }
        #expect(throws: SILError.self) {
            try SILVerifier.proveLoopFunction(
                symbol, in: module, loopInvariants: [LoopInvariant(header: "bb1") { c, _ in c.trueLit }],
                variants: [LoopVariant(header: "bb2") { _, st in st.variables[0] }])
        }
        // The plain encoder does not guess about loops either.
        #expect(throws: SILError.self) { try SILVerifier.prove(symbol, in: module) }
    }

    @Test func irreducibleControlFlowIsRejected() throws {
        let sil = """
            sil_stage canonical
            import Builtin
            import Swift

            sil @$s1F3irrys4Int8VAD_ADtF : $@convention(thin) (Int8, Int8) -> Int8 {
            bb0(%0 : $Int8, %1 : $Int8):
              %2 = struct_extract %0, #Int8._value
              %3 = struct_extract %1, #Int8._value
              %4 = builtin "cmp_slt_Int8"(%2, %3) : $Builtin.Int1
              cond_br %4, bb1, bb2
            bb1:
              cond_br %4, bb2, bb3
            bb2:
              cond_br %4, bb1, bb3
            bb3:
              return %0
            }
            """
        let module = try SILModule(text: sil)
        let error = #expect(throws: SILError.self) { try SILVerifier.loops(of: "$s1F3irrys4Int8VAD_ADtF", in: module) }
        #expect(error.map { "\($0)".contains("irreducible") } == true, "\(String(describing: error))")
    }

    // MARK: nested and sequential loops

    // MARK: nested and sequential loops

    @Test(arguments: optimizations)
    func nestedLoopsComputeTheProduct(_ o: Optimization) throws {
        let module = LoopFixture.module(o)
        let symbol = try LoopFixture.symbol("nested", o)
        let loops = try SILVerifier.loops(of: symbol, in: module)
        try #require(loops.count == 2)
        let (outer, inner) = (loops[0], loops[1])
        #expect(inner.enclosing == [outer.header] && inner.isInnermost && !outer.isInnermost)
        // Both levels start with (t, counter); the rotated -O headers run the body first, so their counters are < bound.
        func invariants(weakInner: Bool = false) -> [LoopInvariant] {
            [
                LoopInvariant(header: outer.header) { c, st in
                    let (a, b) = (st.arguments[0], st.arguments[1])
                    let (t, i) = (st.variables[0], st.variables[1])
                    return c.and(o == .speed ? c.ult(i, a) : c.ule(i, a), c.eq(t, c.mul(i, b, narrowing: false)))
                },
                LoopInvariant(header: inner.header) { c, st in
                    let (a, b) = (st.arguments[0], st.arguments[1])
                    let (t, j) = (st.variables[0], st.variables[1])
                    let outerState = st.enclosing[outer.header]!
                    let (t0, i) = (outerState[0], outerState[1])
                    let f = c.and(c.ult(i, a), o == .speed ? c.ult(j, b) : c.ule(j, b))
                    return weakInner ? f : c.and(f, c.eq(t, c.add(t0, j).sum))
                },
            ]
        }
        let product: @Sendable (CNFBuilder, [BV], [BV]) -> Int32 = { c, a, r in c.eq(r[0], c.mul(a[0], a[1], narrowing: false)) }
        let proved = try SILVerifier.proveLoopFunction(symbol, in: module, loopInvariants: invariants(), ensures: product)
        #expect(proved.partialCorrectnessProved, "\(proved.summary) \(failed(proved))")
        #expect(!proved.terminationProved && proved.summary.contains("termination not proved"))

        // Forgetting how the inner counter relates to the outer total breaks the outer step.
        let weak = try SILVerifier.proveLoopFunction(symbol, in: module, loopInvariants: invariants(weakInner: true), ensures: product)
        #expect(!weak.partialCorrectnessProved)
        #expect(weak.failures.allSatisfy { $0.kind == .step || $0.kind == .exit })
    }

    @Test(arguments: optimizations)
    func aLoopAfterAnotherLoopSeesTheFirstLoopsResult(_ o: Optimization) throws {
        let module = LoopFixture.module(o)
        let symbol = try LoopFixture.symbol("twoLoops", o)
        let loops = try SILVerifier.loops(of: symbol, in: module)
        try #require(loops.count == 2)
        // The first loop counts a up to n, the second counts b up to a: the result is n.
        let rotated = o == .speed
        let first = LoopInvariant(header: loops[0].header) { c, st in
            let (n, a) = (st.arguments[0], st.variables[0])
            return rotated ? c.ult(a, n) : c.ule(a, n)
        }
        let second: @Sendable (CNFBuilder, LoopState) -> Int32 = { c, st in
            let (n, b) = (st.arguments[0], st.variables[0])
            return rotated ? c.ult(b, n) : c.ule(b, n)
        }
        let result = try SILVerifier.proveLoopFunction(
            symbol, in: module, loopInvariants: [first, LoopInvariant(header: loops[1].header, holds: second)],
            ensures: { c, a, r in c.eq(r[0], a[0]) })
        #expect(result.partialCorrectnessProved, "\(result.summary) \(failed(result))")

        // Claiming the wrong result is caught at the exit of the second loop.
        let wrong = try SILVerifier.proveLoopFunction(
            symbol, in: module, loopInvariants: [first, LoopInvariant(header: loops[1].header, holds: second)],
            ensures: { c, a, r in c.eq(r[0], c.add(a[0], c.constant(1, width: 8)).sum) })
        #expect(!wrong.partialCorrectnessProved)
    }

    @Test(arguments: optimizations)
    func aConditionallyExecutedLoopBeforeAnotherLoopIsRejected(_ o: Optimization) throws {
        let module = LoopFixture.module(o)
        let symbol = try LoopFixture.symbol("condLoops", o)
        let loops = try SILVerifier.loops(of: symbol, in: module)
        try #require(loops.count == 2)
        // Whatever the invariants say, the values reaching the second loop depend on whether the first one ran.
        let trivial = loops.map { LoopInvariant(header: $0.header) { c, _ in c.trueLit } }
        do {
            _ = try SILVerifier.proveLoopFunction(symbol, in: module, loopInvariants: trivial)
            Issue.record("expected a rejection")
        } catch let error as SILError {
            #expect("\(error)".contains("conditionally executed loop"), "\(error)")
        }
    }
}
