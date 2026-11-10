import Foundation

// Reading guide
// Mapper plan T2: a walk over `X(input: $0).execute()`, where `execute()` is declared once, in an unconstrained protocol
// extension whose body only returns one requirement of the protocol (`{ body }`), checks `X.body`. Its subject is
// rewritten to `X.body` before linking, so it links to the scanned `X.body.getter`. Read from the sources of the
// packages (no build). Anything else keeps the subject: another declaration of `execute` anywhere, a constrained
// extension, a body that does more, a member that is not a requirement, a type that is not declared once with the
// conformance, a call on a value the closure does not build (`X.shared.execute()`), an imported module that is not
// read (its declarations are unknown), or a file whose comments and literals cannot be told apart for sure.
// Tests: Tests/SFVerifyKitTests/ForwarderResolutionTests.swift.

/// `func execute()` in `extension Rule` returns `body` (`isCall` for `body()`).
struct ForwarderMethod {
    var proto: String
    var member: String
    var isCall: Bool
}

/// A method without parameters of an unconstrained protocol extension, and its body.
private struct ForwarderCandidate {
    var proto: String
    var name: String
    var body: Substring
}

extension Check {
    /// One-line protocol-extension forwarders, and the types that conform to their protocols, read from source text.
    struct Forwarders {
        /// `execute` → `Rule`, `body`.
        private(set) var byMember: [String: ForwarderMethod] = [:]
        /// `TextRule` → `["Rule"]`, for a type declared exactly once (as a struct, enum, class or actor).
        private(set) var conformances: [String: Set<String>] = [:]

        /// Reads `sources`; with `members`, only forwarders of those names are looked for.
        init(sources: [String], members: Set<String>? = nil) {
            // A file whose comments and literals cannot be told apart for sure may declare anything: nothing is followed.
            let stripped = sources.map(ForwarderSource.strippingComments)
            guard !stripped.contains(nil) else { return }
            let texts = stripped.compactMap { $0 }
            var declarations: [String: Int] = [:]
            var protocols: [String: [String: Bool]] = [:]
            var candidates: [ForwarderCandidate] = []
            var conformances: [String: Set<String>] = [:]
            for text in texts {
                for declaration in ForwarderSource.typeDeclarations(in: text) {
                    declarations[declaration.name, default: 0] += 1
                    if declaration.kind == "protocol" {
                        protocols[declaration.name] = ForwarderSource.requirements(in: declaration.body)
                    } else {
                        conformances[declaration.name, default: []].formUnion(declaration.inherited)
                    }
                }
                for extended in ForwarderSource.extensions(in: text) {
                    conformances[extended.name, default: []].formUnion(extended.inherited)
                    guard extended.unconstrained else { continue }
                    for method in ForwarderSource.methods(in: extended.body) where members?.contains(method.name) ?? true {
                        candidates.append(ForwarderCandidate(proto: extended.name, name: method.name, body: method.body))
                    }
                }
            }
            self.conformances = conformances.filter { declarations[$0.key] == 1 }
            for candidate in candidates {
                guard declarations[candidate.proto] == 1, let requirements = protocols[candidate.proto],
                    ForwarderSource.declarationCount(of: candidate.name, in: texts) == 1,
                    let forward = ForwarderSource.forwardedMember(candidate.body), requirements[forward.member] == forward.isCall
                else { continue }
                byMember[candidate.name] = ForwarderMethod(proto: candidate.proto, member: forward.member, isCall: forward.isCall)
            }
        }

        /// `body` for `TextRule` and `execute`, when `TextRule` conforms to the forwarder's protocol.
        func forwarded(type: String, member: String) -> ForwarderMethod? {
            guard let forward = byMember[member], conformances[type]?.contains(forward.proto) == true else { return nil }
            return forward
        }
    }

