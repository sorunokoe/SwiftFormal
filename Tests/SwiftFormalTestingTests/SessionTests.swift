import Foundation
import SwiftFormal
@testable import SwiftFormalTesting
import Testing

// A toy event screen with the shape of a TCA feature: a state, an action enum with payloads, and a reducer whose
// `reduce(into:action:)` returns an effect the walk ignores.

private enum Kind: CaseIterable { case single, multiStage }

private struct DetailsState: Equatable {
    var kind = Kind.single
    var selectedTabIndex = 0
    var tabs: [String] { kind == .multiStage ? ["Overview", "Ranking", "Stages"] : ["Overview", "Ranking"] }
}

private enum DetailsAction {
    case changeKind(Kind)
    case tabSelected(Int)
    case retry
}

private struct Effect {}

private struct Box { let kind: Kind }

private enum Payload {
    case text(String)
    case data(Box)
    case number(Double)
}

private struct DetailsReducer {
    /// The defect: a new kind with fewer tabs keeps the selected index.
    var clampsTheIndex: Bool

    func reduce(into state: inout DetailsState, action: DetailsAction) -> Effect {
        switch action {
        case .changeKind(let kind):
            state.kind = kind
            if clampsTheIndex { state.selectedTabIndex = min(state.selectedTabIndex, state.tabs.count - 1) }
        case .tabSelected(let index): state.selectedTabIndex = index
        case .retry: break
        }
        return Effect()
    }
}

private let tabActions = Domain<DetailsAction>.union(
    Domain<Kind>.allCases.map(DetailsAction.changeKind), Domain.int(0...2).map(DetailsAction.tabSelected), .of([.retry]))

/// A tab control sends only the index of a tab it drew.
private func send(_ reducer: DetailsReducer) -> (inout DetailsState, DetailsAction) -> Void {
    { state, action in
        if case .tabSelected(let index) = action, !state.tabs.indices.contains(index) { return }
        _ = reducer.reduce(into: &state, action: action)
    }
}

