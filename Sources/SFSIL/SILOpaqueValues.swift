import Foundation
import SFBV
import SFCNF

// Foundation and SwiftUI value types that real app state is full of: `UUID`, `URL`, `Locale`, `Date` and SwiftUI's
// `Color`. One such stored property used to make every accessor and the synthesized `==`/`hash(into:)` of its struct
// unsupported. Logic now holds each of them as one opaque 64-bit handle (`ValueType.opaque`), like a `String`:
//
// - Holding, copying, passing, storing in a struct, enum or `Optional`, and destroying a value never trap, and run no
//   code of the read modules (destroying a `Color` is refused while some deinit of the read modules runs code: SwiftUI
//   may hold a platform colour object of the app).
// - A handle stands for the value according to `Identity` (below). `==` is exact for `UUID`, true for two copies of one
//   `URL` or `Locale` and unknown otherwise, and unknown for `Color`. A `Date`'s handle is the `Double` it wraps, and
//   its `==`, `<` and arithmetic are Foundation's IEEE operations on it (`SILFoundationValues.swift`, which adds more
//   types: `Decimal`, `Calendar`, `Image`, ...).
// - The calls in `OpaqueValues.table` are read; any other is an assumed call with `OpaqueCallMode.all` and refused
//   otherwise (`SILFoundationValues.swift`, `unreadCall`). A result such
//   a call makes (`UUID()`, `URL(string:)`, `uuidString`, `hashValue`, ...) is unknown, so it is recorded as an
//   approximation: a counterexample that needs a particular result is reported as undecided, never as `mayTrap`.
//   A value derived from a handle (`uuidString`, `hashValue`, `timeIntervalSince1970`, ...) is the same for the same
//   handle within one query (`CNFBuilder.opaqueResults`): the real getters are functions of the value.
// - Two fresh values (`UUID()` twice) get two unknown handles: logic proves them neither equal nor different.
//
// SIL prints these types without their module, so a name is used only after the compile probe that confirms package
// types (`SILModule.confirmPackageTypes`, `TypeNameCheck`) showed that, with this code's imports, the bare name means
// the Foundation or SwiftUI type, and only when no read module declares a type of that name. The summaries are keyed by
// mangled symbol, which names the module. They are not standard library, so they are kept out of `StdlibSummary.table`
// and the standard-library pin; `SILOpaqueValueTests` checks every symbol against real `swiftc` output instead.

