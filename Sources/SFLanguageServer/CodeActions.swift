import Foundation
import SFVerifyKit

/// A position in a document, LSP style: 0-based line, UTF-16 column.
package struct Position: Equatable, Sendable {
    package var line: Int
    package var character: Int

    package init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    package var json: JSONValue { ["line": .number(Double(line)), "character": .number(Double(character))] }
}

/// An insertion of `text` at `position` of the file at `path`, replacing the text up to `end` when given.
package struct Insertion: Equatable, Sendable {
    package var path: String
    package var position: Position
    package var text: String
    package var end: Position?
}

/// One code action: insertions, and a file to create first (empty) when it does not exist.
package struct CodeAction: Equatable, Sendable {
    package var title: String
    package var create: String?
    package var insertions: [Insertion]
}

/// The edits the server offers on a checked function. Each is plain text built from the stored verdict and the
/// file as the editor has it; none of them changes a verdict, and the next check reads them like any other edit.
package enum CodeActions {
    /// Every action for `result` in `text` (the file's current text). `testDirectory`: the directory of a test target
    /// of the function's package, where a new test file goes; nil offers no test.
    package static func actions(for result: StoredResult, text: String, testDirectory: String?) -> [CodeAction] {
        let lines = text.components(separatedBy: "\n")
        var actions: [CodeAction] = []
        if let testDirectory, let replay = replayTest(result, text: text, testDirectory: testDirectory) { actions.append(replay) }
        if let contract = addContract(result, lines: lines) { actions.append(contract) }
        if let testDirectory, let prove = proveSkeleton(result, testDirectory: testDirectory) { actions.append(prove) }
        return actions
    }

    // MARK: replay

    /// A Swift Testing test that replays the logic counterexample on the compiled function (the test
    /// `swiftformal check --emit-tests` writes), in `<testDirectory>/<Module>ReplayTests.swift`.
    package static func replayTest(_ result: StoredResult, text: String, testDirectory: String) -> CodeAction? {
        let entry = result.entry
        guard [.contractFails, .mayTrap].contains(entry.logic), let e = entry.counterexample, e.replay != nil else { return nil }
        if let location = entry.location, Playback.uncallable(declaredAt: location.line, in: text) != nil { return nil }
        let path = testDirectory + "/\(entry.module)ReplayTests.swift"
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        let index = (existing?.components(separatedBy: "func playback_").count ?? 1)
        let releaseReport = result.module?.configurations == ["release"] || result.module?.optimization == "-O"
        guard case .success(let test) = Playback.test(function: entry.function, symbol: "", e, index: index, releaseReport: releaseReport)
        else {
            return nil
        }
        let header = existing == nil ? replayHeader(module: entry.module) : ""
        let footer = existing == nil ? "\n#endif\n" : ""
        return CodeAction(
            title: "Replay the counterexample as a test (\(entry.module)ReplayTests.swift)",
            create: existing == nil ? path : nil,
            insertions: [Insertion(path: path, position: insertionPoint(in: existing), text: header + test.source + "\n" + footer)])
    }

    /// Where a test goes in the replay file: before its closing `#endif`, else at the end; the start of a new file.
    private static func insertionPoint(in existing: String?) -> Position {
        guard let existing else { return Position(line: 0, character: 0) }
        let lines = existing.components(separatedBy: "\n")
        if let endif = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "#endif" }) {
            return Position(line: endif, character: 0)
        }
        return Position(line: lines.count - 1, character: lines.last.map { $0.utf16.count } ?? 0)
    }

    private static func replayHeader(module: String) -> String {
        """
        // Each test replays a counterexample SwiftFormal found on the compiled code, and passes while it still
        // reproduces: a trap ends the process (an exit test), a broken postcondition returns false. Once the function
        // is fixed its test fails; delete it then. Exit tests need Swift 6.3 or newer on macOS or Linux.

        #if (os(macOS) || os(Linux)) && compiler(>=6.3)
        import Testing
        @testable import \(module)


        """
    }

    // MARK: contracts

    /// `@Verify` with an empty contract to fill in (`#requires`, `#ensures`), and `import SwiftFormal` when the file does
    /// not import the macros yet.
    package static func addContract(_ result: StoredResult, lines: [String]) -> CodeAction? {
        guard let path = result.file, let line = declarationLine(result, lines: lines) else { return nil }
        let above = attributeStart(line, lines: lines)
        guard !(above...line).contains(where: { lines[$0].contains("@Verify") }) else { return nil }
        let name = result.entry.function
        guard !name.hasPrefix("static "), !name.contains(".getter"), !name.contains(".setter"), !name.contains("init(") else { return nil }
        guard let column = result.entry.location?.column,
            let open = SourceRanges(lines.joined(separator: "\n")).bodyOpening(line: line + 1, column: column)
        else { return nil }
        let indent = String(lines[line].prefix { $0 == " " || $0 == "\t" })
        let body = indent + "    "
        let contract = body + "#requires(true)  // the inputs callers may pass\n" + body + "#ensures { _ in true }  // what it returns\n"
        var insertions = [
            Insertion(path: path, position: Position(line: above, character: 0), text: indent + "@Verify\n"),
            bodyInsertion(contract, path: path, after: open, lines: lines, indents: (indent, body)),
        ]
        if !lines.contains(where: importsTheMacros) {
            let last = lines.lastIndex { $0.hasPrefix("import ") || $0.hasPrefix("@testable import ") } ?? -1
            insertions.insert(Insertion(path: path, position: Position(line: last + 1, character: 0), text: "import SwiftFormal\n"), at: 0)
        }
        return CodeAction(title: "Add a contract (@Verify, #requires, #ensures)", create: nil, insertions: insertions)
    }

    /// Whether `line` imports `@Verify`: `import SwiftFormal` (with any access or `@testable`). `import SwiftFormalTesting`
    /// does not re-export the macros.
    private static func importsTheMacros(_ line: String) -> Bool {
        let words = line.split(separator: " ")
        guard let module = words.last, let position = words.firstIndex(of: "import"), position == words.count - 2 else { return false }
        return module == "SwiftFormal"
    }

    /// `text` (whole lines) as the first lines of a body whose `{` ends at `open`: on the next line, or, when code
    /// follows the `{` on its line, after a line break, with that code moved to the line after it (indented as the
    /// body, or as the declaration when it is the closing `}`).
    private static func bodyInsertion(
        _ text: String, path: String, after open: (line: Int, character: Int), lines: [String], indents: (outer: String, body: String)
    ) -> Insertion {
        let rest = Array(lines[open.line].utf16).dropFirst(open.character)
        let blank = rest.prefix { $0 == 0x20 || $0 == 0x09 }.count  // spaces and tabs
        let following = String(decoding: rest.dropFirst(blank), as: UTF16.self)
        if following.isEmpty || following.hasPrefix("//") || following == "\r" {
            return Insertion(path: path, position: Position(line: open.line + 1, character: 0), text: text)
        }
        return Insertion(
            path: path, position: Position(line: open.line, character: open.character),
            text: "\n" + text + (following.hasPrefix("}") ? indents.outer : indents.body),
            end: Position(line: open.line, character: open.character + blank))
    }

    // MARK: walks

    /// A `Prove(it:over:)` test of the function, in `<testDirectory>/<Name>ProveTests.swift`, to fill in.
    package static func proveSkeleton(_ result: StoredResult, testDirectory: String) -> CodeAction? {
        let entry = result.entry
        guard entry.walks.isEmpty, entry.checkedOutcome != .provedByLogic else { return nil }
        let base = entry.function.prefix { $0 != "(" && $0 != "," }
        let words = base.split(separator: " ").last.map(String.init) ?? String(base)
        let parts = words.split(separator: ".").map(String.init).filter { !["getter", "setter", "init"].contains($0) }
        guard let last = parts.last, !last.hasPrefix("__") else { return nil }
        let identifier = parts.joined(separator: "_").filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let path = testDirectory + "/\(identifier.prefix(1).uppercased() + identifier.dropFirst())ProveTests.swift"
        guard !FileManager.default.fileExists(atPath: path) else { return nil }
        let subject = parts.joined(separator: ".")
        let source = """
            import SwiftFormalTesting
            import Testing
            @testable import \(entry.module)

            @Test func \(identifier)Promises() {
                // `over:` lists every input; leave it out when the input type is `Finite` (`.allCases` for an enum).
                Prove(\(literal(subject)), it: { (input: <#Input#>) in <#call \(subject) with input#> }, over: <#.allCases#>) {
                    Deterministic()
                    // Satisfies("what it promises") { input, output in <#condition#> }
                }
            }

            """
        return CodeAction(
            title: "Add a Prove(it:over:) test (\((path as NSString).lastPathComponent))", create: path,
            insertions: [Insertion(path: path, position: Position(line: 0, character: 0), text: source)])
    }

    // MARK: reading the declaration

    /// The 0-based line of the function's declaration, when the stored location is a line of `lines` that declares it.
    private static func declarationLine(_ result: StoredResult, lines: [String]) -> Int? {
        guard let line = result.entry.location?.line, line >= 1, line <= lines.count else { return nil }
        return line - 1
    }

    /// The first line of the attributes and blank-free run of `@…` lines directly above `line`.
    private static func attributeStart(_ line: Int, lines: [String]) -> Int {
        var start = line
        while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("@") { start -= 1 }
        return start
    }

    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
