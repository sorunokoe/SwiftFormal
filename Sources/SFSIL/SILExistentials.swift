import Foundation

// Existentials (`any AnalyticsManager`, `any Error`) as values. Logic never looks inside one: opening it to call a
// requirement (`open_existential_addr`, `witness_method` on an opened type) is rejected, like calling a closure. It can
// still be stored, copied, passed and destroyed. Destroying it destroys the value inside, which can run the deinit of
// an object of a read module, so existentials follow the closure rule: refused when such a deinit runs code.

extension TypeContext {
    /// The layout of every existential value: one opaque handle.
    static let existential = ValueType.opaque(name: "existential")

    /// True for an existential value type: `any P`, `any P & Q`, `any P<A>`. Existential metatypes (`any P.Type`) and
    /// types opened from an existential (`@opened(…) Self`) are not existential values.
    static func isExistential(_ t: String) -> Bool {
        t.hasPrefix("any ") && !t.hasSuffix(".Type") && !t.hasSuffix(".Protocol")
    }

    /// The handle for an existential value type; nil for any other type.
    func existentialType(_ t: String) throws(SILError) -> ValueType? {
        guard Self.isExistential(t) else { return nil }
        return try heldUnlessDeinitsRunCode(t, Self.existential)
    }
}
