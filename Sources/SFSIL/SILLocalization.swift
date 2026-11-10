import SFBV

// Reading guide
// Localization calls (`NSLocalizedString`, `String(localized:)`, a `localized…` method with no body): which key a
// rule picks, not what text the key gives.
//
// The text a key gives depends on the catalogue and the language, which logic does not read. So a localization call
// is an unknown function of its key: the same key (and table, bundle, value or locale) gives the same text in one
// run, and a call with another key gives an unknown text. That is congruence, not a fresh value per call
// (`CNFBuilder.opaqueResult`). It makes "two cases give the same text" refutable when they pick the same key, and
// "this case gives the text of key k" provable. The converse never holds: two keys may give the same text, so
// "the texts differ" is never proved from "the keys differ" (a counterexample that needs two keys to give the same
// text is not kept, `SILVerifier.run`). The determinism is an assumption the report names.
//
// `Bundle.main` and `Locale.current`, read by the default arguments of these calls, are each one value in a run.
// Part of `FunctionRun` (`SILFunctionRun.swift`).

/// The localization calls Scan reads as a function of their key, and the assumption they make.
package enum Localization {
    static let nsLocalizedString = "$s10Foundation17NSLocalizedString_9tableName6bundle5value7commentS2S_SSSgSo8NSBundleCS2StF"
    static let stringLocalized =
        "$sSS10FoundationE9localized5table6bundle6locale7commentS2SAAE17LocalizationValueV_SSSgSo8NSBundleCSgAA6LocaleVs12StaticStringVSgtcfC"
    /// `String.LocalizationValue(stringLiteral:)`: a literal key.
    static let literalKey = "$sSS10FoundationE17LocalizationValueV13stringLiteralACSS_tcfC"
    /// The default arguments `bundle: Bundle = .main` of `NSLocalizedString` and `locale: Locale = .current` of
    /// `String(localized:)`.
    static let stableDefaults: [String: String] = [
        nsLocalizedString + "fA1_": "Bundle.main",
        String(stringLocalized.dropLast(2)) + "fcfA2_": "Locale.current",
    ]

    /// The names `localize` leaves a result unknown under (`Verifier.honest`).
    package static let approximations: Set<String> = [
        "NSLocalizedString(_:tableName:bundle:value:comment:)", "String(localized:table:bundle:locale:comment:)", method,
    ]
    /// The approximation a `localized…` method with no body makes.
    static let method = "a `localized…` method with no body"

    static let assumption =
        "localization is deterministic: the same key, table, bundle and locale give the same text in one run (two keys may give the same text)"

    /// A method with no body whose name starts with `localized` and that returns a `String`: an app's own
    /// `"key".localized()`.
    static func isLocalizing(label: String, result: String) -> Bool {
        let name = label.prefix { $0 != "(" }.split(separator: ".").last ?? ""
        return name.hasPrefix("localized") && ["String", "Swift.String"].contains(Assumptions.typeText(result))
    }
}

extension FunctionRun {
    /// Encodes `request` when `target` is a localization call this file reads; false when it is not one.
    func encodeLocalization(_ target: String, _ request: SummarizedCall) throws -> Bool {
        if let name = Localization.stableDefaults[target] {
            // One value in a run: the same unknown each time it is read.
            let leaves = c.opaqueResult(name, of: c.constant(0, width: 1), fresh: fresh(try resultType(of: request)))
            try setResult(request, leaves)
            return true
        }
        switch target {
        case Localization.literalKey:
            // The key's text is the localization value's handle; only `String.LocalizationValue` reads it.
            guard request.conventions.first == .out, request.names.count == 3 else {
                throw SILError.invalid("String.LocalizationValue(stringLiteral:) of unexpected shape at \(request.id)")
            }
            try writeBack(try flat(request.names[1]), names: request.names, conventions: request.conventions)
            env[request.id] = make(request.type, [])
            return true
        case Localization.nsLocalizedString:
            // (key, tableName, bundle, value, comment): the comment does not change the text.
            try localize(request, name: "NSLocalizedString(_:tableName:bundle:value:comment:)", keys: 0..<4)
            return true
        case Localization.stringLocalized:
            // (key, table, bundle, locale, comment, String.Type).
            try localize(request, name: "String(localized:table:bundle:locale:comment:)", keys: 0..<4)
            return true
        default:
            return false
        }
    }

