import Foundation
import SFBV
import SFCNF
import SFProve
import SFSIL
import Testing

/// Plan item L3: bounded unrolling finds real traps in loops, and never one that no run reaches.
@Suite struct SILUnwindTests {
    static let source = """
        public func thirdStep(_ n: Int8) -> Int8 { var x: Int8 = 100; var i: Int8 = 0; while i < n { x += 10; i += 1 }; return x }
        public func wraps(_ n: Int8) -> Int8 { var s: Int8 = 0; var i: Int8 = 0; while i < n { s = s &+ i; i += 1 }; return s }
        // i is 10 after the loop, so 245 + i is 255: safe. With a free state at the header it would overflow.
        public func exitsAtTen(_ n: UInt8) -> UInt8 { var i: UInt8 = 0; while i < 10 { i += 1 }; return i + 245 &+ n }
        public func afterLoop(_ n: UInt8) -> UInt8 { var i: UInt8 = 0; while i < n { i += 1 }; return 200 + i }
        // The exit test after the body: at the header i is anything, but one safe iteration back means i < 100.
        public func countUp(_ n: Int8) -> Int8 { var i: Int8 = 0; repeat { i += 1 } while i < 100 && i < n; return i }
        // Steps by 2: for n = 127, i goes from 126 to 128.
        public func countPast(_ n: Int8) -> Int8 { var i: Int8 = 0; repeat { i += 2 } while i < n; return i }
        // Only the first iteration can trap (n = 127): after it i is 0. The step alone would prove it; the base must not.
        public func firstOnly(_ n: Int8) -> Int8 { var i = n; var k: Int8 = 0; repeat { i += 1; i = 0; k &+= 1 } while k < 3; return i }
        public func nested(_ n: Int8) -> Int8 {
            var x: Int8 = 0
            var i: Int8 = 0
            while i < n { var j: Int8 = 0; while j < 4 { x += 10; j += 1 }; i += 1 }
            return x
        }
        """
    static let module = try! SILCompiler.module(source: source, name: "Unw", optimization: .none)

    static func unwind(_ name: String, _ times: Int) throws -> UnwindResult {
        try SILVerifier.unwind(try module.symbol(module: "Unw", name: name), in: module, times: times)
    }

    @Test func aTrapInTheThirdIterationNeedsThreeUnrollings() throws {
        #expect(try Self.unwind("thirdStep", 2) == .noneWithin)
        guard case .traps(let n) = try Self.unwind("thirdStep", 3) else {
            Issue.record("x + 10 overflows in the third iteration")
            return
        }
        #expect(Int8(truncatingIfNeeded: n[0]) >= 3, "\(n)")
    }

    @Test func noTrapIsInventedBeforeTheLoopIsReached() throws {
        #expect(try Self.unwind("wraps", 8) == .noneWithin)
        #expect(try Self.unwind("exitsAtTen", 3) == .noneWithin)
        #expect(try Self.unwind("exitsAtTen", 12) == .noneWithin)
    }

    @Test func codeAfterTheLoopSeesTheStateTheLoopLeaves() throws {
        #expect(try Self.unwind("afterLoop", 8) == .noneWithin)
        guard case .traps(let n) = try Self.unwind("afterLoop", 60) else {
            Issue.record("200 + i overflows once the loop ran 56 times")
            return
        }
        #expect(n[0] >= 56 && n[0] <= 60, "\(n)")
    }

    /// The bound counts visits to any loop header: the 13th `x += 10` comes after about 17 of them.
    @Test func nestedLoopsUnrollTogether() throws {
        #expect(try Self.unwind("nested", 8) == .noneWithin)
        guard case .traps(let n) = try Self.unwind("nested", 24) else {
            Issue.record("x passes 127 in the fourth outer iteration")
            return
        }
        #expect(Int8(truncatingIfNeeded: n[0]) >= 4, "\(n)")
    }

    static func twoInduction(_ name: String) throws -> Bool {
        try SILVerifier.proveByTwoInduction(try module.symbol(module: "Unw", name: name), in: module)
    }

    @Test func twoInductionProvesALoopWhoseTestComesLast() throws {
        let symbol = try Self.module.symbol(module: "Unw", name: "countUp")
        let invariantTrue = try SILVerifier.proveLoopFunction(
            symbol, in: Self.module,
            loopInvariants: [LoopInvariant(header: try SILVerifier.loops(of: symbol, in: Self.module)[0].header) { c, _ in c.trueLit }])
        #expect(!invariantTrue.partialCorrectnessProved, "the header alone knows nothing about i")
        #expect(try Self.twoInduction("countUp"))
    }

    @Test func twoInductionNeverProvesALoopThatTraps() throws {
        #expect(try !Self.twoInduction("countPast"))
        #expect(try !Self.twoInduction("thirdStep"))
        #expect(try !Self.twoInduction("firstOnly"))
        #expect(try !Self.twoInduction("nested"))  // two loops: not attempted
    }
}
