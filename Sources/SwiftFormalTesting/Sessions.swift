public import SwiftFormal
public import Testing

/// A start state and the actions sent from it, in order: one input of a session walk.
///
/// It prints as the actions joined by arrows (`tabSelected(2) → retry`), or `(no actions)`, so a failing session reads
/// as the steps that lead to the failure. When the walk starts from more than one state, the start comes first
/// (`from State(…): tabSelected(2)`).
public struct Session<State, Action>: CustomStringConvertible {
    /// The state before the first action.
    public let start: State
    /// The actions, in the order they are sent.
    public let actions: [Action]
    let showsStart: Bool

    /// The actions joined by arrows, after the start state when the walk has several.
    public var description: String {
        let steps = actions.isEmpty ? "(no actions)" : actions.map(readableDescription).joined(separator: " → ")
        return showsStart ? "from \(readableDescription(start)): \(steps)" : steps
    }
}

/// `String(describing:)` without the module and type names Swift prints for an enum case in a payload:
/// `changeKind(.multiStage)`, not `changeKind(MyApp.Kind.multiStage)`, and `present(Data(…))`, not
/// `present(MyApp.Data(…))`. A type's own `description` is kept as it is, and so is the text of a string.
func readableDescription<Value>(_ value: Value) -> String {
    if let custom = value as? any CustomStringConvertible { return custom.description }
    let text = Array(String(describing: value))
    var out = ""
    var index = 0
    while index < text.count {
        if text[index] == "\"" {
            let end = closingQuote(in: text, from: index)
            out += String(text[index...end])
            index = end + 1
            continue
        }
        guard text[index].isUppercase, index == 0 || !isNamePart(text[index - 1]) else {
            out.append(text[index])
            index += 1
            continue
        }
        var parts: [String] = []
        var end = index
        while let part = qualifiedPart(in: text, at: end) {
            parts.append(part)
            end += part.count
            guard end < text.count, text[end] == ".", end + 1 < text.count else { break }
            guard text[end + 1].isLetter || text[end + 1] == "_" || text[end + 1] == "(" else { break }
            end += 1
        }
        let names = parts.filter { !$0.hasPrefix("(") }
        if names.count >= 2, let last = names.last {
            out += last.first?.isLowercase == true || last.first == "_" ? "." + last : last
        } else {
            out += String(text[index..<end])
        }
        index = max(end, index + 1)
    }
    return out
}

private func isNamePart(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "_" }

/// A name, or the `(unknown context at $…)` Swift prints for a private type, starting at `index`.
private func qualifiedPart(in text: [Character], at index: Int) -> String? {
    guard index < text.count else { return nil }
    if text[index] == "(" {
        let marker = Array("(unknown context at ")
        guard text.count >= index + marker.count, Array(text[index..<index + marker.count]) == marker,
            let close = text[index...].firstIndex(of: ")")
        else { return nil }
        return String(text[index...close])
    }
    var end = index
    while end < text.count, isNamePart(text[end]) { end += 1 }
    return end > index ? String(text[index..<end]) : nil
}

/// The index of the quote that closes the string starting at `start`, or the last index.
private func closingQuote(in text: [Character], from start: Int) -> Int {
    var index = start + 1
    while index < text.count {
        if text[index] == "\\" {
            index += 2
            continue
        }
        if text[index] == "\"" { return index }
        index += 1
    }
    return text.count - 1
}

/// Every state a session went through: the start, then the state after each action.
public struct SessionRun<State, Action> {
    /// `states[0]` is the start; `states[i]` is the state after `actions[i - 1]`.
    public let states: [State]

    /// The state after the last action.
    public var finalState: State { states[states.count - 1] }
}

/// A statement about every state of a session: the start and the state after each action.
///
/// ```swift
/// Always("the selected tab is on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
/// ```
public struct Always<State, Action>: PropertyConvertible {
    /// The property this value stands for.
    public let property: Property<Session<State, Action>, SessionRun<State, Action>>

    /// Checks `holds` on the start state and after every action; `name` says what it means in the report.
    public init(_ name: String, _ holds: @escaping (State) -> Bool) {
        property = .perInput(name) { session, run in
            guard let index = run.states.firstIndex(where: { !holds($0) }) else { return nil }
            return index == 0
                ? "fails in the start state" : "fails after action \(index) (\(readableDescription(session.actions[index - 1])))"
        }
    }
}

/// A statement about every step of a session: the state before an action, the action, and the state after it.
///
/// ```swift
/// EachStep("a tap never selects more than 13 clubs") { before, action, after in after.selected.count <= 13 }
/// ```
public struct EachStep<State, Action>: PropertyConvertible {
    /// The property this value stands for.
    public let property: Property<Session<State, Action>, SessionRun<State, Action>>

    /// Checks `holds(before, action, after)` for every action of every session.
    public init(_ name: String, _ holds: @escaping (_ before: State, _ action: Action, _ after: State) -> Bool) {
        property = .perInput(name) { session, run in
            for (index, action) in session.actions.enumerated() where !holds(run.states[index], action, run.states[index + 1]) {
                return "fails at action \(index + 1) (\(readableDescription(action)))"
            }
            return nil
        }
    }
}

