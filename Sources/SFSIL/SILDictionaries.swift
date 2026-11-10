// Reading guide
// `Dictionary` and `Set` (plan item L2): count-only values, like arrays (`ValueType.array`). A dictionary or set is one
// 64-bit leaf, its count; keys, values and elements are not stored. `count` and `isEmpty` are exact; whether a key is
// present is unknown unless the collection is empty, and a count changes by exactly what the call's result says
// (`updateValue` returns nil exactly when it inserted). Each call that hashes or compares keys runs the read modules'
// own `hash(into:)` and `==`, so a trap in them is never hidden. Three traps of the standard library are kept, or a
// verdict would be a false `safe` (Swift 6.4.0 sources):
// - a dictionary literal with two equal keys (`Dictionary.swift:880`), decided exactly when every key of the literal
//   is a value this function computed and the key type is an integer, `Bool`, an `Optional` of one, or a type whose
//   `==` the read modules define; unknown otherwise;
// - `init(uniqueKeysWithValues:)` with two equal keys (`NativeDictionary.swift:823-825`), decided the same way;
// - a key type whose `hash(into:)` and `==` disagree (`KEY_TYPE_OF_DICTIONARY_VIOLATES_HASHABLE_REQUIREMENTS`,
//   `NativeDictionary.swift:458,487,557`; `NativeSet.swift:363`), possible whenever a key of a type of the read
//   modules is inserted next to another: unknown there. Standard-library types hash consistently (trusted, TRUST.md).
// Tests: Tests/SFSILTests/SILDictionaryTests.swift; zoo cases in Tests/SFOracleTests/ScanZooTests.swift.

import Foundation
package import SFBV
import SFCNF

/// `Dictionary<Key, Value>` or `Set<Element>` (`ValueType.hashed`). Like `ArrayElement`, two such types are equal
/// whatever their type arguments (generic signatures print `Dictionary<τ_0_0, τ_0_1>`): the layout is the same.
package struct HashedCollection: Sendable, CustomStringConvertible {
    package enum Kind: Sendable, Hashable { case dictionary, set }
    package let kind: Kind
    /// The key type of a dictionary, the element type of a set.
    package let key: String
    /// The value type of a dictionary; nil for a set.
    package let value: String?

    /// The type as hashing and printing name it: `Dictionary<K, V>` or `Set<E>`.
    package var description: String { kind == .dictionary ? "Dictionary<\(key), \(value ?? "")>" : "Set<\(key)>" }
    /// The types whose code hashing, comparing or printing the collection runs.
    var components: [String] { [key] + (value.map { [$0] } ?? []) }
}

extension HashedCollection {
    /// The element types of an array, dictionary or set type, and how reports name their unknown contents; nil for any
    /// other type.
    static func contents(of type: String) -> (types: [String], name: String)? {
        if let element = TypeContext.arrayElement(type) { return ([element], "Array elements") }
        return parse(type).map { ($0.components, "\($0) contents") }
    }
}

extension HashedCollection: Equatable {
    package static func == (a: Self, b: Self) -> Bool { a.kind == b.kind }
}

extension HashedCollection {
    /// `Dictionary<K, V>`, `[K : V]` and `Set<E>` (also with `Swift.`); nil for any other type text.
    package static func parse(_ text: String) -> HashedCollection? {
        let t = text.trimmingCharacters(in: .whitespaces)
        for (prefix, kind) in [("Dictionary<", HashedCollection.Kind.dictionary), ("Set<", .set)] {
            for p in [prefix, "Swift." + prefix] where t.hasPrefix(p) && t.hasSuffix(">") {
                let parts = splitTopLevel(String(t.dropFirst(p.count).dropLast()))
                if kind == .dictionary, parts.count == 2 { return HashedCollection(kind: kind, key: parts[0], value: parts[1]) }
                if kind == .set, parts.count == 1 { return HashedCollection(kind: kind, key: parts[0], value: nil) }
                return nil
            }
        }
        guard t.hasPrefix("["), t.hasSuffix("]"), matchingClose(Substring(t), open: "[", close: "]") == t.index(before: t.endIndex)
        else { return nil }
        let inner = t.dropFirst().dropLast()
        var depth = 0
        for i in inner.indices {
            let ch = inner[i]
            if "<([".contains(ch) { depth += 1 }
            if ">)]".contains(ch) { depth -= 1 }
            if ch == ":", depth == 0 {
                let key = inner[..<i].trimmingCharacters(in: .whitespaces)
                let value = inner[inner.index(after: i)...].trimmingCharacters(in: .whitespaces)
                return HashedCollection(kind: .dictionary, key: key, value: value)
            }
        }
        return nil
    }

}

