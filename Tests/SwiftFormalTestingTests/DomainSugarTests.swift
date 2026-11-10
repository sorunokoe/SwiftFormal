import SwiftFormal
import SwiftFormalTesting
import Testing

private enum Unit: CaseIterable { case meters, feet }

private struct Conditions {
    let altitude: Int
    let temperature: Int
    let unit: Unit
}

private enum Step {
    case serverSends(Unit)
    case types(Int)
    case restoreDefaults
}

/// Domains written as the app's tests need them, without a mirror enum per table.
@Suite struct DomainSugarTests {
    @Test func aTableOfNamedValuesPrintsItsNames() {
        let servers: Domain<NamedValue<Conditions>> = .named([
            "metric default": Conditions(altitude: 0, temperature: 25, unit: .meters),
            "imperial at max": Conditions(altitude: 13_123, temperature: 122, unit: .feet),
            "cold day": Conditions(altitude: 120, temperature: -5, unit: .meters),
        ])
        #expect(servers.count == 3 && servers.complete)
        #expect(servers[2].description == "cold day" && servers[2].temperature == -5)
        let report = runWalk("temperature", { (row: NamedValue<Conditions>) in row.temperature }, over: servers) {
            Satisfies("not below zero") { _, temperature in temperature >= 0 }
        }
        #expect(report.counterexamples.first?.counterexample.input == "cold day")
    }

    @Test func anEnumWithPayloadsIsOneUnionOfItsCases() {
        let steps = Domain<Step>.union(
            Domain<Unit>.allCases.map(Step.serverSends), Domain.int(0...2).map(Step.types), .of([.restoreDefaults]))
        #expect(steps.count == 6 && steps.complete)
        #expect(steps.count == Domain.union([Domain<Unit>.allCases.map(Step.serverSends)]).count + 4)
    }
}
