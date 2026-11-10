// Reading guide
// The associated types of a conformance (`associatedtype Output` of `protocol Mapper`), for generic bodies read at a
// concrete type (`SILGenerics.swift`). At `-Onone`, `X(input: x).execute()` calls the protocol extension's
// `execute()` with `<X>`, and its body names `Self.Output`. Each non-generic `sil_witness_table X: Mapper` says what
// that is: `associated_type Output: Int8`. Reading the body at `X` writes `Int8` for `Self.Output` (mapper plan T3).
// Only an exact entry of a non-generic table is used; two tables that disagree drop the entry; a nested associated
// type (`Self.Output.Element`), a generic conformance (`Box<Int8>`) or a missing entry is left as written, which
// never resolves, so the call stays `unsupported`.
// Tests: Tests/SFSILTests/SILForwarderTests.swift.

import Foundation

/// `"Rank.Output"` -> `Int8`, from the `associated_type` lines of the non-generic `sil_witness_table`s of a module.
struct AssociatedTypes: Sendable, Equatable {
    private(set) var types: [String: String] = [:]
    /// Keys that two tables (same-named types in two modules) disagree on; never filled in again, as witnesses.
    private(set) var conflicting: Set<String> = []

    /// Records the `associated_type Name: Type` lines of the non-generic witness table of `type`.
    mutating func add(of type: String, table: [String]) {
        for line in table { if let (name, concrete) = Self.entry(line) { add("\(type).\(name)", concrete) } }
    }

    mutating func link(_ other: Self) {
        for (key, type) in other.types { add(key, type) }
        conflicting.formUnion(other.conflicting)
        for key in conflicting { types[key] = nil }
    }

    private mutating func add(_ key: String, _ type: String) {
        guard !conflicting.contains(key) else { return }
        if let mine = types[key], mine != type {
            types[key] = nil
            conflicting.insert(key)
        } else {
            types[key] = type
        }
    }

    /// `associated_type Output: Int8` -> ("Output", "Int8"); nil for any other line of a witness table.
    private static func entry(_ raw: String) -> (name: String, type: String)? {
        let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("associated_type "), let colon = line.range(of: ": ") else { return nil }
        let name = line[line.index(line.startIndex, offsetBy: "associated_type ".count)..<colon.lowerBound]
        let type = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !type.isEmpty else { return nil }
        return (String(name), type)
    }
}

extension SILModule {
    /// The type a conformance of `type` gives its associated type `name`, from a non-generic witness table.
    package func associatedType(of type: String, _ name: String) -> String? {
        associatedTypes.types["\(type).\(name)"]
    }

    /// `text` with each type parameter replaced (`substitutingTypeParameters`), and each `P.Name` whose `P` is replaced
    /// by `X` replaced by `X`'s associated type `Name` when a witness table gives it. `P.Name.More` is left alone.
    func substitutingParameters(_ map: [String: String], in text: String) -> String {
        guard text.contains("."), !associatedTypes.types.isEmpty else { return substitutingTypeParameters(map, in: text) }
        var result = ""
        var index = text.startIndex
        var quoted = false
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                result.append(character)
                if character == "\"" { quoted = false }
                index = text.index(after: index)
                continue
            }
            guard Self.isWordCharacter(character) else {
                if character == "\"" { quoted = true }
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let end = text[index...].firstIndex { !Self.isWordCharacter($0) } ?? text.endIndex
            let word = String(text[index..<end])
            let isMember = result.last == "." || result.last == "@"
            if !isMember, result.last != "#", let concrete = map[word],
                let (type, after) = associatedTypeUse(of: concrete, in: text, at: end)
            {
                result += type
                index = after
                continue
            }
            result += isMember ? word : (map[word] ?? word)
            index = end
        }
        return result
    }

    /// The associated type of `concrete` that `.Name` at `position` names, and where its name ends; nil when there is
    /// none, the name is followed by another member, or no witness table gives it.
    private func associatedTypeUse(of concrete: String, in text: String, at position: String.Index) -> (String, String.Index)? {
        guard position < text.endIndex, text[position] == "." else { return nil }
        let start = text.index(after: position)
        let end = text[start...].firstIndex { !Self.isWordCharacter($0) } ?? text.endIndex
        guard start < end, text[start].isLetter || text[start] == "_" else { return nil }
        if end < text.endIndex, text[end] == ".", text.index(after: end) < text.endIndex,
            Self.isWordCharacter(text[text.index(after: end)])
        {
            return nil
        }
        guard let type = associatedType(of: concrete, String(text[start..<end])) else { return nil }
        return (type, end)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
