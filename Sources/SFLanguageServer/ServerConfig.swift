import Foundation

/// A SwiftPM package directory and one of its targets (`--scan <dir>:<target>`).
package struct TargetRef: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The package directory, absolute and standardized.
    package var package: String
    package var target: String

    package init(package: String, target: String) {
        self.package = Paths.standard(package)
        self.target = target
    }

    package var argument: String { "\(package):\(target)" }
    package var description: String { argument }
}

/// When the server checks, and what.
package struct ServerConfig: Equatable, Sendable {
    package enum CheckOn: String, Sendable { case save, never }

    package var checkOn: CheckOn = .save
    /// `--scan` targets. Empty: the target that holds the saved file.
    package var scans: [TargetRef] = []
    /// `--tests`: where the walks are.
    package var tests: TargetRef?
    package var walks = true
    package var budget: Int?

    package init() {}

    /// Reads `{"checkOn": "save", "scan": ["Dir:Target", …], "tests": "Dir:Target", "walks": true, "budget": 300000}`.
    /// Package directories are relative to `base`. Members that are absent keep the values of `defaults`.
    package static func parse(_ value: JSONValue, base: String, defaults: ServerConfig = ServerConfig()) throws -> ServerConfig {
        var config = defaults
        if let text = value["checkOn"].string {
            guard let checkOn = CheckOn(rawValue: text) else { throw ConfigError("checkOn must be \"save\" or \"never\", not \"\(text)\"") }
            config.checkOn = checkOn
        }
        if let list = value["scan"].array {
            config.scans = try list.map { try target($0.string, base: base, key: "scan") }
        } else if let one = value["scan"].string {
            config.scans = [try target(one, base: base, key: "scan")]
        }
        if let text = value["tests"].string { config.tests = text.isEmpty ? nil : try target(text, base: base, key: "tests") }
        if let walks = value["walks"].bool { config.walks = walks }
        if let budget = value["budget"].int {
            guard budget > 0 else { throw ConfigError("budget must be positive") }
            config.budget = budget
        }
        return config
    }

    private static func target(_ text: String?, base: String, key: String) throws -> TargetRef {
        guard let text, let colon = text.lastIndex(of: ":"), colon != text.startIndex, text.index(after: colon) != text.endIndex else {
            throw ConfigError("\(key) entries are \"<package-dir>:<target>\", got \(text.map { "\"\($0)\"" } ?? "a non-string")")
        }
        let directory = String(text[..<colon])
        let path = directory.hasPrefix("/") ? directory : base + "/" + directory
        return TargetRef(package: path, target: String(text[text.index(after: colon)...]))
    }

    /// The configuration in `<root>/swiftformal.json`, or nil when there is none.
    package static func file(root: String) throws -> JSONValue? {
        let path = root + "/swiftformal.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        do { return try JSONDecoder().decode(JSONValue.self, from: data) } catch {
            throw ConfigError("\(path) is not valid JSON: \(error)")
        }
    }
}

/// A configuration that cannot be used; the message says why.
package struct ConfigError: Error, CustomStringConvertible, Equatable {
    package var description: String
    package init(_ description: String) { self.description = description }
}

/// Path helpers: one spelling per file, so results and edits meet.
package enum Paths {
    /// Absolute, `.`/`..` removed, symbolic links resolved.
    package static func standard(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The path of a `file://` URI, or nil for another scheme.
    package static func path(uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return standard(url.path)
    }

    /// The `file://` URI of `path`.
    package static func uri(path: String) -> String { URL(fileURLWithPath: path).absoluteString }

    /// True when `path` is `directory` or inside it.
    package static func isInside(_ path: String, _ directory: String) -> Bool {
        path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    /// Folders no check reads from directly: build products, VCS data, editor state. Only the part of `path` below
    /// the innermost of `roots` that holds it counts, so a workspace that itself sits in a `.build` folder still works.
    package static func isIgnored(_ path: String, roots: [String] = []) -> Bool {
        let base = roots.filter { isInside(path, $0) }.max { $0.count < $1.count }
        let relative = base.map { String(path.dropFirst($0.count)) } ?? path
        return relative.split(separator: "/").contains { [".build", ".git", ".swiftpm", "node_modules", "DerivedData"].contains($0) }
    }

    /// The nearest directory at or above `path`'s folder that holds a `Package.swift`.
    package static func packageRoot(of path: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> String?
    {
        var directory = (path as NSString).deletingLastPathComponent
        while !directory.isEmpty {
            if exists(directory + "/Package.swift") { return directory }
            if directory == "/" { break }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }
}
