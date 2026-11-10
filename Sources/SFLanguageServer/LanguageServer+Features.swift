import Foundation
import SFVerifyKit

// Code lenses, hovers and code actions, from the stored verdicts.
extension LanguageServer {
    /// One lens above each checked function of the document. Several functions on one line (a property's getter and
    /// setter) get one lens each, named.
    func codeLenses(_ params: JSONValue) -> JSONValue {
        guard let path = params["textDocument"]["uri"].string.flatMap(Paths.path(uri:)) else { return [] }
        let results = store.results(inFile: path)
        guard !results.isEmpty else { return [] }
        let hash = currentHash(path)
        let config = config(for: path) ?? ServerConfig()
        let lines = Dictionary(grouping: results) { $0.entry.location?.line ?? 0 }
        var lenses: [JSONValue] = []
        for (line, onLine) in lines.sorted(by: { $0.key < $1.key }) where line >= 1 {
            for result in onLine {
                var title = Render.lensTitle(result, current: result.isCurrent(currentHash: hash), checkOn: config.checkOn)
                if onLine.count > 1 { title = Render.shortName(result.entry.function) + ": " + title }
                let position = Position(line: line - 1, character: 0).json
                lenses.append(["range": ["start": position, "end": position], "command": ["title": .string(title), "command": ""]])
            }
        }
        return .array(lenses)
    }

    /// The verdicts of the innermost function around `position`: every function whose body holds the line, the
    /// smallest first (a property's getter and setter share one).
    func results(at params: JSONValue) -> Located? {
        guard let path = params["textDocument"]["uri"].string.flatMap(Paths.path(uri:)),
            let line = params["position"]["line"].int ?? params["range"]["start"]["line"].int, let text = currentText(path)
        else { return nil }
        let ranges = SourceRanges(text)
        let around = store.results(inFile: path).compactMap { result -> (StoredResult, ClosedRange<Int>)? in
            guard let location = result.entry.location else { return nil }
            let range = ranges.range(line: location.line, column: location.column)
            return range.contains(line + 1) ? (result, range) : nil
        }
        guard let smallest = around.map({ $0.1.count }).min() else { return nil }
        return Located(path: path, text: text, results: around.filter { $0.1.count == smallest }.map(\.0))
    }

    /// The verdicts under a position, with their file and its current text.
    struct Located {
        let path: String
        let text: String
        let results: [StoredResult]
    }

    func hover(_ params: JSONValue) -> JSONValue {
        guard let located = results(at: params) else { return .null }
        let (path, results) = (located.path, located.results)
        let hash = currentHash(path)
        let checkOn = config(for: path)?.checkOn ?? .save
        let text = results.map { Render.hover($0, current: $0.isCurrent(currentHash: hash), checkOn: checkOn) }.joined(
            separator: "\n\n---\n\n")
        return ["contents": ["kind": "markdown", "value": .string(text)]]
    }

    /// Edits for a current verdict only: a counterexample or a contract of code that changed since could be wrong.
    func codeActions(_ params: JSONValue) -> JSONValue {
        guard let located = results(at: params) else { return [] }
        let (path, text, results) = (located.path, located.text, located.results)
        let hash = currentHash(path)
        let testDirectory = testDirectory(for: path)
        var actions: [JSONValue] = []
        for result in results where result.isCurrent(currentHash: hash) {
            for action in CodeActions.actions(for: result, text: text, testDirectory: testDirectory) {
                guard let edit = workspaceEdit(action) else { continue }
                let kind = action.title.hasPrefix("Replay") ? "quickfix" : "refactor"
                actions.append(["title": .string(action.title), "kind": .string(kind), "edit": edit])
            }
        }
        return .array(actions)
    }

    /// A test target's folder in the package of `path`: `<Module>Tests` if there is one, else the first test target.
    func testDirectory(for path: String) -> String? {
        guard let root = Paths.packageRoot(of: path), let manifest = manifests.cachedManifest(root) else { return nil }
        let module = manifest.target(containing: path)?.name
        let tests = manifest.targets.filter { $0.type == "test" && FileManager.default.fileExists(atPath: $0.path) }
        return (tests.first { $0.name == (module ?? "") + "Tests" } ?? tests.first)?.path
    }

    /// The action as an LSP `WorkspaceEdit`; nil when it creates a file and the client cannot.
    func workspaceEdit(_ action: CodeAction) -> JSONValue? {
        if action.create != nil, !(support.documentChanges && support.createFiles) { return nil }
        var order: [String] = []
        var edits: [String: [JSONValue]] = [:]
        for insertion in action.insertions {
            if edits[insertion.path] == nil { order.append(insertion.path) }
            let range: JSONValue = ["start": insertion.position.json, "end": (insertion.end ?? insertion.position).json]
            edits[insertion.path, default: []].append(["range": range, "newText": .string(insertion.text)])
        }
        let uri = { (path: String) in self.documents[path]?.uri ?? Paths.uri(path: path) }
        guard support.documentChanges else {
            return ["changes": .object(Dictionary(uniqueKeysWithValues: order.map { (uri($0), JSONValue.array(edits[$0] ?? [])) }))]
        }
        var changes: [JSONValue] = []
        if let create = action.create {
            changes.append(["kind": "create", "uri": .string(uri(create)), "options": ["ignoreIfExists": true]])
        }
        for path in order {
            let version: JSONValue = documents[path]?.version.map { .number(Double($0)) } ?? .null
            changes.append(["textDocument": ["uri": .string(uri(path)), "version": version], "edits": .array(edits[path] ?? [])])
        }
        return ["documentChanges": .array(changes)]
    }
}
