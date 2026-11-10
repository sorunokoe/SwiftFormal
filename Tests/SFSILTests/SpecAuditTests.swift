import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL
import SFTestSupport

/// Audits of specs, on real `swiftc` output: vacuity checks, and mutation testing of the spec.
enum AuditFixture {
    static let source = """
        public func clampA(_ x: Int32, _ lo: Int32, _ hi: Int32) -> Int32 {
            if x < lo { return lo }
            if x > hi { return hi }
            return x
        }
        public func absA(_ x: Int8) -> Int8 { x < 0 ? 0 &- x : x }
        public func scale(_ x: Int16) -> Int16 { x &* 3 &+ 7 }
        """
    static let onone = try! SILCompiler.module(source: source, name: "Au", optimization: .none)
    static let speed = try! SILCompiler.module(source: source, name: "Au", optimization: .speed)
    static func module(_ o: Optimization) -> SILModule { o == .none ? onone : speed }
    static func symbol(_ n: String, _ o: Optimization) throws -> String { try module(o).symbol(module: "Au", name: n) }
}

private typealias Spec = (CNFBuilder, [BV], BV) -> Int32

private func clampRequires(_ c: CNFBuilder, _ x: [BV]) -> Int32 { c.sle(x[1], x[2]) }
/// Only an upper bound.
private func clampWeak(_ c: CNFBuilder, _ x: [BV], _ r: BV) -> Int32 { c.sle(r, x[2]) }
/// Range, plus identity when `x` is already in range. Sounder, but it leaves the out-of-range results open.
private func clampMedium(_ c: CNFBuilder, _ x: [BV], _ r: BV) -> Int32 {
    let inRange = c.and(c.sle(x[1], x[0]), c.sle(x[0], x[2]))
    return c.and(c.and(c.sle(x[1], r), c.sle(r, x[2])), c.or(-inRange, c.eq(r, x[0])))
}
/// The whole function: below the range gives `lo`, above gives `hi`, otherwise `x`.
private func clampStrong(_ c: CNFBuilder, _ x: [BV], _ r: BV) -> Int32 {
    let below = c.slt(x[0], x[1]), above = c.slt(x[2], x[0])
    return c.and(
        c.and(c.or(-below, c.eq(r, x[1])), c.or(-above, c.eq(r, x[2]))),
        c.or(c.or(below, above), c.eq(r, x[0]))
    )
}