extension TypeContext {
    /// `ValueType.hashed` for a dictionary or set type (see `hashedCollection(_:)`), nil for other types.
    func hashedLayout(_ text: String) throws(SILError) -> ValueType? { try hashedCollection(text).map { .hashed($0) } }

    /// The layout of a dictionary or set type, nil for other types. Throws when destroying its keys or values may run
    /// code of the read modules (release and destroy instructions are not modelled), as for arrays.
    func hashedCollection(_ text: String) throws(SILError) -> HashedCollection? {
        guard let collection = HashedCollection.parse(text) else { return nil }
        for part in collection.components where !destroysWithoutModuleCode(part) {
            throw SILError.unsupported(
                "\(collection) of \(part): destroying its contents may run code of this module (classes, closures, existentials)")
        }
        return collection
    }
}

// MARK: - encoding

/// The limit on counts, as for arrays: no allocation of 2^48 bytes succeeds (TRUST.md).
private let countLimit: UInt64 = 1 << 48

extension SILEncoder {
    /// A call into `Dictionary` or `Set` (see `StdlibSummary.HashedOperation`); returns the direct result's leaves.
    func applyHashed(_ kind: HashedCollection.Kind, _ operation: StdlibSummary.HashedOperation, _ call: SummaryCall) throws -> [BV] {
        let substitutions = call.request.substitutions
        let expected = kind == .set ? 1 : operation == .uniqueKeys ? 3 : 2
        guard substitutions.count == expected else {
            throw SILError.unsupported("call to \(call.name) with <\(substitutions.joined(separator: ", "))>")
        }
        for substitution in substitutions where !module.destroysWithoutModuleCode(substitution) {
            throw SILError.unsupported("\(call.name) on \(substitution), whose values may run code of this module when destroyed")
        }
        let model = HashedModel(encoder: self, c: c, call: call, kind: kind, key: substitutions[0])
        if let result = try model.read(operation) { return result }
        guard let result = try model.change(operation) else { throw SILError.invalid("\(call.name): no model of \(operation)") }
        return result
    }
}

/// The semantics of one `Dictionary`/`Set` call.
private struct HashedModel {
    let encoder: SILEncoder
    let c: CNFBuilder
    let call: SummaryCall
    let kind: HashedCollection.Kind
    let key: String

    var zero: BV { c.constant(0, width: 64) }
    var one: BV { c.constant(1, width: 64) }
    /// An unknown choice: whether a key is present, whether two keys collide, ...
    func choice() -> Int32 { c.input(width: 1).bits[0] }
    var keyName: String { kind == .dictionary ? "key" : "element" }

    /// The calls that make a new collection or only read one; nil for the others.
    func read(_ operation: StdlibSummary.HashedOperation) throws -> [BV]? {
        switch operation {
        case .count: return [try call.word(0)]
        case .isEmpty: return [BV(bits: [c.eq(try call.word(0), zero)])]
        case .lookup: return try lookup()
        case .contains: return try contains()
        case .equals: return try equals(value: kind == .dictionary ? call.request.substitutions[1] : nil)
        case .empty: return [zero]
        case .defaultFalse: return [c.constant(0, width: 1)]
        default: return nil
        }
    }

    /// The calls that change an `inout` collection or build one from elements; nil for the others.
    func change(_ operation: StdlibSummary.HashedOperation) throws -> [BV]? {
        switch operation {
        case .assign: return try assign()
        case .updateValue: return try updateValue()
        case .remove: return try remove()
        case .insert: return try insert()
        case .removeAll:
            try call.set(1, [zero])
            return []
        case .dictionaryLiteral: return try dictionaryLiteral()
        case .setLiteral: return try setLiteral()
        case .uniqueKeys: return try uniqueKeys(sequence: call.request.substitutions[2])
        default: return nil
        }
    }

    // MARK: lookups

    /// `subscript(_:)` get: (@out Optional<Value>, key, dictionary).
    func lookup() throws -> [BV] {
        let n = try call.word(2)
        let nonEmpty = -c.eq(n, zero)
        try probe(try call.leaves(1), when: nonEmpty)
        try call.set(0, try optional(try call.writtenType(0), isNone: c.or(-nonEmpty, choice())))
        call.approximate(call.name)
        return []
    }

    /// `Set.contains(_:)`: (element, set).
    func contains() throws -> [BV] {
        let n = try call.word(1)
        let nonEmpty = -c.eq(n, zero)
        try probe(try call.leaves(0), when: nonEmpty)
        call.approximate(call.name)
        return [BV(bits: [c.and(nonEmpty, choice())])]
    }

    /// Hashes `value` (the standard library always does once the collection is not empty) and compares it with keys
    /// that are there, which runs `==` on unknown keys.
    func probe(_ value: [BV], when condition: Int32) throws {
        try call.hash(key, value, condition)
        try call.equate(key, condition)
    }

