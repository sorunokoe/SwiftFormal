import Testing
@_spi(Extending) @testable import SwiftFormal

private enum Terrain: CaseIterable, Equatable { case meadow, field, sand, pondCenter, pondEdge, unknown }
private enum Surface: CaseIterable, Hashable { case grass, beach, water, other }

private func surface(_ terrain: Terrain) -> Surface {
    switch terrain {
    case .meadow, .field: .grass
    case .sand: .beach
    case .pondCenter, .pondEdge: .water
    case .unknown: .other
    }
}

@Suite struct DomainTests {
    @Test func productIndexingVisitsEveryTupleOnce() {
        let pairs = Domain<(Int, Bool)>.product(.int(0...2), .bool)
        let triples = Domain<(Int, Bool, Int)>.product(.int(0...1), .bool, .int(5...7))
        let quads = Domain<(Bool, Bool, Int, Bool)>.product(.bool, .bool, .int(0...2), .bool)
        #expect(Set((0..<pairs.count).map { "\(pairs[$0])" }).count == 6)
        #expect(Set((0..<triples.count).map { "\(triples[$0])" }).count == 12)
        #expect(Set((0..<quads.count).map { "\(quads[$0])" }).count == 24)
    }

    @Test func optionalAddsNilFirst() {
        let domain = Domain<Int?>.optional(.int(1...3))
        #expect(domain.count == 4)
        #expect(domain[0] == nil && domain[3] == 3)
    }

    @Test func arraysCoverEveryLengthExactlyOnce() {
        let domain = Domain<[Bool]>.arrays(of: .bool, maxLength: 3)
        #expect(domain.count == 1 + 2 + 4 + 8)
        #expect(Set((0..<domain.count).map { "\(domain[$0])" }).count == 15)
    }

    @Test func fullIntRangeSaturatesInsteadOfOverflowing() {
        #expect(Domain.int(Int.min...Int.max).count == Int.max)
    }

    @Test func productCountSaturates() {
        let big = Domain<Int>.int(Int.min...Int.max)
        #expect(Domain<(Int, Int)>.product(big, big).count == Int.max)
    }

    @Test func filterKeepsMatchingValuesAndCompleteness() {
        let evens = Domain.int(0...9).filter { $0 % 2 == 0 }
        #expect(evens.count == 5 && evens.complete)
    }

    @Test func unionIndexesEveryPartInOrder() {
        let parts = (0..<300).map { Domain<Int>.int($0 * 1_000...($0 * 1_000 + $0 % 7)) } + [.of([]), .just(-1)]
        let union = Domain.union(parts)
        let expected = parts.flatMap { part in (0..<part.count).map(part.element) }
        #expect(union.count == expected.count)
        #expect((0..<union.count).map(union.element) == expected)
    }

    @Test func samplesAreNeverComplete() {
        #expect(!Domain.samples([1, 2]).complete)
        #expect(!Domain<Int>.boundaries.complete)
    }
}

@Suite struct VerifyTests {
    @Test func enumMapperIsProvedOverAllCases() {
        let report = runWalk("surface", surface, over: .allCases) {
            Property.deterministic()
            Property.matches { terrain in terrain == .sand ? Surface.beach : surface(terrain) }
            Property.image(equals: Set(Surface.allCases))
        }
        #expect(report.isProved, "\(report)")
        #expect(report.evaluated == Terrain.allCases.count)
    }

    @Test func wrongMappingGivesCounterexampleWithRealInput() {
        let mutated: (Terrain) -> Surface = { $0 == .pondEdge ? .other : surface($0) }
        let report = runWalk("mutated", mutated, over: .allCases) {
            Property.matches(surface)
        }
        guard case let .counterexample(example) = report.results[1].verdict else {
            Issue.record("expected a counterexample\n\(report)")
            return
        }
        #expect(example.input == "pondEdge")
    }

    @Test func injectivityNamesTheCollision() {
        let report = runWalk("surface", surface, over: .allCases) { .injective() }
        guard case let .counterexample(example) = report.results[1].verdict else {
            Issue.record("surface is not injective\n\(report)")
            return
        }
        #expect(example.detail.contains("both give"))
    }