    /// `walks` with the subject `X.execute()` of a walk over `X(…).execute()` rewritten to `X.body` when `execute()` is a
    /// one-line protocol-extension forwarder (`Forwarders`). Read from what the walks' code can see: `testFiles`, and the
    /// targets under `packages` that they or the `scanned` targets import, transitively (a nested package's copy of a
    /// type that nothing imports does not count). An import that is not found keeps every subject.
    public static func resolvingForwarders(_ walks: [WalkCheck], packages: [String], scanned: [String], testFiles: [String]) -> [WalkCheck]
    {
        guard walks.contains(where: { forwarderCandidate($0) != nil }) else { return walks }
        var roots: [String] = []
        for root in packages
        where !roots.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL == URL(fileURLWithPath: root).standardizedFileURL }) {
            roots.append(root)
        }
        let read = { (file: String) in try? String(contentsOfFile: file, encoding: .utf8) }
        let testTexts = testFiles.map(read)
        guard !testTexts.contains(nil) else { return walks }
        return resolvingForwarders(
            walks, testTexts: testTexts.compactMap { $0 }, scanned: scanned,
            targets: roots.flatMap { sourceTargets(under: $0, extensions: ["swift", "h"]) }, read: read
        )
    }

    /// Modules a test or a target may import that declare no member of the app's types: the toolchain's, the SDK's
    /// common ones, and SwiftFormal's. Any other import must be a target read here.
    static let systemModules: Set = [
        "Swift", "_Concurrency", "_StringProcessing", "Foundation", "FoundationEssentials", "Dispatch", "Darwin", "Glibc",
        "os", "Observation", "Combine", "SwiftUI", "UIKit", "AppKit", "CoreGraphics", "CoreFoundation", "Testing", "XCTest",
        "SwiftFormal", "SwiftFormalContracts", "SwiftFormalTesting",
    ]

    /// `resolvingForwarders` over the sources the walks' code can see: `testTexts`, then the `targets` that they or the
    /// `scanned` targets import, transitively. A module imported but not among `targets` (a remote dependency, a path
    /// dependency outside the roots) or a file that cannot be read may declare a member that Swift picks over the
    /// forwarder, so then no subject is rewritten. The walks' own files are read with `read` too.
    static func resolvingForwarders(
        _ walks: [WalkCheck], testTexts: [String], scanned: [String], targets: [SourceTarget], read: (String) -> String?
    ) -> [WalkCheck] {
        let candidates = walks.compactMap(forwarderCandidate)
        let members = Set(candidates.map(\.member))
        guard !members.isEmpty else { return walks }
        var texts = testTexts
        var pending = Set(scanned).union(texts.flatMap(ForwarderSource.imports))
        var visited: Set<String> = []
        while let name = pending.popFirst() {
            visited.insert(name)
            let found = targets.filter { $0.name == name }
            guard !found.isEmpty || systemModules.contains(name) else { return walks }
            for target in found {
                let files = target.files.map { (path: $0, text: read($0)) }
                guard !files.contains(where: { $0.text == nil }) else { return walks }
                // A C-family target's header may declare a member Swift sees (an Objective-C category): one that
                // names a forwarded member keeps every subject.
                let headers = files.filter { !$0.path.hasSuffix(".swift") }.compactMap(\.text)
                guard !headers.contains(where: { header in members.contains { ForwarderSource.mentions($0, in: header) } }) else {
                    return walks
                }
                let swift = files.filter { $0.path.hasSuffix(".swift") }.compactMap(\.text)
                texts += swift
                pending.formUnion(Set(swift.flatMap(ForwarderSource.imports)).subtracting(visited))
            }
        }
        // A file that can matter declares the method, the type or a protocol.
        let words = members.union(candidates.map(\.type)).union(["protocol"])
        let forwarders = Forwarders(sources: texts.filter { text in words.contains { text.contains($0) } }, members: members)
        var cache: [String: [String]] = [:]
        return resolvingForwarders(walks, forwarders: forwarders) { file in
            if let lines = cache[file] { return lines }
            let lines = read(file)?.components(separatedBy: "\n")
            cache[file] = lines
            return lines
        }
    }

    /// `resolvingForwarders`, with the walk files' lines from `lines`.
    static func resolvingForwarders(_ walks: [WalkCheck], forwarders: Forwarders, lines: (String) -> [String]?) -> [WalkCheck] {
        walks.map { walk in
            guard let (type, member) = forwarderCandidate(walk), let forward = forwarders.forwarded(type: type, member: member),
                let lines = lines(walk.file), walk.line >= 1, walk.line <= lines.count,
                ForwarderSource.closureBuilds(type, calling: member, at: walk.line - 1, in: lines)
            else { return walk }
            var resolved = walk
            let rest = walk.subject.dropFirst(type.count + 1 + member.count)
            resolved.subject =
                type + "." + forward.member + (forward.isCall ? "()" : "") + (rest.hasPrefix("()") ? rest.dropFirst(2) : rest)
            return resolved
        }
    }

    /// `("TextRule", "execute")` for a walk subject `TextRule.execute()` or `TextRule.execute (finite)`.
    private static func forwarderCandidate(_ walk: WalkCheck) -> (type: String, member: String)? {
        guard walk.kind == nil else { return nil }
        let parts = subjectKey(walk.subject).split(separator: ".")
        guard parts.count == 2, parts[0].first?.isUppercase == true else { return nil }
        let rest = walk.subject.dropFirst(parts[0].count + 1 + parts[1].count)
        guard rest.isEmpty || rest.hasPrefix("()") || rest.first == " " else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// For unlinked walks whose subject `X.member` names a type that a scan has functions of, but no scanned member:
    /// one hint that says which member to name (`"X.body"`). Returns the hints and the walks it did not explain.
    public static func memberHints(for walks: [WalkCheck], scans: [ScanReport]) -> (hints: [String], rest: [WalkCheck]) {
        let keys = scans.flatMap { $0.inventory.map { functionKey($0.name) } }
        var explained: [(subject: String, example: String)] = []
        var rest: [WalkCheck] = []
        for walk in walks {
            let key = subjectKey(walk.subject)
            let parts = key.split(separator: ".")
            let members = parts.count == 2 ? keys.filter { $0.hasPrefix(parts[0] + ".") && $0.split(separator: ".").count == 2 } : []
            guard walk.kind == nil, parts.first?.first?.isUppercase == true, let first = members.first else {
                rest.append(walk)
                continue
            }
            let example = members.first { $0.hasSuffix(".body") } ?? first
            if !explained.contains(where: { $0.subject == key }) { explained.append((key, example)) }
        }
        guard let example = explained.first?.example else { return ([], rest) }
        let count = explained.count == 1 ? "1 walk names" : "\(explained.count) walks name"
        let hint =
            "\(count) a member that logic did not scan, of a type it did (\(explained.map(\.subject).joined(separator: ", "))): "
            + "name the member the walk reaches, e.g. Prove(\"\(example)\", it: …). check follows a protocol-extension method "
            + "such as `execute()` to that member only when its body is just that member"
        return ([hint], rest)
    }
}

