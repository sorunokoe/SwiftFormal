public import SwiftFormal

#if compiler(>=6.1)
    public import Testing
#endif

/// The budget and `allowBounded` that every `Prove` uses when the call does not pass its own.
///
/// Set them for a whole suite or one test with the ``WalkDefaultsTrait`` trait (Swift 6.1 or newer), for example an exhaustive budget on
/// CI and a sampled one locally:
///
/// ```swift
/// @Suite(.swiftFormal(budget: Budget(maxEvaluations: 50_000), allowBounded: true))
/// struct PricingTests { ... }
/// ```
///
/// An argument written at the call wins. The values are task-local; `Prove(neverTraps:)` reads them in the test and passes them to its
/// child process.
public enum WalkDefaults {
    /// The budget a `Prove` uses when the call passes none. `Budget.default` unless a trait sets it.
    @TaskLocal public static var budget: Budget = .default

    /// Whether a `Prove` accepts a `bounded` verdict (with a warning) when the call does not say. `false` unless a
    /// trait sets it.
    @TaskLocal public static var allowBounded = false
}

#if compiler(>=6.1)
    /// A trait that sets ``WalkDefaults`` for a suite (and every test in it) or for one test.
    ///
    /// Create it with `.swiftFormal(budget:allowBounded:)`. Test scoping traits need Swift 6.1 or newer.
    public struct WalkDefaultsTrait: TestTrait, SuiteTrait, TestScoping {
        /// The budget for calls that pass none, or `nil` to keep the surrounding one.
        public var budget: Budget?
        /// Whether calls that do not say accept a `bounded` verdict, with a warning.
        public var allowBounded: Bool

        /// Applies to every test in a suite, also in nested suites.
        public var isRecursive: Bool { true }

        /// Runs `function` with ``WalkDefaults`` set from this trait.
        public func provideScope(
            for test: Test,
            testCase: Test.Case?,
            performing function: @Sendable () async throws -> Void
        ) async throws {
            try await WalkDefaults.$budget.withValue(budget ?? WalkDefaults.budget) {
                try await WalkDefaults.$allowBounded.withValue(allowBounded) {
                    try await function()
                }
            }
        }
    }

    extension Trait where Self == WalkDefaultsTrait {
        /// Sets the default budget, and whether a `bounded` verdict is accepted, for `Prove` calls that do not pass
        /// their own. With `allowBounded: true`, a bounded verdict is a warning instead of a failure.
        public static func swiftFormal(budget: Budget? = nil, allowBounded: Bool = false) -> Self {
            WalkDefaultsTrait(budget: budget, allowBounded: allowBounded)
        }
    }
#endif
