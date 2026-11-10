extension SILModule {
    /// The top-level module of an import line. SIL keeps attributes and the access level (`@preconcurrency package
    /// import os`); a scoped or submodule import (`import struct Foundation.Date`) stands for its whole top-level
    /// module, which declares at least as many names.
    static func importedModule(_ line: String) -> String? {
        let words = line.split(separator: " ")
        guard let at = words.firstIndex(of: "import"), at + 1 < words.count,
            words[..<at].allSatisfy({ $0.hasPrefix("@") || accessLevels.contains(String($0)) })
        else { return nil }
        return words[words.count - 1].split(separator: ".").first.map(String.init)
    }

    private static let accessLevels: Set<String> = ["public", "package", "internal", "fileprivate", "private"]
}
