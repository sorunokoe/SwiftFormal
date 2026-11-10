import Foundation

// Reading guide
// The arguments a catalogue text reads (`StringsLint.swift`): each conversion of its formats, at the position it
// reads (`n$`, or the next one), as a type class. `%#@name@` reads the argument and type its substitution gives.

extension StringsLint {
    struct Why: Error { let text: String }

    static func name(_ type: Character) -> String {
        switch type {
        case "i": "an integer (%d)"
        case "l": "a 64-bit integer (%ld)"
        case "f": "a floating-point number (%f)"
        case "@": "an object (%@)"
        case "s": "a C string (%s)"
        case "p": "a pointer (%p)"
        default: "any value"
        }
    }

    /// The argument each conversion of the entry's formats reads: position → type class ("i" int, "l" 64-bit int,
    /// "f" floating, "@" object, "s" C string, "p" pointer, "?" unknown).
    static func signature(_ entry: Entry) -> Result<[Int: Character], Why> {
        var types: [Int: Character] = [:]
        for format in entry.formats {
            var reader = FormatReader(s: Array(format.unicodeScalars))
            do {
                while let (position, type) = try reader.next(entry.substitutions) {
                    if let clash = record(&types, position, type, format) { return .failure(clash) }
                }
            } catch {
                return .failure(Why(text: "\(error.text) in \(format.debugDescription)"))
            }
        }
        return .success(types)
    }

    private static func record(_ types: inout [Int: Character], _ at: Int, _ type: Character, _ format: String) -> Why? {
        if let earlier = types[at], earlier != type, earlier != "?", type != "?" {
            return Why(text: "argument \(at + 1) is read as \(name(earlier)) and as \(name(type)) (\(format.debugDescription))")
        }
        if types[at] == nil || types[at] == "?" { types[at] = type }
        return nil
    }

    static func typeClass(_ spec: [Unicode.Scalar]) -> Character {
        guard let kind = spec.last else { return "?" }
        let long = spec.dropLast().contains { "lqzjt".unicodeScalars.contains($0) }
        switch kind {
        case "d", "i", "o", "u", "x", "X", "c", "C": return long ? "l" : "i"
        case "e", "E", "f", "F", "g", "G", "a", "A": return "f"
        case "@": return "@"
        case "s", "S": return "s"
        case "p": return "p"
        default: return "?"
        }
    }

    /// Reads the conversions of one format, as `printf` does.
    struct FormatReader {
        let s: [Unicode.Scalar]
        var i = 0
        /// The argument a conversion with no `n$` reads.
        var following = 0

        func peek(_ ahead: Int = 0) -> Unicode.Scalar? { i + ahead < s.count ? s[i + ahead] : nil }

        mutating func read(while keep: (Unicode.Scalar) -> Bool) -> [Unicode.Scalar] {
            var out: [Unicode.Scalar] = []
            while let x = peek(), keep(x) {
                out.append(x)
                i += 1
            }
            return out
        }

        /// The position and type class of the next conversion; nil at the end.
        mutating func next(_ substitutions: [String: (position: Int?, specifier: String)]) throws(Why) -> (Int, Character)? {
            while let x = peek() {
                i += 1
                guard x == "%" else { continue }
                if peek() == "%" {
                    i += 1
                    continue
                }
                if let found = try conversion(substitutions) { return found }
            }
            return nil
        }

        /// The conversion after a `%`; nil when it is not one (`%` followed by text).
        private mutating func conversion(_ substitutions: [String: (position: Int?, specifier: String)]) throws(Why) -> (Int, Character)? {
            let start = i
            let digits = read { ("0"..."9").contains($0) }
            var position: Int?
            if peek() == "$", let n = Int(String(String.UnicodeScalarView(digits))), n >= 1 {
                position = n - 1
                i += 1
            } else {
                i = start
            }
            if peek() == "#", peek(1) == "@" {
                // `%#@name@`: a substitution, whose argument and specifier the entry gives.
                i += 2
                let name = String(String.UnicodeScalarView(read { $0 != "@" }))
                guard peek() == "@" else { throw Why(text: "unterminated %#@…@") }
                i += 1
                let substitution = substitutions[name]
                let type = substitution.map { typeClass(Array($0.specifier.unicodeScalars)) } ?? "?"
                return (position ?? substitution?.position.map { $0 - 1 } ?? take(), type)
            }
            let size = read { "-+ #0'.123456789*".unicodeScalars.contains($0) }
            if size.contains("*") { throw Why(text: "%* (a width read from the arguments)") }
            let spec = read { "hlqLzjt".unicodeScalars.contains($0) } + (peek().map { [$0] } ?? [])
            guard let kind = spec.last, "diouxXcCeEfFgGaA@sSp".unicodeScalars.contains(kind) else { return nil }
            i += 1
            return (position ?? take(), typeClass(spec))
        }

        /// The next argument of a conversion with no `n$`.
        private mutating func take() -> Int {
            defer { following += 1 }
            return following
        }
    }
}
