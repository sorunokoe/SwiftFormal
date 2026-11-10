import Testing
@testable import SwiftFormal

private enum Mode: CaseIterable, Finite { case off, low, high }

private func discounted(_ price: Int, _ percent: Int, brokenAt broken: Int? = nil) -> Int {
    Contract.requires(percent >= 0 && percent <= 100, "percent in 0...100")
    var result = price - price * percent / 100
    if percent == broken { result = -1 }
    return Contract.ensures(result, "0 <= result <= price") { $0 >= 0 && $0 <= price }
}

@Suite struct ContractTests {
    @Test func provesEnsuresOverTheWholeDomain() {
        let report = _verifyContracts(
            "discounted",
            { (args: (Int, Int)) in discounted(args.0, args.1) },
            over: .product(.int(0...50), .int(0...100))
        )
        #expect(report.isProved)
        #expect(report.excluded == 0)
    }

    @Test func requiresNarrowsTheDomainAndIsReported() {
        let report = _verifyContracts(
            "discounted",
            { (args: (Int, Int)) in discounted(args.0, args.1) },
            over: .product(.int(0...10), .int(-5...105)),
            requires: { 0...100 ~= $0.1 }
        )
        #expect(report.isProved)
        #expect(report.excluded == 11 * 10)
        #expect(report.evaluated == 11 * 101)
    }

    @Test func ensuresViolationIsACounterexampleNotATrap() throws {
        let report = _verifyContracts(
            "discounted",
            { (args: (Int, Int)) in discounted(args.0, args.1, brokenAt: 40) },
            over: .product(.int(0...10), .int(0...100))
        )
        #expect(!report.hasNoCounterexample)
        let failure = try #require(report.counterexamples.first)
        #expect(failure.property == "ensures")
        #expect(failure.counterexample.detail.contains("0 <= result <= price"))
        #expect(failure.counterexample.input?.hasSuffix(", 40)") == true)
    }

    // A failed `ensures` named the predicate but not the value that broke it (U13).
    @Test func ensuresViolationShowsTheReturnedValue() throws {
        let report = _verifyContracts(
            "discounted",
            { (args: (Int, Int)) in discounted(args.0, args.1, brokenAt: 40) },
            over: .product(.int(0...10), .int(0...100))
        )
        let failure = try #require(report.counterexamples.first)
        #expect(failure.counterexample.detail == "violated: 0 <= result <= price (result: -1)")
    }

    @Test func aLongReturnedValueIsShortenedInTheMessage() throws {
        func long(_ flag: Bool) -> String {
            Contract.ensures(String(repeating: "x", count: 1_000), "short") { $0.count < 10 }
        }
        let report = _verifyContracts("long", long, over: .bool)
        let detail = try #require(report.counterexamples.first?.counterexample.detail)
        #expect(detail.hasPrefix("violated: short (result: xxx"))
        #expect(detail.hasSuffix("...)"))
        #expect(detail.count < 400)
    }

    // `.deterministic()` calls the function a second time. That call used to run outside the recorder, so a failing
    // `ensures` reached `assertionFailure` and stopped a debug build instead of becoming a counterexample.
    @Test func aPropertyThatCallsTheFunctionAgainStillRecordsEnsures() throws {
        let report = _verifyContracts(
            "discounted",
            { (args: (Int, Int)) in discounted(args.0, args.1, brokenAt: 40) },
            over: .product(.int(0...10), .int(0...100)),
            properties: { Property.deterministic() }
        )
        let failure = try #require(report.counterexamples.first)
        #expect(failure.property == "ensures")
        #expect(report.counterexamples.allSatisfy { $0.property == "ensures" })
    }

    @Test func requiresOutsideAWalkStillChecksItsCondition() {
        // In a walk the recorder is bound and a false condition is ignored; outside one it would assert.
        #expect(discounted(100, 20) == 80)
        Contract.$recorder.withValue(Contract.Recorder()) { _ = discounted(100, 200) }
    }

    @Test func finiteInputIsInferredFromTheSignature() {
        func rank(_ mode: Mode?) -> Int { mode.map { Mode.allCases.firstIndex(of: $0)! } ?? -1 }
        let report = runWalk("rank", rank) {
            Property.satisfies("rank in -1...2") { (_: Mode?, rank: Int) in (-1...2).contains(rank) }
        }
        #expect(report.isProved)
        #expect(report.evaluated == 4)
    }
}
