import Foundation

extension SwiftPMBuild {
    /// Whether a compile command read from the build log is whole. `swift build -v` runs tasks in parallel, and another
    /// task can print into the middle of the command line (actool's `/* com.apple.actool.compilation-results */` and a
    /// newline, seen on a real app), which cuts the command short or splits a path. A whole command names its module,
    /// has sources (a `.swift` file or an existing `@` file list), has no comment text, and every plugin it loads is an
    /// existing `<path>#<module>`.
    package static func isWhole(_ command: [String]) -> Bool {
        let fm = FileManager.default
        guard command.contains("-module-name") else { return false }
        if command.contains(where: { $0.contains("/*") || $0.contains("*/") }) { return false }
        var hasSources = false
        for token in command {
            if token.hasPrefix("@") {
                guard fm.fileExists(atPath: String(token.dropFirst())) else { return false }
                hasSources = true
            } else if token.hasSuffix(".swift") {
                hasSources = true
            }
        }
        guard hasSources else { return false }
        let values = command.filter { $0 != "-Xfrontend" }
        for (index, token) in values.enumerated() where token == "-load-plugin-executable" {
            guard index + 1 < values.count, let hash = values[index + 1].lastIndex(of: "#"),
                fm.fileExists(atPath: String(values[index + 1][..<hash]))
            else { return false }
        }
        return true
    }
}
