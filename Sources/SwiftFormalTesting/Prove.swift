internal import Foundation
public import SwiftFormal
public import Testing

/// Logs `report` for `swiftformal check` with the walk's input type when known, attaches it to the test, and records an
/// issue unless it is a proof (or an accepted `bounded` verdict, then a warning). With `everyFailure`, the issue lists
/// every failing input; with `knownIssue`, the failures it names are recorded as known.
func record(
    _ report: Report, allowBounded: Bool, inputType: Any.Type?, knownIssue: KnownFailure? = nil,
    everyFailure: EveryFailure? = nil, sourceLocation: SourceLocation
) {
    WalkLog.append(report, inputType: inputType, at: sourceLocation)
    #if compiler(>=6.2)
        if Test.current != nil {
            let everyReport = WalkAttachments.everyReport(environment: ProcessInfo.processInfo.environment)
            for file in WalkAttachments.contents(for: report, at: sourceLocation, inputType: inputType, everyReport: everyReport) {
                Attachment.record(file.text, named: file.name, sourceLocation: sourceLocation)
            }
        }
    #endif
    let severity = WalkIssue.severity(for: report, allowBounded: allowBounded)
    var message = severity.map { WalkIssue.message(for: report, severity: $0) } ?? ""
    if let everyFailure, !everyFailure.failures.isEmpty { message += "\n" + WalkIssue.list(everyFailure) }
    let failures = everyFailure?.failures ?? report.counterexamples
    let findings = WalkFindings(
        message: message, severity: severity, failingInputs: failures.map(\.counterexample.input),
        listsEveryFailure: everyFailure?.sampledInputs == nil && everyFailure != nil)
    WalkIssue.record(findings, knownIssue: knownIssue, sourceLocation: sourceLocation)
}

/// Every failing input a walk with `reporting: .everyFailure` found.
struct EveryFailure {
    var failures: [(property: String, counterexample: Counterexample)]
    /// How many inputs were drawn when the domain did not fit the budget; `nil` when the whole domain was walked, so a
    /// failure missing from the list does not happen.
    var sampledInputs: Int?
}

extension FailureReporting {
    /// Walks like `runWalk`, and with `.everyFailure` also finds every failing input of a walk that failed.
    func walk<Input, Output>(
        _ subject: String, _ function: @escaping (Input) throws -> Output, over domain: Domain<Input>, budget: Budget,
        properties: () -> [Property<Input, Output>]
    ) -> (report: Report, everyFailure: EveryFailure?) {
        let list = properties()
        let report = runWalk(subject, function, over: domain, budget: budget, properties: { return list })
        guard self == .everyFailure else { return (report, nil) }
        let sampled = domain.count <= budget.maxEvaluations ? nil : budget.maxEvaluations
        guard !report.hasNoCounterexample else { return (report, EveryFailure(failures: [], sampledInputs: sampled)) }
        let failures = everyCounterexample(of: function, over: domain, budget: budget, properties: list)
        return (report, EveryFailure(failures: failures, sampledInputs: sampled))
    }
}

/// Which issue a walk records for a report.
enum WalkIssue {
    /// How serious the issue is; `Issue.Severity` exists only from Swift 6.3.
    enum Severity { case warning, error }

    /// None for a proof, a warning for a `bounded` verdict that `allowBounded` accepts, an error otherwise.
    static func severity(for report: Report, allowBounded: Bool) -> Severity? {
        if report.isProved { return nil }
        return allowBounded && report.hasNoCounterexample ? .warning : .error
    }

    /// The issue's text: the report, with a first line that says a warning is not a proof.
    static func message(for report: Report, severity: Severity) -> String {
        severity == .warning
            ? "bounded, accepted with allowBounded (not a proof):\n" + report.description : report.description
    }
}

/// The files attached to a test whose report is not a proof, and under `swiftformal check` to every test.
enum WalkAttachments {
    /// Set by `swiftformal check`, which reads every walk's JSON line from Swift Testing's event stream (plan item U12).
    static let variable = "SWIFTFORMAL_WALK_EVENTS"

    /// Whether every report, proofs too, is attached as its JSON line.
    static func everyReport(environment: [String: String]) -> Bool {
        environment[variable].map { !$0.isEmpty && $0 != "0" } ?? false
    }

