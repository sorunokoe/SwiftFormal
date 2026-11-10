/// A statement about a function `(Input) throws -> Output`, checked while a walk goes over the domain.
///
/// A property sees each `(input, output)` pair and may also see the end of the walk. It returns a
/// failure message for the first violation; the walk turns that into a counterexample.
public struct Property<Input, Output> {
    /// The name shown in reports.
    public let name: String
    let makeObserver: () -> Observer

    /// Calls the function under test again, for properties that need a second evaluation.
    @_spi(Extending) public typealias Evaluate = (Input) throws -> Output

    /// The per-run state of a property. `makeObserver` creates a fresh one for every walk.
    @_spi(Extending) public struct Observer {
        let observe: (Input, Output, Evaluate) -> String?
        let finish: (_ walkedWholeDomain: Bool) -> String?
        /// The observer calls `evaluate` once more on the same input (`deterministic`). The parallel walk then makes
        /// that second call on the worker thread, right after the first, and hands the observer its result.
        var reevaluatesOnce = false

        /// - Parameters:
        ///   - observe: Called for each input with its output. Return a message to fail.
        ///   - finish: Called once after the walk. Only properties that say "something must happen"
        ///     (for example, every expected output appears) can fail here, and only when
        ///     `walkedWholeDomain` is true.
        @_spi(Extending) public init(
            observe: @escaping (Input, Output, Evaluate) -> String?,
            finish: @escaping (_ walkedWholeDomain: Bool) -> String? = { _ in nil }
        ) {
            self.observe = observe
            self.finish = finish
        }
    }

    /// A property that keeps state across inputs.
    @_spi(Extending) public static func custom(_ name: String, makeObserver: @escaping () -> Observer) -> Property {
        Property(name: name, makeObserver: makeObserver)
    }

    /// A property decided one input at a time. Return a message to fail.
    public static func perInput(_ name: String, _ check: @escaping (Input, Output) -> String?) -> Property {
        custom(name) { Observer(observe: { input, output, _ in check(input, output) }) }
    }
}

/// Collects the properties written in the trailing closure of a `Prove`.
@resultBuilder
public enum PropertyBuilder<Input, Output> {
    /// The properties produced by one statement of the closure.
    public typealias Part = [Property<Input, Output>]

    /// Turns one property into a part.
    public static func buildExpression(_ property: Property<Input, Output>) -> Part { [property] }
    /// Joins the parts of a closure body.
    public static func buildBlock(_ parts: Part...) -> Part { parts.flatMap { $0 } }
    /// Joins the parts produced by a `for` loop.
    public static func buildArray(_ parts: [Part]) -> Part { parts.flatMap { $0 } }
    /// Joins the part of an `if` without `else`, or nothing.
    public static func buildOptional(_ part: Part?) -> Part { part ?? [] }
    /// Takes the part of the first branch of an `if`/`else`.
    public static func buildEither(first part: Part) -> Part { part }
    /// Takes the part of the second branch of an `if`/`else`.
    public static func buildEither(second part: Part) -> Part { part }
}
