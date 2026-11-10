import Foundation
package import SFVerifyKit

/// What a stored result looks like in the editor: a code lens title, a diagnostic, a hover. A result that is not
/// current (stale, or about another version of the file) shows `⚠ stale` and nothing else: no verdict, no
/// diagnostic. Only a current proof shows `✓`.
package enum Render {
    /// The lens title for `result`; `current` says whether it is about the text in the editor.
    package static func lensTitle(_ result: StoredResult, current: Bool, checkOn: ServerConfig.CheckOn = .save) -> String {
        guard current else {
            return checkOn == .save
                ? "⚠ stale: changed since the last check (save to check again)"
                : "⚠ stale: changed since the last check (run SwiftFormal: Check Now)"
        }
        let entry = result.entry
        let qualifiers = qualifiers(result.module, entry: entry)
        switch entry.checkedOutcome {
        case .provedByLogic: return "✓ proved" + qualifiers
        case .cannotTrap: return "✓ cannot crash" + qualifiers
        case .provedByLogicAndWalk: return "✓ cannot crash · " + walked(entry) + qualifiers
        case .provedByWalk: return "✓ " + walked(entry)
        default: return unprovedTitle(entry)
        }
    }

    /// The lens title of an outcome that is not a proof.
    private static func unprovedTitle(_ entry: CheckResults.Entry) -> String {
        switch entry.checkedOutcome {
        case .bounded: "~ " + walked(entry) + ", not a proof"
        case .counterexample: "✗ counterexample" + counterexampleSummary(entry)
        case .knownIssue: "! known issue: a walk fails"
        case .conflict: "! walks disagree: one proves it, one fails with a known issue"
        case .typeWalkFailed: "? unchecked: a walk over its whole type failed"
        case .walkMissing: "? unchecked: its linked walk did not report"
        case .unchecked, .provedByLogic, .cannotTrap, .provedByLogicAndWalk, .provedByWalk: "? unchecked: " + uncheckedReason(entry)
        }
    }

    /// The last part of a function's name, enough to tell apart functions declared on one line: `value.getter`,
    /// `init(value:)`.
    package static func shortName(_ function: String) -> String {
        var name = Substring(function)
        if name.hasPrefix("static ") { name = name.dropFirst("static ".count) }
        if let comma = name.range(of: ", scope ") { name = name[..<comma.lowerBound] }
        let head = name.prefix { $0 != "(" }
        let parts = head.split(separator: ".")
        let accessors: Set<Substring> = ["getter", "setter", "modify", "read", "didset", "willset"]
        let keep = parts.count >= 2 && accessors.contains(parts[parts.count - 1]) ? 2 : 1
        return parts.suffix(keep).joined(separator: ".") + name.dropFirst(head.count)
    }

    /// ` (debug, release asserts)`, `-O`, `unpinned compiler`, `for every run that ends`; empty without any.
    package static func qualifiers(_ module: CheckReport.Module?, entry: CheckResults.Entry) -> String {
        var parts: [String] = []
        if let configurations = module?.configurations, !configurations.isEmpty {
            parts.append(configurations.joined(separator: ", ") + " asserts")
        }
        if let optimization = module?.optimization, optimization != "-Onone" { parts.append(optimization) }
        if module?.pinned == false { parts.append("unpinned compiler") }
        if entry.proofScope == FunctionReport.partialCorrectness { parts.append("for every run that ends") }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }

    /// `walked 12/12 (complete domain)` or `walked 40/1000 (sample)`, over every record of the linked walks.
    package static func walked(_ entry: CheckResults.Entry) -> String {
        let records = entry.walks.flatMap(\.records)
        let evaluated = records.reduce(0) { $0 &+ $1.evaluated }
        let complete = !records.isEmpty && records.allSatisfy { $0.verdict == "proved" && $0.domainComplete }
        let size = records.contains { $0.domainSize == Int.max } ? "2^63+" : "\(records.reduce(0) { $0 &+ $1.domainSize })"
        return "walked \(evaluated)/\(size) (\(complete ? "complete domain" : "sample"))"
    }

    /// The build a logic counterexample holds in, and what fails, briefly.
    private static func counterexampleSummary(_ entry: CheckResults.Entry) -> String {
        guard let e = entry.counterexample, [.contractFails, .mayTrap].contains(entry.logic) else { return " (walk)" }
        let (build, failure) = splitBuild(e.failure)
        let text = ": \(failure) when \(e.inputs.joined(separator: ", "))"
        return (build.map { " (\($0))" } ?? "") + (text.count > 90 ? String(text.prefix(89)) + "…" : text)
    }

    /// `("release asserts", "traps: …")` for a failure that `SFVerify.worse` prefixed with the build it holds in.
    package static func splitBuild(_ failure: String) -> (build: String?, failure: String) {
        let pattern = #"^in a (\w+) build \(-assert-config \w+\): "#
        guard let range = failure.range(of: pattern, options: .regularExpression) else { return (nil, failure) }
        let words = failure[range].split(separator: " ")
        return ("\(words.count > 2 ? words[2] : "") asserts", String(failure[range.upperBound...]))
    }

    private static func uncheckedReason(_ entry: CheckResults.Entry) -> String {
        switch entry.logic {
        case .undecided: return "undecided" + (entry.category.map { " (\($0))" } ?? "")
        case .unsupported: return "outside what logic reads" + (entry.category.map { " (\($0))" } ?? "")
        case .internalError: return "internal error"
        default: return entry.logic.rawValue
        }
    }

    // MARK: diagnostics

    /// LSP severities.
    package enum Severity: Int, Sendable {
        case error = 1, warning, information, hint
    }

    /// The diagnostic for a current result, or nil when there is nothing to say (proved, unchecked, or not current).
    /// Severities follow `swiftformal check --format xcode`: a broken contract, a failing walk and a walk that did
    /// not report are errors, and so is a failed walk over the type that no test marks as known; a trap is a warning; a
    /// known issue, a disagreement or a sample is information.
    package static func diagnostic(_ result: StoredResult, current: Bool) -> Diagnostic? {
        guard current, let location = result.entry.location else { return nil }
        let entry = result.entry
        let name = entry.function
        switch entry.checkedOutcome {
        case .counterexample:
            if [.contractFails, .mayTrap].contains(entry.logic) {
                let severity: Severity = entry.logic == .contractFails ? .error : .warning
                guard let e = entry.counterexample else { return Diagnostic(location.line, severity, "\(name) may trap") }
                let line = e.at.flatMap { Paths.standard($0.file) == result.file ? $0.line : nil } ?? location.line
                let replay = e.replay.map { "; replay: \($0)" } ?? ""
                return Diagnostic(
                    line, severity,
                    "\(name) \(e.failure) when \(e.inputs.joined(separator: ", ")) — concrete counterexample (logic, every input)\(replay)"
                )
            }
            let failing = entry.walks.filter { !$0.knownIssue && $0.records.contains { $0.verdict == "failed" } }
            let detail = failing.flatMap(failedProperties).joined(separator: "; ")
            return Diagnostic(location.line, .error, "\(name) is broken: a walk found a failing input — \(detail)")
        case .walkMissing:
            return Diagnostic(
                location.line, .error,
                "\(name) is not checked: its linked walk did not report (test filtered out, or it did not reach the walk)"
            )
        case .knownIssue:
            return Diagnostic(location.line, .information, "\(name) fails a walk marked as a known issue")
        case .bounded:
            return Diagnostic(location.line, .information, "\(name) is not proved: walks sampled its inputs (\(walked(entry)))")
        case .conflict:
            return Diagnostic(
                location.line, .information, "\(name): walks disagree — one proved its promises, another fails with a known issue")
        case .typeWalkFailed:
            return Diagnostic(
                location.line, entry.typeWalkFailedUnmarked ? .error : .information,
                "\(name) is in a type whose walk found a failing input: not blamed on this member, and not proved by that walk")
        case .provedByLogic, .provedByLogicAndWalk, .provedByWalk, .cannotTrap, .unchecked:
            return ignoredContracts(entry).map { Diagnostic(location.line, .warning, "\(name): contract not read: \($0)") }
        }
    }

    /// A warning at each `// sf:verify` comment of `text`: it is no longer read (only `@Verify` asks for a proof).
    package static func markerDiagnostics(_ text: String) -> [Diagnostic] {
        guard text.contains(Gate.markerToken) else { return [] }
        return Gate.staleMarkers(in: [""]) { _ in text }.map { Diagnostic($0.line, .warning, Gate.markerMessage) }
    }

    /// Why a hand-written `f_requires` / `f_ensures` next to the function was not read; nil when there is none.
    private static func ignoredContracts(_ entry: CheckResults.Entry) -> String? {
        FunctionReport.ignoredContractMessage(entry.ignoredContracts ?? [])
    }

    /// A diagnostic's line (1-based), severity and message.
    package struct Diagnostic: Equatable {
        /// The 1-based line it is on.
        package var line: Int
        /// How bad it is.
        package var severity: Severity
        /// What it says.
        package var message: String

        init(_ line: Int, _ severity: Severity, _ message: String) {
            self.line = line
            self.severity = severity
            self.message = message
        }
    }

    private static func failedProperties(_ result: CheckEntry.WalkResult) -> [String] {
        result.records.filter { $0.verdict == "failed" }.flatMap { record in
            let failed = record.properties.filter { $0.verdict == "failed" }
            if failed.isEmpty { return ["walk \"\(record.subject)\" failed"] }
            return failed.map { "\($0.name) fails\($0.input.map { " for \($0)" } ?? "")" }
        }
    }

    // MARK: hover

    /// Markdown for a hover over the function.
    package static func hover(_ result: StoredResult, current: Bool, checkOn: ServerConfig.CheckOn = .save) -> String {
        let entry = result.entry
        var lines = ["**SwiftFormal** · `\(entry.function)` · \(lensTitle(result, current: current, checkOn: checkOn))", ""]
        guard current else {
            lines.append(
                "This function, or code it depends on, changed after its last check, so its earlier verdict is not shown. "
                    + (checkOn == .save ? "Save to check again." : "Run **SwiftFormal: Check Now** to check again."))
            return lines.joined(separator: "\n")
        }
        lines += meaning(entry)
        lines += counterexampleLines(entry)
        lines += walkLines(entry)
        if entry.checkedOutcome == .unchecked {
            if let detail = entry.detail { lines += ["", "Why: \(detail)"] }
            if let hint = entry.hint { lines.append("Fix: \(hint)") }
        }
        if let module = result.module {
            let compiler = module.compiler.map { ", \($0)" } ?? ""
            let pin = module.pinned == false ? " — **unpinned compiler**: docs/TRUST.md does not cover this verdict" : ""
            lines += ["", "_\(module.module), \(module.optimization)\(compiler)\(pin)_"]
        }
        return lines.joined(separator: "\n")
    }

    private static func counterexampleLines(_ entry: CheckResults.Entry) -> [String] {
        guard let e = entry.counterexample, [.contractFails, .mayTrap].contains(entry.logic) else { return [] }
        var lines = ["", "**Counterexample** (concrete; found by logic for every input):", ""]
        lines.append("- input: `\(e.inputs.joined(separator: ", "))`")
        if let value = e.result { lines.append("- returns: `\(value)`") }
        lines.append("- fails: \(e.failure)")
        if let at = e.at { lines.append("- at: \((at.file as NSString).lastPathComponent):\(at.line):\(at.column)") }
        if let replay = e.replay { lines.append("- replay: `\(replay)`") }
        if let ensures = e.ensuresCall { lines.append("- check: `\(ensures)` is false") }
        return lines
    }

    private static func walkLines(_ entry: CheckResults.Entry) -> [String] {
        var lines: [String] = []
        for walk in entry.walks {
            for record in walk.records {
                let domain = record.domainSize == Int.max ? "more than 2^63" : "\(record.domainSize)"
                lines.append(
                    "- walk \"\(record.subject)\" (\((walk.walk.file as NSString).lastPathComponent):\(walk.walk.line)): "
                        + "\(record.verdict), \(record.evaluated) of \(domain) inputs\(walk.knownIssue ? ", known issue" : "")")
                for property in record.properties where property.verdict != "proved" {
                    lines.append("  - \(property.name): \(property.verdict)\(property.input.map { " for `\($0)`" } ?? "")")
                }
            }
            if walk.records.isEmpty { lines.append("- walk \"\(walk.walk.subject)\": wrote no result") }
        }
        return lines
    }

    private static func meaning(_ entry: CheckResults.Entry) -> [String] {
        switch entry.checkedOutcome {
        case .provedByLogic: ["Logic proved its contract (`requires` ⇒ no trap and `ensures`) for every input, from the compiled code."]
        case .cannotTrap: ["Logic proved that no input makes it trap, from the compiled code. No contract states more."]
        case .provedByLogicAndWalk: ["Logic proved it cannot trap; its linked walks proved their promises over their whole domain."]
        case .provedByWalk: ["Its linked walks proved their promises over their whole domain (every input was run)."]
        default: [unprovedMeaning(entry.checkedOutcome)]
        }
    }

    private static func unprovedMeaning(_ outcome: CheckEntry.Outcome) -> String {
        switch outcome {
        case .bounded: "Walks found no failing input, but ran only a sample: this is not a proof."
        case .counterexample: "An input breaks a promise."
        case .knownIssue: "A walk fails, and the test marks it as a known issue."
        case .conflict: "One walk that names it proved its promises; another fails, and the test marks it as a known issue."
        case .typeWalkFailed: "A walk over its whole type found a failing input: which member is at fault is not known."
        case .walkMissing: "A walk is linked to it but wrote no result: it is not checked."
        case .unchecked, .provedByLogic, .cannotTrap, .provedByLogicAndWalk, .provedByWalk:
            "Neither logic nor a walk says anything about it: it is not checked."
        }
    }
}
