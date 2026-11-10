import Foundation
import SFBV
import SFCNF
import SFProve
import SFSIL
import SFTestSupport
import Testing

/// Plan item L4: `for-in` at `-Onone`, through exact summaries of the standard library's iterators.
enum IteratorFixture {
    static let source = """
        public func rangeSum(_ n: UInt8) -> UInt8 { var s: UInt8 = 0; for i in 0..<n { s &+= i }; return s }
        public func rangeOverflow(_ n: UInt8) -> UInt8 { var s: UInt8 = 0; for i in 0..<n { s += i }; return s }
        public func closedTop(_ n: Int8) -> Int8 { var last: Int8 = 0; for i in n...Int8.max { last = i }; return last }
        public func closedCount(_ n: Int8) -> Int8 { var c: Int8 = 0; for _ in 0...n { c &+= 1 }; return c }
        public func strideSum(_ n: Int) -> Int { var s = 0; for i in stride(from: 0, to: n, by: 3) { s &+= i }; return s }
        public func strideNearMax(_ k: UInt8) -> Int {
            var c = 0
            for _ in stride(from: Int.max - 300, through: Int.max, by: Int(k) + 1) { c &+= 1 }
            return c
        }
        public func strideZero(_ k: Int) -> Int { var s = 0; for i in stride(from: 0, through: 10, by: k) { s &+= i }; return s }
        public func arrayCount(_ a: [Int8]) -> Int { var c = 0; for _ in a { c &+= 1 }; return c }
        public func offsets(_ a: [Int8]) -> Int { var s = 0; for (i, _) in a.enumerated() { s &+= i }; return s }
        public func indexSum(_ a: [Int8]) -> Int { var s = 0; for i in a.indices { s &+= i }; return s }
        public func elementSum(_ a: [Int8]) -> Int8 { var s: Int8 = 0; for x in a { s &+= x }; return s }
        public func nestedRanges(_ n: UInt8, _ m: UInt8) -> UInt8 {
            var t: UInt8 = 0
            for _ in 0..<n { for j in 0..<m { t &+= j } }
            return t
        }

        // Straight-line uses of the same iterators, compared with hand-written equivalents on every input.
        public func rangeTwo(_ a: Int8, _ b: Int8) -> Int8 {
            var it = (a..<b).makeIterator()
            var s: Int8 = 0
            if let x = it.next() { s &+= x }
            if let y = it.next() { s &+= y &* 2 }
            return s
        }
        public func rangeTwoHand(_ a: Int8, _ b: Int8) -> Int8 {
            precondition(a <= b)
            var s: Int8 = 0
            if a != b { s &+= a; if a + 1 != b { s &+= (a + 1) &* 2 } }
            return s
        }
        public func closedThree(_ a: Int8, _ b: Int8) -> Int8 {
            var it = (a...b).makeIterator()
            var s: Int8 = 0
            if let x = it.next() { s &+= x }
            if let y = it.next() { s &+= y &* 2 }
            if let z = it.next() { s &+= z &* 3 }
            return s
        }
        public func closedThreeHand(_ a: Int8, _ b: Int8) -> Int8 {
            precondition(a <= b)
            var s: Int8 = a
            if a != b { s &+= (a + 1) &* 2; if a + 1 != b { s &+= (a + 2) &* 3 } }
            return s
        }
        public func strideThree(_ a: Int8, _ b: Int8, _ k: Int8) -> Int {
            var it = stride(from: Int(a), to: Int(b), by: Int(k)).makeIterator()
            var s = 0
            if let x = it.next() { s &+= x }
            if let y = it.next() { s &+= y &* 2 }
            if let z = it.next() { s &+= z &* 3 }
            return s
        }
        public func strideThreeHand(_ a: Int8, _ b: Int8, _ k: Int8) -> Int {
            precondition(k != 0)
            var (v, s, w) = (Int(a), 0, 1)
            for _ in 0..<3 where k > 0 ? v < Int(b) : v > Int(b) { s &+= v &* w; v += Int(k); w += 1 }
            return s
        }
        public func throughThree(_ a: Int8, _ b: Int8, _ k: Int8) -> Int {
            var it = stride(from: Int(a), through: Int(b), by: Int(k)).makeIterator()
            var s = 0
            if let x = it.next() { s &+= x }
            if let y = it.next() { s &+= y &* 2 }
            if let z = it.next() { s &+= z &* 3 }
            return s
        }
        public func enumeratedTwo(_ a: [Int8]) -> Int {
            var it = a.enumerated().makeIterator()
            var s = 0
            if let p = it.next() { s &+= p.offset &+ 1 }
            if let q = it.next() { s &+= q.offset &* 10 }
            return s
        }
        """
    static let onone = try! SILCompiler.module(source: source, name: "It", optimization: .none)
    static func symbol(_ name: String) throws -> String { try onone.symbol(module: "It", name: name) }