    /// The result of a localization call: an unknown function of the arguments `keys`.
    private func localize(_ request: SummarizedCall, name: String, keys: Range<Int>) throws {
        guard request.type.leafWidths == [64], keys.upperBound <= request.names.count else {
            throw SILError.invalid("\(name) of unexpected shape at \(request.id)")
        }
        let key = try localizationKey(request, keys)
        let text = c.opaqueResult("localization", of: key, fresh: [c.input(width: 64)])
        env[request.id] = make(request.type, text)
        out.approximations.insert(name)
        Assumptions.note(Localization.assumption)
    }

    /// A `localized…` method with no body (`encodeOpaqueCall`): its result is the same unknown function of the
    /// arguments, so the same key gives the same text. False when the method is not one.
    func localizeOpaqueCall(_ request: SummarizedCall, label: String, result: String) throws -> Bool {
        guard Localization.isLocalizing(label: label, result: result), request.type.leafWidths == [64] else { return false }
        let key = try localizationKey(request, request.names.indices)
        env[request.id] = make(request.type, c.opaqueResult("localization: \(label)", of: key, fresh: [c.input(width: 64)]))
        out.approximations.insert(Localization.method)
        Assumptions.note(Localization.assumption)
        return true
    }

    /// The arguments `indices` as one key: equal exactly when the values are (a payload a case does not hold is 0).
    private func localizationKey(_ request: SummarizedCall, _ indices: Range<Int>) throws -> BV {
        var bits: [Int32] = []
        for k in indices where request.conventions[k] != .out {
            let (argument, convention) = (request.names[k], request.conventions[k])
            let (type, leaves) = convention == .indirect ? try slotValue(argument) : (valueType(try lookup(argument)), try flat(argument))
            bits += (type.map { canonical($0, leaves[...]) } ?? leaves).flatMap(\.bits)
        }
        return BV(bits: bits)
    }

    /// `leaves` of a `type` value with the payloads of the cases it is not in set to 0.
    private func canonical(_ type: ValueType, _ leaves: ArraySlice<BV>) -> [BV] {
        guard type.leafWidths.count == leaves.count else { return Array(leaves) }
        switch type {
        case .aggregate(_, let fields):
            var (out, rest) = ([BV](), leaves)
            for field in fields {
                let n = field.type.leafWidths.count
                out += canonical(field.type, rest.prefix(n))
                rest = rest.dropFirst(n)
            }
            return out
        case .enumeration(_, let cases):
            let tag = leaves[leaves.startIndex]
            var (out, rest) = ([tag], leaves.dropFirst())
            for (k, item) in cases.enumerated() {
                guard let payload = item.payload else { continue }
                let n = payload.leafWidths.count
                let holds = c.eq(tag, c.constant(UInt64(k), width: tag.width))
                out += canonical(payload, rest.prefix(n)).map { c.select(holds, $0, c.constant(0, width: $0.width)) }
                rest = rest.dropFirst(n)
            }
            return out
        default:
            return Array(leaves)
        }
    }

    private func resultType(of request: SummarizedCall) throws -> ValueType {
        guard request.conventions.first == .out else { return request.type }
        return try slot(request.names[0]).type
    }

    private func setResult(_ request: SummarizedCall, _ leaves: [BV]) throws {
        if request.conventions.first == .out {
            try writeBack(leaves, names: request.names, conventions: request.conventions)
            env[request.id] = make(request.type, [])
        } else {
            env[request.id] = make(request.type, leaves)
        }
    }
}
