public import Foundation
public import SwiftFormal
public import Testing

// Names that walked before `Prove` became the one way to walk. Each one a pre-release user may have written stays as an
// unavailable declaration, so the compiler says what to write instead. None of them can be called.

/// Removed: `Prove` walks and records in one call.
@_documentation(visibility: internal)
@available(
    *, unavailable,
    message: "use Prove(it: function, over: domain) { properties }: it walks and records the result in one call"
)
public func expectProved(
    _ report: Report,
    allowBounded: Bool = WalkDefaults.allowBounded,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    fatalError("unavailable")
}

/// Removed: use `Prove(_:it:over:)`.
@_documentation(visibility: internal)
@available(*, unavailable, message: "use Prove(it: function, over: domain) { properties }")
@discardableResult
public func expectProved<Input, Output>(
    _ subject: String = "function",
    _ function: @escaping (Input) throws -> Output,
    over domain: Domain<Input>,
    budget: Budget = WalkDefaults.budget,
    allowBounded: Bool = WalkDefaults.allowBounded,
    reporting: FailureReporting = .firstFailure,
    knownIssue: KnownFailure? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] }
) -> Report {
    fatalError("unavailable")
}

/// Removed: use `Prove(_:it:)`.
@_documentation(visibility: internal)
@available(*, unavailable, message: "use Prove(it: function) { properties }")
@discardableResult
public func expectProved<Input: Finite, Output>(
    _ subject: String = "function",
    _ function: @escaping (Input) throws -> Output,
    budget: Budget = WalkDefaults.budget,
    allowBounded: Bool = WalkDefaults.allowBounded,
    reporting: FailureReporting = .firstFailure,
    knownIssue: KnownFailure? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] }
) -> Report {
    fatalError("unavailable")
}

/// Removed: use `Prove(it: step, over: .sessions(from: start, actions: actions, upTo: maxActions))`.
@_documentation(visibility: internal)
@available(
    *, unavailable,
    message: "use Prove(it: step, over: .sessions(from: start, actions: actions, upTo: maxActions)) { properties }"
)
@discardableResult
public func expectProved<State, Action>(
    _ subject: String,
    from start: State,
    actions: Domain<Action>,
    upTo maxActions: Int,
    budget: Budget = WalkDefaults.budget,
    allowBounded: Bool = WalkDefaults.allowBounded,
    knownIssue: KnownFailure? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    step: @escaping (inout State, Action) throws -> Void,
    @PropertyBuilder<Session<State, Action>, SessionRun<State, Action>> properties: () -> [Property<
        Session<State, Action>, SessionRun<State, Action>
    >] = { [] }
) -> Report {
    fatalError("unavailable")
}

/// Removed: use `Prove(it: step, over: .sessions(from: starts, actions: actions, upTo: maxActions))`.
@_documentation(visibility: internal)
@available(
    *, unavailable,
    message: "use Prove(it: step, over: .sessions(from: starts, actions: actions, upTo: maxActions)) { properties }"
)
@discardableResult
public func expectProved<State, Action>(
    _ subject: String,
    from starts: Domain<State>,
    actions: Domain<Action>,
    upTo maxActions: Int,
    budget: Budget = WalkDefaults.budget,
    allowBounded: Bool = WalkDefaults.allowBounded,
    knownIssue: KnownFailure? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    step: @escaping (inout State, Action) throws -> Void,
    @PropertyBuilder<Session<State, Action>, SessionRun<State, Action>> properties: () -> [Property<
        Session<State, Action>, SessionRun<State, Action>
    >] = { [] }
) -> Report {
    fatalError("unavailable")
}

/// Removed (pre-release name): use `Prove(_:it:over:)`.
@_documentation(visibility: internal)
@available(*, unavailable, message: "use Prove(it: function, over: domain) { properties }")
@discardableResult
public func prove<Input, Output>(
    _ subject: String = "function",
    _ function: @escaping (Input) throws -> Output,
    over domain: Domain<Input>,
    budget: Budget = WalkDefaults.budget,
    allowBounded: Bool = WalkDefaults.allowBounded,
    sourceLocation: SourceLocation = #_sourceLocation,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] }
) -> Report {
    fatalError("unavailable")
}

