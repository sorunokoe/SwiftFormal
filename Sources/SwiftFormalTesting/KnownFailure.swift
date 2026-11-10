internal import SwiftFormal
public import Testing

/// A failure a walk is expected to find: a known defect kept as it is. Pass it as `knownIssue:` instead of wrapping the
/// walk in `withKnownIssue { … }`.
///
/// The test passes while the walk fails as described, and fails once the walk passes (the defect was fixed: remove the
/// known issue). A plain string is enough:
///
/// ```swift
/// Prove(it: { placementText($0) }, over: .int(1...100),
///       knownIssue: "21th, 22th, 23th: only 1-3 get their own suffix") {
///     Satisfies("English ordinal suffix") { number, text in text == "\(number)\(suffix(number)) place" }
/// }
/// ```
///
/// Name the failing inputs to keep the test strict: a failure on another input is then an ordinary failure. With
/// `reporting: .everyFailure`, which finds every failing input, a named input that no longer fails is one too.
///
/// ```swift
/// knownIssue: KnownFailure("zh-Hant takes %1$d %2$d", failingInputs: ["zh-Hant: item_moved_to_archive"])
/// ```
public struct KnownFailure: Sendable, ExpressibleByStringInterpolation {
    /// Why the walk fails, shown with the known issue.
    public var comment: Comment
    /// The inputs expected to fail, as the report prints them (`String(describing:)`), or `nil` for any input.
    public var failingInputs: [String]?

    /// A known failure on `failingInputs`, written as the report prints them, or on any input when `nil`.
    public init(_ comment: Comment, failingInputs: [String]? = nil) {
        self.comment = comment
        self.failingInputs = failingInputs
    }

    /// A known failure on exactly these inputs, compared as the report prints them (`String(describing:)`).
    public init<Input>(_ comment: Comment, inputs: [Input]) {
        self.init(comment, failingInputs: inputs.map { String(describing: $0) })
    }

    /// A known failure on any input, described by a string literal.
    public init(stringLiteral value: String) { self.init(Comment(rawValue: value)) }

    /// A known failure on any input, described by an interpolated string.
    public init(stringInterpolation: DefaultStringInterpolation) {
        self.init(Comment(rawValue: stringInterpolation.description))
    }
}

/// How many failing inputs a walk reports: the first of each property, which is all a proof needs and keeps failing
/// walks fast, or every one, for an audit (every translation key in every language).
public enum FailureReporting: Sendable {
    /// Stop checking a property at its first failing input.
    case firstFailure
    /// Walk the whole domain (within the budget) and list every failing input of every property in the issue.
    case everyFailure
}

/// What a walk found, for the test issues it records.
struct WalkFindings {
    /// The whole report, as the issue's text.
    var message: String
    /// `nil` when the walk passed.
    var severity: WalkIssue.Severity?
    /// The failing inputs as the report prints them; `nil` for a failure that names no input.
    var failingInputs: [String?]
    /// Whether every failing input is listed, so a known input missing from the list no longer fails.
    var listsEveryFailure: Bool
}

extension WalkIssue {
    /// Records the issues for `findings`: none for a pass, the report otherwise. With a known failure, the matching
    /// failures are recorded as known, and a pass records "known issue was not recorded" (the defect is gone).
    static func record(_ findings: WalkFindings, knownIssue: KnownFailure?, sourceLocation: SourceLocation) {
        guard let knownIssue, findings.severity == .error, !findings.failingInputs.isEmpty else {
            if let severity = findings.severity { record(findings.message, severity: severity, sourceLocation: sourceLocation) }
            // A walk that passed, or found no failing input, did not show the known failure.
            if let knownIssue { withKnownIssue(knownIssue.comment, sourceLocation: sourceLocation) {} }
            return
        }
        guard let listed = knownIssue.failingInputs else {
            withKnownIssue(knownIssue.comment, sourceLocation: sourceLocation) {
                record(findings.message, severity: .error, sourceLocation: sourceLocation)
            }
            return
        }
        let unexpected = findings.failingInputs.filter { input in input.map { !listed.contains($0) } ?? true }
        let expected = findings.failingInputs.compactMap { $0 }.filter(listed.contains)
        // When only other inputs failed, nothing says the named ones still fail (the walk may have stopped first).
        if !expected.isEmpty {
            withKnownIssue(knownIssue.comment, sourceLocation: sourceLocation) {
                record(findings.message, severity: .error, sourceLocation: sourceLocation)
            }
        }
        if !unexpected.isEmpty {
            let inputs = unexpected.map { $0 ?? "(no input)" }.joined(separator: ", ")
            record(
                "fails for inputs the known issue does not name: \(inputs)\n" + findings.message, severity: .error,
                sourceLocation: sourceLocation)
        }
        guard findings.listsEveryFailure else { return }
        for input in listed where !expected.contains(input) {
            record("the known issue names \(input), which no longer fails", severity: .error, sourceLocation: sourceLocation)
        }
    }

    /// One issue with `severity`; a warning is silent before Swift 6.3, which has no issue severity.
    static func record(_ message: String, severity: Severity, sourceLocation: SourceLocation) {
        #if compiler(>=6.3)
            Issue.record(Comment(rawValue: message), severity: severity == .warning ? .warning : .error, sourceLocation: sourceLocation)
        #else
            if severity == .error { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
        #endif
    }

    /// Every failure, one line each, for the issue of a walk with `reporting: .everyFailure`; the first 200 are shown.
    static func list(_ every: EveryFailure) -> String {
        let shown = 200
        let failures = every.failures
        let among = every.sampledInputs.map { " among \($0) sampled inputs" } ?? ""
        var lines = ["every failure\(among) (\(failures.count)):"]
        for (property, example) in failures.prefix(shown) {
            lines.append("  \(property)" + (example.input.map { " for input \($0)" } ?? "") + ": \(example.detail)")
        }
        if failures.count > shown { lines.append("  … and \(failures.count - shown) more (Prove(...).failures has them all)") }
        return lines.joined(separator: "\n")
    }
}
