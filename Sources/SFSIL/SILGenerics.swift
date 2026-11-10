import Foundation
import SFBV
import SFCNF

// Plan item L7: calls to the module's own generic functions at `-Onone`. At `-Onone` the compiler does not specialize:
// `useClamp` calls `clampG<T: Comparable>` as `apply %13<Int8>(…)`, and the body of `clampG` names its parameter `T`.
// A call with substitutions reads that body at the call site's concrete types: the text of the body with `T` replaced
// by `Int8`, parsed like any other function, under the key `symbol<Int8>`. A `witness_method $Int8, #Comparable."<"`
// in it is resolved for the concrete type, through the module's own witness tables or, for the comparisons of a
// standard integer type, through `IntegerWitness`. Nothing is ever proved "for all T": the generic function itself is
// still refused (its parameter types do not resolve), and every refusal below is fail-closed.

extension SILModule {
    /// The key `function(_:)` reads `symbol` under at these substitutions: `symbol<Int8, Square>`. Mangled names never
    /// contain `<`, so a key is never a real symbol. Throws `unsupported` when the call cannot be read soundly: the callee
    /// is not a generic function of the read modules, a substitution is not a concrete type logic models (an
    /// existential, a class, an associated type, a type parameter), or a parameter name could also mean a type.
    package func specialize(_ symbol: String, _ substitutions: [String]) throws(SILError) -> String {
        let call = "generic call to \(symbol) with <\(substitutions.joined(separator: ", "))>"
        // `$s` and a digit: a module of the package (`$s2Gn…`); standard-library symbols start `$ss` or `$sS`.
        guard symbol.hasPrefix("$s"), symbol.dropFirst(2).first?.isNumber == true, let header = header(of: symbol) else {
            throw SILError.unsupported("\(call): not a generic function of the read modules")
        }
        let parameters = try GenericClause(header: header, symbol: symbol).parameters
        guard parameters.count == substitutions.count else {
            throw SILError.unsupported("\(call): \(parameters.count) generic parameters")
        }
        for name in parameters where !isSubstitutable(name) {
            throw SILError.unsupported("\(call): the generic parameter \(name) cannot be told apart from a type name in SIL")
        }
        for substitution in substitutions { try requireConcrete(substitution, in: call) }
        return "\(symbol)<\(substitutions.joined(separator: ", "))>"
    }

    /// The header and body of the function a specialization key names, written at its substitutions; nil when `key` is
    /// not a key. `function(_:)` parses them under the key.
    func specializedText(_ key: String) throws(SILError) -> (header: String, body: [String])? {
        guard let angle = key.firstIndex(of: "<"), key.hasSuffix(">") else { return nil }
        let symbol = String(key[..<angle])
        let substitutions = splitTopLevel(String(key[key.index(after: angle)..<key.index(before: key.endIndex)]))
        _ = try specialize(symbol, substitutions)
        guard let header = header(of: symbol), let body = bodyLines(of: symbol) else {
            throw SILError.unsupported("no body for \(symbol) (external or not emitted)")
        }
        let clause = try GenericClause(header: header, symbol: symbol)
        let map = Dictionary(zip(clause.parameters, substitutions), uniquingKeysWith: { first, _ in first })
        let concreteHeader = substitutingParameters(map, in: clause.headerWithoutClause)
        var lines: [String] = []
        var resolvedWitnesses: Set<String> = []
        for raw in body {
            var line = substitutingParameters(map, in: stripComment(raw).trimmingCharacters(in: .whitespaces))
            if let witness = try resolveWitnessMethod(line, in: key) {
                resolvedWitnesses.insert(witness.id)
                line = "\(witness.id) = function_ref @\(witness.symbol) : $()"
            }
            lines.append(Self.droppingSubstitutions(of: resolvedWitnesses, in: line))
        }
        return (concreteHeader, lines)
    }