extension Domain {
    /// Every session of up to `maxActions` actions from `start`: every sequence of `actions`, shortest first, so a failing
    /// session in a report is a shortest one. `n` actions give `1 + n + n² + … + n^maxActions` sessions.
    ///
    /// Walk it with `Prove(it: step, over: .sessions(from: start, actions: actions, upTo: 4)) { … }`, where `step` sends
    /// one action to the state.
    public static func sessions<State, Action>(from start: State, actions: Domain<Action>, upTo maxActions: Int) -> Domain
    where Value == Session<State, Action> {
        sessionDomain(from: .just(start), actions: actions, upTo: maxActions)
    }

    /// Every session of up to `maxActions` actions from every state of `starts`: a screen that opens with data from a
    /// server, or with any number of items selected. A failing session then names its start state.
    public static func sessions<State, Action>(from starts: Domain<State>, actions: Domain<Action>, upTo maxActions: Int)
        -> Domain where Value == Session<State, Action>
    {
        sessionDomain(from: starts, actions: actions, upTo: maxActions)
    }
}

/// Every session of up to `maxActions` actions from each state of `starts`, shortest first.
private func sessionDomain<State, Action>(from starts: Domain<State>, actions: Domain<Action>, upTo maxActions: Int)
    -> Domain<Session<State, Action>>
{
    let showsStart = starts.count > 1
    return Domain.product(starts, Domain.arrays(of: actions, maxLength: maxActions)).map {
        Session(start: $0.0, actions: $0.1, showsStart: showsStart)
    }
}

extension Prove {
    /// Walks every session of `sessions`, sending each action with `step`, and records a test issue unless every
    /// property holds after every step.
    ///
    /// `step` sends one action. For a TCA reducer that is `{ _ = reducer.reduce(into: &$0, action: $1) }`; effects are
    /// not run, so an answer the reducer waits for is an action of its own. An action that cannot happen in some state (a
    /// tap on a tab that is not shown) is skipped in `step` with an early `return`.
    ///
    /// ```swift
    /// @Test func selectedTabStaysOnScreen() {
    ///     Prove(it: { _ = TabsReducer().reduce(into: &$0, action: $1) },
    ///           over: .sessions(from: TabsState(), actions: tabActions, upTo: 4)) {
    ///         Always("the selected tab is on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
    ///     }
    /// }
    /// ```
    ///
    /// `swiftformal check` reads the function under test from the `it:` closure, as for any `Prove`:
    /// `TabsReducer.reduce(into:action:)` here, `State.send(_:)` for `{ $0.send($1) }` (`$0` is the state), and for
    /// `reducer.reduce(…)` the type `reducer` is created with in the test sources (`let reducer = TabsReducer()`; a written type
    /// alone, `let reducer: Base`, is only the static type and links nothing). Pass a subject
    /// (`Prove("TabsReducer.reduce(into:action:)", it: …)`) when the closure does not start with that call.
    ///
    /// - Parameters:
    ///   - subject: The name in the report and the function `swiftformal check` links the walk to. By default the
    ///     check reads it from the `it:` closure, and the report uses the test's name.
    ///   - step: Sends one action to the state.
    ///   - sessions: The sessions to walk: `.sessions(from:actions:upTo:)`.
    ///   - budget: The most sessions to run before the verdict is only `bounded`.
    ///   - allowBounded: Accept "no failing session found" when the sessions do not fit the budget.
    ///   - reporting: `.everyFailure` lists every failing session in the issue and in ``failures``.
    ///   - knownIssue: A failure the test expects; the test then fails when the walk passes.
    ///   - sourceLocation: Where the issues and the walk's record are placed: the call.
    ///   - properties: What must hold: ``Always`` for every state, ``EachStep`` for every step, `Satisfies` for a whole
    ///     session and its run.
    @discardableResult
    public init<State, Action>(
        _ subject: String? = nil,
        it step: @escaping (inout State, Action) throws -> Void,
        over sessions: Domain<Session<State, Action>>,
        budget: Budget = WalkDefaults.budget,
        allowBounded: Bool = WalkDefaults.allowBounded,
        reporting: FailureReporting = .firstFailure,
        knownIssue: KnownFailure? = nil,
        sourceLocation: SourceLocation = #_sourceLocation,
        @PropertyBuilder<Session<State, Action>, SessionRun<State, Action>> properties: () -> [Property<
            Session<State, Action>, SessionRun<State, Action>
        >] = { [] }
    ) where Input == Session<State, Action>, Output == SessionRun<State, Action> {
        let run = { (session: Session<State, Action>) throws -> SessionRun<State, Action> in
            var state = session.start
            var states = [state]
            states.reserveCapacity(session.actions.count + 1)
            for action in session.actions {
                try step(&state, action)
                states.append(state)
            }
            return SessionRun(states: states)
        }
        // `$0` in `step` is the state, so `check` reads `$0.send` as a member of `State`.
        self.init(
            walking: Self.subject(subject), run, over: sessions, budget: budget, allowBounded: allowBounded, reporting: reporting,
            knownIssue: knownIssue, sourceLocation: sourceLocation, inputType: State.self, properties: properties)
    }
}
