import Foundation
import Testing
import SFProve
import SFSIL

/// `static let` and global `let` values whose initializer logic reads (`SILGlobals.swift`), in real `swiftc` output:
/// the addressor's `builtin "once"`, then `pointer_to_address` of the global's address.
enum GlobalFixture {
    static let source = """
        public struct Helper { public var a: Int8; public var b: Int8 }
        public struct Empty { public init() {} }
        public enum Limits {
            public static let helper = Helper(a: 100, b: -100)
            public static let empty = Empty()
            public static let doubled = Limits.helper.a / 2 * 2
            public static var counter = Helper(a: 1, b: 2)
            public static let failing = Helper(a: Limits.helper.a + Limits.helper.a, b: 0)
            public static let shared = Config(scale: 3)
        }
        public struct Config { public var scale: Int8; public init(scale: Int8) { self.scale = scale } }
        public let topLevel = Helper(a: 7, b: 8)

        public func plusA(_ x: Int8) -> Int8 { x > 20 ? 0 : x + Limits.helper.a }
        public func plusAOver(_ x: Int8) -> Int8 { x > 30 ? 0 : x + Limits.helper.a }
        public func minusB(_ x: Int8) -> Int8 { x < -20 ? 0 : x + Limits.helper.b }
        public func useEmpty(_ x: Int8) -> Int8 { _ = Limits.empty; return x &+ 1 }
        public func nested(_ x: Int8) -> Int8 { x > 27 ? 0 : x + Limits.doubled }
        public func mutable(_ x: Int8) -> Int8 { x &+ Limits.counter.a }
        public func trapsOnFirstUse(_ x: Int8) -> Int8 { x &+ Limits.failing.b }
        public func scaled(_ x: Int8) -> Int8 { x > 40 || x < -40 ? 0 : x * Limits.shared.scale }
        public func global(_ x: Int8) -> Int8 { x > 120 ? 0 : x + topLevel.a }
        """
    static let module = try! SILCompiler.module(source: source, name: "Gl", optimization: .none)

    static func verdict(_ name: String) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try module.symbol(module: "Gl", name: name), in: module)
    }
}

@Suite(.tags(.slow)) struct SILGlobalTests {
    @Test func aStaticLetOfAStructIsItsInitialValue() throws {
        for name in ["plusA", "minusB", "useEmpty", "nested", "scaled", "global"] {
            #expect(try GlobalFixture.verdict(name) == .proved, "\(name)")
        }
        guard case .counterexample(let inputs) = try GlobalFixture.verdict("plusAOver") else {
            Issue.record("plusAOver overflows for 28...30")
            return
        }
        #expect(inputs.count == 1 && (28...30).contains(Int8(truncatingIfNeeded: inputs[0])), "\(inputs)")
    }

    @Test func anInitializerThatTrapsTrapsOnFirstUse() throws {
        // `helper.a + helper.a` is 200: the first read of `failing` traps, whatever the input.
        guard case .counterexample = try GlobalFixture.verdict("trapsOnFirstUse") else {
            Issue.record("reading Limits.failing traps")
            return
        }
    }

    @Test func aStaticVarIsNotRead() throws {
        #expect(throws: SILError.self) { try GlobalFixture.verdict("mutable") }
    }
}
