import SwiftFormal
import Testing

// Stands in for an enum from a binary framework: `CaseIterable` (compiler-synthesized), never `Finite`, and not
// ours to extend in a test target without boilerplate.
private enum Firmness: CaseIterable { case soft, medium, firm }

// A hand-written `allCases` that forgets the last hour: only `Finite` may claim a list is complete.
private struct Hour: CaseIterable, Equatable {
    let h: Int
    static var allCases: [Hour] { (0..<23).map(Hour.init) }
}

// A type that is both: its own `Finite` domain must win over `allCases`.
private enum Tier: CaseIterable, Finite {
    case low, high
    static var domain: Domain<Tier> { .just(.high) }
}

@Finite private struct Turf {
    var firmness: Firmness
    var previous: Firmness?
    var wet: Bool
}

@Suite struct CaseIterableDomainTests {
    @Test func caseIterableTypeHasASampledDomainWithoutFinite() {
        #expect(Firmness.domain.count == 3)
        #expect(!Firmness.domain.complete)
        #expect(Firmness?.domain.count == 4)
        #expect(Firmness?.domain.complete == false)
    }

    @Test func aHandWrittenAllCasesThatLeavesAValueOutIsNeverProved() {
        let report = runWalk("hour", { (hour: Hour) in hour.h }, over: Hour.domain) { Satisfies("below 24") { $1 < 24 } }
        #expect(Hour.domain.count == 23)
        #expect(!report.isProved)
        #expect(report.hasNoCounterexample)
    }

    @Test func finiteDomainWinsOverAllCases() {
        #expect(Tier.domain.count == 1)
        #expect(Tier.domain.complete)
        #expect(Tier?.domain.count == 2)
    }

    @Test func finiteStructTakesCaseIterableFieldsAsSamples() {
        #expect(Turf.domain.count == 3 * 4 * 2)
        #expect(!Turf.domain.complete)
    }
}
