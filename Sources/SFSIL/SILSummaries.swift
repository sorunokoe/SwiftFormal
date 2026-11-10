import Foundation
import SFBV
import SFCNF
package import SFSemantics

/// What logic assumes about a standard-library function whose body it does not read.
///
/// The functions here only make, combine or inspect strings and hashers. Logic models those values as opaque
/// handles (`ValueType.opaque`). Strings are handles of their value (`SILStrings.swift`), so the `String` calls in
/// `TextOperation` are exact or partly exact. For the rest a summary says:
/// the call does not trap, and its results (the return value and every `@inout`/`@out` argument) are *unknown*:
/// fresh values the solver may choose freely. Proofs stay sound because every possible actual result is among
/// the values the solver considers. A counterexample may depend on a value the real call never returns; the
/// encoder records each summarized call in `EncodedFunction.approximations` so that callers can tell.
///
/// Generic calls are summarized only when every substitution is a standard-library value type. For a type of the
/// verified module, the summary instead calls that type's own witness (its `hash(into:)` or `description`),
/// so that a trap in user code is never hidden behind a summary.
package enum StdlibSummary: Sendable, Hashable {
    /// Unknown results; never traps.
    case unknown
    /// `Hasher.combine<T>(_:)`: T's own `hash(into:)` for a module type, then an unknown hasher.
    case hashCombine
    /// `_hashValue(for:)`, behind every `hashValue` getter: `value._rawHashValue(seed: 0)`, whose default makes a
    /// `Hasher`, runs T's `hash(into:)` and finalizes. Runs T's own `hash(into:)` (plan item L9); unknown result. A type
    /// whose `_rawHashValue` is not the default is refused.
    case hashValue
    /// The `RawRepresentable` default `hash(into:)`: T's `rawValue` getter, then an unknown hasher.
    case rawValueHash
    /// String interpolation or `String(describing:)` of a T: T's `description`/`debugDescription` for a module
    /// type, then an unknown result.
    case describe
    /// A `String` call on handles (`SILStrings.swift`): exact, or exact as far as the operands are known. Never traps.
    case text(TextOperation)
    /// `Swift.min(_:_:)` / `Swift.max(_:_:)`: exact, for standard integer types only.
    case minimum, maximum
    /// Only for arrays (`Entry.arrayOperation`); rejected on anything else.
    case array
    /// A `Dictionary` or `Set` call (`SILDictionaries.swift`): counts exact, keys and values unknown.
    case hashed(HashedCollection.Kind, HashedOperation)
    /// `DefaultStringInterpolation(literalCapacity:interpolationCount:)`: computes `literalCapacity +
    /// interpolationCount * 2` with checked arithmetic (`StringInterpolation.swift`), so it traps on overflow, and
    /// allocates that many bytes, which fails at 2^48 or more (the bound of `ValueType.array`). Unknown result.
    case interpolationCapacity
    /// `Double.isFinite`, `isNaN`, ... (and `Float`'s): exact, from the bit pattern (`S0FloatClass`). Never traps.
    case floatClass(S0FloatClass)
    /// Records that observable state was read (`ObservationStateRegistrar.access`): no result, nothing changes, any
    /// generic substitutions. Never traps unless a fatal-error issue reporter is installed (`trustsRecordedAccess`).
    case recordsAccess
    /// Effects logic computes exactly (`ComputedSummary`).
    case computed(ComputedSummary)
    /// A range of standard integers (`SILRanges.swift`): exact.
    case range(RangeOperation)

    /// What an `Array` call does to counts. Logic models an array by its count only (`ValueType.array`):
    /// counts and the index checks that trap are exact; elements read from an array are unknown.
    package enum ArrayOperation: Sendable, Hashable {
        /// Reads an array without changing it.
        case read(ArrayRead)
        /// Returns a new array.
        case make(ArrayMake)
        /// Changes an `inout` array.
        case mutate(ArrayMutation)
        /// Compares elements with `==`.
        case search(ArraySearch)
    }

    package enum ArrayRead: Sendable, Hashable { case count, startIndex, isEmpty, subscriptGet, first, last, indices }
    package enum ArrayMake: Sendable, Hashable { case concatenate, allocate, finalize, empty, repeating, defaultFalse }
    package enum ArrayMutation: Sendable, Hashable { case append, appendArray, removeAll, removeAt, insert, removeLast, popLast }
    package enum ArraySearch: Sendable, Hashable { case equals, contains, firstIndex }

    /// `Array.subscript.modify`, the coroutine behind `array[i] = x` and `array[i] += x`.
    package static let arraySubscriptModify = "$sSayxSiciM"

    package struct Entry: Sendable {
        /// How reports name the call, for example `String.==`.
        package let name: String
        package let summary: StdlibSummary
        /// True when the symbol is generic; its single substitution decides whether user code can run.
        package let isGeneric: Bool
        /// The array model of this call, when its subject is an array.
        package var arrayOperation: StdlibSummary.ArrayOperation?
        /// True when the substitution is the collection itself (`Array<X>`) rather than the element type `X`.
        package var onCollection = false
        /// The `[_semantics "…"]` tags the compiler may print on this symbol (swift-6.4.0-RELEASE, checked against
        /// `tools/summary-probe/probe.swift` in the oracle lane). A printed tag outside this set refuses the call: the
        /// symbol is then not the function this entry was written for (plan item R9). Tags never add behaviour.
        package var semantics: Set<String> = []
        /// Set when the call prints a standard integer as its decimal text (`SILStringFacts.swift`).
        package var integerText: StdlibSummary.IntegerText?

        package init(
            name: String, summary: StdlibSummary, isGeneric: Bool, arrayOperation: StdlibSummary.ArrayOperation? = nil,
            onCollection: Bool = false
        ) {
            self.name = name
            self.summary = summary
            self.isGeneric = isGeneric
            self.arrayOperation = arrayOperation
            self.onCollection = onCollection
        }
    }

    /// Every summarized symbol, checked against `-emit-sil -Onone` output of Swift 6.
    package static let table: [String: Entry] = {
        var t: [String: Entry] = [:]
        func add(
            _ symbol: String, _ name: String, _ summary: StdlibSummary = .unknown, generic: Bool = false, tag: String? = nil
        ) {
            t[symbol] = Entry(name: name, summary: summary, isGeneric: generic)
            t[symbol]?.semantics = Set([tag].compactMap { $0 })
        }
        add("$sSJ38_builtinExtendedGraphemeClusterLiteral17utf8CodeUnitCount7isASCIISJBp_BwBi1_tcfC", "a character literal")
        add("$sSS19stringInterpolationSSs013DefaultStringB0V_tcfC", "String(stringInterpolation:)", .text(.interpolated))
        add(
            "$ss26DefaultStringInterpolationV15literalCapacity18interpolationCountABSi_SitcfC", "string interpolation",
            .interpolationCapacity)
        add("$ss26DefaultStringInterpolationV13appendLiteralyySSF", "string interpolation", .text(.appendLiteral))
        add("$ss26DefaultStringInterpolationV06appendC0yyxlF", "string interpolation", .describe, generic: true)
        add("$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzlF", "string interpolation", .describe, generic: true)
        add(
            "$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzs20TextOutputStreamableRzlF",
            "string interpolation", .describe, generic: true)
        add("$sSS10describingSSx_tclufC", "String(describing:)", .describe, generic: true)
        add("$sSS10describingSSx_tcs23CustomStringConvertibleRzlufC", "String(describing:)", .describe, generic: true)
        add("$sSSySSxcs25LosslessStringConvertibleRzlufC", "String.init(_:)", .describe, generic: true)
        add("$sSzsE11descriptionSSvg", "BinaryInteger.description", generic: true, tag: "binaryInteger.description")
        add("$sSd8isFiniteSbvg", "Double.isFinite", .floatClass(.finite))
        add("$sSd5isNaNSbvg", "Double.isNaN", .floatClass(.nan))
        add("$sSd10isInfiniteSbvg", "Double.isInfinite", .floatClass(.infinite))
        add("$sSd6isZeroSbvg", "Double.isZero", .floatClass(.zero))
        add("$sSd8isNormalSbvg", "Double.isNormal", .floatClass(.normal))
        add("$sSd11isSubnormalSbvg", "Double.isSubnormal", .floatClass(.subnormal))
        add("$sSf8isFiniteSbvg", "Float.isFinite", .floatClass(.finite))
        add("$sSf5isNaNSbvg", "Float.isNaN", .floatClass(.nan))
        add("$sSf10isInfiniteSbvg", "Float.isInfinite", .floatClass(.infinite))
        add("$sSf6isZeroSbvg", "Float.isZero", .floatClass(.zero))
        add("$sSf8isNormalSbvg", "Float.isNormal", .floatClass(.normal))
        add("$sSf11isSubnormalSbvg", "Float.isSubnormal", .floatClass(.subnormal))
        addFloatingPoint(to: &t)
        add("$ss3minyxx_xtSLRzlF", "min(_:_:)", .minimum, generic: true)
        add("$ss3maxyxx_xtSLRzlF", "max(_:_:)", .maximum, generic: true)
        add("$ss6HasherV7combineyyxSHRzlF", "Hasher.combine(_:)", .hashCombine, generic: true)
        add("$ss10_hashValue3forSix_tSHRzlF", "_hashValue(for:)", .hashValue, generic: true)
        // No `_precondition` or `fatalError` in `Hasher.swift` (swift-6.4.0-RELEASE): neither can trap.
        add("$ss6HasherVABycfC", "Hasher()")
        add("$ss6HasherV8finalizeSiyF", "Hasher.finalize()")
        add("$sSYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF", "RawRepresentable.hash(into:)", .rawValueHash, generic: true)
        func array(_ symbol: String, _ name: String, _ operation: ArrayOperation, generic: Bool = true, tag: String? = nil) {
            t[symbol] = Entry(name: name, summary: .array, isGeneric: generic, arrayOperation: operation)
            t[symbol]?.semantics = Set([tag].compactMap { $0 })
        }
        /// A `Collection` (or `Sequence`) member: summarized as `summary` for standard non-array subjects.
        func collection(_ symbol: String, _ name: String, _ operation: ArrayOperation, _ summary: StdlibSummary) {
            t[symbol] = Entry(name: name, summary: summary, isGeneric: true, arrayOperation: operation, onCollection: true)
        }
        array("$sSa5countSivg", "Array.count", .read(.count), tag: "array.get_count")
        // Internal; never called from user code at -Onone, so not in the probe. Its tag is from `Array.swift`@6.4.0.
        array("$sSa9_getCountSiyF", "Array.count", .read(.count), tag: "array.get_count")
        array("$sSa10startIndexSivg", "Array.startIndex", .read(.startIndex))
        array("$sSa8endIndexSivg", "Array.endIndex", .read(.count))
        array("$sSayxSicig", "Array.subscript", .read(.subscriptGet))
        array("$sSa6appendyyxnF", "Array.append(_:)", .mutate(.append), tag: "array.append_element")
        array("$sSa2peoiyySayxGz_ABtFZ", "Array.+=", .mutate(.appendArray))
        array("$sSa1poiySayxGAB_ABtFZ", "Array.+", .make(.concatenate))
        array("$ss27_allocateUninitializedArrayySayxG_BptBwlF", "an array literal", .make(.allocate), tag: "array.uninitialized_intrinsic")
        array("$ss27_finalizeUninitializedArrayySayxGABnlF", "an array literal", .make(.finalize), tag: "array.finalize_intrinsic")
        array("$sS2ayxGycfC", "Array()", .make(.empty), tag: "array.init.empty")
        array("$sSa9repeating5countSayxGx_SitcfC", "Array(repeating:count:)", .make(.repeating), tag: "array.init")
        array("$sSa9removeAll15keepingCapacityySb_tF", "Array.removeAll()", .mutate(.removeAll))
        array("$sSa9removeAll15keepingCapacityySb_tFfA_", "Array.removeAll()", .make(.defaultFalse), generic: false)
        array("$sSa6remove2atxSi_tF", "Array.remove(at:)", .mutate(.removeAt), tag: "array.mutate_unknown")
        array("$sSa6insert_2atyxn_SitF", "Array.insert(_:at:)", .mutate(.insert))
        array("$sSasSQRzlE2eeoiySbSayxG_ABtFZ", "Array.==", .search(.equals))
        collection("$sSlsE7isEmptySbvg", "Collection.isEmpty", .read(.isEmpty), .unknown)
        collection("$sSlsE5first7ElementQzSgvg", "Collection.first", .read(.first), .unknown)
        collection("$sSKsE4last7ElementQzSgvg", "BidirectionalCollection.last", .read(.last), .unknown)
        collection("$sSmsSKRzrlE10removeLast7ElementSTQzyF", "removeLast()", .mutate(.removeLast), .array)
        collection("$sSmsSKRzrlE7popLast7ElementSTQzSgyF", "popLast()", .mutate(.popLast), .array)
        collection("$sSTsSQ7ElementRpzrlE8containsySbABF", "Sequence.contains(_:)", .search(.contains), .unknown)
        collection("$sSlsSQ7ElementRpzrlE10firstIndex2of0C0QzSgAB_tF", "Collection.firstIndex(of:)", .search(.firstIndex), .unknown)
        addHashedCollections(to: &t)
        collection(
            "$sSksSx5IndexRpzSnyABG7IndicesRtzSiAA_6StrideRTzrlE7indicesACvg", "RandomAccessCollection.indices", .read(.indices), .array)
        addRanges(to: &t)
        addStrings(to: &t)
        // Plan item L4: `for-in` iteration (`SILIterators.swift`). Exact; only array elements are unknown.
        func iteration(_ operation: IteratorOperation) -> StdlibSummary { .computed(.iterator(operation)) }
        add(
            "$sSlss16IndexingIteratorVyxG0B0RtzrlE04makeB0ACyF", "Collection.makeIterator()", iteration(.makeIndexingIterator),
            generic: true)
        add("$ss16IndexingIteratorV4next7ElementQzSgyF", "IndexingIterator.next()", iteration(.indexingNext), generic: true)
        add("$ss6stride4from2to2bys8StrideToVyxGx_x0E0QztSxRzlF", "stride(from:to:by:)", iteration(.stride), generic: true)
        add("$ss6stride4from7through2bys13StrideThroughVyxGx_x0E0QztSxRzlF", "stride(from:through:by:)", iteration(.stride), generic: true)
        add(
            "$ss8StrideToV12makeIterators0abD0VyxGyF", "StrideTo.makeIterator()", iteration(.makeStrideIterator(through: false)),
            generic: true)
        add(
            "$ss13StrideThroughV12makeIterators0abD0VyxGyF", "StrideThrough.makeIterator()", iteration(.makeStrideIterator(through: true)),
            generic: true)
        add("$ss16StrideToIteratorV4nextxSgyF", "StrideToIterator.next()", iteration(.strideNext(through: false)), generic: true)
        add("$ss21StrideThroughIteratorV4nextxSgyF", "StrideThroughIterator.next()", iteration(.strideNext(through: true)), generic: true)
        add("$sSTsE10enumerateds18EnumeratedSequenceVyxGyF", "Sequence.enumerated()", iteration(.enumerated), generic: true)
        add(
            "$ss18EnumeratedSequenceV12makeIteratorAB0D0Vyx_GyF", "EnumeratedSequence.makeIterator()", iteration(.makeEnumeratedIterator),
            generic: true)
        add(
            "$ss18EnumeratedSequenceV8IteratorV4nextSi6offset_7ElementQz7elementtSgyF", "EnumeratedSequence.Iterator.next()",
            iteration(.enumeratedNext), generic: true)
        addComposableArchitecture(to: &t)
        addObjectIdentity(to: &t)
        return t
    }()

    /// Standard-library value types whose protocol implementations cannot run code of the verified module.
    package static func isStandardType(_ text: String) -> Bool {
        if let wrapped = optionalWrapped(text) { return isStandardType(wrapped) }
        return standardTypes.contains(text.hasPrefix("Swift.") ? String(text.dropFirst(6)) : text)
    }

    /// `T` for the type text `Optional<T>` or `T?`.
    package static func optionalWrapped(_ text: String) -> String? {
        let t = text.hasPrefix("Swift.") ? String(text.dropFirst(6)) : text
        if t.hasPrefix("Optional<"), t.hasSuffix(">") { return String(t.dropFirst("Optional<".count).dropLast()) }
        if t.hasSuffix("?") { return String(t.dropLast()) }
        return nil
    }

    /// Whether a standard integer type is signed; nil for anything that is not a standard integer type.
    package static func integerKind(_ text: String) -> IntegerKind? {
        let t = text.hasPrefix("Swift.") ? String(text.dropFirst(6)) : text
        guard standardTypes.contains(t) else { return nil }
        if t.hasPrefix("Int") { return .signed }
        return t.hasPrefix("UInt") ? .unsigned : nil
    }

    /// The two kinds of standard integer types.
    package enum IntegerKind: Sendable { case signed, unsigned }

    private static let standardTypes: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Bool",
        "String", "Substring", "Character", "Double", "Float", "Float16",
    ]
}

