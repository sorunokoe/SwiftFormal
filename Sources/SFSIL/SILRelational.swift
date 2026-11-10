// Reading guide
// What relational claims over walks need from the SIL reader (mapper verification, Phase 2; SFVerifyKit's
// `RelationalProofs.swift` makes the claims): `==` of two values of one type, as Swift synthesizes it, decided on their
// leaves, and whether a function's signature can hold a floating-point number (whose `==` is not equality of bits:
// `-0.0 == 0.0`, `nan != nan`; such claims are refused, not approximated).
// Tests: Tests/SFVerifyKitTests/RelationalProofTests.swift.

import Foundation
package import SFBV

extension ValueType {
    /// True exactly when `a` and `b` (each laid out as `leafWidths`) are equal by the `==` Swift synthesizes: every
    /// stored field equal; the same case, with equal payloads; strings by their identity (`StringIdentity`: equal
    /// handles exactly when the strings are `==`). Nil for a type whose leaves do not decide `==`: arrays, dictionaries
    /// and sets (their elements are not stored), and opaque values other than `String`. Scalars compare their bits, so
    /// the caller refuses floating-point types (`SILModule.holdsNoFloatingPoint`).
    package func equal(_ c: CNFBuilder, _ a: ArraySlice<BV>, _ b: ArraySlice<BV>) -> Int32? {
        guard a.count == leafWidths.count, b.count == a.count else { return nil }
        switch self {
        case .scalar: return c.eq(a[a.startIndex], b[b.startIndex])
        case .opaque(let name): return name == "String" ? c.eq(a[a.startIndex], b[b.startIndex]) : nil
        case .array, .hashed: return nil
        case .aggregate(_, let fields): return fieldsEqual(fields, c, a, b)
        case .enumeration(_, let cases): return casesEqual(cases, c, a, b)
        }
    }

    private func fieldsEqual(_ fields: [Field], _ c: CNFBuilder, _ a: ArraySlice<BV>, _ b: ArraySlice<BV>) -> Int32? {
        var all = c.trueLit
        var offset = 0
        for field in fields {
            let n = field.type.leafWidths.count
            let range = offset..<(offset + n)
            guard let same = field.type.equal(c, slice(a, range), slice(b, range)) else { return nil }
            all = c.and(all, same)
            offset += n
        }
        return all
    }

    private func casesEqual(_ cases: [Case], _ c: CNFBuilder, _ a: ArraySlice<BV>, _ b: ArraySlice<BV>) -> Int32? {
        let tagA = a[a.startIndex], tagB = b[b.startIndex]
        var all = c.eq(tagA, tagB)
        for (index, enumCase) in cases.enumerated() {
            guard let payload = enumCase.payload else { continue }
            let range = payloadLeafRange(ofCase: index)
            guard let same = payload.equal(c, slice(a, range), slice(b, range)) else { return nil }
            let active = c.eq(tagA, c.constant(UInt64(index), width: tagA.width))
            all = c.and(all, c.or(-active, same))
        }
        return all
    }

    /// True when `leaves` is a value of this type (see `validity`): the input assumption of a free value.
    package func isValid(_ c: CNFBuilder, _ leaves: ArraySlice<BV>) -> Int32 { validity(c, leaves) }

    /// The wrapped type of an `Optional`; nil for any other type.
    package var optionalWrapped: ValueType? {
        guard case .enumeration(let name, let cases) = self, name.hasPrefix("Optional<"), cases.count == 2 else { return nil }
        return cases[1].payload
    }

    /// The names of the structs and enums inside this type, itself included (`Optional`s and tuples by their parts).
    package var nominalNames: Set<String> {
        switch self {
        case .scalar, .opaque, .array, .hashed: return []
        case .aggregate(let name, let fields):
            let inner = fields.reduce(into: Set<String>()) { $0.formUnion($1.type.nominalNames) }
            return name.isEmpty || name.hasPrefix("@") ? inner : inner.union([name])
        case .enumeration(let name, let cases):
            let inner = cases.reduce(into: Set<String>()) { $0.formUnion($1.payload?.nominalNames ?? []) }
            return name.hasPrefix("Optional<") ? inner : inner.union([name])
        }
    }

    private func slice(_ leaves: ArraySlice<BV>, _ range: Range<Int>) -> ArraySlice<BV> {
        leaves[(leaves.startIndex + range.lowerBound)..<(leaves.startIndex + range.upperBound)]
    }
}

extension SILModule {
    /// The type texts of `symbol`'s parameters and result (the `@out` one when it returns indirectly), as SIL prints
    /// them; nil when the header is not read.
    package func signatureTypes(_ symbol: String) -> (parameters: [String], result: String)? {
        guard let header = header(of: symbol), let colon = header.range(of: " : $"), header.hasSuffix(" {"),
            let signature = FunctionSignature(String(header[colon.upperBound...].dropLast(2)))
        else { return nil }
        return (signature.parameters.map(\.type), signature.indirectResult ?? signature.result)
    }

