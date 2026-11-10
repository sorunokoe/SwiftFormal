import SwiftFormal
import SwiftFormalTesting
import Testing

private enum Audience: CaseIterable, Finite, Hashable {
    case anyone, friends, nobody
}

private func label(_ audience: Audience) -> String {
    switch audience {
    case .anyone: "Everyone"
    case .friends: "Friends"
    case .nobody: "Only me"
    }
}

extension Audience {
    var title: String { label(self) }
}

@Suite struct ProveTests {
    @Test func provesAnExhaustiveTable() {
        let report = Prove("label", it: label) {
            Property.deterministic()
            Property.table([.anyone: "Everyone", .friends: "Friends", .nobody: "Only me"])
        }.report
        #expect(report.isProved)
    }

    @Test func expectProvedAcceptsAFunctionAndADomain() {
        let report = Prove("negate twice", it: { (value: Bool) in !(!value) }, over: .bool) {
            Property.deterministic()
        }.report
        #expect(report.isProved)
    }

    @Test func tableThatMissesACaseIsACounterexample() {
        let report = runWalk("label", label) {
            Property.table([.anyone: "Everyone", .friends: "Friends"])
        }
        #expect(report.counterexamples.first?.counterexample.input == "nobody")
    }

    @Test func tableWithAWrongRowIsACounterexample() {
        let report = runWalk("label", label) {
            Property.table([.anyone: "Everyone", .friends: "Friend", .nobody: "Only me"])
        }
        #expect(report.counterexamples.first?.counterexample.detail.contains("expected \"Friend\"") == true)
    }

    @Test func aFailedProofBecomesATestIssue() {
        withKnownIssue("the table is deliberately wrong") {
            Prove("label", it: label) {
                Property.table([.anyone: "Everyone", .friends: "Friends", .nobody: "Nobody"])
            }
        }
    }

    @Test func aBoundedVerdictIsNotAProofUnlessAllowed() {
        let sample = Domain<Int>.samples([1, 2, 3])
        withKnownIssue("a sampled domain cannot be proved") {
            Prove("identity", it: { (value: Int) in value }, over: sample)
        }
        Prove("identity", it: { (value: Int) in value }, over: sample, allowBounded: true)
    }

    @Test func proveReadsLikeSwiftUI() {
        let prove = Prove(it: { label($0) }, over: .allCases) {
            Deterministic()
            Matches(table: [.anyone: "Everyone", .friends: "Friends", .nobody: "Only me"])
            Satisfies("never empty") { _, text in !text.isEmpty }
        }
        #expect(prove.report.isProved)
        #expect(prove.report.subject == "proveReadsLikeSwiftUI()")
        #expect(Prove("label", it: label).report.isProved)
    }

    @Test func aKeyPathIsAFunctionUnderTest() {
        let prove = Prove(it: \Audience.title) { Satisfies("never empty") { _, text in !text.isEmpty } }
        #expect(prove.report.isProved)
    }

    @Test func aFailedProveBecomesATestIssue() {
        withKnownIssue("the table is deliberately wrong") {
            Prove(it: label, over: .allCases) {
                Matches(table: [.anyone: "Everyone", .friends: "Friends", .nobody: "Nobody"])
            }
        }
        withKnownIssue("a sampled domain cannot be proved") {
            Prove(it: { (value: Int) in value }, over: .samples([1, 2, 3]))
        }
        Prove(it: { (value: Int) in value }, over: .samples([1, 2, 3]), allowBounded: true)
    }
}
