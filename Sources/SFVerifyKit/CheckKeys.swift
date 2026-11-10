import Foundation

/// The keys `swiftformal check` links walks to scanned functions by: `Type.member`, read from a scanned function's name
/// and from a walk's subject.
extension Check {
    /// `Type.member` for a scanned function name: drops `static`, argument labels, generic parameters,
    /// accessor suffixes and the `, scope N` of closures. An operator keeps its symbol: `static Rank.< infix(_:_:)` →
    /// `Rank.<`.
    public static func functionKey(_ name: String) -> String {
        var s = Substring(name)
        if s.hasPrefix("static ") { s = s.dropFirst(7) }
        if let comma = s.firstIndex(of: ",") { s = s[..<comma] }
        if let paren = s.firstIndex(of: "(") { s = s[..<paren] }
        // Generic parameters follow a name (`map<A>`, `== infix<A>`); a `<` after a dot is the operator `Rank.<`.
        if let angle = s.indices.first(where: { s[$0] == "<" && $0 > s.startIndex && isIdentifierCharacter(s[s.index(before: $0)]) }) {
            s = s[..<angle]
        }
        for fixity in [" infix", " prefix", " postfix"] where s.hasSuffix(fixity) { s = s.dropLast(fixity.count) }
        if let member = operatorMember(s) { return member.owner + "." + member.symbol }
        var parts = s.split(separator: ".").map(String.init)
        let accessors: Set = ["getter", "setter", "modify", "read", "didset", "willset", "unsafeAddressor", "unsafeMutableAddressor"]
        while parts.count > 1, let last = parts.last, accessors.contains(last) { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    /// The leading `Type.member` (or `Type`) of a walk subject: `"SupportedLocale.matching(identifier:)"` →
    /// `SupportedLocale.matching`, `"ConditionsCustomStore without overlay"` → `ConditionsCustomStore`. An operator after
    /// the type is the member: `"LoadingState.=="` → `LoadingState.==`, not the whole type.
    public static func subjectKey(_ subject: String) -> String {
        var rest = Substring(subject).drop { $0 == "." }
        var names: [Substring] = []
        while true {
            let name = rest.prefix(while: isIdentifierCharacter)
            guard !name.isEmpty else { break }
            names.append(name)
            rest = rest.dropFirst(name.count)
            guard rest.first == "." else { break }
            rest = rest.dropFirst()
            let symbol = rest.prefix(while: isOperatorCharacter)
            if !symbol.isEmpty, rest.first.map(isIdentifierCharacter) != true {
                return names.joined(separator: ".") + "." + symbol
            }
        }
        return names.joined(separator: ".")
    }

    /// `Rank` and `<` for `Rank.<`: an operator symbol after the last dot (`Version....` is `Version` and `...`).
    private static func operatorMember(_ key: Substring) -> (owner: String, symbol: Substring)? {
        let run = key.reversed().prefix(while: isOperatorCharacter).count
        guard run >= 2 else { return nil }
        let operatorStart = key.index(key.endIndex, offsetBy: -run)
        guard operatorStart > key.startIndex, key[operatorStart] == ".",
            isIdentifierCharacter(key[key.index(before: operatorStart)])
        else { return nil }
        return (String(key[..<operatorStart]), key[key.index(after: operatorStart)...])
    }

    /// A character of a Swift operator made of ASCII symbols.
    static func isOperatorCharacter(_ character: Character) -> Bool { "/=-+!*%<>&|^~?.".contains(character) }

    /// Whether a walk with `subjectKey` covers the function with `functionKey`: the same `Type.member`, or a
    /// subject that names only the type (a walk over a whole reducer or model) and the function is one of its members.
    public static func covers(subjectKey: String, functionKey: String) -> Bool {
        guard let first = subjectKey.first, !subjectKey.isEmpty else { return false }
        if subjectKey == functionKey { return true }
        guard !subjectKey.contains("."), first.isUppercase else { return false }
        return functionKey.hasPrefix(subjectKey + ".")
    }

}