    static func loopProof(_ name: String) throws -> LoopProofResult {
        let symbol = try symbol(name)
        return try SILVerifier.proveLoopFunction(
            symbol, in: onone, loopInvariants: try SILVerifier.iteratorInvariants(of: symbol, in: onone))
    }
}

@Suite struct SILIteratorTests {
    @Test func forInLoopsWithoutATrapAreProvedWithTheIteratorInvariants() throws {
        for name in [
            "rangeSum", "closedTop", "strideSum", "strideNearMax", "arrayCount", "offsets", "indexSum", "elementSum", "nestedRanges",
        ] {
            let result = try IteratorFixture.loopProof(name)
            #expect(result.partialCorrectnessProved, "\(name): \(result.summary)")
        }
    }

    @Test func forInLoopsThatCanTrapAreNeverProved() throws {
        // `s += i` overflows for n >= 24; `0...n` traps for n < 0; `stride(by: 0)` traps.
        for name in ["rangeOverflow", "closedCount", "strideZero"] {
            let result = try IteratorFixture.loopProof(name)
            #expect(!result.partialCorrectnessProved, "\(name): \(result.summary)")
        }
    }

    /// The summaries are exact: two or three `next()` calls equal the hand-written loop on every input, traps included.
    @Test func iteratorSummariesEqualTheHandWrittenSemantics() throws {
        let m = IteratorFixture.onone
        for (summarized, hand) in [("rangeTwo", "rangeTwoHand"), ("closedThree", "closedThreeHand")] {
            let verdict = try SILVerifier.proveEquivalent(
                try IteratorFixture.symbol(summarized), in: m, try IteratorFixture.symbol(hand), in: m)
            #expect(verdict == .proved, "\(summarized): \(verdict)")
        }
    }

    /// `stride` checks its step, and its overflow-safe `_step` stops at the end of `Int` instead of trapping.
    @Test func strideTrapsOnlyOnAZeroStep() throws {
        let m = IteratorFixture.onone
        guard case .counterexample(let v) = try SILVerifier.prove(try IteratorFixture.symbol("strideThree"), in: m) else {
            Issue.record("strideThree should trap at k = 0")
            return
        }
        #expect(v[2] == 0)
        let zeroStep: (CNFBuilder, [BV]) -> Int32 = { c, a in -c.eq(a[2], c.constant(0, width: 8)) }
        #expect(try SILVerifier.prove(try IteratorFixture.symbol("strideThree"), in: m, requires: zeroStep) == .proved)
        #expect(try SILVerifier.prove(try IteratorFixture.symbol("throughThree"), in: m, requires: zeroStep) == .proved)
        // The first three offsets of an enumerated array: 0, 1 (only when there are elements).
        let verdict = try SILVerifier.prove(
            try IteratorFixture.symbol("enumeratedTwo"), in: m,
            ensures: { c, a, r in
                let n = a[0]
                let one = c.constant(1, width: 64), two = c.constant(2, width: 64)
                return c.eq(r, c.select(c.ult(n, one), c.constant(0, width: 64), c.select(c.ult(n, two), one, c.constant(11, width: 64))))
            })
        #expect(verdict == .proved)
    }

    @Test func iteratorsOverOtherTypesAreRefused() throws {
        let source = """
            public struct Bag: Sequence, IteratorProtocol { var n: Int8; public mutating func next() -> Int8? { n > 0 ? n : nil } }
            public func bagSum(_ b: Bag) -> Int8 { var s: Int8 = 0; for x in b { s &+= x }; return s }
            public func stringCount(_ s: String) -> Int { var c = 0; for _ in s { c &+= 1 }; return c }
            public func strideUInt8(_ n: UInt8) -> UInt8 { var c: UInt8 = 0; for _ in stride(from: 0, to: n, by: 2) { c &+= 1 }; return c }
            """
        let module = try SILCompiler.module(source: source, name: "Rf", optimization: .none)
        for name in ["stringCount", "strideUInt8"] {
            let symbol = try module.symbol(module: "Rf", name: name)
            #expect(throws: SILError.self) { try SILVerifier.loops(of: symbol, in: module) }
        }
    }
}
