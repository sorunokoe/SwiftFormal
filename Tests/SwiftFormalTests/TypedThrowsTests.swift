import SwiftFormal
import Testing

enum ReadingFailure: Error, Equatable { case negative }

// `@Verify` with `#ensures` on a typed-throws function did not compile: the body macro wrapped the body in a closure
// marked plain `throws`, whose `any Error` cannot be converted to `ReadingFailure`.
@Verify(over: .int(-3...3))
func reading(_ raw: Int) throws(ReadingFailure) -> Int {
    #ensures { $0 >= 0 }
    if raw < 0 { throw .negative }
    return raw * 2
}

// Only `limit` is read by the condition; `value` must not be bound (an unused binding is a warning in user code).
@Verify(over: .product(.int(0...5), .int(-1...5)))
func clamped(_ value: Int, to limit: Int) -> Int {
    #requires(limit >= 0)
    #ensures { $0 <= limit }
    return min(value, limit)
}

@Suite struct TypedThrowsTests {
    @Test func typedThrowsKeepsItsErrorType() {
        #expect(throws: ReadingFailure.negative) { try reading(-1) }
        #expect((try? reading(2)) == 4)
    }

    @Test func aThrowIsACounterexampleOfTotalAndEnsuresStillHolds() throws {
        let report = verify_reading()
        let failure = try #require(report.counterexamples.first)
        #expect(failure.property == "total")
        #expect(report.counterexamples.count == 1, "\(report)")
    }

    @Test func requiresWithAnUnusedParameterStillNarrowsTheDomain() {
        let report = verify_clamped()
        #expect(report.isProved, "\(report)")
        #expect(report.excluded == 6)
    }
}