/// Removed (pre-release name): use `Prove(_:it:)`.
@_documentation(visibility: internal)
@available(*, unavailable, message: "use Prove(it: function) { properties }")
@discardableResult
public func prove<Input: Finite, Output>(
    _ subject: String = "function",
    _ function: @escaping (Input) throws -> Output,
    budget: Budget = WalkDefaults.budget,
    allowBounded: Bool = WalkDefaults.allowBounded,
    sourceLocation: SourceLocation = #_sourceLocation,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] }
) -> Report {
    fatalError("unavailable")
}

/// Removed: use `Prove(neverTraps:)`.
@_documentation(visibility: internal)
@available(*, unavailable, message: "use await Prove(neverTraps: Walk.self)")
@discardableResult
public func expectNoTrap<Walk: ExitTestWalk>(
    _ subject: String,
    _ walk: Walk.Type,
    budget: Budget = WalkDefaults.budget,
    allowBounded: Bool = WalkDefaults.allowBounded,
    knownIssue: KnownFailure? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Bool {
    fatalError("unavailable")
}

/// Removed: declare the function and its inputs in an `ExitTestWalk` type and use `Prove(neverTraps:)`.
@_documentation(visibility: internal)
@available(
    *, unavailable,
    message: "declare the function and its inputs in an ExitTestWalk type and use await Prove(neverTraps: Walk.self)"
)
public func walkInExitTest<Input, Output>(
    _ subject: String = "function",
    _ function: @escaping (Input) throws -> Output,
    over domain: Domain<Input>,
    budget: Budget = .default,
    allowBounded: Bool = false,
    sourceLocation: SourceLocation = #_sourceLocation,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] }
) {
    fatalError("unavailable")
}

/// Removed (pre-release name): the behaviour lock left the public API. State what must hold with `Prove`.
@_documentation(visibility: internal)
@available(
    *, unavailable,
    message: "the behaviour lock was removed; state what must hold: Prove(it: function, over: domain) { Matches(table: ...) }"
)
public func lockBehavior<Input, Output>(
    _ name: String,
    _ function: (Input) throws -> Output,
    over domain: Domain<Input>,
    maxInputs: Int = 100_000,
    file: StaticString = #filePath,
    directory: URL? = nil
) -> Never {
    fatalError("unavailable")
}

/// Removed (pre-release name): the behaviour lock left the public API. State what must hold with `Prove`.
@_documentation(visibility: internal)
@available(
    *, unavailable,
    message: "the behaviour lock was removed; state what must hold: Prove(it: function, over: domain) { Matches(table: ...) }"
)
public func expectLocked<Input, Output>(
    _ name: String,
    _ function: (Input) throws -> Output,
    over domain: Domain<Input>,
    maxInputs: Int = 100_000,
    file: StaticString = #filePath,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Never {
    fatalError("unavailable")
}

/// Removed (pre-release name): left with the behaviour lock.
@_documentation(visibility: internal)
@available(*, unavailable, message: "use String(describing:)")
public func describeOutput<Output>(_ value: Output) -> String {
    fatalError("unavailable")
}

/// Removed (pre-release name): SwiftUI declares `Table` too. Use `Matches(table:)`.
@_documentation(visibility: internal)
@available(*, unavailable, message: "use Matches(table:); SwiftUI also declares Table")
public struct Table<Input: Equatable, Output: Equatable> {
    /// Removed: use `Matches(table:)`.
    public init(_ rows: KeyValuePairs<Input, Output>) { fatalError("unavailable") }
}

/// Removed (pre-release name): SwiftUI declares `Image` too. Use `Outputs(exactly:)`.
@_documentation(visibility: internal)
@available(*, unavailable, message: "use Outputs(exactly:); SwiftUI also declares Image")
public func Image<Input, Output: Hashable>(equals expected: Set<Output>) -> Property<Input, Output> {
    fatalError("unavailable")
}

/// Removed (pre-release name): SwiftUI declares `Image` too. Use `Outputs(within:)`.
@_documentation(visibility: internal)
@available(*, unavailable, message: "use Outputs(within:); SwiftUI also declares Image")
public func Image<Input, Output: Hashable>(within allowed: Set<Output>) -> Property<Input, Output> {
    fatalError("unavailable")
}
