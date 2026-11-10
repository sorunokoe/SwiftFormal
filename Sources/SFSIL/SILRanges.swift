import SFBV
import SFCNF

/// Swift's ranges of standard integers (`Range`, `ClosedRange` and the three partial ranges).
///
/// A range value is its stored bounds, so `struct_extract #Range.lowerBound` and the `struct $Range<Int>` the compiler
/// writes for an inlined `..<` work as for any struct. At `-Onone` the compiler inlines `..<`, `...` and
/// `Range.contains` (they are `@_transparent`); the calls that remain are answered exactly by `StdlibSummary.range`:
/// `ClosedRange.contains`, `~=` (also behind `case lo...hi:`), `isEmpty` and the partial-range initializers.
/// `Array.indices` is an array read (`0 ..< count`). Bounds of any other type are not modelled: `Range<Double>` is
/// rejected through `Double`, and a summary on a non-integer bound throws.
package enum RangeShape: Sendable, Hashable {
    case halfOpen, closed, from, through, upTo

    /// The stored properties, in declaration order.
    var fields: [String] {
        switch self {
        case .halfOpen, .closed: ["lowerBound", "upperBound"]
        case .from: ["lowerBound"]
        case .through, .upTo: ["upperBound"]
        }
    }

    private static let byName: [String: RangeShape] = [
        "Range": .halfOpen, "ClosedRange": .closed, "PartialRangeFrom": .from, "PartialRangeThrough": .through,
        "PartialRangeUpTo": .upTo,
    ]

    /// The shape of a range type name without arguments (`ClosedRange`).
    static func named(_ base: String) -> RangeShape? { byName[base.hasPrefix("Swift.") ? String(base.dropFirst(6)) : base] }

    /// The shape and bound type of a range type (`ClosedRange<UInt8>` gives `.closed`, `UInt8`).
    package static func of(_ text: String) -> (shape: RangeShape, bound: String)? {
        guard text.hasSuffix(">"), let open = text.firstIndex(of: "<"), let shape = named(String(text[..<open])) else { return nil }
        return (shape, String(text[text.index(after: open)..<text.index(before: text.endIndex)]))
    }

    /// Whether `value` is in a range of this shape with these bound leaves.
    func contains(_ value: BV, bounds: [BV], signed: Bool, in c: CNFBuilder) throws -> Int32 {
        guard bounds.count == fields.count else { throw SILError.invalid("a range with \(bounds.count) bounds") }
        let below = { (a: BV, b: BV) in signed ? c.slt(a, b) : c.ult(a, b) }
        switch self {
        case .halfOpen: return c.and(-below(value, bounds[0]), below(value, bounds[1]))
        case .closed: return c.and(-below(value, bounds[0]), -below(bounds[1], value))
        case .from: return -below(value, bounds[0])
        case .through: return -below(bounds[0], value)
        case .upTo: return below(value, bounds[0])
        }
    }
}

extension StdlibSummary {
    /// What a range call computes (`StdlibSummary.range`).
    package enum RangeOperation: Sendable, Hashable {
        /// `Range.contains(_:)`, `ClosedRange.contains(_:)`: the substitution is the bound type.
        case contains(RangeShape)
        /// `RangeExpression.~=`: the substitution is the range type.
        case patternMatch
        /// `Range.isEmpty` (`lowerBound == upperBound`), `ClosedRange.isEmpty` (never).
        case isEmpty(RangeShape)
        /// `PartialRangeFrom(_:)`, `PartialRangeThrough(_:)`, `PartialRangeUpTo(_:)`: the value is the bound.
        case make(RangeShape)
    }

    static func addRanges(to table: inout [String: Entry]) {
        func add(_ symbol: String, _ name: String, _ operation: RangeOperation) {
            table[symbol] = Entry(name: name, summary: .range(operation), isGeneric: true)
        }
        add("$sSn8containsySbxF", "Range.contains(_:)", .contains(.halfOpen))
        add("$sSN8containsySbxF", "ClosedRange.contains(_:)", .contains(.closed))
        add("$sSXsE2teoiySbx_5BoundQztFZ", "RangeExpression.~=", .patternMatch)
        add("$sSn7isEmptySbvg", "Range.isEmpty", .isEmpty(.halfOpen))
        add("$sSN7isEmptySbvg", "ClosedRange.isEmpty", .isEmpty(.closed))
        add("$ss16PartialRangeFromVyAByxGxcfC", "PartialRangeFrom.init(_:)", .make(.from))
        add("$ss19PartialRangeThroughVyAByxGxcfC", "PartialRangeThrough.init(_:)", .make(.through))
        add("$ss16PartialRangeUpToVyAByxGxcfC", "PartialRangeUpTo.init(_:)", .make(.upTo))
    }

