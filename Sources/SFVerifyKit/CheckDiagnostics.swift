import Foundation

extension CheckReport {
    private typealias Severity = CompilerDiagnostic.Severity

    /// The report as compiler diagnostics (`swiftformal check --format xcode`): one `error`, `warning` or `note` per
    /// function with something to say, each followed by `note:` lines at related places (the walk, the replay, the
    /// call chain to what logic does not read). An `error` is exactly what makes `hasFailures(strict:)` true, so Xcode's
    /// red marks match the exit code. A counterexample says it is concrete (an input that fails); `undecided` says no
    /// proof and no counterexample was found. Functions that are only unchecked are listed with `showUnchecked`, proved
    /// ones with `showProved`; walks whose subject names no scanned function are warnings at the walk.
    public func diagnostics(strict: Bool = false, showUnchecked: Bool = false, showProved: Bool = false) -> String {
        var lines: [String] = []
        var shownTypeWalks: Set<String> = []
        for entry in entries {
            lines += Self.diagnostics(entry, strict: strict, showUnchecked: showUnchecked, showProved: showProved, shown: &shownTypeWalks)
        }
        for walk in notRunWalks {
            lines.append(Self.line(Self.place(walk), .note, "walk \"\(walk.subject)\" was not run: \(walk.notRunReason ?? "not run")"))
        }
        for walk in unlinkedWalks {
            lines.append(
                Self.line(
                    Self.place(walk), .warning,
                    "walk \"\(walk.subject)\" was not run: its subject names no scanned function "
                        + "(start it with one, e.g. \"Type.member: …\")"))
        }
        return lines.joined(separator: "\n")
    }

    /// The lines of one function's verdict (see `diagnostics(strict:showUnchecked:showProved:)`).
    private static func diagnostics(
        _ entry: CheckEntry, strict: Bool, showUnchecked: Bool, showProved: Bool, shown shownTypeWalks: inout Set<String>
    ) -> [String] {
        var out: [String] = []
        switch entry.outcome {
        case .counterexample: out += counterexample(entry, strict: strict)
        case .walkMissing: out += walkMissing(entry)
        case .knownIssue, .bounded: out += walkNote(entry)
        case .conflict: out += conflict(entry)
        case .typeWalkFailed: out += typeWalkFailed(entry, shown: &shownTypeWalks)
        case .unchecked where showUnchecked: out += unchecked(entry.function)
        case .provedByLogic, .provedByLogicAndWalk, .provedByWalk, .cannotTrap:
            if showProved { out += proved(entry) }
            out += weakContract(entry.function)
        case .unchecked: break
        }
        if let message = entry.function.ignoredContractMessage {
            out.append(line(entry.function.location, .warning, "\(entry.function.name): contract not read: \(message)"))
        }
        return out
    }

    /// Logic's input, a failing walk's, or both when a walk failed on a function logic also found broken.
    private static func counterexample(_ entry: CheckEntry, strict: Bool) -> [String] {
        let byLogic = [.contractFails, .mayTrap].contains(entry.function.status)
        var out = byLogic ? logicCounterexample(entry.function, strict: strict) : []
        if !byLogic || entry.namedWalkFailedUnmarked { out += walkCounterexample(entry) }
        return out
    }

    private static func line(_ location: SourceLocation?, _ severity: Severity, _ message: String) -> String {
        CompilerDiagnostic.line(location, severity, message, tag: "[swiftformal]", fallback: "swiftformal")
    }

    /// A note at a place; none without one, since a note with no place says nothing an editor can show.
    private static func note(_ location: SourceLocation?, _ message: String) -> [String] {
        location.map { [line($0, .note, message)] } ?? []
    }

    private static func place(_ walk: WalkCheck) -> SourceLocation {
        SourceLocation(file: URL(fileURLWithPath: walk.file).standardizedFileURL.path, line: walk.line, column: 1)
    }

