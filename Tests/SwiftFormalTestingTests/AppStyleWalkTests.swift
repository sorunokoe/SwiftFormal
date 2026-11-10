import SwiftFormal
import SwiftFormalTesting
import Testing

// Three walks from a real iOS app, rewritten in the DSL on toy types with the same shape (no app code here). Each one
// was a page of harness before: a step enum with descriptions, a session struct and its domain, an outcome struct and
// a run function for the sessions; an exit test, a confirmation exit test and `withKnownIssue` for the trap; and
// `partition`, a loop of prints and an `#expect` on the list for the translations.

// MARK: - The toy app

private enum EventKind: CaseIterable { case unknown, multiStage, knockout }

private struct EventDetailsStore {
    struct State {
        var kind = EventKind.unknown
        var selectedTabIndex = 0
        var tabs: [String] { kind == .multiStage ? ["Overview", "Ranking", "Stages"] : ["Overview", "Ranking"] }
        var selectedTab: String { tabs[selectedTabIndex] }
    }

    enum Action {
        case changeKind(EventKind)
        case tabSelected(Int)
        case viewRanking
        case retry
    }

    struct Effect {}

    func reduce(into state: inout State, action: Action) -> Effect {
        switch action {
        case .changeKind(let kind):
            state.kind = kind
            state.selectedTabIndex = min(state.selectedTabIndex, state.tabs.count - 1)
        case .tabSelected(let index): state.selectedTabIndex = index
        case .viewRanking: state.selectedTabIndex = 1
        case .retry: break
        }
        return Effect()
    }
}

/// `BoundLabelRule.formattedBound`: `Int(…)` traps for a value out of range, infinity and NaN.
private func boundLabel(_ input: Double) -> String {
    let prefix = input < 0 ? "+" : ""
    let scaled = Int((abs(input) * 10.0).rounded())
    return "\(prefix)\(scaled / 10).\(scaled % 10)"
}

private let english = ["moved": "%@ moved to the archive", "count": "%d items"]
private let translations = [
    "de": ["moved": "%@ ins Archiv verschoben", "count": "%d Elemente"],
    "zh-Hant": ["moved": "%1$d %2$d 已移至封存", "count": "%d 個項目"],
]

private struct KeyInLanguage: CustomStringConvertible {
    let key: String
    let language: String
    var description: String { "\(language): \(key)" }
}

private func localized(_ input: KeyInLanguage) -> String { translations[input.language]?[input.key] ?? input.key }

private func formatArguments(_ text: String) -> [Character] {
    var found: [Character] = []
    var rest = Substring(text)
    while let percent = rest.firstIndex(of: "%") {
        rest = rest[rest.index(after: percent)...].drop { $0.isNumber || $0 == "$" }
        if let letter = rest.first { found.append(letter) }
    }
    return found
}

// MARK: - The walks

/// What the event screen can send that touches the tabs.
private let tabActions = Domain<EventDetailsStore.Action>.union(
    Domain<EventKind>.allCases.map(EventDetailsStore.Action.changeKind),
    Domain.int(0...2).map(EventDetailsStore.Action.tabSelected),
    .of([.viewRanking, .retry]))

private let reducer = EventDetailsStore()

/// Every value the server sends, and the ones a `Double` can hold that it never sends.
enum BoundLabel: ExitTestWalk {  // internal: the child process finds it by name
    static let inputs: Domain<Double> = .of([0, 15, -5, 54, -10, 36.4, 9.2e17, 1e18, .infinity, -.infinity, .nan])
    static func call(_ input: Double) -> String { boundLabel(input) }
}

private let allKeysInAllLanguages: Domain<KeyInLanguage> = .of(
    translations.keys.sorted().flatMap { language in english.keys.sorted().map { KeyInLanguage(key: $0, language: language) } })

@MainActor
@Suite("Formal: the app's walks in the DSL")
struct AppStyleWalkTests {
    @Test("event details: every sequence of up to 4 tab events keeps the selected tab on screen")
    func selectedTabNeverOutOfRange() {
        Prove(
            "EventDetailsStore.reduce(into:action:)",
            it: { state, action in
                // The tab control sends only the index of a tab it drew.
                if case .tabSelected(let index) = action, !state.tabs.indices.contains(index) { return }
                _ = reducer.reduce(into: &state, action: action)
            },
            over: .sessions(from: EventDetailsStore.State(), actions: tabActions, upTo: 4)
        ) {
            Always("the selected tab is on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
        }
    }

    @Test("bound label: no Double the type can hold traps")
    func boundLabelTraps() async {
        await Prove(
            neverTraps: BoundLabel.self,
            knownIssue: KnownFailure("Int((abs(x) * 10).rounded()) traps for |x| ≥ 9.3e17, ±infinity and NaN", inputs: [1e18]))
    }

    @Test("every key in every language takes the same format arguments as English")
    func everyFormatMismatch() {
        Prove(
            "localized(_:)", it: localized, over: allKeysInAllLanguages, reporting: .everyFailure,
            knownIssue: KnownFailure("zh-Hant takes %1$d %2$d; English takes one object", failingInputs: ["zh-Hant: moved"])
        ) {
            Satisfies("the same format arguments as English") { input, shown in
                formatArguments(shown) == formatArguments(english[input.key] ?? "")
            }
        }
    }
}
