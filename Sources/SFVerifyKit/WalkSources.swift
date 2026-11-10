import Foundation

/// What `findWalks` reads from all the test sources to name the function a walk calls, beyond the call itself: the
/// `call` of each `ExitTestWalk` type (for `Prove(neverTraps: Walk.self)`), and the type each name is declared with
/// (for `{ reducer.reduce(into: &$0, action: $1) }`).
///
/// Both are read from text, so both fail closed: a name declared twice, declared without a type that can be read, or
/// bound anywhere in a way that hides its type (a closure parameter, `for … in`, `case let`, a tuple) names no type,
/// and the walk stays unlinked unless it has a subject. A wrong type would make a walk prove a function it never calls.
struct WalkSources {
    private let texts: [String]
    /// How many times each type name is declared in the test sources (`enum`, `struct`, `class`, `actor`, `typealias`).
    private var typeDeclarations: [String: Int] = [:]
    /// `{ (index: Int) in <body of call> }` for each `ExitTestWalk` type, by its name; `nil` for a name declared twice.
    private var calls: [String: String?] = [:]

    init(texts: [String]) {
        self.texts = texts
        let declaration = try? NSRegularExpression(pattern: #"\b(?:enum|struct|class|actor|typealias)\s+(\w+)"#)
        for text in texts {
            for match in declaration?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                typeDeclarations[String(text[range]), default: 0] += 1
            }
        }
        for text in texts {
            for (name, closure) in Self.walkCalls(in: text) {
                calls[name] = calls[name] == nil ? closure : .some(nil)
            }
        }
    }

    /// The `call` of the `ExitTestWalk` type `name` as a closure, or `nil` when it is not found once, or another type of
    /// that name is declared too (`A.Halve` and `B.Halve`: `neverTraps: B.Halve.self` must not read `A.Halve`).
    func walkCall(of name: String) -> String? {
        guard typeDeclarations[name] == 1 else { return nil }
        return calls[name].flatMap { $0 }
    }

    /// The type `name` is declared with in the test sources: `let name = Type(…)` (or `let name: Type = Type(…)`), the
    /// value's own type, whose method the call runs. `nil` unless every declaration of `name` is of that form with one
    /// type: a written type alone (`let name: Base`, a function parameter `name: Base`) is only the static type, and the
    /// call may run a subclass's override or another conformer's method; any other binding hides the type.
    func declaredType(of name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let constructed = #"\b(?:let|var)\s+"# + escaped + #"\s*(?::\s*([A-Z]\w*)\s*)?=\s*([A-Z]\w*)\s*\("#
        // Bindings whose type the text does not say: any `let`/`var` of the name, a closure parameter or `for … in`, a
        // pattern of `case let`, a tuple, a parameter or an argument label.
        let lets = #"\b(?:let|var)\s+"# + escaped + #"\b"#
        let hiding = [
            #"\b"# + escaped + #"\s*(?::[^,)\n]*)?(?:,\s*[\w$]+\s*(?::[^,)\n]*)?)*\)?\s+in\b"#,
            #"\bcase\s+(?:let|var)\b[^\n:]*\b"# + escaped + #"\b"#,
            #"\b(?:let|var)\s*\([^)]*\b"# + escaped + #"\b"#,
            #"[(,]\s*(?:\w+\s+)?"# + escaped + #"\s*:"#,
        ]
        var types: Set<String> = []
        var constructions = 0
        var letCount = 0
        for text in texts {
            for groups in Self.groups(constructed, in: text) {
                constructions += 1
                // `let name: Base = Derived()`: the written type is not the value's.
                if let written = groups[0], written != groups[1] { return nil }
                if let type = groups[1] { types.insert(type) }
            }
            letCount += Self.count(lets, in: text)
            for pattern in hiding where Self.count(pattern, in: text) > 0 { return nil }
        }
        guard types.count == 1, constructions > 0, constructions == letCount else { return nil }
        return types.first
    }

    /// The capture groups 1 and 2 of every match of `pattern` in `text`, `nil` where a group did not take part.
    private static func groups(_ pattern: String, in text: String) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1...2).map { index in Range(match.range(at: index), in: text).map { String(text[$0]) } }
        }
    }

    private static func count(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Each `ExitTestWalk` type in `text` with its `call` as a closure: `static func call(_ index: Int) -> Tab { body }`
    /// gives `{ (index: Int) in body }`.
    private static func walkCalls(in text: String) -> [(name: String, closure: String?)] {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:enum|struct|class|actor)\s+(\w+)[^{;]*\bExitTestWalk\b[^{;]*\{"#)
        else { return [] }
        let characters = Array(text)
        let utf16 = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: utf16).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text), let end = Range(match.range, in: text)?.upperBound
            else { return nil }
            let open = text.distance(from: text.startIndex, to: end) - 1
            guard let close = closingBrace(in: characters, from: open) else { return (String(text[nameRange]), nil) }
            let body = String(characters[(open + 1)..<close])
            return (String(text[nameRange]), callClosure(in: body))
        }
    }

    /// `{ (name: Type) in body }` for the `func call(` in a type's body, or `nil` when it cannot be read.
    private static func callClosure(in body: String) -> String? {
        guard let range = body.range(of: "func call(") else { return nil }
        let characters = Array(body)
        let start = body.distance(from: body.startIndex, to: range.upperBound) - 1
        guard let parametersEnd = closingParenthesis(in: characters, from: start) else { return nil }
        let parameter = String(characters[(start + 1)..<parametersEnd])
        let parts = parameter.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let name = parts[0].split(separator: " ").last else { return nil }
        guard let open = characters[parametersEnd...].firstIndex(of: "{"), let close = closingBrace(in: characters, from: open)
        else { return nil }
        let code = String(characters[(open + 1)..<close]).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return "{ (\(name): \(parts[1])) in \(code) }"
    }

    private static func closingBrace(in characters: [Character], from open: Int) -> Int? {
        closing(in: characters, from: open, opening: "{", closing: "}")
    }

    private static func closingParenthesis(in characters: [Character], from open: Int) -> Int? {
        closing(in: characters, from: open, opening: "(", closing: ")")
    }

    private static func closing(in characters: [Character], from open: Int, opening: Character, closing: Character) -> Int? {
        var depth = 0
        var inString = false
        var index = open
        while index < characters.count {
            let character = characters[index]
            if character == "\"" { inString.toggle() }
            if !inString {
                if character == opening { depth += 1 }
                if character == closing {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index += 1
        }
        return nil
    }
}
