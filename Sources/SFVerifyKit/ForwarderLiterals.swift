/// Swift source without comments, with each string and regex literal replaced by `""`, for `ForwarderSource`.
/// Soundness review P1: a `/*` inside `"""…"""`, `#"…"#`, `#/…/#` or an interpolation is not a comment, so it must not
/// hide the declarations after it. Nil when a comment or literal is not closed, when braces do not balance, or when a
/// bare `/` that may start a regex literal shares its line with a quote or a comment: the file is then unknown, never
/// "declares nothing".
struct LiteralFreeSource {
    private let characters: [Character]
    private var index = 0
    private var out: [Character] = []

    static func text(_ source: String) -> String? {
        var reader = LiteralFreeSource(characters: Array(source))
        guard reader.code(closing: false) else { return nil }
        var depth = 0
        for character in reader.out {
            if character == "{" { depth += 1 } else if character == "}" { depth -= 1 }
            if depth < 0 { return nil }
        }
        return depth == 0 ? String(reader.out) : nil
    }

    private init(characters: [Character]) { self.characters = characters }

    private func at(_ offset: Int) -> Character? {
        index + offset < characters.count ? characters[index + offset] : nil
    }

    private func hashes(from start: Int) -> Int {
        var count = 0
        while start + count < characters.count, characters[start + count] == "#" { count += 1 }
        return count
    }

    /// Code up to the end of the text, or (`closing`) up to the `)` that ends an interpolation, which is kept.
    private mutating func code(closing: Bool) -> Bool {
        var depth = 0
        var mayHoldRegex = false
        while let character = at(0) {
            if character.isNewline { mayHoldRegex = false }
            if closing, closesInterpolation(character, depth: &depth) {
                out.append(character)
                index += 1
                return true
            }
            if character == "/", at(1) == "/" || at(1) == "*" {
                guard !mayHoldRegex, skipComment() else { return false }
                continue
            }
            let count = hashes(from: index)
            if character == "\"" || (count > 0 && at(count) == "\"") {
                guard !mayHoldRegex, string(hashes: count) else { return false }
                continue
            }
            if count > 0, at(count) == "/" {
                guard !mayHoldRegex, regex(hashes: count) else { return false }
                continue
            }
            if character == "/", mayStartRegex() { mayHoldRegex = true }
            out.append(character)
            index += 1
        }
        return !closing
    }

    /// Whether `character` is the `)` that closes the interpolation; tracks the nested parentheses in `depth`.
    private func closesInterpolation(_ character: Character, depth: inout Int) -> Bool {
        if character == "(" { depth += 1 }
        guard character == ")" else { return false }
        if depth == 0 { return true }
        depth -= 1
        return false
    }

    /// A `//` comment up to its newline, or a block comment, which leaves a space.
    private mutating func skipComment() -> Bool {
        if at(1) == "/" {
            while let next = at(0), !next.isNewline { index += 1 }
            return true
        }
        guard skipBlockComment() else { return false }
        out.append(" ")
        return true
    }

    /// `/* … */`, nested ones included.
    private mutating func skipBlockComment() -> Bool {
        var depth = 0
        while let character = at(0) {
            if character == "/", at(1) == "*" {
                depth += 1
                index += 2
            } else if character == "*", at(1) == "/" {
                depth -= 1
                index += 2
                if depth == 0 { return true }
            } else {
                index += 1
            }
        }
        return false
    }

    /// A string literal starting at `index` with `hashes` `#`s; an interpolation's code is read like any code.
    private mutating func string(hashes: Int) -> Bool {
        let multiline = at(hashes) == "\"" && at(hashes + 1) == "\"" && at(hashes + 2) == "\""
        index += hashes + (multiline ? 3 : 1)
        while let character = at(0) {
            if character == "\\", self.hashes(from: index + 1) == hashes {
                index += 1 + hashes
                if at(0) == "(" {
                    index += 1
                    let saved = out
                    guard code(closing: true) else { return false }
                    out = saved
                } else {
                    index += 1
                }
                continue
            }
            if character.isNewline, !multiline { return false }
            let quotes = multiline ? 3 : 1
            if character == "\"", (0..<quotes).allSatisfy({ at($0) == "\"" }), self.hashes(from: index + quotes) >= hashes {
                index += quotes + hashes
                out += ["\"", "\""]
                return true
            }
            index += 1
        }
        return false
    }

    /// An extended regex literal `#/ … /#` starting at `index`.
    private mutating func regex(hashes: Int) -> Bool {
        index += hashes + 1
        while let character = at(0) {
            if character == "\\" {
                index += 2
                continue
            }
            if character == "/", self.hashes(from: index + 1) >= hashes {
                index += 1 + hashes
                out += ["\"", "\""]
                return true
            }
            index += 1
        }
        return false
    }

    /// Whether the `/` at `index` may start a bare regex literal: not followed by a space, and not after an operand.
    private func mayStartRegex() -> Bool {
        guard let next = at(1), !next.isWhitespace else { return false }
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        return !(previous.isLetter || previous.isNumber || "_)]}\"`".contains(previous))
    }
}
