import Testing

@testable import SwiftFormal

private struct Boom: Error {}

/// The parallel `verify` must give the serial `verify`'s report for the same arguments, whatever the threads and chunks.
@Suite struct ParallelVerifyTests {
    private static let settings: [Parallelism] = [
        .threads(1, chunkSize: 1), .threads(3, chunkSize: 7), .threads(8, chunkSize: 1024), .threads(8, chunkSize: 64),
        .threads(5, chunkSize: 4096),
    ]

    private func expectSameReport<Input: Sendable, Output: Sendable>(
        _ subject: String, _ function: @escaping @Sendable (Input) throws -> Output, over domain: Domain<Input>,
        budget: Budget = .default, assuming: (@Sendable (Input) -> Bool)? = nil,
        properties: @escaping () -> [Property<Input, Output>], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let serial = runWalk(
            subject, function, over: domain, budget: budget, properties: properties, assuming: assuming.map { a in { a($0) } })
        for setting in Self.settings {
            let parallel = runWalk(
                subject, function, over: domain, budget: budget, parallelism: setting, properties: properties, assuming: assuming)
            #expect(parallel.description == serial.description, "\(setting)", sourceLocation: sourceLocation)
            #expect(
                parallel.evaluated == serial.evaluated && parallel.excluded == serial.excluded, "\(setting)", sourceLocation: sourceLocation
            )
            #expect(parallel.results.map(\.verdict) == serial.results.map(\.verdict), "\(setting)", sourceLocation: sourceLocation)
        }
    }

    @Test func failuresAreTheSerialOnes() {
        expectSameReport(
            "third", { (x: Int) in x / 3 }, over: .int(0...99_999),
            properties: {
                [
                    .satisfies("small") { _, y in y < 20_000 }, .satisfies("not 777") { x, _ in x != 777 }, .injective(),
                    .image(within: Set(0..<40_000)), .deterministic(),
                ]
            })
        expectSameReport(
            "last digit", { (x: Int) in x % 10 }, over: .int(0...9_999), properties: { [.image(equals: Set(0..<11)), .injective()] })
    }

    @Test func throwingInputsAndEarlyStops() {
        let failsEvery1000: @Sendable (Int) throws -> Int = { x in
            guard x % 1000 != 999 else { throw Boom() }
            return x
        }
        let failsOnce: @Sendable (Int) throws -> Int = { x in
            guard x != 4321 else { throw Boom() }
            return x
        }
        expectSameReport(
            "throws then all fail", failsEvery1000, over: .int(0...199_999),
            properties: { [.satisfies("below 5000") { _, y in y < 5000 }, .satisfies("below 70000") { _, y in y < 70_000 }] })
        expectSameReport("first throw", failsOnce, over: .int(0...99_999), properties: { [] })
    }

    @Test func excludedInputs() {
        expectSameReport(
            "identity", { (x: Int) in x }, over: .int(0...99_999), assuming: { $0 % 3 != 0 },
            properties: { [.satisfies("not 50001") { x, _ in x != 50_001 }, .injective()] })
    }

    /// Sampled walks draw on the calling thread, so the inputs are the pinned serial ones (4966554 for this seed).
    @Test func sampledWalksDrawTheSameInputs() {
        let unwrap: @Sendable (Int?) throws -> Int = { x in
            guard let x else { throw Boom() }
            return x
        }
        expectSameReport(
            "identity", { (x: Int) in x }, over: .int(0...999_999_999), budget: Budget(maxEvaluations: 100_000),
            properties: { [.satisfies("not a multiple of 9973") { _, y in y % 9973 != 0 }] })
        expectSameReport(
            "sum", { (x: [Int]) in x.reduce(0, +) }, over: .arrays(of: .int(0...9), maxLength: 12), budget: Budget(maxEvaluations: 50_000),
            properties: { [.satisfies("sum below 90") { _, s in s < 90 }, .injective()] })
        expectSameReport(
            "unwrap", unwrap, over: .optional(.union([.int(0...2), .int(100...199_999), .just(-1)])),
            budget: Budget(maxEvaluations: 30_000), properties: { [.satisfies("not -1") { _, y in y != -1 }, .injective()] })
    }
}
