public import SwiftFormal

extension Domain {
    /// Every value of every domain in `parts`, one part after the other: an enum with payload cases, one part per case.
    ///
    /// ```swift
    /// let actions = Domain<TabsStore.Action>.union(
    ///     Domain.of(allKinds).map(TabsStore.Action.changeKind),
    ///     Domain.int(0...2).map(TabsStore.Action.tabSelected),
    ///     .of([.viewRanking, .retry]))
    /// ```
    ///
    /// A part whose values are not actions yet is written `Domain.int(…).map(…)`: `.int(…)` alone would look for `int`
    /// on the domain of actions.
    public static func union(_ parts: Domain...) -> Domain { union(parts) }

    /// The values of a table, each printed by its name in a report: a failing input reads `"cold day"`, not the
    /// value's whole description. Members of the value are read through the name: `$0.altitude`.
    ///
    /// ```swift
    /// let servers: Domain<NamedValue<Conditions>> = .named([
    ///     "metric default": Conditions(altitude: 0, temperature: 25, unit: .meters),
    ///     "cold day": Conditions(altitude: 120, temperature: -5, unit: .meters),
    /// ])
    /// ```
    public static func named<Named>(_ rows: KeyValuePairs<String, Named>) -> Domain where Value == NamedValue<Named> {
        .of(rows.map { NamedValue(name: $0.key, value: $0.value) })
    }
}

/// A value with the name a table gave it (`Domain.named(_:)`), printed as that name.
@dynamicMemberLookup
public struct NamedValue<Value>: CustomStringConvertible {
    /// The row's name.
    public let name: String
    /// The value itself.
    public let value: Value

    /// Creates a named value.
    public init(name: String, value: Value) {
        self.name = name
        self.value = value
    }

    /// The name.
    public var description: String { name }

    /// A member of the value: `row.altitude` reads `row.value.altitude`.
    public subscript<Member>(dynamicMember member: KeyPath<Value, Member>) -> Member { value[keyPath: member] }
}

extension NamedValue: Sendable where Value: Sendable {}
extension NamedValue: Equatable where Value: Equatable {}
extension NamedValue: Hashable where Value: Hashable {}
