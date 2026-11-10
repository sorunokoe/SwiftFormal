// The `Dictionary` and `Set` rows of the summary table (plan item L2); their meaning is in `SILDictionaries.swift`.
// `Scripts/check-summary-pin.py` reads the rows here too.

extension StdlibSummary {
    /// What a `Dictionary` or `Set` call does (`StdlibSummary.hashed`).
    package enum HashedOperation: Sendable, Hashable {
        case count, isEmpty
        /// `Dictionary.subscript(_:)` get: an `Optional` value, nil when the dictionary is empty.
        case lookup
        /// `Dictionary.subscript(_:)` set: inserts, replaces or (with nil) removes.
        case assign
        /// `Dictionary.updateValue(_:forKey:)`: the old value, nil exactly when the key was inserted.
        case updateValue
        /// `Dictionary.removeValue(forKey:)` and `Set.remove(_:)`: the removed value, nil exactly when nothing was removed.
        case remove
        /// `Set.contains(_:)`.
        case contains
        /// `Set.insert(_:)`: `inserted` is false exactly when an equal element was there.
        case insert
        /// `[k: v, ...]`: traps on two equal keys.
        case dictionaryLiteral
        /// `[a, b, ...] as Set`: equal elements are kept once, never a trap.
        case setLiteral
        /// `Dictionary(uniqueKeysWithValues:)` of an array: traps on two equal keys.
        case uniqueKeys
        /// `Dictionary()`, `Set()`.
        case empty
        /// `removeAll(keepingCapacity:)`, and the `false` of its default argument.
        case removeAll, defaultFalse
        /// `==`: false for different counts, true for two empty collections, unknown otherwise.
        case equals
    }

    /// The `Dictionary` and `Set` rows of `table` (swift-6.4.0-RELEASE, `-Onone`).
    static func addHashedCollections(to t: inout [String: Entry]) {
        func add(_ symbol: String, _ name: String, _ kind: HashedCollection.Kind, _ operation: HashedOperation, tag: String? = nil) {
            t[symbol] = Entry(name: name, summary: .hashed(kind, operation), isGeneric: true)
            t[symbol]?.semantics = Set([tag].compactMap { $0 })
        }
        add("$sSD5countSivg", "Dictionary.count", .dictionary, .count)
        add("$sSD7isEmptySbvg", "Dictionary.isEmpty", .dictionary, .isEmpty)
        add("$sSDyq_Sgxcig", "Dictionary.subscript", .dictionary, .lookup)
        add("$sSDyq_Sgxcis", "Dictionary.subscript", .dictionary, .assign)
        add("$sSD11updateValue_6forKeyq_Sgq_n_xtF", "Dictionary.updateValue(_:forKey:)", .dictionary, .updateValue)
        add("$sSD11removeValue6forKeyq_Sgx_tF", "Dictionary.removeValue(forKey:)", .dictionary, .remove)
        add(
            "$sSD17dictionaryLiteralSDyxq_Gx_q_td_tcfC", "a dictionary literal", .dictionary, .dictionaryLiteral,
            tag: "optimize.sil.specialize.generic.size.never")
        add(
            "$sSD20uniqueKeysWithValuesSDyxq_Gqd__n_tcSTRd__x_q_t7ElementRtd__lufC", "Dictionary(uniqueKeysWithValues:)",
            .dictionary, .uniqueKeys)
        add("$sS2Dyxq_GycfC", "Dictionary()", .dictionary, .empty)
        add("$sSD9removeAll15keepingCapacityySb_tF", "Dictionary.removeAll()", .dictionary, .removeAll)
        add("$sSD9removeAll15keepingCapacityySb_tFfA_", "Dictionary.removeAll()", .dictionary, .defaultFalse)
        add("$sSDsSQR_rlE2eeoiySbSDyxq_G_ABtFZ", "Dictionary.==", .dictionary, .equals)
        add("$sSh5countSivg", "Set.count", .set, .count)
        add("$sSh7isEmptySbvg", "Set.isEmpty", .set, .isEmpty)
        add("$sSh8containsySbxF", "Set.contains(_:)", .set, .contains)
        add("$sSh6insertySb8inserted_x17memberAfterInserttxnF", "Set.insert(_:)", .set, .insert)
        add("$sSh6removeyxSgxF", "Set.remove(_:)", .set, .remove)
        add("$sSh12arrayLiteralShyxGxd_tcfC", "a set literal", .set, .setLiteral)
        add("$sS2hyxGycfC", "Set()", .set, .empty)
        add("$sSh9removeAll15keepingCapacityySb_tF", "Set.removeAll()", .set, .removeAll)
        add("$sSh9removeAll15keepingCapacityySb_tFfA_", "Set.removeAll()", .set, .defaultFalse)
        add("$sSh2eeoiySbShyxG_ABtFZ", "Set.==", .set, .equals)
    }

    /// Whether `==` and `hash(into:)` of `type` are the standard library's, which agree (trusted, TRUST.md): integers,
    /// `Bool`, strings, floating point, and optionals and arrays of those. A type of the read modules may disagree.
    static func hashesConsistently(_ type: String) -> Bool {
        if isStandardType(type) { return true }
        if let wrapped = optionalWrapped(type) { return hashesConsistently(wrapped) }
        if let element = TypeContext.arrayElement(type) { return hashesConsistently(element) }
        return false
    }
}