extension StdlibSummary.Entry {
    /// The array model of a call with these substitutions; nil when the call is summarized another way. Throws for
    /// an array-only entry (`StdlibSummary.array`) called on something that is not an array.
    package func arrayOperation(for substitutions: [String]) throws -> StdlibSummary.ArrayOperation? {
        guard let arrayOperation else { return nil }
        if !onCollection || substitutions.count == 1 && TypeContext.arrayElement(substitutions[0]) != nil { return arrayOperation }
        guard summary != .array else {
            throw SILError.unsupported("\(name) on <\(substitutions.joined(separator: ", "))>, which is not an array")
        }
        return nil
    }

    /// Refuses a callee whose printed declaration carries a `[_semantics "…"]` tag this entry does not expect: then the
    /// symbol is not the function the summary was written for (a mistyped table row, or a changed standard library).
    package func checkSemantics(_ printed: Set<String>, of symbol: String) throws {
        let unexpected = printed.subtracting(semantics)
        guard unexpected.isEmpty else {
            let tags = unexpected.sorted().map { "[_semantics \"\($0)\"]" }.joined(separator: " ")
            throw SILError.unsupported(
                "call to \(name) (\(symbol)): its declaration carries \(tags), which the summary table does not expect")
        }
    }

    /// The generic substitution of a call to this entry, nil for a non-generic one. Throws when the call is
    /// outside what the summary covers: a different number of substitutions, or a type of the verified module
    /// for a summary that would otherwise hide that type's own code.
    package func subject(of substitutions: [String]) throws -> String? {
        guard isGeneric == !substitutions.isEmpty, substitutions.count <= 1 else {
            throw SILError.unsupported("call to \(name) with <\(substitutions.joined(separator: ", "))>")
        }
        guard let subject = substitutions.first else { return nil }
        let runsOnlyStandardCode: Set<StdlibSummary> = [.unknown, .minimum, .maximum]
        // `CGFloat`'s `Comparable` is its `Double`'s (`SILCGFloat.swift`): `min` and `max` read it like `Double`.
        let floatExtremum = summary != .unknown && subject == "CGFloat"
        if runsOnlyStandardCode.contains(summary), !StdlibSummary.isStandardType(subject), !floatExtremum {
            throw SILError.unsupported("\(name) on \(subject), a type outside the standard library")
        }
        return subject
    }

