#if (os(macOS) || os(Linux)) && compiler(>=6.3)
    import Foundation
    import SwiftFormal
    @testable import SwiftFormalTesting
    import Testing

    // U4: a walk that survives a trap. The function under test runs in an exit-test child; a trap ends only the child,
    // and the parent names the input.

    /// Traps when `a + b` overflows: first at (1, 255), step 511.
    private func average(_ a: UInt8, _ b: UInt8) -> UInt8 { (a + b) / 2 }
    private func averageFixed(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((UInt16(a) + UInt16(b)) / 2) }
    private let bytePairs = Domain.product(UInt8.domain, UInt8.domain)

    /// Over budget, so the walk samples it.
    private let wide = Domain<Int>.int(0...1_000_000)
    private let sampledBudget = Budget(maxEvaluations: 1_000, seed: 42)
    private func halveSmall(_ value: Int) -> Int {
        precondition(value <= 500_000, "too big")
        return value / 2
    }

    @Suite struct TrapWalkExitTests {
        @Test func aTrapNamesItsInputAndIsConfirmedAlone() async {
            let child = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                walkInThisExitTest(
                    "average", { average($0.0, $0.1) }, over: bytePairs, properties: { Property.deterministic() })
            }
            var walk = TrapWalk(child, over: bytePairs)
            guard case .trapped(let trap) = walk.outcome else {
                Issue.record("expected a trap, got \(walk)")
                return
            }
            #expect(trap.step.step == 511)
            #expect(trap.input.0 == 1 && trap.input.1 == 255)
            let step = walk.stepToConfirm
            #expect(step == trap.step)
            if let step {
                walk.confirm(
                    await #expect(processExitsWith: .failure) { [step = step as WalkStep] in
                        callAloneInExitTest(step, over: bytePairs) { average($0.0, $0.1) }
                    })
            }
            guard case .trapped(let confirmed) = walk.outcome else { return }
            #expect(confirmed.alone == .traps)
            #expect(walk.stepToConfirm == nil)
            #expect(walk.description.hasPrefix("average traps for input (1, 255) (step 511, SIG"))
            #expect(walk.description.hasSuffix("confirmed: it traps when called alone on this input"))
            withKnownIssue("average traps") { walk.expectNoTrap() }
        }

        @Test func aSampledWalkNamesTheSampledInput() async {
            let expected = (0..<sampledBudget.maxEvaluations).lazy
                .map { WalkStep(step: $0, domainCount: wide.count, budget: sampledBudget) }
                .first { ($0.input(in: wide) ?? 0) > 500_000 }
            let child = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                walkInThisExitTest("halveSmall", halveSmall, over: wide, budget: sampledBudget)
            }
            let walk = TrapWalk(child, over: wide)
            guard case .trapped(let trap) = walk.outcome else {
                Issue.record("expected a trap, got \(walk)")
                return
            }
            #expect(trap.step == expected)
            #expect(trap.input > 500_000)
            #expect(trap.message?.contains("too big") == true)
        }

        @Test func aTrapInAPropertyIsNotBlamedOnTheFunction() async {
            let child = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                walkInThisExitTest(
                    "identity", { (value: UInt8) in value }, over: UInt8.domain,
                    properties: {
                        Property.satisfies("not seven") { input, _ in
                            precondition(input != 7)
                            return true
                        }
                    })
            }
            var walk = TrapWalk(child, over: UInt8.domain)
            guard case .trappedWhileChecking(let trap) = walk.outcome else {
                Issue.record("expected a trap while checking, got \(walk)")
                return
            }
            #expect(trap.input == 7)
            if let step = walk.stepToConfirm {
                walk.confirm(
                    await #expect(processExitsWith: .failure) { [step = step as WalkStep] in
                        callAloneInExitTest(step, over: UInt8.domain) { (value: UInt8) in value }
                    })
            }
            guard case .trappedWhileChecking(let confirmed) = walk.outcome else { return }
            #expect(confirmed.alone == .returns)
            #expect(walk.description.hasPrefix("identity: a property, observer or #requires trapped while checking input 7"))
        }

        @Test func aWalkWithoutATrapPasses() async {
            let child = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                walkInThisExitTest("averageFixed", { averageFixed($0.0, $0.1) }, over: bytePairs)
            }
            let walk = TrapWalk(child, over: bytePairs)
            guard case let .walked(report, proved, accepted) = walk.outcome else {
                Issue.record("expected a walk, got \(walk)")
                return
            }
            #expect(proved && accepted)
            #expect(report.hasPrefix("verify averageFixed: 65536 of 65536 inputs"))
            #expect(walk.expectNoTrap())
        }

        // Without a trap the child's verdict must still reach the parent: a counterexample fails the test there.
        @Test func aCounterexampleWithoutATrapFailsInTheParent() async {
            let child = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                walkInThisExitTest(
                    "identity", { (value: UInt8) in value }, over: UInt8.domain,
                    properties: { Property.satisfies("below 200") { _, output in output < 200 } })
            }
            let walk = TrapWalk(child, over: UInt8.domain)
            guard case let .walked(report, proved, accepted) = walk.outcome else {
                Issue.record("expected a walk, got \(walk)")
                return
            }
            #expect(!proved && !accepted)
            #expect(report.contains("FAILED       below 200 for input 200"))
            withKnownIssue("the property has a counterexample") { #expect(!walk.expectNoTrap()) }
        }

        @Test func aChildThatExitsOnItsOwnIsNeverAPass() async {
            let child = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                walkInThisExitTest(
                    "exits",
                    { (value: UInt8) -> UInt8 in
                        if value == 3 { exit(1) }
                        return value
                    }, over: UInt8.domain)
            }
            let walk = TrapWalk(child, over: UInt8.domain)
            guard case .unexpectedExit = walk.outcome else {
                Issue.record("expected an unexpected exit, got \(walk)")
                return
            }
            withKnownIssue("the function called exit") { walk.expectNoTrap() }
        }

        // Exiting in the test runner's own process would end every test; outside an exit test nothing runs.
        @Test func outsideAnExitTestNothingRunsAndTheMisuseIsAnIssue() {
            var calls = 0
            withKnownIssue("walkInExitTest needs an exit test") {
                walkInThisExitTest("counted", { (_: Bool) in calls += 1 }, over: .bool)
            }
            withKnownIssue("callAloneInExitTest needs an exit test") {
                callAloneInExitTest(WalkStep(step: 0, domainCount: 2, budget: .default), over: Domain.bool) { _ in calls += 1 }
            }
            #expect(calls == 0)
            #expect(!WalkProbe.isPublishing)
        }
    }

    @Suite struct TrapWalkReadingTests {
        private func standardError(_ lines: [String]) -> [UInt8] { Array(lines.joined(separator: "\n").utf8) }
        private let header = TrapWalkProtocol.header(
            subject: "f", step: WalkStep(step: 0, domainCount: 256, budget: .default))

        @Test func aMarkerInTheFunctionIsATrapOnThatInput() {
            let walk = TrapWalk(
                status: .signal(SIGTRAP),
                standardError: standardError([header, "x.swift:3: Fatal error: boom", "SWIFTFORMAL-WALK-TRAP 42 0"]),
                over: UInt8.domain)
            guard case .trapped(let trap) = walk.outcome else {
                Issue.record("got \(walk)")
                return
            }
            #expect(trap.input == 42)
            #expect(trap.message == "x.swift:3: Fatal error: boom")
            #expect(walk.subject == "f")
        }

        @Test func aMarkerWhileCheckingIsNotBlamedOnTheFunction() {
            let walk = TrapWalk(
                status: .signal(SIGILL), standardError: standardError([header, "SWIFTFORMAL-WALK-TRAP 9 1"]),
                over: UInt8.domain)
            guard case .trappedWhileChecking(let trap) = walk.outcome else {
                Issue.record("got \(walk)")
                return
            }
            #expect(trap.input == 9)
        }

        @Test func aSignalWithoutAMarkerHasAnUnknownInput() {
            let walk = TrapWalk(status: .signal(SIGTRAP), standardError: standardError([header]), over: UInt8.domain)
            guard case .trappedInputUnknown = walk.outcome else {
                Issue.record("got \(walk)")
                return
            }
        }

        @Test func anotherDomainSizeHasAnUnknownInput() {
            let walk = TrapWalk(
                status: .signal(SIGTRAP), standardError: standardError([header, "SWIFTFORMAL-WALK-TRAP 9 0"]),
                over: Domain.bool)
            guard case .trappedInputUnknown(_, let detail) = walk.outcome else {
                Issue.record("got \(walk)")
                return
            }
            #expect(detail == "the child walked 256 values; this domain has 2")
        }

        @Test func unobservedStandardErrorIsNeverAPass() {
            let walk = TrapWalk(
                status: .exitCode(TrapWalkProtocol.walkedAccepted), standardError: [], over: UInt8.domain)
            guard case .unexpectedExit = walk.outcome else {
                Issue.record("got \(walk)")
                return
            }
        }

        @Test func noResultAndForeignExitsAreUnexpected() {
            for status in [nil, ExitStatus.exitCode(0), .exitCode(1), .signal(SIGKILL)] {
                let walk = TrapWalk(status: status, standardError: standardError([header]), over: UInt8.domain)
                guard case .unexpectedExit = walk.outcome else {
                    Issue.record("\(String(describing: status)) gave \(walk)")
                    continue
                }
            }
        }

        @Test func aConfirmationThatReturnsSaysTheTrapNeedsEarlierCalls() {
            var walk = TrapWalk(
                status: .signal(SIGTRAP), standardError: standardError([header, "SWIFTFORMAL-WALK-TRAP 5 0"]),
                over: UInt8.domain)
            walk.confirm(status: .exitCode(TrapWalkProtocol.aloneReturned))
            #expect(walk.description.hasSuffix("does not trap, so the trap depends on earlier calls"))
        }
    }
#endif
