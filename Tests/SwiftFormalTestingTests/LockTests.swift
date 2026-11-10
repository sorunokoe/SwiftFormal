import Foundation
import SwiftFormal
@testable import SwiftFormalTesting
import Testing

private func coversAllPairs(_ rows: [[Int]], levels: [Int]) -> Bool {
    for i in levels.indices {
        for j in levels.indices where j > i {
            for a in 0..<levels[i] {
                for b in 0..<levels[j] where !rows.contains(where: { $0[i] == a && $0[j] == b }) { return false }
            }
        }
    }
    return true
}

private struct Pair: Equatable {
    var flag: Bool
    var count: Int
}

private func classify(_ pair: Pair) -> String {
    switch (pair.flag, pair.count) {
    case (true, 0): "on-empty"
    case (true, _): "on"
    case (false, ..<0): "off-negative"
    default: "off"
    }
}

private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sflock-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct PairwiseTests {
    @Test func coversEveryPairAndIsMuchSmallerThanTheProduct() {
        let levels = [3, 3, 3, 3, 3, 3, 3, 3]
        let rows = Pairwise.rows(levels: levels)
        #expect(coversAllPairs(rows, levels: levels))
        #expect(rows.count < 60, "8 factors of 3 values: product is 6561")
        #expect(rows == Pairwise.rows(levels: levels), "deterministic")
    }

    @Test func mixedLevelsAndSmallCases() {
        for levels in [[2, 5], [4, 1, 7], [2, 2, 2, 2, 2, 2, 2], [1], []] {
            let rows = Pairwise.rows(levels: levels)
            #expect(coversAllPairs(rows, levels: levels))
            #expect(rows.allSatisfy { $0.count == levels.count })
        }
        #expect(Pairwise.rows(levels: [3, 0, 2]).isEmpty)
    }

    @Test func combinationsAreCompleteWhenSmallAndASampleWhenLarge() {
        let small = Domain<[Int]>.combinations(levels: [2, 3, 4], complete: true) { $0 }
        #expect(small.count == 24 && small.complete)
        #expect(Set((0..<small.count).map { small[$0] }).count == 24)

        let large = Domain<[Int]>.combinations(levels: Array(repeating: 6, count: 8), complete: true) { $0 }
        #expect(large.count < 200 && !large.complete)
    }

    @Test func hugeCombinationsStayBoundedAndShowEveryValue() {
        let levels = [3000, 2000, 1500, 900, 40, 40, 5, 5]
        let domain = Domain<[Int]>.combinations(levels: levels, complete: true) { $0 }
        #expect(domain.count <= 4096 && !domain.complete)
        let rows = (0..<domain.count).map { domain[$0] }
        for (factor, count) in levels.enumerated() where count <= domain.count {
            #expect(Set(rows.map { $0[factor] }).count == count, "factor \(factor) shows all its values")
        }
        #expect(rows == (0..<domain.count).map { domain[$0] }, "deterministic")
    }
}

@Suite struct LockTests {
    private let domain = Domain<Pair>.combinations(levels: [2, 3], complete: true) {
        Pair(flag: $0[0] == 1, count: $0[1] - 1)
    }

    @Test func recordsThenMatchesThenReportsExactlyWhatMoved() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        guard case .recorded = checkBehaviorLock("classify", classify, over: domain, directory: directory) else {
            Issue.record("first run should record")
            return
        }
        guard case .matches = checkBehaviorLock("classify", classify, over: domain, directory: directory) else {
            Issue.record("second run should match")
            return
        }

        // A "refactor" that quietly changes one case.
        let refactored: (Pair) -> String = { $0.flag && $0.count == 0 ? "on" : classify($0) }
        guard case let .changed(changes, _, _) = checkBehaviorLock("classify", refactored, over: domain, directory: directory) else {
            Issue.record("a changed behaviour must be reported")
            return
        }
        #expect(changes.count == 1)
        #expect(changes[0].was == "on-empty" && changes[0].now == "on")
        #expect(changes[0].input.contains("flag: true") && changes[0].input.contains("count: 0"))
    }

    @Test func masksAddressesAndDetectsAShrunkDomain() throws {
        #expect(BehaviorLock.mask("<Foo: 0x000000012ab3c4d0> and 0xff") == "<Foo: 0x*> and 0xff")

        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        checkBehaviorLock("n", classify, over: domain, directory: directory)
        let smaller = Domain<Pair>.of((0..<3).map { domain[$0] })
        guard case let .changed(changes, oldCount, newCount) = checkBehaviorLock("n", classify, over: smaller, directory: directory) else {
            Issue.record("a shrunk domain is a change")
            return
        }
        #expect(oldCount == 6 && newCount == 3 && changes.count == 3)
    }
}