    /// True when the type text `text` cannot hold a floating-point number, at any depth (in a field, a payload, an
    /// `Optional`, a tuple, a generic argument). False when it can, or when a type is not declared in the read
    /// modules (it might).
    package func holdsNoFloatingPoint(_ text: String) -> Bool { types.holdsNoFloatingPoint(text) }

    /// True when a read module defines an `==` that mentions one of the types `names` (by their last component): a
    /// hand-written equality, which the leaves of a value do not decide. The witness thunks of `Equatable` and the
    /// derived `__derived_struct_equals` / `__derived_enum_equals` do not count.
    package func definesEquality(mentioning names: Set<String>) -> Bool {
        let manglings = names.map { name -> String in
            let bare = name.prefix { $0 != "<" }.split(separator: ".").last.map(String.init) ?? name
            return "\(bare.utf8.count)\(bare)"
        }
        return symbols.contains { symbol in
            guard symbol.contains("2eeoi"), !symbol.contains("SQ2eeoi") else { return false }
            return manglings.contains { mangled in symbol.contains(mangled + "V") || symbol.contains(mangled + "O") }
        }
    }
}

extension TypeContext {
    private static let floatingPoint: Set = [
        "Double", "Float", "Float16", "Float80", "CGFloat", "Builtin.FPIEEE16", "Builtin.FPIEEE32", "Builtin.FPIEEE64",
        "Builtin.FPIEEE80",
    ]

    /// `SILModule.holdsNoFloatingPoint` for one type as SIL prints it.
    func holdsNoFloatingPoint(_ text: String, depth: Int = 0) -> Bool {
        let t = Self.bareType(text)
        let name = t.hasPrefix("Swift.") ? String(t.dropFirst(6)) : t
        guard depth < 16, !Self.floatingPoint.contains(name), !ambiguous.contains(t) else { return false }
        if scalarWidth(t) != nil || ["String", "()", "any Error"].contains(name) { return true }
        if (t.hasPrefix("@thin ") || t.hasPrefix("@thick ")) && t.hasSuffix(".Type") { return true }
        let next = depth + 1
        for prefix in ["Optional<", "Swift.Optional<"] where t.hasPrefix(prefix) && t.hasSuffix(">") {
            return holdsNoFloatingPoint(String(t.dropFirst(prefix.count).dropLast()), depth: next)
        }
        if t.hasSuffix("?") && !t.contains("->") { return holdsNoFloatingPoint(String(t.dropLast()), depth: next) }
        if t.hasPrefix("("), t.hasSuffix(")"), !t.contains("->") {
            return splitTopLevel(String(t.dropFirst().dropLast())).allSatisfy { element in
                guard let colon = element.firstIndex(of: ":"), element[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
                else { return holdsNoFloatingPoint(element, depth: next) }
                return holdsNoFloatingPoint(String(element[element.index(after: colon)...]), depth: next)
            }
        }
        return nominalHoldsNoFloatingPoint(t, depth: next)
    }

    /// The type text without its `$` and ownership convention.
    private static func bareType(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("$") { t.removeFirst() }
        for convention in ["@owned ", "@guaranteed ", "@in_guaranteed ", "@in ", "@closureCapture "] where t.hasPrefix(convention) {
            t.removeFirst(convention.count)
        }
        return t
    }

    /// `holdsNoFloatingPoint` for a struct or enum declared in a read module (generic ones with their arguments).
    private func nominalHoldsNoFloatingPoint(_ t: String, depth next: Int) -> Bool {
        if let fields = structs[t] { return fields.allSatisfy { holdsNoFloatingPoint($0.type, depth: next) } }
        if let cases = enums[t] { return cases.allSatisfy { $0.payload.map { holdsNoFloatingPoint($0, depth: next) } ?? true } }
        if let binary = binary.enums[t] {
            return binary.cases.allSatisfy { !$0.payloadUnknown && ($0.payload.map { holdsNoFloatingPoint($0, depth: next) } ?? true) }
        }
        guard t.hasSuffix(">"), let open = t.firstIndex(of: "<"), let declaration = generics[String(t[..<open])] else { return false }
        let arguments = splitTopLevel(String(t[t.index(after: open)..<t.index(before: t.endIndex)]))
        guard arguments.count == declaration.parameters.count, arguments.allSatisfy({ holdsNoFloatingPoint($0, depth: next) }) else {
            return false
        }
        let map = Dictionary(zip(declaration.parameters, arguments), uniquingKeysWith: { first, _ in first })
        return declaration.fields.allSatisfy { holdsNoFloatingPoint(substituting(map, in: $0.type), depth: next) }
            && declaration.cases.allSatisfy { $0.payload.map { holdsNoFloatingPoint(substituting(map, in: $0), depth: next) } ?? true }
    }
}