    /// Logic found an input: a broken contract is an error, a trap a warning (an error with `strict`).
    private static func logicCounterexample(_ f: FunctionReport, strict: Bool) -> [String] {
        let severity: Severity = f.status == .contractFails || strict ? .error : .warning
        guard let e = f.counterexample else {
            return [line(f.location, severity, "\(f.name) \(f.status == .contractFails ? "breaks its contract" : "may trap")")]
        }
        let place = e.at ?? f.location
        var out = [
            line(
                place, severity,
                "\(f.name) \(e.failure) when \(e.inputs.joined(separator: ", ")) — concrete counterexample (logic, every input)")
        ]
        if let result = e.result { out += note(place, "returns \(result)") }
        if let replay = e.replay { out += note(place, "replay: \(replay)") }
        if e.at != nil, e.at != f.location { out += note(f.location, "in \(f.name)") }
        for more in f.moreTraps ?? [] {
            out += note(more.at ?? f.location, "also \(more.failure) when \(more.inputs.joined(separator: ", "))")
        }
        return out
    }

    /// A walk found a failing input that no test marks as known: an error at the function, notes at the walk.
    private static func walkCounterexample(_ entry: CheckEntry) -> [String] {
        let f = entry.function
        let failing = entry.walks.filter { !$0.knownIssue && $0.records.contains { $0.verdict == "failed" } }
        let first = failing.first.map { place($0.walk) }
        let subjects = failing.map { "\"\($0.walk.subject)\" (\($0.walk.place))" }.joined(separator: ", ")
        var out = [
            line(
                f.location ?? first, .error, "\(f.name) is broken: walk \(subjects) found a failing input — concrete counterexample (walk)")
        ]
        for result in failing { out += failedProperties(result) }
        return out
    }

    /// Each failing property of a walk with its input, then how to run that walk again.
    private static func failedProperties(_ result: CheckEntry.WalkResult) -> [String] {
        let at = place(result.walk)
        var out: [String] = []
        for record in result.records where record.verdict == "failed" {
            let properties = record.properties.filter { $0.verdict == "failed" }
            if properties.isEmpty { out += note(at, "walk \"\(record.subject)\" failed") }
            for property in properties {
                let input = property.input.map { " for \($0)" } ?? ""
                out += note(at, "\(property.name) fails\(input)\(property.detail.map { " — \($0)" } ?? "")")
            }
        }
        if let test = result.walk.test {
            out += note(at, "replay: swift test --filter '\((result.walk.suite.map { "\($0)/" } ?? "") + test)'")
        }
        return out
    }

    private static func walkMissing(_ entry: CheckEntry) -> [String] {
        let silent = entry.walks.filter(\.records.isEmpty)
        var out = [
            line(
                entry.function.location ?? silent.first.map { place($0.walk) }, .error,
                "\(entry.function.name) is not checked: its linked walk did not report (test filtered out, or it did not reach the walk)")
        ]
        for result in silent { out += note(place(result.walk), "walk \"\(result.walk.subject)\" wrote no result") }
        return out
    }

    /// A known issue, or a walk that sampled its domain: notes, since neither proves nor fails the run.
    private static func walkNote(_ entry: CheckEntry) -> [String] {
        let f = entry.function
        guard entry.outcome == .bounded else {
            let known = entry.walks.filter(\.knownIssue)
            var out = [line(f.location ?? known.first.map { place($0.walk) }, .note, "\(f.name) fails a walk marked as a known issue")]
            for result in known { out += failedProperties(result) }
            return out
        }
        var out = [line(f.location ?? entry.walks.first.map { place($0.walk) }, .note, "\(f.name) is not proved: walks sampled its inputs")]
        for result in entry.walks {
            for record in result.records where record.verdict != "proved" {
                let domain = record.domainSize == Int.max ? "more than 2^63" : "\(record.domainSize)"
                out += note(place(result.walk), "walk \"\(record.subject)\" found no failing input in \(record.evaluated) of \(domain)")
            }
        }
        return out
    }

