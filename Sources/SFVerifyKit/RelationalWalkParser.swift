import Foundation

// Reading guide
// The reader of a walk's relational claims, from the source text of a test (`RelationalWalks.swift` says which closures
// it reads, and what logic's results do to the walk).
// Tests: Tests/SFVerifyKitTests/RelationalWalkTests.swift.

/// Reads the relational claims of `Prove(it:…)` walks from source text (see the top of this file).
enum RelationalWalkParser {
    /// The claims of every walk in `text`, at the line of its `Prove(`.
    static func requests(in text: String, file: String) -> [RelationalRequest] {
        let lines = text.components(separatedBy: "\n")
        var requests: [RelationalRequest] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
            guard let range = line.range(of: "Prove(") else { continue }
            if let before = line[..<range.lowerBound].last, before.isLetter || before.isNumber || before == "_" || before == "." {
                continue
            }
            let rest = ([String(line[range.lowerBound...])] + lines[(index + 1)..<min(index + 80, lines.count)])
                .joined(separator: "\n")
            requests += walk(Substring(rest), call: "Prove(", file: file, line: index + 1)
        }
        return requests
    }

    /// The claims of the walk that starts `text` (`Prove(` …).
    static func walk(_ text: Substring, call: String, file: String, line: Int) -> [RelationalRequest] {
        let open = text.index(text.startIndex, offsetBy: call.count - 1)
        guard let close = matching(text, open) else { return [] }
        let arguments = splitTopLevel(text[text.index(after: open)..<close], by: [","]).map(labeled)
        guard let function = arguments.first(where: { $0.label == "it" })?.value, let (forward, unwraps) = closure(function), !unwraps,
            !forward.isEmpty
        else { return [] }
        let after = text[text.index(after: close)...].drop { $0 == " " || $0 == "\t" }
        guard after.first == "{", let end = matching(after, after.startIndex) else { return [] }
        var requests: [RelationalRequest] = []
        for statement in splitTopLevel(after[after.index(after: after.startIndex)..<end], by: ["\n", ";"]) {
            guard let read = property(statement) else { continue }
            requests.append(
                RelationalRequest(
                    claim: read.claim, file: file, line: line, property: read.name, forward: forward, other: read.other,
                    unwrapsOther: read.unwraps))
        }
        return requests
    }

    /// One claim of a walk, read: what it claims, the property's name, and the other chain (the inverse, or the
    /// other rule; none for `Injective`), with whether it ends in `!`.
    struct Claim {
        var claim: RelationalRequest.Claim
        var name: String
        var other: [RelationalStep] = []
        var unwraps = false
    }

    /// `Injective()`, `RoundTrip(through: {…})`, `Agrees(with: {…})`, `Agrees("name", with: {…})`, `Matches({…})`,
    /// `Matches("name", {…})`, or a trailing closure for the last argument.
    static func property(_ statement: Substring) -> Claim? {
        let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        let name = text.prefix { $0.isLetter }
        guard ["Injective", "RoundTrip", "Agrees", "Matches"].contains(name),
            let arguments = arguments(text.dropFirst(name.count).drop { $0 == " " })
        else { return nil }
        let title = arguments.first.flatMap { $0.label == nil ? literal($0.value) : nil }
        let closures = arguments.dropFirst(title == nil ? 0 : 1)
        guard name != "Injective" else { return arguments.isEmpty ? Claim(claim: .injective, name: "injective") : nil }
        let labels: [String?] = name == "RoundTrip" ? [nil, "through"] : name == "Agrees" ? [nil, "with"] : [nil]
        guard closures.count == 1, labels.contains(closures.first?.label), let other = closures.first.flatMap({ closure($0.value) }),
            !other.steps.isEmpty
        else { return nil }
        if name == "RoundTrip" {
            return title == nil ? Claim(claim: .roundTrip, name: "round trip", other: other.steps, unwraps: other.unwraps) : nil
        }
        guard !other.unwraps else { return nil }
        return Claim(claim: .agrees, name: title ?? (name == "Agrees" ? "agrees with other rule" : "matches oracle"), other: other.steps)
    }

    /// The arguments of a block that `text` follows its name with: `(…)`, a trailing closure, or both; nil when
    /// anything else follows.
    private static func arguments(_ text: Substring) -> [(label: String?, value: Substring)]? {
        var rest = text
        var arguments: [(label: String?, value: Substring)] = []
        if rest.first == "(" {
            guard let close = matching(rest, rest.startIndex) else { return nil }
            let inside = rest[rest.index(after: rest.startIndex)..<close]
            if !inside.allSatisfy(\.isWhitespace) { arguments = splitTopLevel(inside, by: [","]).map(labeled) }
            rest = rest[rest.index(after: close)...].drop { $0 == " " }
        }
        if rest.first == "{" {
            guard let close = matching(rest, rest.startIndex) else { return nil }
            arguments.append((nil, rest[...close]))
            rest = rest[rest.index(after: close)...]
        }
        return rest.allSatisfy(\.isWhitespace) ? arguments : nil
    }

    // MARK: closures

    /// The chain a closure (or key path `\.p`) calls on its parameter; `unwraps` when it ends in `!`.
    static func closure(_ text: Substring) -> (steps: [RelationalStep], unwraps: Bool)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        if text.hasPrefix("\\.") {
            let names = text.dropFirst(2).split(separator: ".", omittingEmptySubsequences: false)
            guard names.allSatisfy(isIdentifier) else { return nil }
            return (names.map { RelationalStep(.getter, name: String($0)) }, false)
        }
        guard text.first == "{", let close = matching(text, text.startIndex), text.index(after: close) == text.endIndex else { return nil }
        var body = text.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)[...]
        var parameter = "$0"
        if let range = body.range(of: #"\sin\s"#, options: .regularExpression), let named = parameterName(body[..<range.lowerBound]) {
            parameter = named
            body = body[range.upperBound...].drop { $0.isWhitespace }
        }
        // A chain may continue on the next line (`\n    .execute()`); anything else on two lines is not one chain.
        body = Substring(body.replacingOccurrences(of: #"\s*\n\s*\."#, with: ".", options: .regularExpression))
        guard !body.contains("\n"), !body.contains(";") else { return nil }
        for keyword in ["return ", "try "] where body.hasPrefix(keyword) { body = body.dropFirst(keyword.count).drop { $0 == " " } }
        guard !body.hasPrefix("try"), !body.hasPrefix("await") else { return nil }
        var unwraps = false
        if body.hasSuffix("!") {
            unwraps = true
            body = body.dropLast()
        }
        guard let steps = chain(body.trimmingCharacters(in: .whitespaces)[...], parameter: parameter) else { return nil }
        return (steps.steps, unwraps)
    }

    /// `seat`, `(seat)`, `seat: Seat`, `(seat: Seat)` before ` in`.
    private static func parameterName(_ text: Substring) -> String? {
        var text = text.trimmingCharacters(in: .whitespaces)[...]
        if text.hasPrefix("("), text.hasSuffix(")") { text = text.dropFirst().dropLast() }
        let name = text.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        let rest = text.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        guard isIdentifier(name), rest.isEmpty || rest.hasPrefix(":") else { return nil }
        return String(name)
    }

    /// The steps `expression` applies to `parameter`, and the type of the value it gives when it is the one an
    /// initializer builds (for the member called on it).
    static func chain(_ expression: Substring, parameter: String) -> (steps: [RelationalStep], type: String?)? {
        if expression == parameter { return ([], nil) }
        if expression.hasSuffix(")") {
            guard let open = openingParenthesis(expression) else { return nil }
            let callee = expression[..<open]
            let inside = expression[expression.index(after: open)..<expression.index(before: expression.endIndex)]
            // `receiver.m()`: a method without arguments of a value the chain built.
            if let dot = callee.lastIndex(of: "."), isIdentifier(callee[callee.index(after: dot)...]),
                callee[callee.index(after: dot)...].first?.isLowercase == true,
                let receiver = chain(callee[..<dot], parameter: parameter)
            {
                guard inside.allSatisfy(\.isWhitespace) else { return nil }
                return (
                    receiver.steps + [RelationalStep(.method, type: receiver.type, name: String(callee[callee.index(after: dot)...]))], nil
                )
            }
            // `f(x: …)`, `T.f(x: …)`, `T(x: …)`: one argument, itself a chain.
            let path = callee.split(separator: ".", omittingEmptySubsequences: false)
            guard !path.isEmpty, path.allSatisfy(isIdentifier) else { return nil }
            let arguments = splitTopLevel(inside, by: [","]).map(labeled)
            guard arguments.count == 1, let argument = chain(arguments[0].value, parameter: parameter) else { return nil }
            let label = arguments[0].label ?? "_"
            let last = String(path[path.count - 1])
            if last.first?.isUppercase == true {
                let type = path.joined(separator: ".")
                return (argument.steps + [RelationalStep(.initializer, type: type, name: "init", labels: [label])], type)
            }
            guard path.count == 1 || path[path.count - 2].first?.isUppercase == true else { return nil }
            let type = path.count == 1 ? nil : path.dropLast().joined(separator: ".")
            return (argument.steps + [RelationalStep(.function, type: type, name: last, labels: [label])], nil)
        }
        // `receiver.p`: a property.
        guard let dot = expression.lastIndex(of: "."), isIdentifier(expression[expression.index(after: dot)...]),
            let receiver = chain(expression[..<dot], parameter: parameter)
        else { return nil }
        return (
            receiver.steps + [RelationalStep(.getter, type: receiver.type, name: String(expression[expression.index(after: dot)...]))], nil
        )
    }

    // MARK: text

    private static func isIdentifier(_ text: Substring) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `"name"` without escapes or interpolation.
    private static func literal(_ text: Substring) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
        let inside = text.dropFirst().dropLast()
        guard !inside.contains("\""), !inside.contains("\\") else { return nil }
        return String(inside)
    }

    /// `label: value` or `value`.
    private static func labeled(_ text: Substring) -> (label: String?, value: Substring) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        let name = text.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        let rest = text.dropFirst(name.count).drop { $0 == " " }
        guard isIdentifier(name), rest.hasPrefix(":"), !rest.hasPrefix("::") else { return (nil, text) }
        return (String(name), rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)[...])
    }

    /// The index of the bracket that closes the one at `open`, past strings; nil when a string interpolates or the
    /// text ends first.
    static func matching(_ text: Substring, _ open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var inString = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if character == "\\" {
                    let next = text.index(after: index)
                    guard next < text.endIndex, text[next] != "(" else { return nil }
                    index = text.index(after: next)
                    continue
                }
                if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if "([{".contains(character) {
                depth += 1
            } else if ")]}".contains(character) {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The `(` of a call that ends `expression`.
    private static func openingParenthesis(_ expression: Substring) -> Substring.Index? {
        var index = expression.startIndex
        while index < expression.endIndex {
            if expression[index] == "(", let close = matching(expression, index), expression.index(after: close) == expression.endIndex {
                return index
            }
            if "([{\"".contains(expression[index]) {
                let close = expression[index] == "\"" ? closingQuote(expression, index) : matching(expression, index)
                guard let close else { return nil }
                index = close
            }
            index = expression.index(after: index)
        }
        return nil
    }

    /// `text` split at `separators` outside brackets and strings; empty parts dropped.
    static func splitTopLevel(_ text: Substring, by separators: Set<Character>) -> [Substring] {
        var parts: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if "([{\"".contains(character) {
                guard let close = character == "\"" ? closingQuote(text, index) : matching(text, index) else { return [] }
                index = text.index(after: close)
                continue
            }
            if separators.contains(character) {
                parts.append(text[start..<index])
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        parts.append(text[start...])
        return parts.filter { !$0.allSatisfy(\.isWhitespace) }
    }

    private static func closingQuote(_ text: Substring, _ open: Substring.Index) -> Substring.Index? {
        var index = text.index(after: open)
        while index < text.endIndex {
            if text[index] == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex, text[next] != "(" else { return nil }
                index = text.index(after: next)
                continue
            }
            if text[index] == "\"" { return index }
            index = text.index(after: index)
        }
        return nil
    }
}
