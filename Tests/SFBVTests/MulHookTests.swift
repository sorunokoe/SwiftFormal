import Foundation
import Testing
import SFBV
import SFCNF
import SFLLVM
import SFProve
import SFSIL
import SFTestSupport

/// The multiplier abstraction applied to real `swiftc` output: the encoders build ordinary products, and the
/// builder's multiplier hooks route them through `MulAbstraction`.
private enum MulFixture {
    static let source = """
        public func mulAB(_ a: Int32, _ b: Int32) -> Int32 { a &* b }
        public func mulBA(_ a: Int32, _ b: Int32) -> Int32 { b &* a }
        public func assocL(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { (a &* b) &* c }
        public func assocR(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { a &* (b &* c) }
        public func distL(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { a &* (b &+ c) }
        public func distR(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { (a &* b) &+ (a &* c) }
        public func mulWrong(_ a: Int32, _ b: Int32) -> Int32 { (b &* a) &+ 1 }
        public func checkedAB(_ a: Int16, _ b: Int16) -> Int16 { a * b }
        public func checkedBA(_ a: Int16, _ b: Int16) -> Int16 { b * a }
        public func ucheckedAB(_ a: UInt16, _ b: UInt16) -> UInt16 { a * b }
        public func ucheckedBA(_ a: UInt16, _ b: UInt16) -> UInt16 { b * a }
        public func smallAB(_ a: Int8, _ b: Int8) -> Int8 { a &* b }
        public func smallBA(_ a: Int8, _ b: Int8) -> Int8 { b &* a }
        public func smallWrong(_ a: Int8, _ b: Int8) -> Int8 { (b &* a) ^ 1 }
        """
    static let sil = try! SILCompiler.module(source: source, name: "Mh", optimization: .none)
    static let silSpeed = try! SILCompiler.module(source: source, name: "Mh", optimization: .speed)
    static let ir = try! LLVMModule(text: try! LLVMCompiler.emit(source: source, module: "Mh", optimization: .speed))

    static func s(_ n: String, _ m: SILModule = sil) throws -> String { try m.symbol(module: "Mh", name: n) }
}

@Suite(.tags(.slow)) struct MulHookTests {
    @Test(arguments: [Optimization.none, .speed])
    func commutativeProductsAreEquivalentAt32Bits(_ o: Optimization) throws {
        let m = o == .none ? MulFixture.sil : MulFixture.silSpeed
        let v = try SILVerifier.proveEquivalent(
            MulFixture.s("mulAB", m), in: m, MulFixture.s("mulBA", m), in: m, refining: true
        )
        #expect(v == .proved)
    }

    @Test func associativityAndDistributivityAt32Bits() throws {
        let m = MulFixture.sil
        #expect(
            try SILVerifier.proveEquivalent(
                MulFixture.s("assocL"), in: m, MulFixture.s("assocR"), in: m, refining: true) == .proved)
        #expect(
            try SILVerifier.proveEquivalent(
                MulFixture.s("distL"), in: m, MulFixture.s("distR"), in: m, refining: true) == .proved)
    }

    @Test func plainProveCannotDoTheseWithinTheSameBudget() throws {
        let m = MulFixture.sil
        for (x, y) in [("mulAB", "mulBA"), ("assocL", "assocR"), ("distL", "distR")] {
            let v = try SILVerifier.proveEquivalent(
                MulFixture.s(x), in: m, MulFixture.s(y), in: m, conflictBudget: 20_000
            )
            #expect(v == .unknown, "\(x) vs \(y)")
        }
    }

    @Test func checkedMultiplicationTrapsOnTheSameInputs() throws {
        let m = MulFixture.sil
        #expect(
            try SILVerifier.proveEquivalent(
                MulFixture.s("checkedAB"), in: m, MulFixture.s("checkedBA"), in: m, refining: true) == .proved)
        #expect(
            try SILVerifier.proveEquivalent(
                MulFixture.s("ucheckedAB"), in: m, MulFixture.s("ucheckedBA"), in: m, refining: true) == .proved)
    }

    @Test func aFalseClaimStillGetsAReplayableCounterexample() throws {
        let m = MulFixture.sil
        let v = try SILVerifier.proveEquivalent(
            MulFixture.s("mulAB"), in: m, MulFixture.s("mulWrong"), in: m, refining: true
        )
        guard case .counterexample(let inputs) = v else { Issue.record("expected a counterexample, got \(v)"); return }
        let a = Int32(truncatingIfNeeded: inputs[0]), b = Int32(truncatingIfNeeded: inputs[1])
        #expect(a &* b != (b &* a) &+ 1)
    }

    @Test func refiningAgreesWithPlainProveOnSmallWidths() throws {
        let m = MulFixture.sil
        let pairs = [("smallAB", "smallBA"), ("smallAB", "smallWrong")]
        for (x, y) in pairs {
            let plain = try SILVerifier.proveEquivalent(MulFixture.s(x), in: m, MulFixture.s(y), in: m)
            let refined = try SILVerifier.proveEquivalent(MulFixture.s(x), in: m, MulFixture.s(y), in: m, refining: true)
            switch (plain, refined) {
            case (.proved, .proved), (.counterexample, .counterexample): break
            default: Issue.record("\(x) vs \(y): plain \(plain), refining \(refined)")
            }
        }
    }

    @Test func postconditionOnASilProductIsProvedWithRefining() throws {
        let m = MulFixture.sil
        let v = try SILVerifier.prove(
            MulFixture.s("mulAB"), in: m, refining: true,
            ensures: { c, x, r in c.eq(r, c.mul(x[1], x[0])) }
        )
        #expect(v == .proved)
    }

    @Test func llvmProductsAreProvedWithRefining() throws {
        let symbol = try MulFixture.s("mulAB", MulFixture.silSpeed)
        let v = try LLVMVerifier.prove(
            symbol, in: MulFixture.ir, refining: true,
            ensures: { c, x, r in c.eq(r, c.mul(x[1], x[0])) }
        )
        #expect(v == .proved)
    }
}