    /// The Boolean result of a range test, from the values of its address arguments in order. Throws unless the
    /// bounds are a standard integer type.
    static func rangeTest(
        _ operation: RangeOperation, name: String, substitutions: [String], read: [[BV]], in c: CNFBuilder
    ) throws -> Int32 {
        guard substitutions.count == 1 else { throw SILError.unsupported("\(name) with <\(substitutions.joined(separator: ", "))>") }
        let substitution = substitutions[0]
        let query: RangeQuery
        switch operation {
        case .contains(let shape) where read.count == 2 && read[0].count == 1:
            query = RangeQuery(shape: shape, bound: substitution, bounds: read[1], value: read[0][0])
        case .isEmpty(let shape) where read.count == 1:
            query = RangeQuery(shape: shape, bound: substitution, bounds: read[0], value: nil)
        case .patternMatch where read.count == 2 && read[1].count == 1:
            guard let range = RangeShape.of(substitution) else {
                throw SILError.unsupported("\(name) on \(substitution), which is not a range")
            }
            query = RangeQuery(shape: range.shape, bound: range.bound, bounds: read[0], value: read[1][0])
        default: throw SILError.invalid("\(name) of unexpected shape")
        }
        guard let kind = integerKind(query.bound) else {
            throw SILError.unsupported("\(name) on bounds of type \(query.bound), which is not an integer")
        }
        if let value = query.value { return try query.shape.contains(value, bounds: query.bounds, signed: kind == .signed, in: c) }
        guard query.bounds.count == 2 else { throw SILError.invalid("\(name) of unexpected shape") }
        return query.shape == .closed ? c.falseLit : c.eq(query.bounds[0], query.bounds[1])
    }

    /// What a range test reads: the range's shape, bound type and bound leaves, and the value tested (if any).
    private struct RangeQuery {
        let shape: RangeShape
        let bound: String
        let bounds: [BV]
        let value: BV?
    }

    /// The stored bound of a partial range made from `read` (`PartialRangeFrom(5)` is `[5]`).
    static func partialRange(_ shape: RangeShape, name: String, subject: String?, read: [[BV]]) throws -> [BV] {
        guard let subject, integerKind(subject) != nil else {
            throw SILError.unsupported("\(name) on \(subject ?? "?"), which is not an integer")
        }
        guard read.count == 1, read[0].count == 1, shape.fields.count == 1 else { throw SILError.invalid("\(name) of unexpected shape") }
        return read[0]
    }
}

extension TypeContext {
    /// The declaration of a generic type by name: one of this build, or a standard range. A standard range's name
    /// that is also declared in this build is ambiguous (SIL prints both as `Range<Int>`), so it is never resolved.
    func genericDeclaration(of base: String) throws(SILError) -> GenericDeclaration? {
        guard let shape = RangeShape.named(base) else { return generics[base] }
        if generics[base] != nil || structs[base] != nil || enums[base] != nil {
            throw SILError.unsupported("\(SILError.ambiguousTypeKind) \(base)\(SILError.supportedTypesNote)")
        }
        return GenericDeclaration(parameters: ["Bound"], isEnum: false, fields: shape.fields.map { ($0, "Bound") }, cases: [])
    }
}

extension ValueType {
    /// A `Range` or `ClosedRange` of a standard integer always has `lowerBound <= upperBound`; true for anything else.
    func rangeInvariant(_ c: CNFBuilder, _ leaves: ArraySlice<BV>) -> Int32 {
        guard case .aggregate(let name, let fields) = self, let range = RangeShape.of(name), range.shape.fields.count == 2,
            let kind = StdlibSummary.integerKind(range.bound), fields.count == 2, leaves.count == 2
        else { return c.trueLit }
        let (lower, upper) = (leaves[leaves.startIndex], leaves[leaves.startIndex + 1])
        return kind == .signed ? -c.slt(upper, lower) : -c.ult(upper, lower)
    }
}
