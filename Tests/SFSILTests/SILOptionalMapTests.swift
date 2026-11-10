import Foundation
import Testing
import SFProve
import SFSIL

/// `Optional.map` and `flatMap` with a closure literal (`SILOptionalMap.swift`), in real `swiftc` output: the closure's
/// body runs, with its traps, exactly when the optional holds a value.
enum OptionalMapFixture {
    static let source = """
        public struct Section { public var first: Int8; public var count: Int }
        public enum Bad: Error { case negative }
        public func check(_ x: Int8) throws -> Int8 { if x < 0 { throw Bad.negative }; return x }

        public func bump(_ x: Int8?) -> Int8? { x.map { $0 + 1 } }
        public func guarded(_ x: Int8?) -> Int8? { x.map { $0 > 100 ? 0 : $0 + 1 } }
        public func neverRuns(_ x: Int8) -> Int8? { let o: Int8? = nil; return o.map { $0 + x } }
        public func captured(_ x: Int8?, _ k: Int8) -> Int8? { k > 10 || k < -10 ? nil : x.map { ($0 > 100 || $0 < -100 ? 0 : $0) + k } }
        public func capturedOver(_ x: Int8?, _ k: Int8) -> Int8? { k > 30 || k < -30 ? nil : x.map { ($0 > 100 || $0 < -100 ? 0 : $0) + k } }
        public func resultUsed(_ x: Int8?) -> Int8 { (x.map { $0 / 2 } ?? 0) + 63 }
        public func resultUsedOver(_ x: Int8?) -> Int8 { (x.map { $0 / 2 } ?? 0) + 65 }
        public func flat(_ x: Int8?) -> Int8 { (x.flatMap { $0 > 0 ? $0 : nil } ?? 0) - 1 }
        public func flatOver(_ x: Int8?) -> Int8 { (x.flatMap { $0 > 0 ? $0 : nil } ?? -128) - 1 }
        public func section(_ input: [Int8]) -> Section? { input.first.map { Section(first: $0, count: input.count) } }
        public func passed(_ x: Int8?, _ f: (Int8) -> Int8) -> Int8? { x.map(f) }
        public func throwing(_ x: Int8?) throws -> Int8? { try x.map { try check($0) } }
        """
    static let module = try! SILCompiler.module(source: source, name: "Om", optimization: .none)
    /// The same code beside a deinit that can trap: a non-escaping closure is never destroyed, an escaping one may be.
    static let noisy = try! SILCompiler.module(
        source: source + """

            public final class Noisy { public var n = 0; deinit { precondition(n >= 0) } }
            public func escaping(_ x: Int8) -> () -> Int8 { { x } }
            """, name: "Om", optimization: .none)

    static func verdict(_ name: String, in module: SILModule = module) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try module.symbol(module: "Om", name: name), in: module)
    }
}

@Suite(.tags(.slow)) struct SILOptionalMapTests {
    @Test func theClosureRunsExactlyWhenTheOptionalHoldsAValue() throws {
        for name in ["guarded", "neverRuns", "captured", "resultUsed", "flat", "section"] {
            #expect(try OptionalMapFixture.verdict(name) == .proved, "\(name)")
        }
        for name in ["bump", "capturedOver", "resultUsedOver", "flatOver"] {
            guard case .counterexample = try OptionalMapFixture.verdict(name) else {
                Issue.record("\(name) traps")
                continue
            }
        }
    }

    @Test func aNonEscapingClosureIsReadBesideADeinitThatRunsCode() throws {
        #expect(try OptionalMapFixture.verdict("guarded", in: OptionalMapFixture.noisy) == .proved)
        #expect(throws: SILError.self) { try OptionalMapFixture.verdict("escaping", in: OptionalMapFixture.noisy) }
    }

    @Test func aClosureThatIsNotALiteralOrCanThrowIsNotRead() throws {
        for name in ["passed", "throwing"] {
            #expect(throws: SILError.self, "\(name)") { try OptionalMapFixture.verdict(name) }
        }
    }
}
