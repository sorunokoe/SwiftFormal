import SwiftFormal
import SwiftFormalTesting
import Testing

/// Walk (Tier 1) applied to Walk's own domains. Each oracle is plain Swift (`Array`, `Set`, `ClosedRange`), so a
/// `proved` here compares `Domain` with the language, not with itself.
@Suite struct DomainSelfTests {
    private static let smallBounds = Domain<(Int, Int)>
        .product(.int(-4...4), .int(-4...4))
        .filter { $0.0 <= $0.1 }

    /// Domain.int(lo...hi) lists exactly the integers of the range, in order, for every small range.
    @Test func intRangeIsExactlyTheRange() {
        Prove(
            "Domain.int(lo...hi)",
            it: { (bounds: (Int, Int)) -> [Int] in
                let domain = Domain.int(bounds.0...bounds.1)
                return (0..<domain.count).map { domain[$0] }
            },
            over: Self.smallBounds
        ) {
            Property.matches("same elements as the range") { Array($0.0...$0.1) }
        }
    }

    /// The count, and completeness, of a range whose size does not fit in `Int`.
    @Test func hugeRangesSaturateAndStayComplete() {
        let nearTop = Domain.int((Int.max - 2)...Int.max)
        #expect(nearTop.count == 3)
        #expect((0..<3).map { nearTop[$0] } == [Int.max - 2, Int.max - 1, Int.max])
        let nearBottom = Domain.int(Int.min...(Int.min + 2))
        #expect((0..<3).map { nearBottom[$0] } == [Int.min, Int.min + 1, Int.min + 2])
        let everything = Domain.int(Int.min...Int.max)
        #expect(everything.count == Int.max)
        #expect(everything.complete)
    }

    /// `product` visits every pair exactly once, in row-major order.
    @Test func productVisitsEveryPairOnceInOrder() {
        let width = 5, height = 7
        let pairs = Domain<(Int, Int)>.product(.int(0...width - 1), .int(0...height - 1))
        let walked = (0..<pairs.count).map { pairs[$0] }
        let expected = (0..<width).flatMap { a in (0..<height).map { b in (a, b) } }
        #expect(pairs.count == width * height)
        #expect(walked.elementsEqual(expected) { $0 == $1 })
    }

    @Test func tripleProductIsInjectiveAndHasTheProductSize() {
        let triples = Domain<(Int, Int, Int)>.product(.int(0...2), .int(0...3), .int(0...4))
        let walked = (0..<triples.count).map { triples[$0] }
        #expect(triples.count == 60)
        #expect(Set(walked.map { "\($0.0),\($0.1),\($0.2)" }).count == 60)
    }

    /// The number of arrays of length at most `n` over `k` values is 1 + k + k^2 + ... + k^n; each appears once.
    @Test(arguments: [(0, 3), (1, 3), (2, 3), (3, 2), (2, 4)])
    func arraysCoverEveryLengthExactlyOnce(elementCount: Int, maxLength: Int) {
        let domain = Domain<[Int]>.arrays(of: elementCount == 0 ? .of([]) : .int(0...elementCount - 1), maxLength: maxLength)
        var expectedCount = 0
        var power = 1
        for length in 0...maxLength {
            if length > 0 { power *= elementCount }
            expectedCount += power
        }
        let walked = (0..<domain.count).map { domain[$0] }
        #expect(domain.count == expectedCount)
        #expect(Set(walked).count == expectedCount)
        #expect(walked.allSatisfy { $0.count <= maxLength && $0.allSatisfy { (0..<elementCount).contains($0) } })
    }

    @Test func optionalAddsExactlyNil() {
        let wrapped = Domain.int(3...9)
        let domain = Domain<Int?>.optional(wrapped)
        let walked = (0..<domain.count).map { domain[$0] }
        #expect(domain.count == wrapped.count + 1)
        #expect(walked.filter { $0 == nil }.count == 1)
        #expect(walked.compactMap { $0 } == Array(3...9))
    }

    @Test func unionHasTheSumOfTheSizesAndKeepsOrder() {
        let union = Domain<Int>.union([.int(0...2), .of([]), .int(10...11)])
        #expect(union.count == 5)
        #expect((0..<union.count).map { union[$0] } == [0, 1, 2, 10, 11])
    }

    /// A filter keeps exactly the values `Array.filter` keeps, and keeps completeness.
    @Test func filterAgreesWithArrayFilter() {
        let evens = Domain.int(-9...9).filter { $0 % 2 == 0 }
        #expect((0..<evens.count).map { evens[$0] } == (-9...9).filter { $0 % 2 == 0 })
        #expect(evens.complete)
    }

    /// `evenlySpaced` never exceeds its limit, keeps the first and last value, and says it is a sample when it dropped values.
    @Test(arguments: [1, 2, 3, 7, 50, 99, 100, 101])
    func evenlySpacedKeepsTheEndsAndNeverClaimsCompleteness(limit: Int) {
        let source = Domain.int(0...99)
        let spaced = source.evenlySpaced(limit)
        let walked = (0..<spaced.count).map { spaced[$0] }
        #expect(spaced.count <= limit)
        #expect(walked.first == 0)
        if limit >= 2 { #expect(walked.last == 99) }
        #expect(walked == walked.sorted())
        #expect(Set(walked).count == walked.count)
        #expect(spaced.complete == (limit >= 100))
    }

    /// The verdict side: a sample can never be `proved`, a complete domain with a wrong property is a counterexample.
    @Test func verifyNeverCallsASampleProvedAndFindsTheOneBadInput() {
        let function: (Int) -> Int = { $0 == 77 ? -1 : $0 }
        let complete = runWalk("one bad input", function, over: .int(0...99)) {
            Property.satisfies("non-negative") { _, output in output >= 0 }
        }
        #expect(complete.counterexamples.first?.counterexample.input == "77")
        let sampled = runWalk("sample", { $0 }, over: Domain.int(0...99).evenlySpaced(10)) {
            Property.satisfies("non-negative") { _, output in output >= 0 }
        }
        #expect(!sampled.isProved)
        #expect(sampled.hasNoCounterexample)
    }

    /// Sampling above the budget is reproducible: the same seed gives the same report text.
    @Test func sampledRunsReproduceFromTheirSeed() {
        let budget = Budget(maxEvaluations: 50, seed: 12345)
        let run = { runWalk("sampled", { (x: Int) in x &* 3 }, over: .int(0...10_000), budget: budget) { Property.deterministic() } }
        #expect(run().description == run().description)
        #expect(!run().isProved)
    }
}