/// The Foundation and SwiftUI value types logic holds as opaque handles, and the calls on them it reads.
package enum OpaqueValues {
    /// What a handle of the type says about `==`.
    package enum Identity: Sendable, Hashable {
        /// The handle is the value: `==` is handle equality (the type's `==` compares bytes: `UUID`).
        case value
        /// Two copies of one value have the same handle, and `==` is reflexive: same handle gives true; otherwise unknown.
        case copy
        /// `==` is unknown, even on the same handle (`Color` compares opaque boxes; `Date` reads its own, see `DateOperation`).
        case none
    }

    /// How logic holds one of these types.
    package struct Kind: Sendable {
        /// The module that declares the type.
        package let module: String
        /// The mangled prefix of the type's members (`$s10Foundation4UUIDV`).
        let prefix: String
        let identity: Identity
        /// True when a value may hold an object the app made (a platform colour), so destroying it may run a deinit of
        /// the read modules.
        let holdsAppObjects: Bool
    }

    /// The types, by the bare name SIL prints.
    package static let types: [String: Kind] = [
        "UUID": Kind(module: "Foundation", prefix: "$s10Foundation4UUIDV", identity: .value, holdsAppObjects: false),
        "URL": Kind(module: "Foundation", prefix: "$s10Foundation3URLV", identity: .copy, holdsAppObjects: false),
        "Locale": Kind(module: "Foundation", prefix: "$s10Foundation6LocaleV", identity: .copy, holdsAppObjects: false),
        "Date": Kind(module: "Foundation", prefix: "$s10Foundation4DateV", identity: .none, holdsAppObjects: false),
        "Color": Kind(module: "SwiftUI", prefix: "$s7SwiftUI5ColorV", identity: .none, holdsAppObjects: true),
    ].merging(moreTypes) { first, _ in first }

    /// What a read call does.
    package enum Operation: Sendable, Hashable {
        /// `==`, by the type's `Identity`.
        case equals
        /// A new value (`UUID()`, `URL(string:)`, `Date.now`): unknown, of the result's layout (an `Optional` may be nil).
        case make
        /// A value the getter computes from the operand (`uuidString`, `hashValue`): unknown, the same for the same handle.
        case derived
        /// Unknown results, and every `inout` argument (the `Hasher` of `hash(into:)`) unknown afterwards.
        case unknown
        /// Exact, on the `Double` a `Date` is (`SILFoundationValues.swift`).
        case date(DateOperation)
        /// A call `table` does not read, under `OpaqueCallMode.all`: as `unknown`, and a listed assumption.
        case assumed
    }

    /// One read call: the type it belongs to, the member (`==`, `hash(into:)`, ... as witnesses name it), what it does.
    package struct Call: Sendable, Hashable {
        package let type: String
        package let member: String
        package let operation: Operation
    }

    /// Every read call, by mangled symbol, checked against `-emit-sil -Onone` output of Swift 6.4 on macOS 27. None of
    /// them can trap: they compare, hash, print, parse or make a value, and report failure with nil.
    package static let table: [String: StdlibSummary.Entry] = {
        var t: [String: StdlibSummary.Entry] = [:]
        func add(_ type: String, _ suffix: String, _ member: String, _ operation: Operation) {
            guard let kind = types[type] else { return }
            let name = member.first == "(" ? "\(type)\(member)" : "\(type).\(member)"
            t[kind.prefix + suffix] = StdlibSummary.Entry(
                name: name, summary: .computed(.opaqueValue(Call(type: type, member: member, operation: operation))), isGeneric: false)
        }
        for type in ["UUID", "URL", "Locale", "Date", "Color"] {
            add(type, "2eeoiySbAC_ACtFZ", "==", type == "Date" ? .date(.compare("oeq")) : .equals)
            add(type, "4hash4intoys6HasherVz_tF", "hash(into:)", .unknown)
            add(type, "9hashValueSivg", "hashValue", .derived)
            add(type, "11descriptionSSvg", "description", .derived)
        }
        add("UUID", "ACycfC", "()", .make)
        add("UUID", "10uuidStringACSgSSh_tcfC", "(uuidString:)", .make)
        add("UUID", "10uuidStringSSvg", "uuidString", .derived)
        add("UUID", "16debugDescriptionSSvg", "debugDescription", .derived)
        add("URL", "6stringACSgSSh_tcfC", "(string:)", .make)
        add("URL", "14absoluteStringSSvg", "absoluteString", .derived)
        add("Locale", "7currentACvgZ", "current", .make)
        add("Locale", "10identifierACSS_tcfC", "(identifier:)", .make)
        add("Locale", "10identifierSSvg", "identifier", .derived)
        add("Date", "ACycfC", "()", .make)
        add("Date", "3nowACvgZ", "now", .make)
        add("Date", "21timeIntervalSince1970ACSd_tcfC", "(timeIntervalSince1970:)", .date(.make(since1970: true)))
        add("Date", "21timeIntervalSince1970Sdvg", "timeIntervalSince1970", .date(.interval(since1970: true)))
        add("Date", "1loiySbAC_ACtFZ", "<", .date(.compare("olt")))
        add("Color", "7opacityyACSdF", "opacity(_:)", .unknown)
        for color in ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown"]
            + ["white", "gray", "black", "clear", "primary", "secondary"]
        {
            add("Color", "\(color.count)\(color)ACvgZ", color, .make)
        }
        add("Color", "06accentC0ACvgZ", "accentColor", .make)
        addMoreCalls(add)
        return t
    }()

    /// The protocol requirements a `witness_method` on one of these types may name, and the member that implements them.
    static let witnessMembers: [String: String] = [
        "#Equatable.\"==\"": "==", "#Hashable.hash": "hash(into:)", "#Hashable.hashValue!getter": "hashValue",
        "#CustomStringConvertible.description!getter": "description", "#Comparable.\"<\"": "<",
        "#Comparable.\"<=\"": "<=", "#Comparable.\">\"": ">", "#Comparable.\">=\"": ">=",
    ]

    /// The symbol of `member` of `type` in `table`.
    static func symbol(type: String, member: String) -> String? {
        table.first { _, entry in
            guard case .computed(.opaqueValue(let call)) = entry.summary else { return false }
            return call.type == type && call.member == member
        }?.key
    }

    /// Why a call into one of these types that `table` does not read is refused, nil for any other symbol.
    static func unreadCall(_ symbol: String) -> String? {
        guard let (name, _) = types.first(where: { symbol.hasPrefix($0.value.prefix) }) else { return nil }
        let read = table.values.compactMap { entry -> String? in
            guard case .computed(.opaqueValue(let call)) = entry.summary, call.type == name else { return nil }
            return entry.name
        }
        return "Scan holds a \(name) as an opaque value and reads only \(read.sorted().joined(separator: ", "))"
    }
}