    // MARK: changes

    /// `subscript(_:)` set: (@in Optional<Value>, @in key, @inout dictionary). Nil removes the key.
    func assign() throws -> [BV] {
        let n = try call.word(2)
        let nonEmpty = -c.eq(n, zero)
        let new = try call.leaves(0)
        guard let tag = new.first, tag.width == 1 else { throw SILError.invalid("\(call.name): new value at \(call.request.id)") }
        let isSome = tag.bits[0]
        try probe(try call.leaves(1), when: c.trueLit)
        let found = c.and(nonEmpty, choice())
        try insertion(into: n, when: c.and(isSome, -found))
        try disagreement(when: c.and(isSome, nonEmpty))
        let inserted = c.select(c.and(isSome, -found), c.add(n, one).sum, n)
        try call.set(2, [c.select(c.and(-isSome, found), c.sub(n, one).difference, inserted)])
        call.approximate(call.name)
        return []
    }

    /// `updateValue(_:forKey:)`: (@out Optional<Value>, @in value, key, @inout dictionary).
    func updateValue() throws -> [BV] {
        let n = try call.word(3)
        let nonEmpty = -c.eq(n, zero)
        try probe(try call.leaves(2), when: c.trueLit)
        let found = c.and(nonEmpty, choice())
        try insertion(into: n, when: -found)
        try disagreement(when: nonEmpty)
        try call.set(0, try optional(try call.writtenType(0), isNone: -found))
        try call.set(3, [c.select(found, n, c.add(n, one).sum)])
        call.approximate(call.name)
        return []
    }

    /// `removeValue(forKey:)` and `Set.remove(_:)`: (@out Optional<removed>, key, @inout collection).
    func remove() throws -> [BV] {
        let n = try call.word(2)
        let nonEmpty = -c.eq(n, zero)
        try probe(try call.leaves(1), when: c.trueLit)
        let found = c.and(nonEmpty, choice())
        try call.set(0, try optional(try call.writtenType(0), isNone: -found))
        try call.set(2, [c.select(found, c.sub(n, one).difference, n)])
        call.approximate(call.name)
        return []
    }

    /// `Set.insert(_:)`: (@out memberAfterInsert, @in element, @inout set) -> inserted.
    func insert() throws -> [BV] {
        guard call.request.type.leafWidths == [1] else { throw SILError.invalid("\(call.name): result at \(call.request.id)") }
        let n = try call.word(2)
        let nonEmpty = -c.eq(n, zero)
        let element = try call.leaves(1)
        try probe(element, when: c.trueLit)
        let found = c.and(nonEmpty, choice())
        try insertion(into: n, when: -found)
        try disagreement(when: nonEmpty)
        // The member is the inserted element, or the equal one that was there (unknown).
        let member = zip(element, encoder.fresh(try call.writtenType(0))).map { c.select(found, $1, $0) }
        try call.set(0, member)
        try call.set(2, [c.select(found, n, c.add(n, one).sum)])
        call.approximate(call.name)
        return [BV(bits: [-found])]
    }

    /// An insertion into a collection of `n` keys when `condition`: the storage grows, and a count of 2^48 is an
    /// allocation that fails.
    func insertion(into n: BV, when condition: Int32) throws {
        let grown = c.add(n, one).sum
        call.trap(c.and(condition, -c.ult(grown, c.constant(countLimit, width: 64))), "\(kindName) too large: allocation fails")
    }

    /// Inserting next to other keys rehashes them; when the key type's `hash(into:)` and `==` disagree, the standard
    /// library finds two equal keys and traps. Unknown for a type of the read modules; never for a standard one.
    func disagreement(when condition: Int32) throws {
        guard !StdlibSummary.hashesConsistently(key) else { return }
        call.trap(c.and(condition, choice()), "Duplicate \(keyName)s of type '\(key)' were found in a \(kindName)")
        call.approximate("\(key).hash(into:) and ==")
    }

    var kindName: String { kind == .dictionary ? "Dictionary" : "Set" }

    // MARK: making

    /// `init(dictionaryLiteral:)`: (Array<(Key, Value)>, metatype). Traps on two equal keys.
    func dictionaryLiteral() throws -> [BV] {
        let a = try call.argument(0)
        let n = try call.word(0)
        let keys = encoder.literalKeys(of: a.name, count: n, tuples: true, in: call)
        try duplicates(keys, count: n, message: "Dictionary literal contains duplicate keys")
        return [n]
    }

