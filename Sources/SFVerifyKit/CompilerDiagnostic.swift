/// One line in the Swift compiler's diagnostic format, `<file>:<line>:<column>: <severity>: <message>`, which Xcode,
/// the `$swiftc` problem matcher of VS Code and CI log readers pick up. Shared by `sfverify --xcode`, the gate,
/// `swiftformal check --gate` and `swiftformal check --format xcode`; each keeps its own tag and its own fallback place.
package enum CompilerDiagnostic {
    /// The severity word of a line: `error` fails an Xcode build, `warning` and `note` do not.
    package enum Severity: String, Sendable {
        case error, warning, note
    }

    /// `location` as `<file>:<line>:<column>` (a column of 0, which the compiler never prints, is shown as 1), or
    /// `fallback` (a module or tool name) without one. A `tag` such as `[swiftformal]` starts the message.
    package static func line(
        _ location: SourceLocation?, _ severity: Severity, _ message: String, tag: String? = nil, fallback: String
    ) -> String {
        let place = location.map { "\($0.file):\($0.line):\(max($0.column, 1))" } ?? fallback
        let text = tag.map { "\($0) \(message)" } ?? message
        return "\(place): \(severity.rawValue): \(text)"
    }
}