extension ComputedSummary {
    /// `OpaqueValues.Call`: compares, makes or derives opaque handles (see `SILOpaqueValues.swift`).
    func encodeOpaqueValue(_ value: OpaqueValues.Call, _ call: ComputedCall, in c: CNFBuilder, fresh: (ValueType) -> [BV]) throws
        -> ComputedEffect
    {
        guard call.substitutions.isEmpty || call.substitutions == [value.type] else {
            throw SILError.unsupported("call to \(call.name) with <\(call.substitutions.joined(separator: ", "))>")
        }
        // The values read: by value or through an `@in`/`@in_guaranteed` address; metatypes have no leaves.
        let operands = zip(call.inputs, call.conventions).filter { $1 == .value || $1 == .indirect }.map(\.0).filter { !$0.isEmpty }
        let returnsThroughAddress = call.conventions.first == .out
        let output = returnsThroughAddress ? call.writtenTypes.first : call.resultType
        guard let output, !returnsThroughAddress || call.resultType.leafWidths.isEmpty else {
            throw SILError.invalid("\(call.name) of unexpected shape")
        }
        var effect = ComputedEffect()
        /// Binds the call's result (direct or `@out`) to `leaves`; every other written argument becomes unknown.
        func deliver(_ leaves: [BV]) throws {
            guard leaves.map(\.width) == output.leafWidths else { throw SILError.invalid("\(call.name): result of unexpected shape") }
            let others = call.writtenTypes.dropFirst(returnsThroughAddress ? 1 : 0).flatMap(fresh)
            (effect.result, effect.writtenBack) = returnsThroughAddress ? ([], leaves + others) : (leaves, others)
        }
        switch value.operation {
        case .equals:
            guard operands.count == 2, operands.allSatisfy({ $0.map(\.width) == [64] }), output.leafWidths == [1] else {
                throw SILError.invalid("\(call.name) of unexpected shape")
            }
            let (holds, exact) = Self.equality(operands[0][0], operands[1][0], OpaqueValues.types[value.type]?.identity ?? .none, in: c)
            try deliver([BV(bits: [holds])])
            if !exact { effect.approximations.insert(call.name) }
        case .make, .unknown:
            try deliver(fresh(output))
            effect.approximations.insert(call.name)
        case .date(let operation):
            return try encodeDate(operation, call, in: c)
        case .assumed:
            return encodeAssumed(call, value, fresh: fresh)
        case .derived:
            guard let key = operands.first, key.map(\.width) == [64] else { throw SILError.invalid("\(call.name) without its value") }
            try deliver(c.opaqueResult(call.name, of: key[0], fresh: fresh(output)))
            effect.approximations.insert(call.name)
        }
        return effect
    }
}

extension ComputedSummary {
    /// `a == b` on two handles of a type with `identity`, and whether that is the real result for every value.
    fileprivate static func equality(_ a: BV, _ b: BV, _ identity: OpaqueValues.Identity, in c: CNFBuilder) -> (holds: Int32, exact: Bool) {
        let same = c.eq(a, b)
        switch identity {
        case .value: return (same, true)
        case .copy: return (c.or(same, c.input(width: 1).bits[0]), same == c.trueLit)
        case .none: return (c.input(width: 1).bits[0], false)
        }
    }
}

extension CNFBuilder {
    /// The result of the getter `name` on the handle `key`: `unknown` the first time, and for a handle met before, what
    /// it gave then. At most 64 handles per getter are remembered; past that a result is just unknown (still sound).
    func opaqueResult(_ name: String, of key: BV, fresh unknown: [BV]) -> [BV] {
        var result = unknown
        let seen = opaqueResults[name] ?? []
        for (earlier, value) in seen.reversed() where value.map(\.width) == unknown.map(\.width) {
            let same = eq(key, earlier)
            result = zip(value, result).map { select(same, $0, $1) }
        }
        if seen.count < 64 { opaqueResults[name, default: []].append((key, result)) }
        return result
    }
}

extension TypeContext {
    /// The layout of the Foundation or SwiftUI value type `t` (`OpaqueValues`), if this build confirmed the bare name
    /// and no read module declares it.
    func opaqueValueType(_ t: String) throws(SILError) -> ValueType? {
        guard let kind = confirmedOpaqueValue(t) else { return nil }
        let layout = ValueType.opaque(name: t)
        return kind.holdsAppObjects ? try heldUnlessDeinitsRunCode(t, layout) : layout
    }

    /// The `OpaqueValues` entry of `t`, when this build confirmed the name and no read module declares a type of it.
    func confirmedOpaqueValue(_ t: String) -> OpaqueValues.Kind? {
        guard confirmedPackageTypes.contains(t), let kind = OpaqueValues.types[t] else { return nil }
        let declared = structs[t] != nil || enums[t] != nil || generics[t] != nil || rejected[t] != nil || ambiguous.contains(t)
        return declared ? nil : kind
    }

