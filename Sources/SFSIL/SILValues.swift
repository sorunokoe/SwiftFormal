// The reader's vocabulary: `SILError`, scalar widths and `ValueType`, the layout every SIL value gets (plan item H1).

import Foundation
import SFSemantics

/// A frontend for the scalar subset of canonical SIL. Anything outside the subset is rejected with
/// `SILError.unsupported`; nothing is guessed.
package enum SILError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)
    case invalid(String)
    case compilerFailed(String)

    package var description: String {
        switch self {
        case .unsupported(let s): "UNSUPPORTED: \(s)"
        case .invalid(let s): "INVALID SIL: \(s)"
        case .compilerFailed(let s): "COMPILER FAILED: \(s)"
        }
    }
}

/// Bit width of a scalar SIL type such as `Int32`, `UInt8`, `Bool` or `Builtin.Int16`. Nil if not a supported scalar.
func scalarWidth(_ type: String) -> Int? {
    var t = type.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("$") { t.removeFirst() }
    if let w = namedScalarWidths[t] { return w }
    guard t.hasPrefix("Builtin.Int"), let w = Int(t.dropFirst("Builtin.Int".count)), S0Instance.supportedWidths.contains(w) else {
        return nil
    }
    return w
}

/// Standard types held as one scalar. `Builtin.Word` is 64 bits (64-bit targets only; indices into array storage).
/// Floating point is the IEEE 754 bit pattern (`S0FloatInstance` reads it, `FloatCircuit` computes its arithmetic).
private let namedScalarWidths: [String: Int] = [
    "Bool": 1, "Int": 64, "UInt": 64, "Int64": 64, "UInt64": 64, "Int32": 32, "UInt32": 32, "Int16": 16, "UInt16": 16,
    "Int8": 8, "UInt8": 8, "Builtin.Word": 64, "Double": 64, "Builtin.FPIEEE64": 64, "Float": 32, "Builtin.FPIEEE32": 32,
    "Float16": 16, "Builtin.FPIEEE16": 16,
]

/// `$(Builtin.IntN, Builtin.Int1)`: the result type of a `*_with_overflow` builtin.
func overflowWidth(_ type: String) -> Int? {
    var t = type.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("$") { t.removeFirst() }
    guard t.hasPrefix("("), t.hasSuffix(", Builtin.Int1)") else { return nil }
    return scalarWidth(String(t.dropFirst().dropLast(", Builtin.Int1)".count)))
}

/// A supported SIL value type: a scalar, or a struct/tuple whose stored properties are (recursively) supported.
/// Aggregates are flattened to their scalar leaves in declaration order, depth first.
package indirect enum ValueType: Equatable, Sendable, CustomStringConvertible {
    package struct Field: Equatable, Sendable {
        package let name: String
        package let type: ValueType
    }
    package struct Case: Equatable, Sendable {
        package let name: String
        /// Nil for a case without associated values.
        package let payload: ValueType?
    }
    case scalar(Int)
    /// `name` is the struct name, or empty for a tuple (whose fields are named "0", "1", ...).
    case aggregate(name: String, fields: [Field])
    /// A non-generic enum or an `Optional`. Leaves: the tag (the index of the case in `cases`, `tagWidth` bits),
    /// then the payload leaves of every case in order. Payload leaves of the cases that are not active are zero.
    case enumeration(name: String, cases: [Case])
    /// A standard-library value whose contents logic never reads (`String`, `Hasher`, ...): one 64-bit handle.
    /// Only moves, copies and the calls in `StdlibSummaries` may touch it; any other use is rejected.
    case opaque(name: String)
    /// `Array<Element>`: only the element count is modelled (one 64-bit leaf, below 2^48 in every real array).
    /// Elements are not stored: reading one gives an unknown value of the element type.
    case array(element: ArrayElement)
    /// `Dictionary<Key, Value>` or `Set<Element>`: only the count is modelled, as for `array` (`SILDictionaries.swift`).
    case hashed(HashedCollection)

    package var leafWidths: [Int] {
        switch self {
        case .scalar(let w): [w]
        case .opaque, .array, .hashed: [64]
        case .aggregate(_, let fields): fields.flatMap { $0.type.leafWidths }
        case .enumeration(_, let cases): [Self.tagWidth(cases.count)] + cases.flatMap { $0.payload?.leafWidths ?? [] }
        }
    }

    /// Bits needed to number `count` cases (at least one).
    static func tagWidth(_ count: Int) -> Int {
        var w = 1
        while (1 << w) < count { w += 1 }
        return w
    }

    package var totalWidth: Int { leafWidths.reduce(0, +) }

    /// The leaf positions occupied by field `index`.
    func leafRange(ofField index: Int) -> Range<Int>? {
        guard case .aggregate(_, let fields) = self, fields.indices.contains(index) else { return nil }
        let start = fields[..<index].reduce(0) { $0 + $1.type.leafWidths.count }
        return start..<(start + fields[index].type.leafWidths.count)
    }

    package var description: String {
        switch self {
        case .scalar(let w): "i\(w)"
        case .aggregate(let name, let fields):
            name.isEmpty ? "(" + fields.map { $0.type.description }.joined(separator: ", ") + ")" : name
        case .enumeration(let name, _): name
        case .opaque(let name): name
        // The same for every element type, like `==`: the layout does not depend on it.
        case .array: "Array"
        case .hashed(let collection): collection.kind == .dictionary ? "Dictionary" : "Set"
        }
    }

    static func tuple(_ widths: [Int]) -> ValueType {
        .aggregate(name: "", fields: widths.enumerated().map { Field(name: "\($0)", type: .scalar($1)) })
    }
}

/// The element type of an `Array`, as written in the SIL. Elements have no leaves, so every array has the same
/// layout: two array types are equal whatever their elements (generic signatures print `Array<τ_0_0>`).
package struct ArrayElement: Equatable, Sendable, CustomStringConvertible {
    package let text: String
    package static func == (_: Self, _: Self) -> Bool { true }
    package var description: String { text }
}

/// What the value a field is taken from must be: fields are found by position, so a different type is an error.
enum FieldOwner: Sendable, Equatable {
    case type(ValueType)
    /// Any use of the generic struct `name` (`#Pair.a` is printed without the arguments); the fields are in the same
    /// order in every use.
    case instance(of: String)
    case tuple

    func matches(_ type: ValueType) -> Bool {
        guard case .aggregate(let name, _) = type else { return false }
        switch self {
        case .type(let expected): return expected == type
        case .instance(let generic): return name.hasPrefix(generic + "<") && name.hasSuffix(">")
        case .tuple: return name.isEmpty
        }
    }
}

extension SILError {
    /// Appended to an unsupported-type message. Tools strip it again for short reports.
    package static let supportedTypesNote =
        " (only scalars, and structs, tuples, enums and optionals built from them, are supported; classes, existentials, closures and generic functions are rejected)"
    /// The kind given to a type name declared more than once (see `TypeContext.ambiguous`).
    package static let ambiguousTypeKind = "ambiguous type"
}