    /// The report as text and as the JSON line of `SWIFTFORMAL_WALK_LOG`, named after the subject. Empty for a proof,
    /// unless `everyReport`: then a proof is attached as its JSON line.
    static func contents(
        for report: Report, at location: SourceLocation, inputType: Any.Type? = nil, everyReport: Bool = false
    ) -> [(name: String, text: String)] {
        contents(
            subject: report.subject, line: WalkLog.line(for: report, inputType: inputType, at: location), text: report.description,
            proved: report.isProved, everyReport: everyReport)
    }

    /// The text and the encoded JSON line of one walk, named after `subject`: only the line for a proof, and only when
    /// `everyReport`.
    static func contents(subject: String, line: Data?, text: String, proved: Bool, everyReport: Bool) -> [(name: String, text: String)] {
        let stem = BehaviorLock.fileStem(for: subject)
        let json = line.flatMap { String(bytes: $0, encoding: .utf8) }.map { (name: "\(stem).walk.json", text: $0) }
        guard !proved else { return everyReport ? json.map { [$0] } ?? [] : [] }
        return [(name: "\(stem).report.txt", text: text)] + (json.map { [$0] } ?? [])
    }
}

/// Walks a function over every input of a domain inside a test, and fails the test unless every property is proved.
///
/// The properties are written like SwiftUI views:
///
/// ```swift
/// @Test func surfaceText() {
///     Prove(it: { SurfaceTextRule(input: $0).execute() }, over: .allCases) {
///         Deterministic()
///         Matches(table: [.grass: "Grass", .sand: "Sand", .water: "Water"])
///         Satisfies("never empty") { _, text in !text.isEmpty }
///     }
/// }
/// ```
///
/// `swiftformal check` reads the function under test from the `it:` closure (`SurfaceTextRule.execute` here) and runs
/// this test only when logic could not prove that function. A member of the input is read too: `{ $0.label }`,
/// `{ surface in surface.label }` and `\.label` check `Surface.label`, the input type being the one the test reports
/// when it runs. Pass a subject (`Prove("SurfaceTextRule.execute", it: …)`) when the closure does not start with the
/// call.
public struct Prove<Input, Output> {
    /// The verdict of every property, with a counterexample for each one that failed.
    public let report: Report
    /// Every failing input found: all of them with `reporting: .everyFailure`, else the first of each property.
    public let failures: [(property: String, counterexample: Counterexample)]

    /// Walks `function` over `domain`, checks `properties` on every input, and records a test issue unless all are proved.
    ///
    /// - Parameters:
    ///   - subject: The name in the report and the function `swiftformal check` links the walk to. By default the
    ///     check reads it from the `it:` closure, and the report uses the test's name.
    ///   - function: The function under test.
    ///   - domain: The inputs to walk: `.allCases`, `.int(0...100)`, `.of(...)`, or a combination.
    ///   - budget: The most inputs to evaluate before the verdict is only `bounded`.
    ///   - allowBounded: Accept "no failing input found" for a domain too large to walk in full.
    ///   - reporting: `.everyFailure` lists every failing input in the issue and in ``failures``.
    ///   - knownIssue: A failure the test expects, instead of `withKnownIssue { … }` around the walk.
    ///   - sourceLocation: Where the issues and the walk's record are placed: the call.
    ///   - properties: What must hold for every input and its output.
    @discardableResult
    public init(
        _ subject: String? = nil,
        it function: @escaping (Input) throws -> Output,
        over domain: Domain<Input>,
        budget: Budget = WalkDefaults.budget,
        allowBounded: Bool = WalkDefaults.allowBounded,
        reporting: FailureReporting = .firstFailure,
        knownIssue: KnownFailure? = nil,
        sourceLocation: SourceLocation = #_sourceLocation,
        @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] }
    ) {
        self.init(
            walking: Self.subject(subject), function, over: domain, budget: budget, allowBounded: allowBounded,
            reporting: reporting, knownIssue: knownIssue, sourceLocation: sourceLocation, inputType: Input.self,
            properties: properties)
    }

    /// The subject a walk reports: the one written, else the test's name.
    static func subject(_ written: String?) -> String {
        written ?? Test.current.map { $0.displayName ?? $0.name } ?? "function"
    }

    /// The walk every synchronous form runs: `function` over `domain`, logged for `swiftformal check`, attached, and
    /// recorded as a test issue unless proved.
    init(
        walking subject: String, _ function: @escaping (Input) throws -> Output, over domain: Domain<Input>, budget: Budget,
        allowBounded: Bool, reporting: FailureReporting, knownIssue: KnownFailure?, sourceLocation: SourceLocation,
        inputType: Any.Type, properties: () -> [Property<Input, Output>]
    ) {
        let (report, everyFailure) = reporting.walk(subject, function, over: domain, budget: budget, properties: properties)
        self.report = report
        failures = everyFailure?.failures ?? report.counterexamples
        record(
            report, allowBounded: allowBounded, inputType: inputType, knownIssue: knownIssue, everyFailure: everyFailure,
            sourceLocation: sourceLocation)
    }
}

