// Walk entry points that left the public API. A test walks with `Prove` (SwiftFormalTesting); app code marks the
// function `@Verify`. Each name a pre-release user may have written stays as an unavailable declaration, so the compiler says
// what to write instead. None of them can be called.

/// Removed: walk in a test with `Prove` from SwiftFormalTesting, or mark the function `@Verify`.
@_documentation(visibility: internal)
@available(
    *, unavailable,
    message: "walk in a test with Prove(it: function, over: domain) { properties } from SwiftFormalTesting, or mark the function @Verify"
)
public func verify<Input, Output>(
    _ subject: String = "function",
    _ function: @escaping (Input) throws -> Output,
    over domain: Domain<Input>,
    budget: Budget = .default,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] },
    assuming: ((Input) -> Bool)? = nil
) -> Report {
    fatalError("unavailable")
}

/// Removed: walk in a test with `Prove` from SwiftFormalTesting, or mark the function `@Verify`.
@_documentation(visibility: internal)
@available(
    *, unavailable,
    message: "walk in a test with Prove(it: function) { properties } from SwiftFormalTesting, or mark the function @Verify"
)
public func verify<Input: Finite, Output>(
    _ subject: String = "function",
    _ function: @escaping (Input) throws -> Output,
    budget: Budget = .default,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] }
) -> Report {
    fatalError("unavailable")
}

/// Removed: mark the function `@Verify`, which writes `verify_<name>()`, or walk it in a test with `Prove`.
@_documentation(visibility: internal)
@available(
    *, unavailable,
    message:
        "mark the function @Verify with #requires and #ensures (it writes verify_<name>()), or walk it in a test with Prove(it: function, over: domain) { properties }"
)
public func verifyContracts<Input, Output>(
    _ subject: String = "function",
    _ function: @escaping (Input) throws -> Output,
    over domain: Domain<Input>,
    budget: Budget = .default,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] },
    requires: ((Input) -> Bool)? = nil
) -> Report {
    fatalError("unavailable")
}

/// Removed: state what the outputs must be in a test, with `Prove` and `Matches(table:)` or `Outputs(exactly:)`.
@_documentation(visibility: internal)
@available(
    *, unavailable,
    message: "state what the outputs must be in a test: Prove(it: function, over: domain) { Matches(table: ...) } from SwiftFormalTesting"
)
public func partition<Input, Output: Equatable>(
    _ function: (Input) throws -> Output,
    over domain: Domain<Input>,
    limit: Int = 100_000
) -> Never {
    fatalError("unavailable")
}

/// Removed: state what the outputs must be in a test, with `Prove` and `Matches(table:)` or `Outputs(exactly:)`.
@_documentation(visibility: internal)
@available(
    *, unavailable,
    message: "state what the outputs must be in a test: Prove(it: function, over: domain) { Matches(table: ...) } from SwiftFormalTesting"
)
public func partition<Input, Output: Hashable>(
    _ function: (Input) throws -> Output,
    over domain: Domain<Input>,
    limit: Int = 100_000
) -> Never {
    fatalError("unavailable")
}
