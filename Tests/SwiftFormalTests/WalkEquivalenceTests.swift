import Testing
@_spi(Extending) @testable import SwiftFormal

// The faster walk, `partition` and `evenlySpaced` must give the results of the code they replaced.

/// Equatable but not Hashable, so `partition` and `table` take the linear-search overloads. Printed as its value, so
/// reports of both overloads read the same.
private struct OnlyEquatable: Equatable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    let value: Int
    var description: String { "\(value)" }
    init(value: Int) { self.value = value }
    init(integerLiteral value: Int) { self.value = value }
}

private struct Failure: Error {}

@Suite struct WalkEquivalenceTests {
    @Test func hashedPartitionHasTheGroupsOfTheLinearOne() {
        let domain = Domain.int(-500...1_500)
        let hashed = runPartition(
            { (x: Int) -> Int in
                if x % 97 == 13 { throw Failure() }
                return (x &* 7919) % 37
            }, over: domain)
        let linear = runPartition(
            { (x: Int) -> OnlyEquatable in
                if x % 97 == 13 { throw Failure() }
                return OnlyEquatable(value: (x &* 7919) % 37)
            }, over: domain)
        #expect(hashed.groups.map(\.output) == linear.groups.map(\.output.value))
        #expect(hashed.groups.map(\.inputs) == linear.groups.map(\.inputs))
        #expect(hashed.threw.map(\.input) == linear.threw.map(\.input))
        #expect(hashed.inputCount == linear.inputCount)
    }

    @Test func hashedPartitionKeepsNaNsApartLikeEquality() {
        let result = runPartition({ (x: Int) -> Double in x < 3 ? .nan : Double(x % 2) }, over: .int(0...6))
        #expect(result.groups.count == 3 + 2)
        #expect(result.groups.prefix(3).allSatisfy { $0.output.isNaN && $0.inputs.count == 1 })
    }

    @Test func evenlySpacedPicksTheSameIndicesAndNoLongerOverflows() {
        let small = Domain.int(0...1_000).evenlySpaced(7)
        #expect((0..<small.count).map { small[$0] } == (0..<7).map { $0 * 1_000 / 6 })
        let huge = Domain.int(Int.min...Int.max).evenlySpaced(5)
        #expect(huge.count == 5)
        #expect(huge[0] == Int.min && huge[4] == Int.min + (Int.max - 1))
    }

    @Test func theWalkStopsOnlyWhenEveryPropertyAndTotalHaveFailed() {
        var calls = 0
        let report = runWalk(
            "throws on odd",
            { (x: Int) -> Int in
                calls += 1
                if x % 2 == 1 { throw Failure() }
                return x
            }, over: .int(0...99),
            properties: {
                Property.satisfies("below 10") { _, y in y < 10 }
                Property.satisfies("below 50") { _, y in y < 50 }
            }
        )
        // `total` fails at 1, "below 10" at 10, "below 50" at 50: the walk stops right after 50.
        #expect(calls == 51)
        #expect(report.counterexamples.map(\.property) == ["total", "below 10", "below 50"])
    }

    @Test func aWalkWithoutPropertiesStopsAtTheFirstThrow() {
        var calls = 0
        _ = runWalk(
            "throws at 3",
            { (x: Int) -> Int in
                calls += 1
                if x == 3 { throw Failure() }
                return x
            }, over: .int(0...99))
        #expect(calls == 4)
    }

    /// The hashed `Table` finds the rows the linear one finds: the first row of a repeated input, the missing rows, the
    /// wrong rows, with the same messages.
    @Test func hashedTableReportsWhatTheLinearOneReports() {
        func expectSame(_ hashedRows: KeyValuePairs<Int, String>, _ linearRows: KeyValuePairs<OnlyEquatable, String>) {
            let function: (Int) -> String = { $0.isMultiple(of: 3) ? "fizz" : "\($0)" }
            let domain = Domain.int(0...5)
            let hashed = runWalk("fizz", function, over: domain) { Matches(table: hashedRows) }
            let linear = runWalk("fizz", { function($0.value) }, over: domain.map { OnlyEquatable(value: $0) }) {
                Matches(table: linearRows)
            }
            #expect(hashed.description == linear.description)
            #expect(runWalk("fizz", function, over: domain) { Property<Int, String>.table(hashedRows) }.description == hashed.description)
        }
        expectSame([0: "fizz", 1: "1", 2: "2", 3: "fizz", 4: "4", 5: "5"], [0: "fizz", 1: "1", 2: "2", 3: "fizz", 4: "4", 5: "5"])
        expectSame([0: "fizz", 1: "1", 3: "fizz", 5: "5"], [0: "fizz", 1: "1", 3: "fizz", 5: "5"])
        expectSame([0: "fizz", 1: "1", 2: "2", 3: "fizz", 4: "wrong", 5: "5"], [0: "fizz", 1: "1", 2: "2", 3: "fizz", 4: "wrong", 5: "5"])
        // A repeated input (allowed in `KeyValuePairs`): its first row counts.
        expectSame(
            // swiftlint:disable:next duplicated_key_in_dictionary_literal
            [1: "first", 0: "fizz", 1: "1", 2: "2", 3: "fizz", 4: "4", 5: "5"],
            // swiftlint:disable:next duplicated_key_in_dictionary_literal
            [1: "first", 0: "fizz", 1: "1", 2: "2", 3: "fizz", 4: "4", 5: "5"])
    }
}
