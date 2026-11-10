import Foundation

// Reading guide
// Which type a relational claim is about, named as Swift names it (`String(reflecting:)`: `MainApp.Seat`,
// `Swift.Optional<MainApp.Seat>`), so that a result is laid only over a walk over exactly that type. A walk's closure
// `{ $0.code }` names no type, and logic reads whichever scanned `code` there is: without this, a proof about
// `Row.code` would prove a walk over `Seat`. The name comes from the full demangled symbol of the rule's first step:
//
//     MainApp.Row.code.getter : Swift.Int                         → MainApp.Row   (the context: `$0.code`, `$0.m()`)
//     MainApp.SeatRule.init(input: MainApp.Seat) -> …             → MainApp.Seat  (the parameter: `T(x: $0)`, `f($0)`)
//     MainApp.SeatRule.input.getter : MainApp.Seat?               → Swift.Optional<MainApp.Seat>  (an implicit
//                                                                   memberwise initializer: its stored property's type)
//
// A name it cannot read (a generic or private context, a local type, no demangler) is nil, and the walk's verdict stands.
// Tests: Tests/SFVerifyKitTests/RelationalWalkTests.swift, RelationalProofTests.swift.

/// Where the full name of the type a chain's first step takes is read, in its symbol's demangled name.
enum RelationalTypeSource: Hashable, Sendable {
    /// The type the member is declared in: the value is `self`.
    case context(symbol: String)
    /// The parameter at this index of the parameter list.
    case parameter(symbol: String, index: Int)
    /// What a stored property's getter returns.
    case result(symbol: String)

    var symbol: String {
        switch self {
        case .context(let symbol), .parameter(let symbol, _), .result(let symbol): symbol
        }
    }

    /// The type's name in `demangled` (the full demangled name of `symbol`), as `String(reflecting:)` prints it; nil
    /// when it is not read.
    func typeName(in demangled: String) -> String? {
        var text = Substring(demangled)
        // `(extension in MainApp):Shared.Surface.text.getter`: the member of `Shared.Surface` that `MainApp` declares.
        while text.hasPrefix("(extension in "), let colon = text.range(of: "):") { text = text[colon.upperBound...] }
        let end = text.firstIndex { $0 == "(" || $0 == " " || $0 == "<" } ?? text.endIndex
        var path = text[..<end].split(separator: ".", omittingEmptySubsequences: false)
        guard path.count >= 2, path.allSatisfy(Self.isIdentifier) else { return nil }
        switch self {
        case .context:
            if path.last == "getter" {
                guard text[end...].hasPrefix(" : ") else { return nil }
                path.removeLast()
            } else {
                guard text[end...].hasPrefix("(") else { return nil }
            }
            path.removeLast()
            return path.count >= 2 ? Self.canonical(path.joined(separator: ".")) : nil
        case .parameter(_, let index):
            guard text[end...].hasPrefix("("), let parameters = Self.parameters(text[end...]), parameters.indices.contains(index) else {
                return nil
            }
            return Self.parameterType(parameters[index]).map(Self.canonical)
        case .result:
            guard path.last == "getter", text[end...].hasPrefix(" : ") else { return nil }
            let type = text[end...].dropFirst(3).trimmingCharacters(in: .whitespaces)
            return type.isEmpty || type.contains(" -> ") ? nil : Self.canonical(type)
        }
    }

    /// One spelling of a type: `T?` is `Swift.Optional<T>`, as `String(reflecting:)` prints it.
    static func canonical(_ type: String) -> String {
        let text = type.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("?") { return "Swift.Optional<\(canonical(String(text.dropLast())))>" }
        if text.hasPrefix("Swift.Optional<"), text.hasSuffix(">") {
            return "Swift.Optional<\(canonical(String(text.dropFirst("Swift.Optional<".count).dropLast())))>"
        }
        return text
    }

    private static func isIdentifier(_ name: Substring) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The top-level elements of the parenthesized list that `text` starts with.
    private static func parameters(_ text: Substring) -> [Substring]? {
        var depth = 0
        var start = text.index(after: text.startIndex)
        var elements: [Substring] = []
        for index in text.indices {
            // The `>` of a function type's `->` closes nothing.
            if text[index] == ">", index > text.startIndex, text[text.index(before: index)] == "-" { continue }
            switch text[index] {
            case "(", "<", "[": depth += 1
            case ")", ">", "]":
                depth -= 1
                if depth == 0 {
                    let last = text[start..<index]
                    if !last.allSatisfy(\.isWhitespace) || !elements.isEmpty { elements.append(last) }
                    return elements
                }
            case "," where depth == 1:
                elements.append(text[start..<index])
                start = text.index(after: index)
            default: break
            }
        }
        return nil
    }

    /// `input: MainApp.Seat` → `MainApp.Seat`; nil for an `inout` or ownership-marked parameter.
    private static func parameterType(_ element: Substring) -> String? {
        var text = element.trimmingCharacters(in: .whitespaces)[...]
        if let colon = text.range(of: ": "), isIdentifier(text[..<colon.lowerBound]) { text = text[colon.upperBound...] }
        let type = text.trimmingCharacters(in: .whitespaces)
        let marked = ["inout ", "__owned ", "__shared ", "consuming ", "borrowing ", "@"].contains { type.hasPrefix($0) }
        return type.isEmpty || marked ? nil : type
    }
}