    /// `init(uniqueKeysWithValues:)` of an `Array<(Key, Value)>`: (@in sequence, metatype). Traps on two equal keys.
    func uniqueKeys(sequence: String) throws -> [BV] {
        guard TypeContext.arrayElement(sequence) != nil else {
            throw SILError.unsupported("\(call.name) of \(sequence), which is not an array")
        }
        let a = try call.argument(0)
        let n = try call.word(0)
        let source = a.convention == .value ? a.name : encoder.storedValue(into: a.name, in: call)
        let keys = source.flatMap { encoder.literalKeys(of: $0, count: n, tuples: true, in: call) }
        try duplicates(keys, count: n, message: "Duplicate values for key")
        // Each key is inserted next to the earlier ones (`mutatingFind`), which rehashes.
        try disagreement(when: -c.ult(n, c.constant(2, width: 64)))
        return [n]
    }

    /// Hashes each key, then traps when one equals an earlier key: exactly, when the keys are known values that can be
    /// compared; under an unknown choice otherwise.
    func duplicates(_ keys: [[BV]]?, count n: BV, message: String) throws {
        guard let keys else {
            try call.hash(key, nil, -c.eq(n, zero))
            try call.equate(key, -c.ult(n, c.constant(2, width: 64)))
            call.trap(c.and(-c.ult(n, c.constant(2, width: 64)), choice()), message)
            call.approximate("\(call.name) keys")
            return
        }
        for (i, k) in keys.enumerated() {
            try call.hash(key, k, c.trueLit)
            var duplicate = c.falseLit
            for earlier in keys[..<i] {
                // The standard library compares two keys only when their hashes lead to the same bucket.
                guard let equal = try encoder.equalKeys(key, earlier, k, when: choice(), in: call) else {
                    call.approximate("\(call.name) keys")
                    duplicate = c.or(duplicate, choice())
                    continue
                }
                duplicate = c.or(duplicate, equal)
            }
            // With a hash that disagrees with `==`, two equal keys may land in different buckets and go unnoticed.
            if !StdlibSummary.hashesConsistently(key) {
                duplicate = c.and(duplicate, choice())
                call.approximate("\(key).hash(into:) and ==")
            }
            call.trap(duplicate, message)
        }
    }

    /// `init(arrayLiteral:)` of a set: (Array<Element>, metatype). Equal elements are kept once.
    func setLiteral() throws -> [BV] {
        let n = try call.word(0)
        if let elements = encoder.literalKeys(of: try call.argument(0).name, count: n, tuples: false, in: call),
            StdlibSummary.hashesConsistently(key)
        {
            // Exact when every element is known and can be compared: an element equal to an earlier one is dropped.
            var count = zero
            for (i, e) in elements.enumerated() {
                try call.hash(key, e, c.trueLit)
                var seen = c.falseLit
                for earlier in elements[..<i] {
                    guard let equal = try encoder.equalKeys(key, earlier, e, when: choice(), in: call) else {
                        seen = c.or(seen, choice())
                        call.approximate("\(call.name) elements")
                        continue
                    }
                    seen = c.or(seen, equal)
                }
                count = c.select(seen, count, c.add(count, one).sum)
            }
            return [count]
        }
        try call.hash(key, nil, -c.eq(n, zero))
        try call.equate(key, -c.ult(n, c.constant(2, width: 64)))
        // Between 1 and n distinct elements when n > 0.
        let distinct = encoder.fresh(.hashed(HashedCollection(kind: .set, key: key, value: nil)))[0]
        call.approximate(call.name)
        return [c.select(c.eq(n, zero), zero, c.select(c.and(c.ule(one, distinct), c.ule(distinct, n)), distinct, n))]
    }

    // MARK: comparing

    /// `==`: (lhs, rhs, metatype). Runs the key's `hash(into:)` and `==`, and the value's `==`, on unknown values.
    func equals(value: String?) throws -> [BV] {
        let (a, b) = (try call.word(0), try call.word(1))
        let sameCount = c.eq(a, b)
        let compared = c.and(sameCount, -c.eq(a, zero))
        try call.hash(key, nil, c.and(compared, choice()))
        try call.equate(key, compared)
        if let value { try call.equate(value, compared) }
        call.approximate(call.name)
        return [BV(bits: [c.and(sameCount, c.or(c.eq(a, zero), choice()))])]
    }

    // MARK: helpers

    /// An `Optional` of layout `type`: nil when `isNone`, otherwise an unknown value.
    func optional(_ type: ValueType, isNone: Int32) throws -> [BV] {
        guard case .enumeration(_, let cases) = type, cases.count == 2, cases[0].payload == nil, let wrapped = cases[1].payload else {
            throw SILError.invalid("\(call.name): result is not an Optional at \(call.request.id)")
        }
        let payload = encoder.fresh(wrapped).map { leaf in BV(bits: leaf.bits.map { c.and($0, -isNone) }) }
        return [BV(bits: [-isNone])] + payload
    }
}