@Suite(.tags(.slow)) struct SpecAuditTests {
    @Test(arguments: [Optimization.none, .speed])
    func aWeakSpecHasSurvivorsAndACompleteOneDoesNot(_ o: Optimization) throws {
        let symbol = try AuditFixture.symbol("clampA", o)
        let m = AuditFixture.module(o)
        let weak = try SILVerifier.auditSpec(symbol, in: m, requires: clampRequires, ensures: clampWeak)
        let medium = try SILVerifier.auditSpec(symbol, in: m, requires: clampRequires, ensures: clampMedium)
        let strong = try SILVerifier.auditSpec(symbol, in: m, requires: clampRequires, ensures: clampStrong)
        #expect(weak.original == .proved && medium.original == .proved && strong.original == .proved)
        #expect(!weak.survivors.isEmpty, "an upper-bound-only spec should let a wrong clamp through")
        #expect(strong.survivors.isEmpty, "survivors: \(strong.survivors.map(\.mutant.description))")
        #expect(strong.killed > weak.killed)
        #expect(strong.mutationScore == 1.0)
        #expect(strong.ensuresDeterminesResult == true)
        #expect(medium.ensuresDeterminesResult == false, "the range-and-identity spec leaves out-of-range results open")
        #expect(weak.ensuresDeterminesResult == false)
        #expect(strong.undecided == 0)
    }

    @Test func aSurvivorWitnessReallySeparatesTheMutantFromTheOriginal() throws {
        let o = Optimization.none
        let symbol = try AuditFixture.symbol("clampA", o)
        let module = AuditFixture.module(o)
        let audit = try SILVerifier.auditSpec(symbol, in: module, requires: clampRequires, ensures: clampWeak)
        let survivor = try #require(audit.survivors.first)
        guard case .survived(let witness) = survivor.status else { return }
        var lines = try #require(module.bodyLines(of: symbol))
        lines[survivor.mutant.line] = survivor.mutant.replacementLine
        let mutated = module.replacingBody(of: symbol, with: lines)
        let a = Int32(truncatingIfNeeded: witness[0]), lo = Int32(truncatingIfNeeded: witness[1]),
            hi = Int32(truncatingIfNeeded: witness[2])
        #expect(lo <= hi, "the witness meets requires")
        let c = CNFBuilder()
        let args = zip(try module.function(symbol).parameterWidths, witness).map { c.constant($0.1, width: $0.0) }
        let r1 = try SILEncoder(module: module, builder: c).encode(symbol: symbol, arguments: args)
        let r2 = try SILEncoder(module: mutated, builder: c).encode(symbol: symbol, arguments: args)
        let differs =
            r1.trap != r2.trap || r1.undefined != r2.undefined
            || (r1.trap == c.falseLit && r1.undefined == c.falseLit && c.constantValue(r1.result) != c.constantValue(r2.result))
        #expect(differs, "witness \(a),\(lo),\(hi) does not separate the mutant")
    }

    @Test func anUnsatisfiableRequiresIsVacuousEvenThoughTheProofSucceeds() throws {
        let symbol = try AuditFixture.symbol("absA", .none)
        let module = AuditFixture.module(.none)
        let never: (CNFBuilder, [BV]) -> Int32 = { c, x in c.and(c.slt(x[0], c.constant(0, width: 8)), c.sle(c.constant(0, width: 8), x[0]))
        }
        let nonsense: Spec = { c, _, r in c.eq(r, c.constant(5, width: 8)) }
        #expect(try SILVerifier.prove(symbol, in: module, requires: never, ensures: nonsense) == .proved)
        let audit = try SILVerifier.auditSpec(symbol, in: module, requires: never, ensures: nonsense)
        #expect(audit.requiresSatisfiable == false)
        #expect(audit.isVacuous)
    }

    @Test func aTautologicalEnsuresIsReported() throws {
        let symbol = try AuditFixture.symbol("absA", .none)
        let audit = try SILVerifier.auditSpec(
            symbol, in: AuditFixture.module(.none),
            requires: { c, x in c.slt(c.constant(UInt64(bitPattern: -127) & 0xFF, width: 8), x[0]) },
            ensures: { c, _, r in c.or(c.ult(r, c.constant(5, width: 8)), c.ule(c.constant(5, width: 8), r)) }
        )
        #expect(audit.ensuresConstrainsResult == false)
        #expect(audit.isVacuous)
    }

    @Test func aGoodSpecIsNotVacuousAndKillsLiteralMutants() throws {
        let symbol = try AuditFixture.symbol("scale", .none)
        let audit = try SILVerifier.auditSpec(
            symbol, in: AuditFixture.module(.none),
            ensures: { c, x, r in c.eq(r, c.add(c.mul(x[0], c.constant(3, width: 16)), c.constant(7, width: 16)).sum) }
        )
        #expect(audit.original == .proved)
        #expect(!audit.isVacuous)
        #expect(audit.survivors.isEmpty)
        #expect(audit.mutants.contains { $0.mutant.description.hasPrefix("literal") })
        #expect(audit.mutationScore == 1.0)
    }

    @Test func aSpecThatOnlyChecksParityMissesWrongConstants() throws {
        let symbol = try AuditFixture.symbol("scale", .none)
        let audit = try SILVerifier.auditSpec(
            symbol, in: AuditFixture.module(.none),
            ensures: { c, x, r in c.eq(BV(bits: [r.bits[0]]), BV(bits: [c.xor(x[0].bits[0], c.trueLit)])) }
        )
        #expect(audit.original == .proved)
        #expect(!audit.survivors.isEmpty, "x*3+7 and x*3+9 have the same parity")
    }
}
