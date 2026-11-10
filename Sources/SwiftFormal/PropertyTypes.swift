// The built-in properties as types, so a builder reads like SwiftUI:
//
//     Prove(it: { SurfaceTextRule(input: $0).execute() }, over: .allCases) {
//         Deterministic()
//         Matches(table: [.grass: "Grass", .sand: "Sand"])
//         Satisfies("never empty") { _, text in !text.isEmpty }
//     }
//
// Inside `Prove` the builder fixes `Input` and `Output`, so no type is written.
// Each type wraps the matching `Property` factory (`Matches(table:)` is `Property.table`), and both forms can be mixed.
// No type here has the name of a SwiftUI, Foundation, Combine, Observation or UIKit type, so an app file can import
// SwiftUI next to SwiftFormal: the pre-release `Table` (SwiftUI's `Table`) is `Matches(table:)` now, and the old spelling is
// left only in SwiftFormalTesting.

/// A value that stands for one property, so it can be written directly in a property builder.
///
/// Conform your own types to name a property you use in many walks:
///
/// ```swift
/// struct NeverEmpty<Input>: PropertyConvertible {
///     var property: Property<Input, String> { .satisfies("never empty") { _, text in !text.isEmpty } }
/// }
/// ```
public protocol PropertyConvertible<Input, Output> {
    /// The input of the function under test.
    associatedtype Input
    /// The output of the function under test.
    associatedtype Output
    /// The property this value stands for.
    var property: Property<Input, Output> { get }
}

extension PropertyBuilder {
    /// Turns a property written as a type (`Matches(table: [...])`, `Deterministic()`) into a part.
    public static func buildExpression<Convertible: PropertyConvertible>(_ value: Convertible) -> Part
    where Convertible.Input == Input, Convertible.Output == Output {
        [value.property]
    }
}

/// Evaluating the function twice on the same input gives the same output. See `Property.deterministic()`.
public struct Deterministic<Input, Output: Equatable>: PropertyConvertible {
    /// The property this value stands for.
    public let property: Property<Input, Output>

    /// Checks that a second evaluation of every input gives the same output.
    public init() { property = .deterministic() }
}

/// The function agrees with an oracle on every input. See `Property.matches(_:)`.
public struct Matches<Input, Output: Equatable>: PropertyConvertible {
    /// The property this value stands for.
    public let property: Property<Input, Output>

    /// Checks every output against `oracle`: an independent statement of the mapping, or the previous version.
    public init(_ oracle: @escaping (Input) throws -> Output) { property = .matches(oracle) }

    /// Checks every output against `oracle`; `name` is used in the report.
    public init(_ name: String, _ oracle: @escaping (Input) throws -> Output) { property = .matches(name, oracle) }
}

extension Matches where Input: Equatable {
    /// A golden table written as `input: output` rows that must cover the whole domain: every output is checked against
    /// its row, and an input with no row is a failure, so a new enum case needs a row. See `Property.table(_:)`.
    ///
    /// ```swift
    /// Matches(table: [.grass: "Grass", .sand: "Sand"])
    /// ```
    public init(table rows: KeyValuePairs<Input, Output>) { property = .table(rows) }
}

extension Matches where Input: Hashable {
    /// A golden table, as `init(table:)` for `Equatable` inputs, with each input's row found by hashing.
    public init(table rows: KeyValuePairs<Input, Output>) { property = .table(rows) }
}

/// Different inputs never give the same output. See `Property.injective()`.
public struct Injective<Input, Output: Hashable>: PropertyConvertible {
    /// The property this value stands for.
    public let property: Property<Input, Output>

    /// Checks that no two different inputs give the same output.
    public init() { property = .injective() }
}

/// The outputs stay inside a set, or are exactly that set. See `Property.image(equals:)` and `Property.image(within:)`.
public struct Outputs<Input, Output: Hashable>: PropertyConvertible {
    /// The property this value stands for.
    public let property: Property<Input, Output>

    /// Every output is in `allowed`; members may go unreached.
    public init(within allowed: Set<Output>) { property = .image(within: allowed) }

    /// The outputs are exactly `expected`: nothing outside it, and every member reached when the whole domain is walked.
    public init(exactly expected: Set<Output>) { property = .image(equals: expected) }
}

/// An inverse maps every output back to its input. See `Property.roundTrip(through:)`.
public struct RoundTrip<Input: Equatable, Output>: PropertyConvertible {
    /// The property this value stands for.
    public let property: Property<Input, Output>

    /// Checks that `inverse(output) == input` for every input.
    public init(through inverse: @escaping (Output) throws -> Input) { property = .roundTrip(through: inverse) }
}

/// A predicate over each input and its output. See `Property.satisfies(_:_:)`.
public struct Satisfies<Input, Output>: PropertyConvertible {
    /// The property this value stands for.
    public let property: Property<Input, Output>

    /// Checks `predicate(input, output)` for every input; `name` says what it means in the report.
    public init(_ name: String, _ predicate: @escaping (Input, Output) -> Bool) { property = .satisfies(name, predicate) }

    /// Whenever `precondition` holds for the input, `predicate` holds for the output.
    public init(_ name: String, when precondition: @escaping (Input) -> Bool, then predicate: @escaping (Output) -> Bool) {
        property = .satisfies(name, when: precondition, then: predicate)
    }
}