    /// `Swift.min(x, y)` is `y < x ? y : x` and `Swift.max(x, y)` is `y >= x ? y : x`; exact for integers.
    func extremum(of values: [[BV]], subject: String?, in c: CNFBuilder) throws -> BV {
        if let floating = floatExtremum(of: values, subject: subject, in: c) { return floating }
        guard let subject, let kind = StdlibSummary.integerKind(subject), values.count == 2,
            values.allSatisfy({ $0.count == 1 })
        else {
            throw SILError.unsupported("\(name) on \(subject ?? "?"), which is not an integer")
        }
        let (x, y) = (values[0][0], values[1][0])
        let yBelow = kind == .signed ? c.slt(y, x) : c.ult(y, x)
        return summary == .minimum ? c.select(yBelow, y, x) : c.select(yBelow, x, y)
    }
}

/// The operands of a call that is answered by a summary instead of by reading its body.
package struct SummarizedCall {
    /// The SSA name the call's direct result is bound to.
    package let id: String
    /// Argument names, the `@out` address first when there is one.
    package let names: [String]
    /// The direct result type (`()` when the result is returned through `@out`).
    package let type: ValueType
    /// Generic substitutions, for example `["Int32"]`.
    package let substitutions: [String]
    /// One convention per argument name.
    package let conventions: [ParameterConvention]
}