    @Test func roundTripProvedForBijectionAndFailsForLossyMap() {
        let fromInt: (Int) -> Terrain = { Terrain.allCases[$0] }
        let toInt: (Terrain) -> Int = { Terrain.allCases.firstIndex(of: $0)! }
        #expect(runWalk("toInt", toInt, over: .allCases) { .roundTrip(through: fromInt) }.isProved)

        let lossy: (Terrain) -> Int = { min(Terrain.allCases.firstIndex(of: $0)!, 2) }
        #expect(runWalk("lossy", lossy, over: .allCases) { .roundTrip(through: fromInt) }.counterexamples.count == 1)
    }

    @Test func missingOutputIsReportedOnlyOverTheWholeDomain() {
        let all = Set(Surface.allCases)
        #expect(runWalk("surface", surface, over: .allCases) { .image(equals: all) }.isProved)

        let noBeach: (Terrain) -> Surface = { $0 == .sand ? .grass : surface($0) }
        let whole = runWalk("noBeach", noBeach, over: .allCases) { .image(equals: all) }
        #expect(whole.results[1].verdict.isCounterexample)

        let partial = runWalk("noBeach", noBeach, over: Domain<Terrain>.samples([.meadow])) { .image(equals: all) }
        #expect(!partial.results[1].verdict.isCounterexample)
    }

    @Test func sampleDomainNeverProves() {
        let report = runWalk("surface", surface, over: Domain.samples([.meadow, .sand])) { .deterministic() }
        guard case let .bounded(checked, _) = report.results[1].verdict else {
            Issue.record("expected bounded\n\(report)")
            return
        }
        #expect(checked == 2)
        #expect(!report.isProved && report.hasNoCounterexample)
    }

    @Test func domainOverBudgetIsSampledAndBounded() {
        let report = runWalk("identity", { (x: Int) in x }, over: .int(0...9_999), budget: Budget(maxEvaluations: 100)) {
            Property.deterministic()
        }
        #expect(report.evaluated == 100)
        #expect(!report.isProved && report.hasNoCounterexample)
    }

    @Test func sampledRunReproducesExactly() {
        func run() -> String {
            runWalk(
                "f", { (x: Int) in x % 7 == 3 && x > 9_000 ? -1 : x }, over: .int(0...9_999),
                budget: Budget(maxEvaluations: 2_000, seed: 42)
            ) {
                Property.satisfies("nonnegative") { _, out in out >= 0 }
            }.description
        }
        #expect(run() == run())
    }

    @Test func fullDomainFindsRareBugThatExamplesMiss() {
        // Passes at 0, 1, 99, 100 (typical example-test inputs) but fails at exactly 37.
        let f: (Int) -> Int = { $0 == 37 ? -1 : $0 }
        let report = runWalk("f", f, over: .int(0...100)) { .satisfies("nonnegative") { _, out in out >= 0 } }
        guard case let .counterexample(example) = report.results[1].verdict else {
            Issue.record("expected counterexample")
            return
        }
        #expect(example.input == "37")
    }

    @Test func implicationOnlyConstrainsMatchingInputs() {
        let f: (Int) -> Int = { $0 < 0 ? 0 : $0 }
        let report = runWalk("clamp", f, over: .int(-5...5)) {
            Property.satisfies("nonnegative input is kept", when: { $0 >= 0 }, then: { $0 >= 0 })
        }
        #expect(report.isProved)
    }

    @Test func throwingInputFailsTotalAndOthersAreNotProved() {
        struct Boom: Error {}
        let f: (Int) throws -> Int = { if $0 == 3 { throw Boom() } else { $0 } }
        let report = runWalk("f", f, over: .int(0...5)) { .deterministic() }
        #expect(report.results[0].verdict.isCounterexample)
        guard case let .bounded(_, reason) = report.results[1].verdict else {
            Issue.record("deterministic must not be proved when an input threw")
            return
        }
        #expect(reason.contains("threw"))
    }

    @Test func productDomainOfRuleLikeInputIsExhaustive() {
        struct Input { let terrain: Terrain; let name: String? }
        let domain = Domain<(Terrain, String?)>.product(.allCases, .optional(.just("x"))).map(Input.init)
        let report = runWalk("describe", { (i: Input) in "\(i.terrain)-\(i.name ?? "none")" }, over: domain) {
            Property.injective()
        }
        #expect(report.isProved, "\(report)")
        #expect(report.evaluated == 12)
    }