@Suite struct SessionTests {
    @Test func everySessionKeepsTheSelectedTabOnScreen() {
        let report = Prove(
            it: send(DetailsReducer(clampsTheIndex: true)), over: .sessions(from: DetailsState(), actions: tabActions, upTo: 4)
        ) {
            Always("the selected tab is on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
        }.report
        #expect(report.isProved)
        #expect(report.evaluated == 1 + 6 + 36 + 216 + 1296)
    }

    @Test func theFailingSessionReadsAsItsActions() {
        let report = Prove(
            it: send(DetailsReducer(clampsTheIndex: false)), over: .sessions(from: DetailsState(), actions: tabActions, upTo: 4),
            knownIssue: "a new kind keeps the index"
        ) {
            Always("the selected tab is on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
        }.report
        let failure = report.counterexamples.first?.counterexample
        #expect(failure?.input == "changeKind(.multiStage) → tabSelected(2) → changeKind(.single)")
        #expect(failure?.detail == "fails after action 3 (changeKind(.single))")
    }

    @Test func aStepPropertySeesTheStateBeforeAndAfter() {
        let report = Prove(
            it: send(DetailsReducer(clampsTheIndex: true)), over: .sessions(from: DetailsState(), actions: tabActions, upTo: 3)
        ) {
            EachStep("retry changes nothing") { before, action, after in
                guard case .retry = action else { return true }
                return before == after
            }
            Satisfies("a session ends on a tab") { _, run in run.finalState.tabs.indices.contains(run.finalState.selectedTabIndex) }
        }.report
        #expect(report.isProved)
    }

    @Test func sessionsCanStartFromEveryStateOfADomain() {
        let starts = Domain<Kind>.allCases.map { DetailsState(kind: $0, selectedTabIndex: 0) }
        let report = Prove(
            it: send(DetailsReducer(clampsTheIndex: false)), over: .sessions(from: starts, actions: tabActions, upTo: 2),
            knownIssue: "a new kind keeps the index"
        ) {
            Always("the selected tab is on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
        }.report
        #expect(
            report.counterexamples.first?.counterexample.input
                == "from DetailsState(kind: .multiStage, selectedTabIndex: 0): tabSelected(2) → changeKind(.single)")
    }

    @Test func everyFailingSessionIsListedOnRequest() {
        let walk = Prove(
            it: send(DetailsReducer(clampsTheIndex: false)), over: .sessions(from: DetailsState(), actions: tabActions, upTo: 4),
            reporting: .everyFailure,
            knownIssue: "a new kind keeps the index"
        ) {
            Always("the selected tab is on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
        }
        #expect(!walk.report.isProved && walk.report.counterexamples.count == 1)
        #expect(walk.failures.count > 1)
        #expect(walk.failures.first?.counterexample.input == "changeKind(.multiStage) → tabSelected(2) → changeKind(.single)")
    }

    @Test func sessionsAreWalkedShortestFirst() {
        let sessions = Domain<Session<Int, Int>>.sessions(from: 0, actions: .int(1...2), upTo: 2)
        #expect(sessions.count == 1 + 2 + 4)
        #expect((0..<sessions.count).map { sessions[$0].description }.prefix(4) == ["(no actions)", "1", "2", "1 → 1"])
        let starts = Domain<Session<Int, Int>>.sessions(from: .int(0...1), actions: .int(1...1), upTo: 1)
        #expect(
            (0..<starts.count).map { starts[$0].description } == ["from 0: (no actions)", "from 0: 1", "from 1: (no actions)", "from 1: 1"])
    }

    /// `$0` in the step is the state, so the walk's record names the state's type: `check` reads `{ $0.send($1) }` as
    /// `State.send(_:)`, never as a member of `Session`.
    @Test func theRecordNamesTheStateAsTheInputOfTheStep() throws {
        let path = NSTemporaryDirectory() + "walk-log-\(UUID().uuidString).jsonl"
        let earlier = ProcessInfo.processInfo.environment[WalkLog.variable]
        setenv(WalkLog.variable, path, 1)
        defer {
            if let earlier { setenv(WalkLog.variable, earlier, 1) } else { unsetenv(WalkLog.variable) }
            try? FileManager.default.removeItem(atPath: path)
        }
        Prove(
            "Counter.add(_:)", it: { (state: inout Int, action: Int) in state += action },
            over: .sessions(from: 0, actions: .int(0...1), upTo: 1))
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        let line = try #require(lines.first { $0.contains(#""subject":"Counter.add(_:)""#) })
        #expect(line.contains(#""inputType":"Swift.Int""#), "\(line)")
    }

    @Test func theStartStateIsChecked() {
        let report = runWalk(
            "start", { (session: Session<Int, Int>) in SessionRun<Int, Int>(states: [session.start]) },
            over: .just(Session(start: -1, actions: [], showsStart: false))
        ) {
            Always("positive") { $0 > 0 }
        }
        #expect(report.counterexamples.first?.counterexample.input == "(no actions)")
        #expect(report.counterexamples.first?.counterexample.detail == "fails in the start state")
    }

    @Test func qualifiedNamesInActionsAreShortened() {
        #expect(readableDescription(DetailsAction.changeKind(.multiStage)) == "changeKind(.multiStage)")
        #expect(readableDescription(Payload.text("Surface.green")) == "text(\"Surface.green\")")
        #expect(readableDescription(Payload.data(Box(kind: .single))) == "data(Box(kind: .single))")
        #expect(readableDescription(Payload.number(1.5)) == "number(1.5)")
        #expect(
            Session(start: 0, actions: [DetailsAction.retry, .tabSelected(1)], showsStart: true).description
                == "from 0: retry → tabSelected(1)")
    }
}

/// The app's suites run on the main actor; a session walk works there unchanged.
@MainActor @Suite struct MainActorSessionTests {
    private let reducer = DetailsReducer(clampsTheIndex: true)

    @Test func aSessionWalkRunsOnTheMainActor() {
        Prove(
            it: { _ = reducer.reduce(into: &$0, action: $1) }, over: .sessions(from: DetailsState(), actions: tabActions, upTo: 2)
        ) {
            Always("the index is never negative") { $0.selectedTabIndex >= 0 }
        }
    }
}
