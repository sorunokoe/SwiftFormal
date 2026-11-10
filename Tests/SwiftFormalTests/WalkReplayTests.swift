import Testing
@testable import SwiftFormal

// U4: a trap reports the walk's step, and the parent process rebuilds the input from it. These tests pin that the
// replay names exactly the input the walk took at that step, for an enumerated and for a sampled walk.

/// The inputs `verify` takes, in order: `assuming` sees every step, also the steps it excludes.
private func walkOrder<Input>(_ domain: Domain<Input>, budget: Budget) -> [Input] {
    var inputs: [Input] = []
    _ = runWalk(
        "order", { (_: Input) in 0 }, over: domain, budget: budget,
        assuming: { input in
            inputs.append(input)
            return inputs.count % 3 != 0
        })
    return inputs
}

@Suite struct WalkReplayTests {
    @Test func anEnumeratedStepIsTheDomainElement() {
        let domain = Domain.product(UInt8.domain, UInt8.domain)
        let budget = Budget.default
        let order = walkOrder(domain, budget: budget)
        #expect(order.count == 65_536)
        for step in [0, 1, 511, 65_535] {
            let input = domain.walkInput(atStep: step, maxEvaluations: budget.maxEvaluations, seed: budget.seed)
            #expect(input == order[step])
        }
    }

    @Test func aSampledStepReplaysTheSeededDraws() {
        let domain = Domain<Int>.int(0...1_000_000)
        let budget = Budget(maxEvaluations: 1_000, seed: 42)
        let order = walkOrder(domain, budget: budget)
        #expect(order.count == 1_000)
        for step in [0, 1, 2, 3, 500, 999] {
            #expect(domain.walkInput(atStep: step, maxEvaluations: budget.maxEvaluations, seed: budget.seed) == order[step])
        }
    }

    @Test func theProbeIsOffUnlessATrapWalkTurnsItOn() {
        #expect(!WalkProbe.isPublishing)
        _ = runWalk("identity", { (value: Bool) in value }, over: .bool)
        #expect(WalkProbe.step == -1)
    }
}
