import Foundation

// Which `@Verify` functions have a `verify_<name>()` walk, read from the source text: the hint of a promise that only a
// test can check names the walk only where the macro writes one.

extension BuildCheck {
    /// Whether `@Verify` writes a `verify_` walk for the function declared from `declarationLine`: always with
    /// `over:`; without it, only when it has parameters and none is surely not `Finite`. The same rule as the macro
    /// (`Parameter.isSurelyNotFinite` in SwiftFormalMacros), read from the text.
    static func hasWalk(attribute: String, declarationLine: Int, in lines: [String]) -> Bool {
        if attribute.contains("over:") { return true }
        guard let parameters = parameterList(from: declarationLine, in: lines), !parameters.isEmpty else { return false }
        return !parameters.contains(where: isSurelyNotFinite)
    }

    /// The parameters of the function declared from `line`, as written (`_ name: String? = nil`), across lines.
    private static func parameterList(from line: Int, in lines: [String]) -> [String]? {
        let text = lines[line...].prefix(40).joined(separator: "\n")
        guard let name = text.range(of: #"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*\s*(<[^>]*>)?\s*\("#, options: .regularExpression) else {
            return nil
        }
        var depth = 1
        var current = ""
        var parameters: [String] = []
        for character in text[name.upperBound...] {
            if "([<".contains(character) { depth += 1 }
            if ")]>".contains(character) { depth -= 1 }
            if depth == 0 { break }
            if depth == 1, character == "," {
                parameters.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parameters.append(current) }
        return parameters
    }

    private static func isSurelyNotFinite(_ parameter: String) -> Bool {
        guard let colon = parameter.firstIndex(of: ":") else { return true }
        var type = parameter[parameter.index(after: colon)...].split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
        type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if type.hasPrefix("inout ") || type.hasSuffix("...") || type.hasPrefix("some ") || type.hasPrefix("any ") || type.hasPrefix("[")
            || type.hasPrefix("(") || type.hasPrefix("@")
        {
            return true
        }
        while type.hasSuffix("?") || type.hasSuffix("!") { type.removeLast() }
        if type.hasPrefix("Optional<"), type.hasSuffix(">") { type = String(type.dropFirst("Optional<".count).dropLast()) }
        let base = type.split(separator: "<").first.map(String.init) ?? type
        let name = base.split(separator: ".").last.map(String.init) ?? base
        return typesThatAreNotFinite.contains(name)
    }

    /// The standard library and Foundation types that are not `Finite`, as in SwiftFormalMacros.
    private static let typesThatAreNotFinite: Set<String> = [
        "String", "Substring", "Character", "Unicode", "Int", "Int16", "Int32", "Int64", "Int128", "UInt", "UInt16",
        "UInt32", "UInt64", "UInt128", "Double", "Float", "Float16", "Float80", "CGFloat", "Decimal", "Date", "URL",
        "UUID", "Data", "Array", "ContiguousArray", "ArraySlice", "Dictionary", "Set", "Range", "ClosedRange",
        "Result", "Error", "AnyHashable", "Any", "AnyObject", "Locale", "TimeZone", "Calendar", "DateComponents",
        "TimeInterval", "Measurement", "IndexPath", "NSNumber", "NSString", "NSObject",
    ]
}
