import Foundation

/// Reading which function a walk checks from its source text, for `findWalks`.
extension Check {
    /// The subjects of the walks that start on `lines[index]`: every `Prove(`, the one way to walk. The subject is the
    /// string written first, or read from the `it:` closure or the walk type's `call` (`proveSubject`); the call may
    /// continue on the next lines, where `swift format` puts the arguments of a long call.
    static func walkSubjects(in lines: [String], at index: Int, sources: WalkSources = WalkSources(texts: [])) -> [String] {
        let line = lines[index]
        guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return [] }
        var subjects: [String] = []
        var searchFrom = line.startIndex
        while let range = line.range(of: "Prove(", range: searchFrom..<line.endIndex) {
            searchFrom = range.upperBound
            if range.lowerBound > line.startIndex, isIdentifierCharacter(line[line.index(before: range.lowerBound)]) { continue }
            let following = lines[(index + 1)..<min(index + 6, lines.count)]
            let call = ([String(line[range.upperBound...])] + following).joined(separator: " ")
            subjects.append(proveSubject(arguments: Substring(call), sources: sources))
        }
        return subjects
    }

    /// The subject of `Prove(` given the text after its parenthesis: the string written first, or the function the
    /// `it:` closure calls (`{ SurfaceTextRule(input: $0).execute() }` → `SurfaceTextRule.execute`), or, for
    /// `neverTraps: Walk.self`, the function the walk type's `call` calls. A member of the input (`{ $0.label }`,
    /// `{ surface in surface.label }`, `\.label`) gives `$0.label`: the test reports the type `$0` stands for when it runs (the
    /// input, or the state of a session walk), and `check` links the walk with it (`Check.inputMember`). A call on a
    /// name the test sources declare with one type (`reducer.reduce(into:action:)`) gives that type's member. When
    /// nothing can be read, the closure itself, which links to nothing and is listed as unlinked.
    static func proveSubject(arguments: Substring, sources: WalkSources = WalkSources(texts: [])) -> String {
        let rest = arguments.drop { $0.isWhitespace }
        if rest.first == "\"" { return String(rest.dropFirst().prefix { $0 != "\"" }) }
        if rest.hasPrefix("neverTraps:") {
            let type = rest.dropFirst("neverTraps:".count).drop { $0.isWhitespace }
                .prefix { isIdentifierCharacter($0) || $0 == "." }
            let name = type.hasSuffix(".self") ? type.dropLast(5) : type
            let simple = String(name.split(separator: ".").last ?? "")
            guard let call = sources.walkCall(of: simple) else { return "neverTraps: \(name)" }
            return proveSubject(arguments: Substring("it: " + call), sources: sources)
        }
        guard rest.hasPrefix("it:") else { return "" }
        var body = rest.dropFirst(3).drop { $0.isWhitespace }
        if body.first == "\\" { return keyPathSubject(body.dropFirst()) ?? "" }
        let closure = body.first == "{"
        var parameters = ClosureParameters()
        if closure { (body, parameters) = closureBody(body.dropFirst()) }
        body = droppingKeywords(body)
        if let called = calledFunction(body, parameters: parameters, sources: sources) { return called }
        let shown = closure ? "{" + rest.dropFirst(3).drop { $0.isWhitespace }.dropFirst().prefix { $0 != "}" } + "}" : ""
        return shown.trimmingCharacters(in: .whitespaces)
    }

    /// The parameters of a closure: the first is the input (`$0`), with the type written for each, if any.
    struct ClosureParameters {
        var first: String? = "$0"
        var types: [String: String?] = ["$0": nil]
    }

    /// `try`, `try?`, `await`, `return` and `_ =` (in any order) before the call.
    private static func droppingKeywords(_ body: Substring) -> Substring {
        var body = body
        var dropped = true
        while dropped {
            dropped = false
            // `_ = reducer.reduce(…)`: the result is discarded, the call is the same.
            if body.hasPrefix("_") {
                let after = body.dropFirst().drop { $0.isWhitespace }
                if after.first == "=", after.dropFirst().first != "=" {
                    body = after.dropFirst().drop { $0.isWhitespace }
                    dropped = true
                    continue
                }
            }
            for keyword in ["try", "await", "return"] where body.hasPrefix(keyword) {
                let after = body.dropFirst(keyword.count).drop { $0 == "?" || $0 == "!" }
                guard after.first?.isWhitespace == true else { continue }
                body = after.drop { $0.isWhitespace }
                dropped = true
            }
        }
        return body
    }

    /// The body of a closure after its parameter list (`input in`, `(a, b) in`, `(type: UnitSystemType) in`), and its
    /// parameters with the type written for each, if any.
    private static func closureBody(_ text: Substring) -> (body: Substring, parameters: ClosureParameters) {
        let text = text.drop { $0.isWhitespace }
        guard let range = text.range(of: " in ") else { return (text, ClosureParameters()) }
        let header = text[..<range.lowerBound]
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ ,():[]<>-?")
        guard header.allSatisfy({ allowed.contains($0) }) else { return (text, ClosureParameters()) }
        var parameters = ClosureParameters(first: nil, types: [:])
        let list = header.drop { $0 == "(" }.prefix { $0 != ")" }
        for parameter in list.split(separator: ",") {
            let parts = parameter.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            let type = parts.count == 2 ? parts[1].split(separator: "<").first.map(String.init) : nil
            parameters.types[parts[0]] = type?.first?.isUppercase == true ? type : nil
            if parameters.first == nil { parameters.first = parts[0] }
        }
        return (text[range.upperBound...].drop { $0.isWhitespace }, parameters)
    }

    /// `\Surface.label` → `Surface.label`, `\.label` → `$0.label`.
    private static func keyPathSubject(_ text: Substring) -> String? {
        let type = text.prefix(while: isIdentifierCharacter)
        let rest = text.dropFirst(type.count)
        guard rest.first == "." else { return nil }
        let member = rest.dropFirst().prefix(while: isIdentifierCharacter)
        guard !member.isEmpty else { return nil }
        return (type.isEmpty ? "$0" : String(type)) + "." + member
    }

    /// `Type.member(labels:)` for the call chain `body` starts with: `SurfaceTextRule(input: $0).execute()` →
    /// `SurfaceTextRule.execute()`, `Formatter.shared.text(for: $0)` → `Formatter.text(for:)`, `label(for:)` →
    /// `label(for:)`, `Rule($0)` → `Rule.init(_:)`. A property has no labels: `UnitSystem.shared.id` → `UnitSystem.id`.
    /// A chain that starts with a parameter calls a member of the input: `{ (type: UnitSystemType) in type.id }` →
    /// `UnitSystemType.id`, and `$0.label` or `surface.label` with no written type → `$0.label`.
    /// `nil` when the chain names no type.
    private static func calledFunction(
        _ body: Substring, parameters: ClosureParameters = ClosureParameters(), sources: WalkSources = WalkSources(texts: [])
    ) -> String? {
        let links = callChain(body)
        if let first = links.first?.name, first == "$0" || parameters.types[first] != nil {
            guard links.count > 1 else { return nil }
            // A parameter with a written type names it; otherwise only the first parameter is the input (`$0`): in a
            // session step `{ state, action in … }` the second is the action, whose type the walk does not report.
            if let written = parameters.types[first].flatMap({ $0 }) { return written + "." + links[1].written }
            guard first == "$0" || first == parameters.first else { return nil }
            return "$0." + links[1].written
        }
        guard let last = links.last else { return nil }
        if links.count == 1 {
            guard last.name.first?.isUppercase == true else { return last.written }
            return last.name + ".init" + (last.labels.map(labelList) ?? "")
        }
        // `reducer.reduce(into:action:)`: a name the test sources declare with one type.
        if links.count == 2, links[0].labels == nil, links[0].name.first?.isLowercase == true {
            return sources.declaredType(of: links[0].name).map { $0 + "." + last.written }
        }
        guard let owner = links.dropLast().last(where: { $0.name.first?.isUppercase == true }) else { return nil }
        return owner.name + "." + last.written
    }

    /// `(a:_:)`.
    static func labelList(_ labels: [String]) -> String { "(" + labels.map { $0 + ":" }.joined() + ")" }

    /// One name of a call chain, with the argument labels of its call (`nil` for a property or a bare name).
    private struct ChainLink {
        var name: String
        var labels: [String]?
        var written: String { name + (labels.map(Check.labelList) ?? "") }
    }

    /// The names of the call chain `body` starts with: `SurfaceTextRule(input: $0).execute()` → `SurfaceTextRule(input:)`,
    /// `execute()`. A trailing closure adds a label `*` that matches any label.
    private static func callChain(_ body: Substring) -> [ChainLink] {
        var links: [ChainLink] = []
        var rest = body
        if rest.hasPrefix("$0.") {
            links.append(ChainLink(name: "$0"))
            rest = rest.dropFirst(3)
        }
        while let first = rest.first, first.isLetter || first == "_" {
            let name = rest.prefix(while: isIdentifierCharacter)
            var link = ChainLink(name: String(name))
            rest = rest.dropFirst(name.count)
            if rest.first == "(" {
                guard let close = closingParenthesis(in: rest) else { break }
                link.labels = argumentLabels(rest[rest.index(after: rest.startIndex)..<close])
                rest = rest[rest.index(after: close)...]
            }
            if rest.drop(while: { $0 == " " }).first == "{" {
                link.labels = (link.labels ?? []) + ["*"]
                links.append(link)
                break
            }
            links.append(link)
            if rest.hasPrefix("?.") || rest.hasPrefix("!.") { rest = rest.dropFirst() }
            guard rest.first == "." else { break }
            rest = rest.dropFirst()
        }
        return links
    }

    /// The labels of `arguments`, the text between a call's parentheses: `input: $0, 3` → `input`, `_`; or of a
    /// function reference: `from:` → `from`.
    private static func argumentLabels(_ arguments: Substring) -> [String] {
        if let labels = referenceLabels(arguments) { return labels }
        return topLevelArguments(arguments).map { argument in
            let name = argument.drop { $0 == " " }.prefix(while: isIdentifierCharacter)
            let after = argument.drop { $0 == " " }.dropFirst(name.count).drop { $0 == " " }
            guard !name.isEmpty, name.first?.isNumber == false, after.first == ":", !after.hasPrefix("::") else { return "_" }
            return String(name)
        }
    }

    /// `["a", "_"]` for `a:_:`, the labels of a function reference or a scanned name; `[]` for nothing; `nil` otherwise.
    static func referenceLabels(_ text: Substring) -> [String]? {
        guard text.allSatisfy({ isIdentifierCharacter($0) || $0 == ":" || $0 == "*" }), text.isEmpty || text.last == ":" else {
            return nil
        }
        let labels = text.split(separator: ":", omittingEmptySubsequences: false).dropLast().map(String.init)
        return labels.contains(where: \.isEmpty) ? nil : labels
    }

    /// `arguments` split at its top-level commas.
    private static func topLevelArguments(_ arguments: Substring) -> [Substring] {
        guard arguments.contains(where: { !$0.isWhitespace }) else { return [] }
        var parts: [Substring] = []
        var depth = 0
        var inString = false
        var start = arguments.startIndex
        for index in arguments.indices {
            let character = arguments[index]
            if character == "\"" { inString.toggle() }
            guard !inString else { continue }
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(arguments[start..<index])
                start = arguments.index(after: index)
            }
        }
        parts.append(arguments[start...])
        return parts
    }

    private static func closingParenthesis(in text: Substring) -> Substring.Index? {
        var depth = 0
        var inString = false
        for index in text.indices {
            let character = text[index]
            if character == "\"" { inString.toggle() }
            guard !inString else { continue }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
