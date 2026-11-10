import Testing
@testable import SwiftFormal

// Pins the exact inputs a seeded walk visits, so a refactor of `Domain`, `Pairwise` or `verify` cannot silently change
// what users' sampled runs check. A deliberate change re-records these numbers and says so in the CHANGELOG.

// Internal, not private: inside a tuple a private type prints with a runtime address.
enum SampledClub: CaseIterable { case driver, iron, wedge, putter }

/// 64-bit FNV-1a over the description of each value, one per line.
private func fingerprint<S: Sequence>(_ values: S) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for value in values {
        for byte in "\(value)\n".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
    }
    return String(hash, radix: 16)
}

private func draws<Value>(_ domain: Domain<Value>, _ count: Int = 64, seed: UInt64 = 0x5F0F_A117) -> String {
    var rng = SplitMix64(seed: seed)
    return fingerprint((0..<count).map { _ in domain.random(&rng) })
}

private func elements<Value>(_ domain: Domain<Value>, _ limit: Int = 64) -> String {
    fingerprint((0..<min(domain.count, limit)).map { domain[$0] })
}

@Suite struct SampleSequenceTests {
    @Test func theGeneratorItselfIsPinned() {
        var rng = SplitMix64(seed: 0x5F0F_A117)
        let pinned = fingerprint((0..<64).map { _ in rng.next() })
        #expect(pinned == "8146747cb5df595c", "\(pinned)")
    }

    @Test(arguments: [
        (
            "of", draws(Domain.of([3, 1, 4, 1, 5, 9, 2, 6])), elements(Domain.of([3, 1, 4, 1, 5, 9, 2, 6])), "a21a2b55988c341c",
            "d78ab3fcb93f69de"
        ),
        ("int", draws(Domain.int(-1_000...1_000_000)), elements(Domain.int(-1_000...1_000_000)), "58696fc777274ed8", "5a524305bba7cf38"),
        ("bool", draws(Domain.bool), elements(Domain.bool), "2dea86c422a836fd", "73f5c8165aa80ba0"),
        ("allCases", draws(Domain<SampledClub>.allCases), elements(Domain<SampledClub>.allCases), "b218f83b9cabd27b", "e090ea66a303e21b"),
        ("boundaries", draws(Domain.boundaries), elements(Domain.boundaries), "91ea1cbe7e2954d3", "42e0f731a996da78"),
        (
            "map", draws(Domain.int(0...99).map { $0 * 7 }), elements(Domain.int(0...99).map { $0 * 7 }), "44dceddac69644e9",
            "981169df805a136f"
        ),
        (
            "evenlySpaced", draws(Domain.int(0...1_000_000).evenlySpaced(10)),
            elements(Domain.int(0...1_000_000).evenlySpaced(10)), "75748ac4a2309be6", "f3f1e436caadfea0"
        ),
        (
            "optional", draws(Domain<Int?>.optional(.int(0...9))), elements(Domain<Int?>.optional(.int(0...9))), "967f399e7d84e305",
            "59a1bca3e844ce59"
        ),
        (
            "arrays", draws(Domain<[Int]>.arrays(of: .int(0...4), maxLength: 4)),
            elements(Domain<[Int]>.arrays(of: .int(0...4), maxLength: 4)), "88ebd0704a48346d", "4085e0fa473da1b9"
        ),
        (
            "union", draws(Domain.union([.int(0...2), .int(100...199), .just(-1)])),
            elements(Domain.union([.int(0...2), .int(100...199), .just(-1)])), "5e887265db758d3b", "25f9d9cbe1171865"
        ),
        (
            "product2", draws(Domain<(Int, Bool)>.product(.int(0...9), .bool)),
            elements(Domain<(Int, Bool)>.product(.int(0...9), .bool)), "902024749cc15479", "61fa3a6b6598bc01"
        ),
        (
            "product3", draws(Domain.product(Domain.int(0...9), Domain.bool, Domain<SampledClub>.allCases)),
            elements(Domain.product(Domain.int(0...9), Domain.bool, Domain<SampledClub>.allCases)), "b2ee4ac9cd9d9643", "52e91d1723bcad05"
        ),
        (
            "product4", draws(Domain.product(Domain.int(0...9), Domain.bool, Domain<SampledClub>.allCases, Domain.int(-3...3))),
            elements(Domain.product(Domain.int(0...9), Domain.bool, Domain<SampledClub>.allCases, Domain.int(-3...3))), "e35c6a4b82c1b8a7",
            "3f6a5afe44a96280"
        ),
        (
            "nestedProduct", draws(Domain<(Int, (Bool, SampledClub))>.product(.int(0...9), .product(.bool, .allCases))),
            elements(Domain<(Int, (Bool, SampledClub))>.product(.int(0...9), .product(.bool, .allCases)), 80), "b769e829cf040371",
            "b7d6f7f74dee7ea5"
        ),
        (
            "combinationsFull", draws(Domain<[Int]>.combinations(levels: [3, 4, 5], complete: true) { $0 }),
            elements(Domain<[Int]>.combinations(levels: [3, 4, 5], complete: true) { $0 }), "7f7f17ccb98002a2", "f9e0a86bf978a89"
        ),
        (
            "combinationsPairwise", draws(Domain<[Int]>.combinations(levels: [5, 5, 5, 5, 5], complete: true) { $0 }),
            elements(Domain<[Int]>.combinations(levels: [5, 5, 5, 5, 5], complete: true) { $0 }), "3334f08538fe12b0", "9fb64fae5aa47e1e"
        ),
    ])
    func everyCombinatorDrawsAndEnumeratesThePinnedSequence(
        name: String, drawn: String, enumerated: String, pinnedDraws: String, pinnedElements: String
    ) {
        #expect(drawn == pinnedDraws, "\(name): seeded draws changed")
        #expect(enumerated == pinnedElements, "\(name): enumeration order changed")
    }

    @Test(arguments: [
        ([2, 2, 2], "84bdec8a8ae85b65"),
        ([3, 4, 5], "c47ae68486650ccc"),
        ([10, 10, 10, 10], "fdf7c87992cbcd0d"),
        ([2, 3, 4, 5, 6, 7], "5cf088e8ad727e80"),
        (Array(repeating: 3, count: 20), "d623a145e689c6bc"),
    ])
    func pairwiseRowsArePinned(levels: [Int], pinned: String) {
        let rows = fingerprint(Pairwise.rows(levels: levels))
        #expect(rows == pinned, "\(levels): \(rows)")
    }

    @Test func aSampledWalkVisitsThePinnedInputs() {
        var visited: [Int] = []
        let report = runWalk(
            "identity",
            { (x: Int) -> Int in
                visited.append(x)
                return x
            }, over: .int(0...999_999_999), budget: Budget(maxEvaluations: 256))
        #expect(report.evaluated == 256)
        let walked = fingerprint(visited)
        #expect(walked == "ea634c5756d3d31d", "\(walked)")
    }

    @Test func aSampledWalkStopsAtThePinnedCounterexample() {
        let report = runWalk(
            "identity", { (x: Int) in x }, over: .int(0...999_999_999), budget: Budget(maxEvaluations: 100_000),
            properties: { Property.satisfies("not a multiple of 9973") { _, y in y % 9973 != 0 } }
        )
        #expect(report.evaluated == 100_000)
        guard case .counterexample(let found) = report.results[1].verdict else {
            Issue.record("expected a counterexample, got \(report.results[1].verdict)")
            return
        }
        #expect(found.input == "4966554")
    }
}
