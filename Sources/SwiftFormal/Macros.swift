// The macros of `import SwiftFormal`: `@Verify`, `#requires`, `#ensures`, `@Finite` and `@Values`. They are written
// by `SwiftFormalMacros`, a compiler plugin: it runs while the app builds and is never linked into it.

/// Marks a function, or a computed property, whose `#requires` and `#ensures` statements are its contract.
///
/// - The body runs the contract as `Contract` checks, in builds that define `DEBUG` (see ``ContractChecks``). A
///   broken contract is an `assertionFailure` there.
/// - Peers `<name>_requires` and `<name>_ensures` state the same contract as plain functions, in every build
///   configuration; Scan (`sfverify`) proves them on the compiled function, for every input.
/// - When there is something to walk, a peer `verify_<name>()` returns a `Report` from walking the input domain, in
///   every build configuration: with `over:`, or when no parameter is surely not `Finite` (`Bool`, an enum,
///   `@Finite` types). A function without parameters, a computed property, a `mutating` method, and a function
///   without `over:` that takes a `String`, an `Int`, an array, an `inout` value and the like get no walk: Scan proves
///   their contract. A parameter type the macro cannot judge from the source gets its `Finite` domain when it has one;
///   otherwise the walk checks nothing and is `bounded`, never `proved`.
///
/// A body of one expression needs no `return` after the contract lines, as without them.
///
/// ```swift
/// @Verify(over: .product(.int(0 ... 1_000), .int(0 ... 100)))
/// func discounted(price: Int, percent: Int) -> Int {
///     #requires(price >= 0 && price <= 1_000_000)
///     #requires(percent >= 0 && percent <= 100)
///     #ensures { $0 >= 0 && $0 <= price }
///     return price - price * percent / 100
/// }
///
/// #expect(verify_discounted().isProved)
/// ```
///
/// On a computed property, `@Verify` applies to its getter: write the getter's code in the braces, after the
/// contract. Scan proves `body_requires()` and `body_ensures(_:)` on the getter. A property with a setter takes
/// `@Verify` on its `get`; there it can add no peers, so Scan sees the contract only as the checks in the getter (a
/// warning says so).
///
/// ```swift
/// @Verify
/// var body: String {
///     #requires(!title.isEmpty)
///     #ensures { result in result.hasPrefix(title) }
///     title + "."
/// }
/// ```
///
/// On a `mutating` method, each `#ensures` closure also gets `self` from before the call, last; `self` inside it is
/// the value after the call. Scan proves the contract for every `self` and every input.
///
/// ```swift
/// @Verify
/// mutating func add(_ extra: UInt8) -> Bool {
///     #ensures { added, old in added == (count > old.count) }
///     guard extra <= UInt8.max - count else { return false }
///     count += extra
///     return extra > 0
/// }
/// ```
@attached(peer, names: prefixed(verify_), suffixed(_requires), suffixed(_ensures))
@attached(body)
public macro Verify<Value>(over: Domain<Value>) = #externalMacro(module: "SwiftFormalMacros", type: "VerifyMacro")

/// `@Verify` with the input domain, if any, taken from the parameter types: a walk when they are `Finite`, otherwise
/// only the contract Scan proves.
@attached(peer, names: prefixed(verify_), suffixed(_requires), suffixed(_ensures))
@attached(body)
public macro Verify() = #externalMacro(module: "SwiftFormalMacros", type: "VerifyMacro")

/// `@Verify(over:)` with a choice of the build configurations that compile the checks in the body.
///
/// ```swift
/// @Verify(over: .int(0 ... 100), checks: .always)
/// func percentText(_ value: Int) -> String { … }
/// ```
///
/// Write the choice as `.debugOnly` or `.always`: the macro reads it from the source.
@attached(peer, names: prefixed(verify_), suffixed(_requires), suffixed(_ensures))
@attached(body)
public macro Verify<Value>(over: Domain<Value>, checks: ContractChecks) =
    #externalMacro(module: "SwiftFormalMacros", type: "VerifyMacro")

/// `@Verify()` with a choice of the build configurations that compile the checks in the body.
///
/// Write the choice as `.debugOnly` or `.always`: the macro reads it from the source.
@attached(peer, names: prefixed(verify_), suffixed(_requires), suffixed(_ensures))
@attached(body)
public macro Verify(checks: ContractChecks) = #externalMacro(module: "SwiftFormalMacros", type: "VerifyMacro")

/// Which builds compile the contract checks that `@Verify` writes into a function's body.
///
/// `@Verify` writes each `#requires` as a check before the body and each `#ensures` as a check after it; a
/// `mutating` method whose `#ensures` reads the value before the call also copies `self` first. By default
/// (``debugOnly``) all of that is inside `#if DEBUG`, so a release build runs the function as written: no copy of
/// `self`, no check. What stays in every configuration:
///
/// - `verify_<name>()`, which checks each `#ensures` itself, so a walk in a release test build (`swift test -c
///   release`) finds the same broken contracts as in a debug one.
/// - `<name>_requires` and `<name>_ensures`, which Scan (`sfverify`) proves on the compiled function, at `-Onone` and
///   with `-O`.
public enum ContractChecks: Sendable {
    /// Compile the checks only where the module that uses `@Verify` defines the `DEBUG` compilation condition. The
    /// default.
    ///
    /// SwiftPM defines `DEBUG` in debug builds, and Xcode's default Debug configuration does
    /// (`SWIFT_ACTIVE_COMPILATION_CONDITIONS`). A configuration that does not, such as a custom one copied from
    /// Release, leaves the checks out even if it keeps assertions.
    case debugOnly
    /// Compile the checks in every configuration.
    ///
    /// A failing check still calls `assertionFailure`, which stops only builds that keep assertions (`-Onone`). Use
    /// this for a configuration that keeps assertions without defining `DEBUG`; in a `-O` build it only adds the cost
    /// of the checks and the copy of `self`.
    case always
}

/// Derives `Finite` for a struct or enum so `Prove` and `@Verify` find the input space from the type.
///
/// Structs: the product of the stored properties' domains. Enums: the union of the cases, each the product of
/// its payloads. Every property type must be `Finite`; `@Values` overrides one.
///
/// ```swift
/// @Finite struct Order {
///     @Values(.int(0 ... 3)) var quantity: Int
///     var express: Bool
/// }
/// ```
@attached(extension, conformances: Finite, names: named(domain))
public macro Finite() = #externalMacro(module: "SwiftFormalMacros", type: "FiniteMacro")

/// Replaces the domain `@Finite` takes from a stored property's type, for example to limit an `Int`.
@attached(peer)
public macro Values<Value>(_ domain: Domain<Value>) = #externalMacro(module: "SwiftFormalMacros", type: "ValuesMacro")

/// A precondition: callers must satisfy it. `@Verify` leaves inputs outside it out of the walk.
@freestanding(expression)
public macro requires(_ condition: Bool) = #externalMacro(module: "SwiftFormalMacros", type: "RequiresMacro")

/// A postcondition on the returned value, written as a closure: `#ensures { $0 >= 0 }`. In a `mutating` method the
/// closure also gets `self` from before the call: `#ensures { result, old in … }`, or `#ensures { old in … }` when
/// the method returns nothing.
@freestanding(expression)
public macro ensures<Output>(_ predicate: (Output) -> Bool) = #externalMacro(module: "SwiftFormalMacros", type: "EnsuresMacro")