extension SILModule {
    /// The `[_semantics "…"]` tags of `symbol`, empty when none were printed.
    package func semanticsTags(of symbol: String) -> Set<String> { semantics[symbol] ?? [] }

    /// The summary of a call to `symbol`, nil when the call is not summarized. Throws `unsupported` when the callee's
    /// printed declaration carries a tag the entry does not expect (plan item R9).
    func summary(calling symbol: String) throws -> StdlibSummary.Entry? {
        if let witness = StdlibSummary.Entry.integerWitness(symbol) { return witness }
        if let value = try opaqueValueSummary(calling: symbol) { return value }
        guard let entry = StdlibSummary.table[symbol] else { return nil }
        try entry.checkSemantics(semanticsTags(of: symbol), of: symbol)
        return entry
    }

    /// Records the tags of `sil [_semantics "array.get_count"] … @symbol : …` (a declaration or a definition).
    static func recordSemanticsTags(_ line: String, into semantics: inout [String: Set<String>]) {
        guard line.hasPrefix("sil "), let at = line.range(of: " @") else { return }
        var attributes = line[..<at.lowerBound]
        while let open = attributes.range(of: "[_semantics \""), let close = attributes[open.upperBound...].range(of: "\"]") {
            let symbol = String(line[at.upperBound...].prefix { $0 != " " })
            semantics[symbol, default: []].insert(String(attributes[open.upperBound..<close.lowerBound]))
            attributes = attributes[close.upperBound...]
        }
    }
}
