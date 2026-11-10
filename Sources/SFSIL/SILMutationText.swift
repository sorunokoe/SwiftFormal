import Foundation

/// Reading the SIL text of one body for `SILModule.mutants(of:limit:)`.
enum MutationText {
    /// The instruction without its `, loc …` and `// …` tails.
    static func code(_ line: String) -> String {
        let stripped = stripComment(line)
        guard let r = stripped.range(of: ", loc ") else { return stripped.trimmingCharacters(in: .whitespaces) }
        return String(stripped[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// The `, loc …, scope N` tail of a line (without the comment), or "".
    static func location(_ line: String) -> String {
        let stripped = stripComment(line)
        guard let r = stripped.range(of: ", loc ") else { return "" }
        return String(stripped[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// `%5` for `%5 = builtin …`; nil for a line that defines no single value.
    static func definedValue(_ line: String) -> String? {
        let code = code(line)
        guard code.hasPrefix("%"), let eq = code.range(of: " = ") else { return nil }
        let value = String(code[..<eq.lowerBound])
        return value.allSatisfy { $0 == "%" || $0.isNumber } ? value : nil
    }

    /// `bb1` for `bb1(%7 : $Values):` or `bb1:`.
    static func blockLabel(_ line: String) -> String? {
        guard line.hasPrefix("bb") else { return nil }
        let label = String(line.prefix { $0.isLetter || $0.isNumber })
        return label.count > 2 ? label : nil
    }

    /// `[("%0", "Values"), ("%1", "*State")]` for `bb0(%0 : $Values, %1 : $*State):`.
    static func blockParameters(_ line: String) -> [(name: String, type: String)] {
        guard let open = line.firstIndex(of: "("), let close = matchingParen(line, from: open) else { return [] }
        return splitTopLevel(String(line[line.index(after: open)..<close])).compactMap { parameter in
            guard let colon = parameter.range(of: " : ") else { return nil }
            // `%0 : @closureCapture $*State`, `%1 : @owned $S`: attributes come before the type.
            var type = String(parameter[colon.upperBound...])
            while type.hasPrefix("@"), let space = type.firstIndex(of: " ") { type = String(type[type.index(after: space)...]) }
            guard type.hasPrefix("$") else { return nil }
            return (String(parameter[..<colon.lowerBound]), String(type.dropFirst()))
        }
    }

    /// `// %0 "self"` gives (`%0`, `self`).
    static func debugName(_ line: String) -> (value: String, name: String)? {
        guard line.hasPrefix("// %"), let quote = line.firstIndex(of: "\"") else { return nil }
        let value = String(line.dropFirst(3).prefix { $0 != " " })
        let rest = line[line.index(after: quote)...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return (value, String(rest[..<end]))
    }

    /// The parameter types and the direct result of `sil … @f : $@convention(…) (A, @inout B) -> R {`. Nil for a
    /// generic function, whose parameters are substituted.
    static func signature(_ header: String) -> (parameters: [String], result: String)? {
        guard let colon = header.range(of: " : $"), header.hasSuffix(" {") else { return nil }
        var type = String(header[colon.upperBound...].dropLast(2))
        guard !type.contains("<τ"), !type.contains("@substituted") else { return nil }
        while type.hasPrefix("@") {
            var index = type.index(after: type.startIndex)
            while index < type.endIndex, type[index].isLetter || type[index] == "_" { index = type.index(after: index) }
            if index < type.endIndex, type[index] == "(", let close = matchingParen(type, from: index) {
                index = type.index(after: close)
            }
            type = String(type[index...]).trimmingCharacters(in: .whitespaces)
        }
        guard type.hasPrefix("("), let close = matchingParen(type, from: type.startIndex) else { return nil }
        let parameters = splitTopLevel(String(type[type.index(after: type.startIndex)..<close]))
        let rest = type[type.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("-> ") else { return nil }
        var result = String(rest.dropFirst(3))
        for attribute in ["@owned ", "@unowned "] where result.hasPrefix(attribute) { result = String(result.dropFirst(attribute.count)) }
        return (parameters, result)
    }

    /// The index of the `)` that closes the `(` at `open`.
    static func matchingParen(_ text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static let operatorNames: [String: String] = [
        "cmp_slt": "<", "cmp_sle": "<=", "cmp_sgt": ">", "cmp_sge": ">=", "cmp_ult": "<", "cmp_ule": "<=",
        "cmp_ugt": ">", "cmp_uge": ">=", "cmp_eq": "==", "cmp_ne": "!=",
        "sadd_with_overflow": "+", "ssub_with_overflow": "-", "uadd_with_overflow": "+", "usub_with_overflow": "-",
        "smul_with_overflow": "*", "umul_with_overflow": "*", "add": "&+", "sub": "&-", "mul": "&*",
        "and": "&", "or": "|", "xor": "^",
    ]

    /// `cmp_slt -> cmp_sle (Int8)` reads `< becomes <=`; `literal 3 -> 4 (Int8)` reads `the constant 3 becomes 4`.
    static func describe(_ audit: String) -> String {
        let words = audit.split(separator: " ").map(String.init)
        if audit.hasPrefix("literal"), words.count >= 4 { return "the constant \(words[1]) becomes \(words[3])" }
        guard words.count >= 3, let from = operatorNames[words[0]], let to = operatorNames[words[2]] else { return audit }
        return "\(from) becomes \(to)"
    }

    /// The `Builtin.IntN` width of the standard integer types and `Bool`.
    static let integerWidths: [String: Int] = [
        "Int8": 8, "Int16": 16, "Int32": 32, "Int64": 64, "Int": 64,
        "UInt8": 8, "UInt16": 16, "UInt32": 32, "UInt64": 64, "UInt": 64, "Bool": 1,
    ]
}