    /// The type texts of every stored property and enum payload the read modules declare.
    var declaredTypeTexts: [String] {
        structs.values.flatMap { $0.map(\.type) } + enums.values.flatMap { $0.compactMap(\.payload) }
            + generics.values.flatMap { $0.fields.map(\.type) + $0.cases.compactMap(\.payload) }
    }

    /// `witness_method $URL, #Equatable."==" : …`: the symbol of the member that implements the requirement, for a
    /// confirmed `OpaqueValues` type; nil for anything else. The conformance is Foundation's (or SwiftUI's), whose
    /// witness for each of these requirements is the type's own member of that name.
    func opaqueValueWitness(_ rest: String) -> String? {
        guard rest.hasPrefix("$"), let comma = rest.range(of: ", #"), let colon = rest[comma.upperBound...].range(of: " : ") else {
            return nil
        }
        let type = String(rest[rest.index(after: rest.startIndex)..<comma.lowerBound])
        guard confirmedOpaqueValue(type) != nil, let member = OpaqueValues.witnessMembers["#" + rest[comma.upperBound..<colon.lowerBound]]
        else { return nil }
        return OpaqueValues.symbol(type: type, member: member)
    }
}

extension TypeContext {
    /// The instruction `%3 = witness_method $URL, #Equatable."==" : …` as a reference to the member that implements the
    /// requirement (`opaqueValueWitness`); any other instruction the parser does not know is refused.
    func opaqueValueWitness(head: String, result: String, rest: String, line: String) throws(SILError) -> Instruction {
        guard head == "witness_method", let symbol = opaqueValueWitness(rest) else { throw SILError.unsupported("instruction: \(line)") }
        return .functionRef(result: result, symbol: symbol)
    }
}

extension SILModule {
    /// True when `type` is a confirmed `OpaqueValues` type: comparing, hashing or printing it runs no code of the read
    /// modules (only Foundation's or SwiftUI's), like a standard-library value type.
    package func isOpaqueValue(_ type: String) -> Bool { types.confirmedOpaqueValue(type) != nil }

    /// True for a standard-library value type or a confirmed `OpaqueValues` type: its `==`, `hash(into:)` and printing
    /// cannot run code of the read modules.
    func hasLibraryConformance(_ type: String) -> Bool { StdlibSummary.isStandardType(type) || isOpaqueValue(type) }

    /// The summary of a read call on an `OpaqueValues` type, nil for any other symbol. Like a standard-library entry, it
    /// is refused when the callee's printed declaration carries a `[_semantics]` tag (none of these has one).
    func opaqueValueSummary(calling symbol: String) throws -> StdlibSummary.Entry? {
        guard let entry = try OpaqueValues.table[symbol] ?? assumedOpaqueValueCall(symbol) else { return nil }
        try entry.checkSemantics(semanticsTags(of: symbol), of: symbol)
        return entry
    }

    /// The `OpaqueValues` names this code may use: those its SIL mentions, when it imports some module beyond the
    /// standard library (a type may come through a re-export, as `UUID` comes through SwiftUI). The probe decides.
    var opaqueValueCandidates: [(name: String, module: String)] {
        let standard: Set<String> = ["Builtin", "Swift", "SwiftShims"]
        guard imports.contains(where: { !standard.contains($0) && !$0.hasPrefix("_") }) else { return [] }
        let mentioned = mentionedNames(Set(OpaqueValues.types.keys))
        return OpaqueValues.types.filter { mentioned.contains($0.key) }.map { ($0.key, $0.value.module) }
    }

    /// Which of `names` occur as a whole word in a signature, a body or a stored property of the read modules.
    func mentionedNames(_ names: Set<String>) -> Set<String> {
        var found: Set<String> = []
        func scan(_ text: String) {
            for name in names where !found.contains(name) && Self.containsWord(text, name) { found.insert(name) }
        }
        for symbol in symbols {
            if let header = header(of: symbol) { scan(header) }
            for line in bodyLines(of: symbol) ?? [] where found.count < names.count { scan(line) }
            if found.count == names.count { return found }
        }
        types.declaredTypeTexts.forEach(scan)
        return found
    }

    private static func containsWord(_ text: String, _ word: String) -> Bool {
        guard text.containsText(word) else { return false }
        var start = text.startIndex
        while let range = text.range(of: word, range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            func isIdentifier(_ ch: Character?) -> Bool { ch.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
            if !isIdentifier(before), !isIdentifier(after) { return true }
            start = range.upperBound
        }
        return false
    }
}
