import Foundation
import Testing
import SFProve
import SFSIL

/// Calling a closure literal (`SILClosureCalls.swift`), in real `swiftc -Onone` output: a helper that takes a closure
/// runs the literal it is given, with its captured values and its traps.
enum ClosureCallFixture {
    static let source = """
        public func apply(_ x: Int8, _ f: (Int8) -> Int8) -> Int8 { f(x) }
        public func twice(_ x: Int8, _ f: (Int8) -> Int8) -> Int8 { f(f(x)) }
        public struct Rule {
            public var limit: Int8
            func check(_ x: Int8, _ test: (Int8) -> Bool) -> Bool { x < limit && test(x) }
            public func body(_ x: Int8) -> Bool { check(x) { $0 > 0 && $0 + 1 > 1 } }
            public func bodyOver(_ x: Int8) -> Bool { check(x) { $0 - 1 < 1 } }
        }
        public func ruled(_ r: Rule, _ x: Int8) -> Bool { r.body(x) }
        public func ruledOver(_ r: Rule, _ x: Int8) -> Bool { r.bodyOver(x) }

        public func helped(_ x: Int8) -> Int8 { x > 100 ? 0 : apply(x) { $0 + 1 } }
        public func helpedOver(_ x: Int8) -> Int8 { apply(x) { $0 + 1 } }
        public func trailing(_ x: Int8) -> Int8 {
            apply(x) { v in
                if v > 50 || v < -50 { return 0 }
                return v * 2
            }
        }
        public func captured(_ x: Int8, _ k: Int8) -> Int8 {
            k > 10 || k < -10 || x > 100 || x < -100 ? 0 : apply(x) { $0 + k }
        }
        public func capturedOver(_ x: Int8, _ k: Int8) -> Int8 { x > 100 || x < -100 ? 0 : apply(x) { $0 + k } }
        public func nested(_ x: Int8) -> Int8 { x > 60 || x < -60 ? 0 : twice(x) { $0 / 2 + 1 } }
        public func nestedOver(_ x: Int8) -> Int8 { x > 60 || x < -60 ? 0 : twice(x) { $0 * 2 } }
        public func local(_ x: Int8) -> Int8 { let f: (Int8) -> Int8 = { $0 / 2 }; return f(x) + 63 }
        public func localOver(_ x: Int8) -> Int8 { let f: (Int8) -> Int8 = { $0 / 2 }; return f(x) + 65 }
        public func result(_ x: Int8) -> Int8 { apply(x) { _ in 3 } + 124 }
        public func resultOver(_ x: Int8) -> Int8 { apply(x) { _ in 3 } + 125 }

        public func passed(_ x: Int8, _ f: (Int8) -> Int8) -> Int8 { f(x) }
        public func variable(_ x: Int8) -> Int8 { var k: Int8 = 0; k = x > 0 ? 1 : 0; return apply(x) { $0 / 2 + k } }
        public func chosen(_ x: Int8, _ b: Bool) -> Int8 {
            let f: (Int8) -> Int8 = b ? { $0 / 2 } : { $0 / 4 }
            return f(x)
        }
        """
    static let module = try! SILCompiler.module(source: source, name: "Cc", optimization: .none)

    static func verdict(_ name: String) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try module.symbol(module: "Cc", name: name), in: module)
    }
    static func rejection(_ name: String) -> String? {
        do {
            _ = try verdict(name)
            return nil
        } catch {
            return "\(error)"
        }
    }
}

@Suite(.tags(.slow)) struct SILClosureCallTests {
    @Test func aLiteralPassedToAHelperRunsWithItsCapturesAndTraps() throws {
        for name in ["helped", "trailing", "captured", "nested", "local", "result", "ruled"] {
            #expect(try ClosureCallFixture.verdict(name) == .proved, "\(name)")
        }
        for name in ["helpedOver", "capturedOver", "nestedOver", "localOver", "resultOver", "ruledOver"] {
            guard case .counterexample = try ClosureCallFixture.verdict(name) else {
                Issue.record("\(name) traps")
                continue
            }
        }
    }

    @Test func aClosureThatIsNotALiteralOrCapturesAVariableIsNotRun() throws {
        for name in ["passed", "variable", "chosen"] {
            let reason = try #require(ClosureCallFixture.rejection(name), "\(name)")
            #expect(reason.contains("closure"), "\(name): \(reason)")
        }
    }
}
