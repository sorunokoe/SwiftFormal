import Foundation

/// The lines a function covers in its source file, found from where the compiler's debug info puts it (the name of
/// a `func` or `init`, the `{` of a computed property, the `get` or `set` keyword): from the attributes and doc comment
/// above the declaration to the `}` that closes its body. Used to pick the function a cursor is in (`--at`).
///
/// It reads only what decides where a body is: brackets, strings (with interpolation, multi-line and raw) and comments.
/// A declaration whose body it cannot find (a stored property, a protocol requirement, an unbalanced file) covers its
/// declaration line only, so a cursor further down is not taken as inside it.
package struct SourceRanges {
    private let bytes: [UInt8]
    /// Whether each byte is code, not part of a comment or a string literal.
    private let isCode: [Bool]
    /// The offset where each line starts (line 1 at index 0).
    private let lineStarts: [Int]

    /// Scans `text` once for comments, string literals and line starts.
    package init(_ text: String) {
        bytes = Array(text.utf8)
        var mask = [Bool](repeating: true, count: bytes.count)
        var scanner = CodeScanner(bytes: bytes, mask: mask)
        _ = scanner.code(from: 0, closingParen: false)
        mask = scanner.mask
        isCode = mask
        var starts = [0]
        for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") { starts.append(index + 1) }
        lineStarts = starts
    }

    /// The first and last line of the function whose debug location is `line`:`column` (both 1-based).
    ///
    /// A function the compiler writes (a memberwise init, a class's `__allocating_init` or `deinit`, an inherited init)
    /// is placed at its type's name or at the `{` of the type's body. Its body is not the type's: it covers the line it
    /// is placed on only.
    package func range(line: Int, column: Int) -> ClosedRange<Int> {
        guard line >= 1, line <= lineStarts.count else { return line...line }
        let start = min(lineStarts[line - 1] + max(column - 1, 0), lineEnd(line))
        if isTypeDeclaration(at: start) { return line...line }
        let first = firstLine(of: line)
        guard let open = bodyStart(from: start), let close = matchingBrace(open) else { return first...line }
        return first...self.line(of: close)
    }

    /// Just after the `{` that opens the body of the function whose debug location is `line`:`column` (both 1-based),
    /// as a 0-based line and UTF-16 column; nil when it has no body that closes (a requirement, an unbalanced file).
    /// A `{` inside the signature's brackets (a closure default argument) is not the body's.
    package func bodyOpening(line: Int, column: Int) -> (line: Int, character: Int)? {
        guard line >= 1, line <= lineStarts.count else { return nil }
        let start = min(lineStarts[line - 1] + max(column - 1, 0), lineEnd(line))
        guard !isTypeDeclaration(at: start), let open = bodyStart(from: start), matchingBrace(open) != nil else { return nil }
        let braceLine = self.line(of: open)
        let prefix = String(bytes: bytes[lineStarts[braceLine - 1]...open], encoding: .utf8) ?? ""
        return (braceLine - 1, prefix.utf16.count)
    }

    /// Whether `start` is in the header of a type declaration (`struct`, `class`, `enum`, `actor`, `extension`,
    /// `protocol`): at its name or at the `{` that opens its body. The header is read back from `start` to the `{`, `}`,
    /// `;` or open bracket before it, outside brackets, as words and punctuation; a type keyword, not after `.`,
    /// `import`, `let`, `var` or `case`, followed directly by a name (not a keyword, as in `class func`) is a type
    /// declaration.
    private func isTypeDeclaration(at start: Int) -> Bool {
        var end = start
        while end < bytes.count, isCode[end], Self.isWordByte(bytes[end]) { end += 1 }
        let tokens = self.tokens(headerStart(before: start)..<end)
        for (position, token) in tokens.enumerated().dropLast() where Self.typeKeywords.contains(token) {
            guard position == 0 || !Self.notBeforeTypes.contains(tokens[position - 1]) else { continue }
            let name = tokens[position + 1]
            guard let first = name.utf8.first else { continue }
            if first == UInt8(ascii: "`") || (Self.isWordByte(first) && !Self.isDigit(first) && !Self.memberKeywords.contains(name)) {
                return true
            }
        }
        return false
    }

    /// Where the declaration or statement `start` is in begins: after the `{`, `}`, `;` or open bracket before it.
    private func headerStart(before start: Int) -> Int {
        var headerStart = start
        var depth = 0
        while headerStart > 0, !isCode[headerStart - 1] || !Self.isHeaderEnd(bytes[headerStart - 1], depth: &depth) {
            headerStart -= 1
        }
        return headerStart
    }

    /// Whether `byte`, read backwards at bracket depth `depth`, ends the header before it; updates `depth`.
    private static func isHeaderEnd(_ byte: UInt8, depth: inout Int) -> Bool {
        switch byte {
        case UInt8(ascii: ")"), UInt8(ascii: "]"): depth += 1
        case UInt8(ascii: "("), UInt8(ascii: "["):
            if depth == 0 { return true }
            depth -= 1
        case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: ";"): return depth == 0
        default: break
        }
        return false
    }

    /// The words and punctuation of the code in `range` outside brackets.
    private func tokens(_ range: Range<Int>) -> [String] {
        var tokens: [String] = []
        var depth = 0
        var index = range.lowerBound
        while index < range.upperBound {
            let byte = bytes[index]
            if isCode[index], Self.isWordByte(byte) {
                var wordEnd = index
                while wordEnd < range.upperBound, isCode[wordEnd], Self.isWordByte(bytes[wordEnd]) { wordEnd += 1 }
                if depth == 0 { tokens.append(String(bytes: bytes[index..<wordEnd], encoding: .utf8) ?? "") }
                index = wordEnd
                continue
            }
            if isCode[index] {
                switch byte {
                case UInt8(ascii: "("), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: ")"), UInt8(ascii: "]"): depth -= 1
                case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"): break
                default: if depth == 0 { tokens.append(String(UnicodeScalar(byte))) }
                }
            }
            index += 1
        }
        return tokens
    }

    private static let typeKeywords: Set = ["struct", "class", "enum", "actor", "extension", "protocol"]
    /// Tokens after which a type keyword declares no type (`import struct Foundation.Date`, `let actor`, `.class`).
    private static let notBeforeTypes: Set = [".", "import", "let", "var", "case"]
    /// Words that can follow `class` (or `actor`, `enum` used as a name) where no type is declared.
    private static let memberKeywords: Set = [
        "func", "var", "let", "subscript", "init", "deinit", "static", "final", "override", "convenience", "required",
        "mutating", "nonmutating", "public", "private", "fileprivate", "internal", "open", "package", "typealias", "lazy",
        "weak", "unowned", "dynamic", "nonisolated", "case", "in", "is", "as",
    ]

    private static func isWordByte(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "_") || byte >= 0x80 || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) || isDigit(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

    /// `line`, moved up over the attribute and doc-comment lines directly above it.
    private func firstLine(of line: Int) -> Int {
        var first = line
        while first > 1 {
            let text = self.text(ofLine: first - 1).trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("@") || text.hasPrefix("///") else { break }
            first -= 1
        }
        return first
    }

    /// The `{` that opens the body of the declaration at `start`, or nil when it has none: a `}` or `;` comes first,
    /// or a line ends and the next one does not go on with the signature.
    private func bodyStart(from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < bytes.count {
            if isCode[index] {
                switch bytes[index] {
                case UInt8(ascii: "("), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: ")"), UInt8(ascii: "]"): depth -= 1
                case UInt8(ascii: "{") where depth <= 0: return index
                case UInt8(ascii: "}") where depth <= 0, UInt8(ascii: ";") where depth <= 0: return nil
                case UInt8(ascii: "\n") where depth <= 0: if !continuesSignature(after: index) { return nil }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    /// Whether the first code on the lines after the newline at `newline` goes on with a declaration's signature.
    private func continuesSignature(after newline: Int) -> Bool {
        let blank: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n")]
        var index = newline + 1
        while index < bytes.count, !isCode[index] || blank.contains(bytes[index]) { index += 1 }
        return ["{", "->", "throws", "rethrows", "async", "where"].contains { word in
            word.utf8.enumerated().allSatisfy { offset, byte in index + offset < bytes.count && bytes[index + offset] == byte }
        }
    }

    private func matchingBrace(_ open: Int) -> Int? {
        var depth = 0
        for index in open..<bytes.count where isCode[index] {
            if bytes[index] == UInt8(ascii: "{") { depth += 1 }
            if bytes[index] == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private func line(of offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    private func lineEnd(_ line: Int) -> Int { line < lineStarts.count ? lineStarts[line] - 1 : bytes.count }

    private func text(ofLine line: Int) -> String {
        String(bytes: bytes[lineStarts[line - 1]..<lineEnd(line)], encoding: .utf8) ?? ""
    }
}

/// Marks the bytes of comments and string literals as not code, following interpolations back into code.
private struct CodeScanner {
    let bytes: [UInt8]
    var mask: [Bool]

    private func at(_ index: Int, _ text: String) -> Bool {
        var position = index
        for byte in text.utf8 {
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
        }
        return true
    }

    private mutating func clear(_ range: Range<Int>) {
        for index in range where index < mask.count { mask[index] = false }
    }

    /// Code from `start` to the end, or, with `closingParen`, to the `)` that closes an interpolation (its index).
    mutating func code(from start: Int, closingParen: Bool) -> Int {
        var index = start
        var depth = 0
        while index < bytes.count {
            if at(index, "//") {
                index = skipLineComment(index)
            } else if at(index, "/*") {
                index = skipBlockComment(index)
            } else if bytes[index] == UInt8(ascii: "#") || bytes[index] == UInt8(ascii: "\"") {
                index = string(index)
            } else {
                if bytes[index] == UInt8(ascii: "(") { depth += 1 }
                if bytes[index] == UInt8(ascii: ")") {
                    if closingParen, depth == 0 { return index }
                    depth -= 1
                }
                index += 1
            }
        }
        return index
    }

    private mutating func skipLineComment(_ start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
        clear(start..<index)
        return index
    }

    private mutating func skipBlockComment(_ start: Int) -> Int {
        var index = start
        var depth = 0
        while index < bytes.count {
            if at(index, "/*") {
                depth += 1
                index += 2
            } else if at(index, "*/") {
                depth -= 1
                index += 2
                if depth == 0 { break }
            } else {
                index += 1
            }
        }
        clear(start..<index)
        return index
    }

    /// A string literal at `start` (`"`, `"""`, or raw with `#`s), or a lone `#` (`#if`, `#selector`) that is code.
    private mutating func string(_ start: Int) -> Int {
        var hashes = 0
        while start + hashes < bytes.count, bytes[start + hashes] == UInt8(ascii: "#") { hashes += 1 }
        let quote = start + hashes
        guard quote < bytes.count, bytes[quote] == UInt8(ascii: "\"") else { return start + max(hashes, 1) }
        let multiline = at(quote, "\"\"\"")
        let close = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
        let escape = "\\" + String(repeating: "#", count: hashes)
        var index = quote + (multiline ? 3 : 1)
        var literalStart = start
        while index < bytes.count {
            if at(index, close) {
                index += close.utf8.count
                break
            }
            if at(index, escape) {
                let after = index + escape.utf8.count
                if after < bytes.count, bytes[after] == UInt8(ascii: "(") {
                    clear(literalStart..<after + 1)
                    let end = code(from: after + 1, closingParen: true)
                    literalStart = end
                    index = end + 1
                    continue
                }
                index = after + 1
                continue
            }
            if !multiline, bytes[index] == UInt8(ascii: "\n") { break }
            index += 1
        }
        clear(literalStart..<index)
        return index
    }
}