    /// Sampling draws with replacement: the same input drawn twice is not a collision.
    @Test func injectiveIgnoresTheSameInputDrawnTwice() {
        struct Point { let x: Int; let y: Int }
        let budget = Budget(maxEvaluations: 20_000)
        let grid = Domain<(Int, Int)>.product(.int(0...150), .int(0...150))
        let reports = [
            runWalk("double", { (x: Int) in x * 2 }, over: .int(0...30_000), budget: budget, properties: { Property.injective() }),
            runWalk("pair", { (p: (Int, Int)) in p.0 * 1_000 + p.1 }, over: grid, budget: budget, properties: { Property.injective() }),
            runWalk(
                "point", { (p: Point) in p.x * 1_000 + p.y }, over: grid.map(Point.init), budget: budget,
                properties: { Property.injective() }),
        ]
        for report in reports {
            #expect(report.hasNoCounterexample, "\(report)")
        }
    }

    /// Two different inputs with the same output still fail, sampled or not, also when only their parts can be compared.
    @Test func injectiveStillReportsRealCollisionsWhileSampling() {
        struct Point { let x: Int; let y: Int }
        let budget = Budget(maxEvaluations: 20_000)
        let grid = Domain<(Int, Int)>.product(.int(0...150), .int(0...150))
        let reports = [
            runWalk("half", { (x: Int) in x / 2 }, over: .int(0...30_000), budget: budget, properties: { Property.injective() }),
            runWalk("sum", { (p: Point) in p.x + p.y }, over: grid.map(Point.init), budget: budget, properties: { Property.injective() }),
        ]
        for report in reports {
            #expect(!report.hasNoCounterexample, "\(report)")
        }
    }

    @Test func propertiesReadAsDotFactories() {
        let report = runWalk("not", { (value: Bool) in !value }, over: .bool) {
            Property.deterministic()
            Property.injective()
            Property.satisfies("flips") { input, output in output == !input }
        }
        #expect(report.isProved, "\(report)")
        #expect(runWalk("not", { (value: Bool) in !value }, over: .bool) { .deterministic() }.isProved)
    }

    @Test func propertyTypesReadLikeSwiftUIAndMatchTheFactories() {
        let asTypes = runWalk("surface", surface, over: .allCases) {
            Deterministic()
            Matches(surface)
            Matches("named", surface)
            Outputs(within: Set(Surface.allCases))
            Satisfies("any") { _, _ in true }
            Satisfies("when", when: { _ in true }, then: { _ in true })
        }
        let asMembers = runWalk("surface", surface, over: .allCases) {
            Property.deterministic()
            Property.matches(surface)
            Property.matches("named", surface)
            Property.image(within: Set(Surface.allCases))
            Property.satisfies("any") { _, _ in true }
            Property.satisfies("when", when: { _ in true }, then: { _ in true })
        }
        #expect(asTypes.description == asMembers.description)
        #expect(asTypes.isProved)

        let flip = runWalk("not", { (value: Bool) in !value }, over: .bool) {
            Matches(table: [false: true, true: false])
            Injective()
            RoundTrip(through: { !$0 })
            Outputs(exactly: [true, false])
        }
        #expect(flip.isProved, "\(flip)")
        #expect(flip.results.map(\.name) == ["total", "matches table", "injective", "round trip", "image equals expected set"])
        let missingRow = runWalk("not", { (value: Bool) in !value }, over: .bool) { Matches(table: [false: true]) }
        #expect(missingRow.counterexamples.first?.counterexample.input == "true")
    }

    @Test func customPropertyKeepsStatePerRun() {
        let atMostThree = Property<Int, Int>.custom("at most 3 inputs") {
            var seen = 0
            return .init(observe: { _, _, _ in
                seen += 1
                return seen > 3 ? "saw \(seen)" : nil
            })
        }
        let first = runWalk("f", { $0 }, over: .int(0...2)) { atMostThree }
        let second = runWalk("f", { $0 }, over: .int(0...2)) { atMostThree }
        #expect(first.isProved && second.isProved)
    }

    @Test func partitionGroupsCollidingInputsInFirstSeenOrder() {
        let result = runPartition(surface, over: Domain<Terrain>.allCases)
        #expect(result.groups.map(\.output) == [.grass, .beach, .water, .other])
        #expect(result.collisions.map { $0.inputs.count } == [2, 2])
        #expect(!result.isInjective)
        #expect(runPartition({ (x: Int) in x * 2 }, over: .int(0...9)).isInjective)
    }

    @Test func partitionReportsThrowingInputs() {
        struct Boom: Error {}
        let result = runPartition({ (x: Int) throws -> Int in if x == 2 { throw Boom() } else { x } }, over: .int(0...3))
        #expect(result.threw.map(\.input) == [2])
        #expect(!result.isInjective)
    }
}