extension Prove where Input: Finite {
    /// Like `init(_:it:over:budget:allowBounded:reporting:knownIssue:sourceLocation:properties:)`, walking every value
    /// of the `Finite` input.
    @discardableResult
    public init(
        _ subject: String? = nil,
        it function: @escaping (Input) throws -> Output,
        budget: Budget = WalkDefaults.budget,
        allowBounded: Bool = WalkDefaults.allowBounded,
        reporting: FailureReporting = .firstFailure,
        knownIssue: KnownFailure? = nil,
        sourceLocation: SourceLocation = #_sourceLocation,
        @PropertyBuilder<Input, Output> properties: () -> [Property<Input, Output>] = { [] }
    ) {
        self.init(
            subject, it: function, over: Input.domain, budget: budget, allowBounded: allowBounded, reporting: reporting,
            knownIssue: knownIssue, sourceLocation: sourceLocation, properties: properties)
    }
}

/// Writes one JSON line per walk (each `Prove`) to the file named by `SWIFTFORMAL_WALK_LOG`, so that
/// `swiftformal check` reads exact verdicts instead of parsing test output. Does nothing when the variable is unset.
enum WalkLog {
    static let variable = "SWIFTFORMAL_WALK_LOG"

    /// One property of a line: `proved`, `bounded` or `failed`, with the counterexample's input and detail.
    struct Property: Codable {
        var name: String
        var verdict: String
        var checked: Int?
        var input: String?
        var detail: String?
    }

    /// One walk's line, as `swiftformal check` reads it (`WalkRecord`).
    struct Line: Codable {
        var subject: String
        var verdict: String
        var evaluated: Int
        var domainSize: Int
        var domainComplete: Bool
        var properties: [Property]
        var file: String
        var line: Int
        var test: String?
        var inputType: String?

        /// Places the line at `location`, in the current test.
        mutating func place(at location: SourceLocation) {
            file = location.filePath
            line = location.line
            test = Test.current.map { $0.displayName ?? $0.name }
        }
    }

    static func append(_ report: Report, inputType: Any.Type?, at location: SourceLocation) {
        guard let data = line(for: report, inputType: inputType, at: location) else { return }
        append(data)
    }

    /// Appends an encoded line, and the newline.
    static func append(_ encoded: Data) {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else { return }
        var data = encoded
        data.append(0x0A)
        // One write with O_APPEND, so lines from tests running in parallel do not interleave.
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
    }

    /// The JSON line for one report, without the newline.
    static func line(for report: Report, inputType: Any.Type? = nil, at location: SourceLocation) -> Data? {
        try? JSONEncoder().encode(record(for: report, inputType: inputType.map { String(reflecting: $0) }, at: location))
    }

    /// The line for one report, before it is encoded.
    static func record(for report: Report, inputType: String?, at location: SourceLocation) -> Line {
        let properties = report.results.map { result -> Property in
            switch result.verdict {
            case let .proved(checked): Property(name: result.name, verdict: "proved", checked: checked)
            case let .bounded(checked, reason): Property(name: result.name, verdict: "bounded", checked: checked, detail: reason)
            case let .counterexample(example):
                Property(name: result.name, verdict: "failed", input: example.input, detail: example.detail)
            }
        }
        let verdict = report.isProved ? "proved" : report.hasNoCounterexample ? "bounded" : "failed"
        var line = Line(
            subject: report.subject, verdict: verdict, evaluated: report.evaluated, domainSize: report.domainSize,
            domainComplete: report.domainComplete, properties: properties, file: "", line: 0, test: nil, inputType: inputType)
        line.place(at: location)
        return line
    }
}