    /// A type parameter name that can only mean the parameter: an identifier that starts with a capital letter and is not
    /// the name of a type the read modules declare or of a standard type (SIL prints both the same way).
    private func isSubstitutable(_ name: String) -> Bool {
        guard let first = name.first, first.isUppercase, !name.hasPrefix("τ_"),
            name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return false }
        if types.structs[name] != nil || types.enums[name] != nil || types.generics[name] != nil || types.rejected[name] != nil
            || types.ambiguous.contains(name)
        {
            return false
        }
        return !Self.standardTypeNames.contains(name) && (try? types.resolve(name)) == nil
    }

    /// Names that the standard library declares and SIL prints unqualified.
    private static let standardTypeNames: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Bool", "String",
        "Substring", "Character", "Double", "Float", "Float16", "Array", "Optional", "Dictionary", "Set", "Range",
        "ClosedRange", "Never", "Void", "Any", "AnyObject", "AnyHashable", "Error", "Hasher", "Result",
        "StaticString", "IndexingIterator", "StrideTo", "StrideThrough", "EnumeratedSequence", "Slice", "Builtin",
    ]

    /// Fails unless `text` is a type logic models whose every part is concrete: no existential, opened archetype, type
    /// parameter or function type, it resolves, destroying it runs no code of the read modules (`destroy_addr` of a `T`
    /// is not encoded), and every generic argument of it resolves too (a generic argument a type never stores is not
    /// checked by resolving the type itself).
    private func requireConcrete(_ text: String, in call: String) throws(SILError) {
        let t = text.trimmingCharacters(in: .whitespaces)
        for marker in ["any ", "some ", "@opened", "τ_", "each ", "->", "@"] where t.contains(marker) {
            throw SILError.unsupported("\(call): \(t) is not a concrete type")
        }
        do {
            _ = try types.resolve(t)
        } catch {
            throw SILError.unsupported("\(call): \(error)")
        }
        guard types.destroysWithoutModuleCode(t) else {
            throw SILError.unsupported("\(call): destroying a \(t) may run code of this module")
        }
        for part in Self.typeArguments(t) { try requireConcrete(part, in: call) }
    }

    /// The types written inside `t`: generic arguments (`Pair<A, B>`), tuple elements, the element of `[X]` and `X?`.
    private static func typeArguments(_ t: String) -> [String] {
        if let element = TypeContext.arrayElement(t) { return [element] }
        if t.hasSuffix("?") { return [String(t.dropLast())] }
        if t.hasPrefix("("), t.hasSuffix(")") {
            return splitTopLevel(String(t.dropFirst().dropLast())).map { element in
                guard let colon = element.firstIndex(of: ":"), element[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
                else { return element }
                return String(element[element.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard t.hasSuffix(">"), let open = t.firstIndex(of: "<") else { return [] }
        return splitTopLevel(String(t[t.index(after: open)..<t.index(before: t.endIndex)]))
    }

    /// `%8 = witness_method $Square, #Shape.area : … : $…` -> ("%8", the witness for `Square`). Nil for any other line.
    /// Only an exact entry of a non-generic witness table of the read modules, whose thunk is not generic, or a
    /// comparison of a standard integer type (`IntegerWitness`), resolves; anything else is refused.
    private func resolveWitnessMethod(_ line: String, in key: String) throws(SILError) -> (id: String, symbol: String)? {
        guard let eq = line.range(of: " = witness_method $") else { return nil }
        guard let method = WitnessMethodLine(line), isValue(method.id) else {
            throw SILError.unsupported("witness_method in \(key): \(line)")
        }
        let (id, type, requirement) = (method.id, method.type, method.requirement)
        if let symbol = IntegerWitness.symbol(type: type, requirement: requirement) { return (id, symbol) }
        if let symbol = types.opaqueValueWitness("$" + line[eq.upperBound...]) { return (id, symbol) }
        guard !mayHaveUnknownWitness(type: type, requirement: requirement),
            let symbol = methodWitness(type: type, requirement: requirement)
        else {
            throw SILError.unsupported(
                "witness_method \(requirement) of \(type) in \(key): no exact witness in a non-generic witness table of the read modules")
        }
        guard let header = header(of: symbol), let colonDollar = header.range(of: " : $"),
            let signature = FunctionSignature(String(header[colonDollar.upperBound...].dropLast(2))), !signature.isGeneric
        else {
            throw SILError.unsupported(
                "witness_method \(requirement) of \(type) in \(key): its witness \(symbol) is generic or has no body")
        }
        return (id, symbol)
    }

    /// `apply %8<Square>(%0)` -> `apply %8(%0)` for each `%8` that now names a concrete witness: its `Self` substitution
    /// is part of the witness.
    private static func droppingSubstitutions(of ids: Set<String>, in line: String) -> String {
        guard !ids.isEmpty else { return line }
        for opcode in ["= apply ", "try_apply ", "= begin_apply "] {
            guard let at = line.range(of: opcode) else { continue }
            let callee = line[at.upperBound...]
            for id in ids where callee.hasPrefix(id + "<") {
                let open = callee.index(callee.startIndex, offsetBy: id.count)
                guard let close = matchingClose(callee[open...], open: "<", close: ">") else { return line }
                return String(line[..<at.upperBound]) + id + String(callee[callee.index(after: close)...])
            }
        }
        return line
    }

    /// `text` with each type parameter replaced. Quoted text, member names after a dot (`X.T`, `#Pair.T`) and the
    /// words of an `@attribute` are left alone.
    func substitutingTypeParameters(_ map: [String: String], in text: String) -> String {
        var result = ""
        var word = ""
        var quoted = false
        var skip = false
        func flush() {
            result += skip ? word : (map[word] ?? word)
            word = ""
        }
        for character in text {
            if quoted {
                result.append(character)
                if character == "\"" { quoted = false }
                continue
            }
            if character.isLetter || character.isNumber || character == "_" {
                if word.isEmpty { skip = result.last == "." || result.last == "@" }
                word.append(character)
                continue
            }
            flush()
            if character == "\"" { quoted = true }
            result.append(character)
        }
        flush()
        return result
    }
}

/// The generic clause of a function's header: `$@convention(thin) <T, U where T : Comparable> (…) -> …`.
private struct GenericClause {
    /// The parameter names in order (`τ_0_0`, `τ_0_1`, … at the call site).
    let parameters: [String]
    /// The header with the clause removed, so that it reads like a non-generic function's.
    let headerWithoutClause: String

    init(header: String, symbol: String) throws(SILError) {
        guard let signature = header.range(of: " : $@convention("),
            let close = header[signature.upperBound...].firstIndex(of: ")")
        else { throw SILError.unsupported("generic call to \(symbol): signature \(header)") }
        let afterConvention = header.index(after: close)
        let rest = header[afterConvention...].drop { $0 == " " }
        guard rest.hasPrefix("<"), let end = matchingClose(rest, open: "<", close: ">") else {
            throw SILError.unsupported("generic call to \(symbol), which is not generic")
        }
        var inner = String(rest[rest.index(after: rest.startIndex)..<end])
        if let clause = inner.range(of: " where ") { inner = String(inner[..<clause.lowerBound]) }
        parameters = splitTopLevel(inner)
        guard !parameters.isEmpty, parameters.allSatisfy({ !$0.contains(" ") && !$0.contains(":") }) else {
            throw SILError.unsupported("generic call to \(symbol): parameter packs and inline constraints are not read")
        }
        headerWithoutClause = String(header[..<afterConvention]) + " " + String(rest[rest.index(after: end)...].drop { $0 == " " })
    }
}

/// `Equatable.==` and `Comparable.<`, `<=`, `>`, `>=` of a standard integer type (and `Bool.==`), reached through a
/// `witness_method` in a generic body read at that type. The standard library's witnesses compare the two values with
/// `Builtin.cmp_*` (`IntegerTypes.swift.gyb`, `Bool.swift`): exact, and they never trap. Trusted (docs/TRUST.md); checked
/// against the hand-specialized comparison in `SILGenericTests`.
package enum IntegerWitness {
    /// The key a witness is called by, `witness:Int8:#Comparable."<"`: never a real symbol (those start with `$`).
    package static func symbol(type: String, requirement: String) -> String? {
        let name = type.hasPrefix("Swift.") ? String(type.dropFirst(6)) : type
        guard let kind = comparisons[requirement] else { return nil }
        if name == "Bool" { return kind == .equal ? "witness:Bool:\(requirement)" : nil }
        return StdlibSummary.integerKind(name) == nil ? nil : "witness:\(name):\(requirement)"
    }

    /// The comparison of the witness `symbol` calls, nil when `symbol` is not one.
    package static func comparison(_ symbol: String) -> Operands? {
        guard symbol.hasPrefix("witness:"), let colon = symbol.range(of: ":#") else { return nil }
        let type = String(symbol[symbol.index(symbol.startIndex, offsetBy: 8)..<colon.lowerBound])
        guard let kind = comparisons["#" + symbol[colon.upperBound...]], let width = scalarWidth(type) else { return nil }
        return Operands(kind: kind, signed: StdlibSummary.integerKind(type) == .signed, width: width)
    }

    package enum Comparison: Sendable, Hashable { case equal, less, lessOrEqual, greater, greaterOrEqual }

    /// A comparison of two `width`-bit integers.
    package struct Operands: Sendable, Hashable {
        package let kind: Comparison
        package let signed: Bool
        package let width: Int
    }

    private static let comparisons: [String: Comparison] = [
        "#Equatable.\"==\"": .equal, "#Comparable.\"<\"": .less, "#Comparable.\"<=\"": .lessOrEqual,
        "#Comparable.\">\"": .greater, "#Comparable.\">=\"": .greaterOrEqual,
    ]

    /// `a <kind> b` on `width`-bit values.
    static func encode(_ kind: Comparison, signed: Bool, _ a: BV, _ b: BV, in c: CNFBuilder) -> Int32 {
        let less: (BV, BV) -> Int32 = signed ? { c.slt($0, $1) } : { c.ult($0, $1) }
        switch kind {
        case .equal: return c.eq(a, b)
        case .less: return less(a, b)
        case .lessOrEqual: return -less(b, a)
        case .greater: return less(b, a)
        case .greaterOrEqual: return -less(a, b)
        }
    }
}