    /// A walk naming the function proved its promises and another one failed with a known issue: a note, since
    /// neither wins and the run does not fail.
    private static func conflict(_ entry: CheckEntry) -> [String] {
        let f = entry.function
        let known = entry.walks.filter(\.knownIssue)
        var out = [
            line(
                f.location ?? known.first.map { place($0.walk) }, .note,
                "\(f.name): walks disagree — one proved its promises, another fails with a known issue")
        ]
        for result in known { out += failedProperties(result) }
        return out
    }

    /// Only a walk over the whole type failed: no member is blamed. The walk is an error once (a note if the test marks
    /// it as a known issue, as `hasFailures`), then a note at each member of the type.
    private static func typeWalkFailed(_ entry: CheckEntry, shown: inout Set<String>) -> [String] {
        let f = entry.function
        var out: [String] = []
        for result in entry.walks where result.wholeType == true && result.records.contains(where: { $0.verdict == "failed" }) {
            guard shown.insert(result.walk.place).inserted else { continue }
            let known = result.knownIssue ? " (a known issue)" : ""
            out.append(
                line(
                    place(result.walk), result.knownIssue ? .note : .error,
                    "walk \"\(result.walk.subject)\" over the whole type found a failing input\(known) — not blamed on one member"))
            out += failedProperties(result)
        }
        out += note(f.location, "\(f.name) is in a type whose walk failed: neither broken nor proved by that walk")
        return out
    }

    /// Neither engine says anything: undecided (no proof and no counterexample), or outside what logic reads.
    private static func unchecked(_ f: FunctionReport) -> [String] {
        switch f.status {
        case .undecided:
            var out = [line(f.location, .note, "\(f.name) undecided — no proof and no counterexample: \(f.detail ?? f.category ?? "")")]
            if let hint = f.hint { out += note(f.location, "fix: \(hint)") }
            return out
        case .unsupported:
            let what = (f.detail ?? f.category ?? "").replacingOccurrences(of: "UNSUPPORTED: ", with: "")
            var out = [line(f.at ?? f.location, .note, "\(f.name) is outside what logic reads: \(what)")]
            for call in f.calledFrom ?? [] { out += note(call, "called from here") }
            if let hint = f.hint { out += note(f.at ?? f.location, "fix: \(hint)") }
            return out
        default:
            return [line(f.location, .note, "\(f.name) is not checked: \(f.status.rawValue)\(f.detail.map { ": \($0)" } ?? "")")]
        }
    }

    /// With `--mutate`: a contract that holds but also holds for an edit of the function, one note per edit.
    private static func weakContract(_ f: FunctionReport) -> [String] {
        guard let weak = f.weakContract else { return [] }
        var out = [line(f.location, .note, "\(f.name): contract holds, but is weak: it still holds on an edit of the function")]
        for survivor in weak.survivors {
            let maybe = survivor.mayBeEquivalent == true ? " (perhaps the same behaviour)" : ""
            out += note(survivor.at ?? f.location, "still holds when \(survivor.mutation)\(maybe)")
        }
        return out
    }

    private static func proved(_ entry: CheckEntry) -> [String] {
        let f = entry.function
        let walked = entry.walks.map { "\"\($0.walk.subject)\"" }.joined(separator: ", ")
        let logic = "(logic\(CheckReport.assuming(f)))"
        let what =
            switch entry.outcome {
            case .provedByLogic: "contract holds for every input \(logic)"
            case .cannotTrap: "cannot trap for any input \(logic)"
            case .provedByLogicAndWalk: "cannot trap for any input \(logic); walk \(walked) proved its promises over the whole domain"
            default: "walk \(walked) proved its promises over the whole domain"
            }
        let scope = f.proofScope == FunctionReport.partialCorrectness ? ", for every run that ends" : ""
        return [line(f.location, .note, "\(f.name): \(what)\(scope)")]
    }
}
