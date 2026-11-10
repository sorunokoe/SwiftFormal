import SwiftFormal
import Testing

// `@Finite` builds a struct of two to four fields with one flat `product`; it used to nest pairs. Users' walks and
// seeded samples must not change, so both shapes are compared value by value here.

@Finite struct Shot: Equatable {
    @Values(.int(0...4)) var club: Int
    var windy: Bool
    var plan: Plan?
}

@Finite struct WideShot: Equatable {
    @Values(.int(0...2)) var a: Int
    var b: Bool
    var c: Plan
    @Values(.int(-1...1)) var d: Int
}

@Finite struct FiveFields: Equatable {
    var a: Bool
    var b: Plan
    var c: Bool
    var d: Plan?
    @Values(.int(0...1)) var e: Int
}

/// The inputs a seeded, sampled walk visits: a budget one below the domain size makes `verify` sample.
private func draws<Value>(_ domain: Domain<Value>) -> [Value] {
    var visited: [Value] = []
    _ = runWalk("draws", { (value: Value) in visited.append(value) }, over: domain, budget: Budget(maxEvaluations: domain.count - 1))
    return visited
}

@Suite struct FiniteProductOrderTests {
    @Test func threeFieldsMatchTheNestedPairs() {
        let nested = Domain.product(Domain.int(0...4), Domain.product(Bool.domain, Plan?.domain)).map {
            Shot(club: $0.0, windy: $0.1.0, plan: $0.1.1)
        }
        #expect(Shot.domain.count == nested.count)
        #expect((0..<nested.count).map { Shot.domain[$0] } == (0..<nested.count).map { nested[$0] })
        #expect(draws(Shot.domain) == draws(nested))
    }

    @Test func fourFieldsMatchTheNestedPairs() {
        let nested = Domain.product(
            Domain.int(0...2), Domain.product(Bool.domain, Domain.product(Plan.domain, Domain.int(-1...1)))
        ).map { WideShot(a: $0.0, b: $0.1.0, c: $0.1.1.0, d: $0.1.1.1) }
        #expect((0..<nested.count).map { WideShot.domain[$0] } == (0..<nested.count).map { nested[$0] })
        #expect(draws(WideShot.domain) == draws(nested))
    }

    @Test func fiveFieldsStillNest() {
        #expect(FiveFields.domain.count == 2 * 2 * 2 * 3 * 2)
        #expect(Set((0..<FiveFields.domain.count).map { "\(FiveFields.domain[$0])" }).count == FiveFields.domain.count)
    }
}