/// The source reading behind `Check.Forwarders`: comments removed, braces matched, strings skipped.
enum ForwarderSource {
    struct TypeDeclaration {
        var kind: String
        var name: String
        var inherited: Set<String>
        var body: Substring
    }

    struct Extension {
        var name: String
        var inherited: Set<String>
        var unconstrained: Bool
        var body: Substring
    }

    /// The modules `text` imports: `import A`, `@testable import B`, `import struct C.D` → `A`, `B`, `C`.
    static func imports(_ text: String) -> [String] {
        text.matches(
            of: /(?m)^\s*(?:@[A-Za-z_]+\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)/
        )
        .map { String($0.1) }
    }

    /// `text` without comments, each string and regex literal replaced by `""`; nil when that cannot be done for sure
    /// (see `LiteralFreeSource`).
    static func strippingComments(_ text: String) -> String? { LiteralFreeSource.text(text) }

    /// The index of the brace that closes the one at `open`, skipping string literals.
    static func closingBrace(in text: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var inString = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if character == "\\" { index = text.index(after: index) } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            guard index < text.endIndex else { break }
            index = text.index(after: index)
        }
        return nil
    }

    /// `struct X<T>: A, B where … {` → the names of `A` and `B` (without generic arguments or module), and where the
    /// header ends (its `{`); nil when the header has no `{`.
    private struct Header {
        var inherited: Set<String>
        var constrained: Bool
        var open: Substring.Index
    }

    private static func header(_ text: Substring) -> Header? {
        guard let open = text.firstIndex(of: "{") else { return nil }
        var head = text[..<open].drop { $0.isWhitespace }
        if head.first == "<" {
            var depth = 0
            head = head.drop { character in
                if character == "<" { depth += 1 } else if character == ">" { depth -= 1 }
                return depth > 0 || character == ">"
            }
        }
        let constrained = head.range(of: "where") != nil
        let list = head.drop { $0.isWhitespace }
        guard list.first == ":" else { return Header(inherited: [], constrained: constrained, open: open) }
        let clause = list.dropFirst().components(separatedBy: " where ")[0]
        var inherited: Set<String> = []
        for item in clause.split(separator: ",") {
            let name = item.trimmingCharacters(in: .whitespaces).prefix { $0 != "<" && !$0.isWhitespace }
            if let last = name.split(separator: ".").last { inherited.insert(String(last)) }
        }
        return Header(inherited: inherited, constrained: constrained, open: open)
    }

    static func typeDeclarations(in text: String) -> [TypeDeclaration] {
        text.matches(of: /(?:^|[^\w.])(struct|enum|class|actor|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)/).compactMap { match in
            let name = String(match.2)
            guard !["var", "func", "let", "subscript", "init"].contains(name) else { return nil }
            let rest = text[match.range.upperBound...]
            guard match.1 != "typealias", let head = header(rest), let close = closingBrace(in: rest, from: head.open) else {
                return TypeDeclaration(kind: String(match.1), name: name, inherited: [], body: "")
            }
            return TypeDeclaration(kind: String(match.1), name: name, inherited: head.inherited, body: rest[head.open...close])
        }
    }

    static func extensions(in text: String) -> [Extension] {
        text.matches(of: /\bextension\s+([A-Za-z_][A-Za-z0-9_.]*)/).compactMap { match in
            let rest = text[match.range.upperBound...]
            guard let head = header(rest), let close = closingBrace(in: rest, from: head.open) else { return nil }
            let name = String(match.1.split(separator: ".").last ?? match.1)
            let unconstrained = head.inherited.isEmpty && !head.constrained
            return Extension(name: name, inherited: head.inherited, unconstrained: unconstrained, body: rest[head.open...close])
        }
    }

    /// The members a protocol body requires: a property → false, a function without parameters → true.
    static func requirements(in body: Substring) -> [String: Bool] {
        var found: [String: Bool] = [:]
        for match in body.matches(of: /\bvar\s+([A-Za-z_][A-Za-z0-9_]*)/) { found[String(match.1)] = false }
        for match in body.matches(of: /\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)/) { found[String(match.1)] = true }
        return found
    }

    /// The instance methods without parameters or generic parameters of an extension body, with their bodies.
    static func methods(in body: Substring) -> [(name: String, body: Substring)] {
        body.matches(of: /(?:^|[^\w])func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)/).compactMap { match in
            let line = body[..<match.range.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            guard !line.contains("static"), !line.contains("class") else { return nil }
            let rest = body[match.range.upperBound...]
            guard let open = rest.firstIndex(of: "{"), !rest[..<open].contains("where"), !rest[..<open].contains("\n\n"),
                let close = closingBrace(in: rest, from: open)
            else { return nil }
            return (String(match.1), rest[rest.index(after: open)..<close])
        }
    }

    /// Whether `name` appears in `text` as a whole word.
    static func mentions(_ name: String, in text: String) -> Bool {
        guard let pattern = try? Regex("\\b\(NSRegularExpression.escapedPattern(for: name))\\b") else { return true }
        return text.contains(pattern)
    }

    /// How many times `name` is declared in `texts`: `func name`, `var name`, `let name`, `case name` (also in backticks).
    static func declarationCount(of name: String, in texts: [String]) -> Int {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let pattern = try? Regex("\\b(?:func|var|let|case)\\s+`?\(escaped)\\b") else { return Int.max }
        return texts.reduce(0) { $0 + ($1.contains(name) ? $1.matches(of: pattern).count : 0) }
    }

    /// `body`, `return body`, `self.body`, `return self.body` → (`body`, false); `make()` and the like → (`make`, true).
    static func forwardedMember(_ body: Substring) -> (member: String, isCall: Bool)? {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        if text.hasPrefix("return "), let after = Optional(text.dropFirst(7).drop { $0.isWhitespace }) { text = after }
        if text.hasPrefix("self.") { text = text.dropFirst(5) }
        var isCall = false
        if text.hasSuffix("()") {
            text = text.dropLast(2)
            isCall = true
        }
        guard let first = text.first, first.isLetter || first == "_", text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }
        return (String(text), isCall)
    }

    /// Whether the walk starting on `lines[index]` has a closure whose whole body is `Type(…).member()`: a call on a
    /// value the closure builds, so its type is `Type`.
    static func closureBuilds(_ type: String, calling member: String, at index: Int, in lines: [String]) -> Bool {
        let text = lines[index..<min(index + 6, lines.count)].joined(separator: "\n")[...]
        guard let call = text.range(of: "Prove(") else { return false }
        var position = call.upperBound
        var inString = false
        while position < text.endIndex, inString || text[position] != "{" {
            if text[position] == "\\", inString {
                position = text.index(after: position)
            } else if text[position] == "\"" {
                inString.toggle()
            }
            guard position < text.endIndex else { return false }
            position = text.index(after: position)
        }
        guard position < text.endIndex, let close = closingBrace(in: text, from: position) else { return false }
        var body = text[text.index(after: position)..<close].trimmingCharacters(in: .whitespacesAndNewlines)[...]
        if let range = body.range(of: " in "),
            body[..<range.lowerBound].allSatisfy({ $0.isLetter || $0.isNumber || " _,():$".contains($0) })
        {
            body = body[range.upperBound...].drop { $0.isWhitespace }
        }
        for keyword in ["return ", "try ", "await "] where body.hasPrefix(keyword) {
            body = body.dropFirst(keyword.count).drop { $0.isWhitespace }
        }
        guard body.hasPrefix(type + "("), body.hasSuffix(").\(member)()") else { return false }
        let arguments = body.dropFirst(type.count).dropLast(member.count + 3)
        return balanced(arguments)
    }

    /// Whether `text` is one parenthesized group: `(…)` whose first parenthesis closes at its end.
    private static func balanced(_ text: Substring) -> Bool {
        var depth = 0
        for (offset, character) in text.enumerated() {
            if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
            if depth == 0, offset < text.count - 1 { return false }
        }
        return depth == 0 && text.first == "("
    }
}
