/// A type whose complete set of values can be listed. This is what lets `Prove` find the input
/// space from a function's signature alone.
///
/// Type-driven design pays off here: the more a type rules out invalid values, the smaller the
/// domain, and the fewer `#requires` a function needs. Every `CaseIterable` type has a sampled `domain`
/// without conforming (see `CaseIterable.domain`); conforming to `Finite` claims that `allCases` is
/// complete, so walks over it can prove, and lets `Prove` leave out `over:`.
///
/// ```swift
/// struct Percent: Finite {
///     let rawValue: Int
///     init?(_ rawValue: Int) { guard (0 ... 100).contains(rawValue) else { return nil }; self.rawValue = rawValue }
///     static var domain: Domain<Percent> { Domain.int(0 ... 100).map { Percent($0)! } }
/// }
/// ```
public protocol Finite {
    static var domain: Domain<Self> { get }
}

extension Finite where Self: CaseIterable {
    /// Every case of the enum.
    public static var domain: Domain<Self> { .allCases }
}

extension CaseIterable {
    /// Every value `allCases` lists, as a sample, so `@Finite` fields and walks take an enum from another module,
    /// even a binary framework, without `extension X: Finite {}`. A `Finite` conformance's own domain wins over this one.
    ///
    /// Nothing proves a `CaseIterable` type's `allCases` complete: a hand-written one may leave values out. Walks over
    /// this domain are therefore `bounded`, never `proved`. Conform to `Finite` to claim the list is complete, or
    /// walk a domain `sfgen domains` generated, which checks `allCases` against the cases the compiler knows.
    public static var domain: Domain<Self> { .samples(Array(allCases)) }
}

extension Bool: Finite {
    /// Both Boolean values.
    public static var domain: Domain<Bool> { .bool }
}

extension UInt8: Finite {
    /// Every `UInt8` value, 0 through 255.
    public static var domain: Domain<UInt8> { Domain.int(0...255).map { UInt8($0) } }
}

extension Int8: Finite {
    /// Every `Int8` value, -128 through 127.
    public static var domain: Domain<Int8> { Domain.int(-128...127).map { Int8($0) } }
}

extension Optional: Finite where Wrapped: Finite {
    /// `nil` and every value of `Wrapped`.
    public static var domain: Domain<Wrapped?> { .optional(Wrapped.domain) }
}

extension Optional where Wrapped: CaseIterable {
    /// `nil` and the values `Wrapped.allCases` lists, as a sample (see `CaseIterable.domain`), for an optional
    /// field whose type is `CaseIterable` but not `Finite`.
    public static var domain: Domain<Wrapped?> { .optional(Wrapped.domain) }
}

extension Optional where Wrapped: CaseIterable & Finite {
    /// `nil` and `Wrapped`'s own `Finite` domain. This only breaks the tie between the two extensions above.
    public static var domain: Domain<Wrapped?> { .optional(Wrapped.domain) }
}

/// Walks `function` over every value of its `Finite` input type (`package`: users write `Prove`).
package func runWalk<Input: Finite, Output>(
    _ subject: String = "function",
    _ function: @escaping (Input) throws -> Output,
    budget: Budget = .default,
    @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] }
) -> Report {
    runWalk(subject, function, over: Input.domain, budget: budget, properties: properties)
}
