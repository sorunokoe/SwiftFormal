import Foundation
import SwiftFormal
@testable import SwiftFormalTesting
import Testing

// U11: Swift Testing features that work at the macOS 13 floor.

@Suite struct BoundedWarningTests {
    private let sample = runWalk("identity", { (value: Int) in value }, over: .samples([1, 2, 3]))

    // A bounded verdict accepted with `allowBounded` was silent; it is a warning now, so a spot check stays visible.
    @Test func anAcceptedBoundedVerdictIsAWarning() {
        #expect(WalkIssue.severity(for: sample, allowBounded: true) == .warning)
    }

    @Test func aBoundedVerdictNotAllowedIsAnError() {
        #expect(WalkIssue.severity(for: sample, allowBounded: false) == .error)
    }

    @Test func aProofRecordsNothing() {
        let report = runWalk("not", { (value: Bool) in !value }, over: .bool)
        #expect(WalkIssue.severity(for: report, allowBounded: true) == nil)
    }

    @Test func aCounterexampleIsAnErrorEvenWhenBoundedIsAllowed() {
        let report = runWalk(
            "identity", { (value: Int) in value }, over: .samples([1, 2, 3]),
            properties: { Property.satisfies("small") { _, output in output < 3 } })
        #expect(WalkIssue.severity(for: report, allowBounded: true) == .error)
    }

    @Test func theWarningSaysItIsNotAProof() {
        let text = WalkIssue.message(for: sample, severity: .warning)
        #expect(text.hasPrefix("bounded, accepted with allowBounded (not a proof):\n"))
        #expect(text.hasSuffix(sample.description))
    }
}

@Suite struct ReportAttachmentTests {
    @Test func aProofHasNoAttachments() {
        let report = runWalk("not", { (value: Bool) in !value }, over: .bool)
        #expect(WalkAttachments.contents(for: report, at: #_sourceLocation).isEmpty)
    }

    /// Under `swiftformal check` (plan item U12) every report is attached as its JSON line, proofs too: the check reads
    /// the walks' results from the test event stream.
    @Test func underSwiftFormalCheckAProofIsAttachedAsAJSONLine() throws {
        let report = runWalk("not", { (value: Bool) in !value }, over: .bool)
        let files = WalkAttachments.contents(for: report, at: #_sourceLocation, everyReport: true)
        #expect(files.map(\.name) == ["not.walk.json"])
        let json = try #require(files.first?.text.data(using: .utf8))
        let line = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(line["verdict"] as? String == "proved")
        let bounded = runWalk("a/b c", { (value: Int) in value }, over: .samples([1, 2, 3]))
        #expect(
            WalkAttachments.contents(for: bounded, at: #_sourceLocation, everyReport: true).map(\.name) == [
                "a_b_c.report.txt", "a_b_c.walk.json",
            ])
        #expect(WalkAttachments.everyReport(environment: ["SWIFTFORMAL_WALK_EVENTS": "1"]))
        #expect(!WalkAttachments.everyReport(environment: [:]))
    }

    @Test func aReportThatIsNotAProofIsAttachedAsTextAndAsAJSONLine() throws {
        let report = runWalk("a/b c", { (value: Int) in value }, over: .samples([1, 2, 3]))
        let files = WalkAttachments.contents(for: report, at: #_sourceLocation)
        #expect(files.map(\.name) == ["a_b_c.report.txt", "a_b_c.walk.json"])
        #expect(files.first?.text == report.description)
        let json = try #require(files.last?.text.data(using: .utf8))
        let line = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(line["verdict"] as? String == "bounded")
        #expect(line["subject"] as? String == "a/b c")
    }
}

#if compiler(>=6.1)
    @Suite(.swiftFormal(budget: Budget(maxEvaluations: 10), allowBounded: true))
    struct ScopedWalkDefaultsTests {
        @Test func theSuiteBudgetIsTheDefault() {
            let report = Prove("identity", it: { (value: Int) in value }, over: .int(0...99)).report
            #expect(report.evaluated == 10)
            #expect(!report.isProved)
        }

        @Test func theFiniteOverloadUsesTheSuiteBudgetToo() {
            let report = Prove("negate", it: { (value: Int8) in value &* -1 }).report
            #expect(report.evaluated == 10)
        }

        @Test func anExplicitBudgetWins() {
            let report = Prove("identity", it: { (value: Int) in value }, over: .int(0...99), budget: Budget(maxEvaluations: 20)).report
            #expect(report.evaluated == 20)
        }

        @Test func theSessionWalkUsesTheSuiteBudgetToo() {
            let report = Prove(it: { $0 += $1 }, over: .sessions(from: 0, actions: .int(0...9), upTo: 3)).report
            #expect(report.evaluated == 10)
        }

        #if (os(macOS) || os(Linux)) && compiler(>=6.3)
            @Test func theTrapWalkUsesTheSuiteBudgetToo() async {
                let report = await Prove(neverTraps: Halving.self).report
                #expect(report.evaluated == 10 && !report.isProved && report.hasNoCounterexample)
            }
        #endif

        @Test func anExplicitAllowBoundedFalseWins() {
            withKnownIssue("a bounded verdict fails when allowBounded is false") {
                Prove("identity", it: { (value: Int) in value }, over: .int(0...99), allowBounded: false)
            }
        }
    }

#endif

#if (os(macOS) || os(Linux)) && compiler(>=6.3)
    /// A trap walk over 65 536 inputs, to see a suite budget reach the child process.
    enum Halving: ExitTestWalk {
        static let inputs: Domain<Int> = .int(0...65_535)
        static func call(_ value: Int) -> Int { value / 2 }
    }
#endif

@Suite struct UnscopedWalkDefaultsTests {
    @Test func withoutTheTraitTheDefaultsAreUnchanged() {
        #expect(WalkDefaults.budget.maxEvaluations == Budget.default.maxEvaluations)
        #expect(WalkDefaults.budget.seed == Budget.default.seed)
        #expect(!WalkDefaults.allowBounded)
    }

    #if compiler(>=6.1)
        @Test(.swiftFormal(budget: Budget(maxEvaluations: 5))) func theTraitWorksOnOneTest() {
            let report = Prove("identity", it: { (value: Int) in value }, over: .int(0...99), allowBounded: true).report
            #expect(report.evaluated == 5)
            #expect(!WalkDefaults.allowBounded)
        }
    #endif
}
