import Foundation
import SFSIL

/// Which names of a module are Objective-C types, and which of those dispatch could take into its own Swift code (plan
/// item R6-1, `SILForeign.swift`). Both answers come from the compiler's tools, never from the bare name.
enum ForeignTypeCheck {
    /// Finds the module's foreign classes and protocols by demangling, then asks the compiler what Swift calls each
    /// (`NS_SWIFT_NAME`: the mangling keeps the Objective-C name, SIL prints the Swift one) and which of them no
    /// foreign supertype of a read class converts to. A step that cannot be done leaves the types unread, never guessed.
    /// `swiftNames`: the Swift names of classes the compiler's errors do not show renamed (`BinaryTypeCheck`).
    static func check(_ module: inout SILModule, imports: [String], arguments: [String], swiftNames: [String: String] = [:]) throws {
        let symbols = module.foreignCandidateSymbols
        guard !symbols.isEmpty, let found = clangTypes(in: symbols) else { return }
        module.confirmForeignTypes(classes: found.classes, protocols: found.protocols)
        module.renameForeignTypes(swiftNames)
        let question = module.foreignSupertypeQuestion
        guard !question.types.isEmpty else { return }
        let compiler = try ScanToolchain.current().swiftc
        let key = ["foreign", compiler] + question.types + ["\u{0}"] + question.supertypes + ["\u{0}"] + imports + ["\u{0}"] + arguments
        guard let answer = try answers.answer(key, { try probe(question, imports: imports, arguments: arguments) }) else { return }
        module.renameForeignTypes(answer.renamed)
        let unrelated = answer.unrelated.map { spelled -> String in
            let name = spelled.hasPrefix("any ") ? String(spelled.dropFirst(4)) : spelled
            let swiftName = answer.renamed[name] ?? name
            return spelled.hasPrefix("any ") ? "any " + swiftName : swiftName
        }
        module.confirmUnrelatedForeignTypes(unrelated)
    }

    /// The classes and protocols of `__C` named in `symbols`, from the demangler's node trees (`swift-demangle
    /// -tree-only`): a `kind=Class` or `kind=Protocol` node whose module child is `__C`. Nil when the tool fails.
    static func clangTypes(in symbols: [String]) -> (classes: Set<String>, protocols: Set<String>)? {
        let next = (try? ScanToolchain.current().toolchainUsr).map { $0 + "/bin/swift-demangle" }
        let command =
            next.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? ($0, ["-tree-only"]) : nil }
            ?? ("/usr/bin/xcrun", ["swift-demangle", "-tree-only"])
        guard let run = try? Spawn.run(command.0, command.1, input: Data((symbols.joined(separator: "\n") + "\n").utf8)), run.status == 0,
            let text = String(bytes: run.output, encoding: .utf8)
        else { return nil }
        return clangTypes(inTrees: text)
    }

    /// `clangTypes(in:)` on the printed trees.
    static func clangTypes(inTrees text: String) -> (classes: Set<String>, protocols: Set<String>) {
        var classes: Set<String> = [], protocols: Set<String> = []
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for (i, line) in lines.enumerated() where i + 2 < lines.count && (line == "kind=Class" || line == "kind=Protocol") {
            guard lines[i + 1] == "kind=Module, text=\"__C\"", lines[i + 2].hasPrefix("kind=Identifier, text=\""),
                lines[i + 2].hasSuffix("\"")
            else { continue }
            let name = String(lines[i + 2].dropFirst("kind=Identifier, text=\"".count).dropLast())
            if line == "kind=Class" { classes.insert(name) } else { protocols.insert(name) }
        }
        return (classes, protocols)
    }

    /// What the probe found: the Swift name of each type the compiler renamed, and the types (spelled `C` or `any P`,
    /// with their mangled names) to which no supertype converts.
    struct ProbeAnswer: Sendable {
        var renamed: [String: String] = [:]
        var unrelated: Set<String> = []
    }

    /// One `typealias` per type, to read its Swift name off the compiler's "renamed" error, and one line per pair of
    /// type and supertype, `func f<X: Super>(_ x: X) -> C { x }`, which compiles exactly when an instance of a subclass
    /// or conformer of `Super` may be a `C`. A pair counts as unrelated only when the compiler says the conversion
    /// fails (and at most that the type was renamed). Nil when the probe cannot answer (a supertype does not resolve,
    /// an import fails).
    static func probe(_ question: (types: [String], supertypes: [String]), imports: [String], arguments: [String]) throws
        -> ProbeAnswer?
    {
        let directory = NSTemporaryDirectory() + "sfverify-foreign-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/SFForeignProbe.swift"
        let header = imports.filter { $0 != "Builtin" }.map { "import \($0)" }
        let supers = question.supertypes.enumerated().map { "typealias SFSuper\($0.offset) = \($0.element)" }
        let names = question.types.enumerated().map { "typealias SFName\($0.offset) = \($0.element)" }
        var pairs: [(type: Int, line: Int)] = []
        var probes: [String] = []
        for (t, type) in question.types.enumerated() {
            for s in question.supertypes.indices {
                pairs.append((t, header.count + supers.count + names.count + probes.count + 1))
                probes.append("func sfForeign\(t)x\(s)<SFX: SFSuper\(s)>(_ x: SFX) -> \(type) { x }")
            }
        }
        try (header + supers + names + probes).joined(separator: "\n").appending("\n").write(
            toFile: file, atomically: true, encoding: .utf8)
        let sdk = try ModuleCompiler.sdkArguments(arguments)
        let result = try ModuleCompiler.run(
            ["swiftc", "-frontend", "-typecheck", "-parse-as-library", "-module-name", "SFForeignProbe", "-diagnostic-style", "llvm"]
                + sdk.arguments + ModuleCompiler.withModuleCache(arguments) + ["-no-color-diagnostics", file])
        guard let errors = probeErrors(result.errors, file: file, firstName: header.count + supers.count + 1) else { return nil }
        let firstName = header.count + supers.count + 1
        var answer = ProbeAnswer()
        var related: Set<Int> = []
        for (line, messages) in errors {
            let renamings = messages.compactMap(renaming)
            if line < firstName + names.count {
                for renamed in renamings { answer.renamed[renamed.from] = renamed.to }
                if renamings.count < messages.count { related.insert(line - firstName) }
            }
        }
        for pair in pairs {
            // A "no" only when the compiler says the conversion fails (and at most that the type was renamed).
            let messages = errors[pair.line] ?? []
            let fails = messages.contains { $0.contains("cannot convert return expression of type") || $0.contains("does not conform to") }
            let other = messages.contains {
                renaming($0) == nil && !$0.contains("cannot convert return expression of type") && !$0.contains("does not conform to")
            }
            if !fails || other { related.insert(pair.type) }
        }
        answer.unrelated = Set(question.types.indices.filter { !related.contains($0) }.map { question.types[$0] })
        return answer
    }

    /// The error messages of the probe, by line; nil when one is outside the probe lines (a supertype that does not
    /// resolve, an import that fails), which leaves the probe without an answer.
    private static func probeErrors(_ text: String, file: String, firstName: Int) -> [Int: [String]]? {
        var errors: [Int: [String]] = [:]
        for line in text.replacing(/\u{1B}\[[0-9;]*m/, with: "").split(separator: "\n") {
            guard line.hasPrefix(file + ":") else {
                if line.contains("error:") { return nil }
                continue
            }
            let parts = line.dropFirst(file.count + 1).split(separator: ":", maxSplits: 3)
            guard parts.count == 4, let number = Int(parts[0]), parts[2] == " error" else { continue }
            if number < firstName { return nil }
            errors[number, default: []].append(String(parts[3]))
        }
        return errors
    }

    /// `'SharedKtDouble' has been renamed to 'KotlinDouble'` -> (SharedKtDouble, KotlinDouble).
    static func renaming(_ message: String) -> (from: String, to: String)? {
        let quoted = message.split(separator: "'", omittingEmptySubsequences: false)
        guard message.contains("' has been renamed to '"), quoted.count >= 5 else { return nil }
        let (from, to) = (String(quoted[1]), String(quoted[3]))
        guard [from, to].allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }) else { return nil }
        return (from, to)
    }

    private static let answers = ForeignProbeAnswers()
}

/// Probe answers of this process, by everything a probe is made of. Failures are not kept.
private final class ForeignProbeAnswers: Sendable {
    private let stored = Guarded<[[String]: ForeignTypeCheck.ProbeAnswer]>([:])

    func answer(_ key: [String], _ probe: () throws -> ForeignTypeCheck.ProbeAnswer?) throws -> ForeignTypeCheck.ProbeAnswer? {
        if let known = stored.withLock({ $0[key] }) { return known }
        let found = try probe()
        if let found { stored.withLock { $0[key] = found } }
        return found
    }
}
