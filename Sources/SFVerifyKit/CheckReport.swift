import Foundation

public struct CheckReport: Sendable {
    private struct JSONEntry: Encodable {
        var module: String
        var package: String?
        var function: String
        var location: SourceLocation?
        var logic: ScanStatus
        var outcome: CheckEntry.Outcome
        var counterexample: ScanCounterexample?
        var walks: [CheckEntry.WalkResult]
        // What logic said beyond its status, with the keys and meaning of the scan JSON; each absent when unset.
        var category: String?
        var detail: String?
        var hint: String?
        var at: SourceLocation?
        var calledFrom: [SourceLocation]?
        var moreTraps: [ScanCounterexample]?
        var proofScope: String?
        var origin: String?
        /// With `--mutate`: the edits the proved contract does not notice.
        var weakContract: WeakContract?
        /// What the logic verdict took on trust about calls with no body, its callees' included.
        var assumptions: [String]?
        /// Hand-written `f_requires` / `f_ensures` next to the function, which logic does not read.
        var ignoredContracts: [String]?

        init(_ entry: CheckEntry) {
            let function = entry.function
            module = entry.module
            package = entry.package
            self.function = function.name
            location = function.location
            logic = function.status
            outcome = entry.outcome
            counterexample = function.counterexample
            walks = entry.walks
            category = function.category
            detail = function.detail
            hint = function.hint
            at = function.at
            calledFrom = function.calledFrom
            moreTraps = function.moreTraps
            proofScope = function.proofScope
            origin = function.origin
            weakContract = function.weakContract
            assumptions = function.assumptions
            ignoredContracts = function.ignoredContracts
        }
    }

    private struct JSONReport: Encodable {
        var schemaVersion = 1
        var entries: [JSONEntry]
        var unlinkedWalks: [WalkCheck]
        var notRunWalks: [WalkCheck]?
        var scanHints: [String]?
        var ranWalks: Int
        var totalWalks: Int
        var modules: [Module]
    }

    /// What every verdict of one scanned module holds under: how it was compiled, by which compiler, and what a
    /// selector picked (the keys of the scan JSON).
    public struct Module: Codable, Sendable {
        public var module: String
        /// The package directory as given to `--scan`; two packages may have targets of the same name.
        public var package: String?
        /// `-Onone` or `-O`.
        public var optimization: String
        /// The `assert` configurations every verdict holds in (`debug`, `release`).
        public var configurations: [String]?
        /// First line of `swiftc -version`.
        public var compiler: String?
        /// False when the compiler is not one the reader was validated against: `docs/TRUST.md` does not cover the
        /// verdicts then.
        public var pinned: Bool?  // swiftlint:disable:this discouraged_optional_boolean
        public var warnings: [String]?
        public var selection: ScanReport.Selection?
        /// What the proof cache did for this module; absent without one.
        public var proofCache: ProofCacheUse?

        init(_ scan: ScanReport, package: String? = nil) {
            module = scan.module
            self.package = package
            optimization = scan.optimization
            configurations = scan.configurations
            compiler = scan.compiler
            pinned = scan.pinned
            warnings = scan.warnings
            selection = scan.selection
            proofCache = scan.proofCache
        }
    }

    /// Every function with its logic status and final outcome; unchecked functions are included.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let report = JSONReport(
            entries: entries.map(JSONEntry.init), unlinkedWalks: unlinkedWalks,
            notRunWalks: notRunWalks.isEmpty ? nil : notRunWalks, scanHints: scanHints.isEmpty ? nil : scanHints,
            ranWalks: ranWalks, totalWalks: totalWalks, modules: modules)
        return String(bytes: try encoder.encode(report), encoding: .utf8) ?? "{}"
    }

    public var entries: [CheckEntry]
    public var unlinkedWalks: [WalkCheck]
    /// Walks covering only functions where logic found a failing input: seen in the tests, never run
    /// (`WalkCheck.kind`). `notRunWalks` in `--json`, omitted when empty.
    public var notRunWalks: [WalkCheck] = []
    /// What would link the unlinked walks (`Check.scanHints`), one line each; empty when not computed.
    public var scanHints: [String] = []
    public var ranWalks: Int
    public var totalWalks: Int
    /// One per scanned module, in scan order.
    public var modules: [Module] = []

    /// A promise is broken: a contract fails, or a walk found a failing input that is not a known issue (also a walk
    /// over a whole type, though no member is blamed for it). A function that may trap is reported but, as with
    /// `sfverify`, does not fail the run unless `strict` or a walk that names it fails too.
    public func hasFailures(strict: Bool) -> Bool {
        entries.contains {
            switch $0.outcome {
            case .counterexample: strict || $0.function.status != .mayTrap || $0.namedWalkFailedUnmarked
            case .walkMissing: true
            case .typeWalkFailed: $0.typeWalkFailedUnmarked
            default: false
            }
        }
    }

    public func count(_ outcome: CheckEntry.Outcome) -> Int { entries.count { $0.outcome == outcome } }

    /// Grouped by engine: what logic proved or broke, then one block per walk that ran (with the functions it
    /// covers), then the totals per function. `--json` has the verdict of every single function.
    public func text(showUnchecked: Bool = false, showProved: Bool = false) -> String {
        var out: [String] = []
        let modules = Array(Set(entries.map(\.module))).sorted()
        out.append("swiftformal check · \(modules.joined(separator: ", ")) · \(entries.count) functions")

        out += logicLines(showProved: showProved)
        out += walkSection()
        if !unlinkedWalks.isEmpty {
            out.append("")
            out.append("Not run — the subject names no scanned function (start it with one, e.g. \"Type.member: …\"):")
            for walk in unlinkedWalks { out.append("  · \"\(walk.subject)\" (\(walk.place))") }
            for hint in scanHints { out.append("  hint: \(hint)") }
        }
        out += notRunSection()
        if showUnchecked {
            out.append("")
            out.append("Unchecked — neither engine says anything:")
            for entry in entries where entry.outcome == .unchecked {
                let blocked = entry.function.typePath.map { ", " + Verifier.blockedBy($0) } ?? ""
                out.append("  · \(entry.function.name) — logic: \(entry.function.category ?? entry.function.status.rawValue)\(blocked)")
            }
        }

        out.append("")
        out.append("Per function:")
        // A walk proves only the inputs it lists, so it never reads as "every input" (app study round 6, L5).
        func row(_ label: String, _ value: String) { out.append("  " + label.padding(toLength: 37, withPad: " ", startingAt: 0) + value) }
        let byLogic: [CheckEntry.Outcome] = [.provedByLogic, .cannotTrap, .provedByLogicAndWalk]
        let assuming = entries.count { byLogic.contains($0.outcome) && $0.function.assumptions != nil }
        let notes =
            (count(.provedByLogic) > 0 ? ["\(count(.provedByLogic)) by contract"] : [])
            + (assuming > 0 ? ["\(assuming) assuming calls with no body"] : [])
        row(
            "proved by logic for every input",
            "\(count(.provedByLogic) + count(.cannotTrap) + count(.provedByLogicAndWalk))"
                + (notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"))
        row("proved over the walked inputs only", "\(count(.provedByWalk) + count(.provedByLogicAndWalk))")
        row("no failing input in a sample", "\(count(.bounded))")
        row(
            "broken, with the input",
            "\(count(.counterexample))" + (count(.knownIssue) > 0 ? " (+\(count(.knownIssue)) marked as a known issue)" : ""))
        if count(.conflict) > 0 { row("walks disagree (a known issue)", "\(count(.conflict))") }
        if count(.typeWalkFailed) > 0 {
            row("in a type whose walk failed", "\(count(.typeWalkFailed)) (the failure is not blamed on one member)")
        }
        if count(.walkMissing) > 0 { row("linked walk did not report", "\(count(.walkMissing))") }
        row("not checked by either", "\(count(.unchecked))" + (showUnchecked ? "" : "  (--show-unchecked lists them)"))
        return out.joined(separator: "\n")
    }

    /// Broken functions and contracts one per line; functions that only cannot trap as one count unless `showProved`.
    private func logicLines(showProved: Bool) -> [String] {
        let logic = entries.filter { [.contractHolds, .contractFails, .mayTrap, .safe].contains($0.function.status) }
        var out = ["", "Logic — every input, no code run: \(logic.count) of \(entries.count) functions are in the part of Swift it reads"]
        for entry in logic.sorted(by: { rank($0.function.status) < rank($1.function.status) }) {
            let f = entry.function
            switch f.status {
            case .contractHolds:
                out.append(
                    "  ✓ \(f.name)\(place(f)) — contract holds for every input\(Self.assuming(f))"
                        + (f.weakContract == nil ? "" : ", but is weak:"))
                for survivor in f.weakContract?.survivors ?? [] {
                    let maybe = survivor.mayBeEquivalent == true ? " (perhaps the same behaviour)" : ""
                    out.append("      still holds when \(survivor.mutation)\(survivor.at.map { " (\($0))" } ?? "")\(maybe)")
                }
            case .safe: if showProved { out.append("  ✓ \(f.name)\(place(f)) — cannot trap for any input\(Self.assuming(f))") }
            default:
                let e = f.counterexample
                let when = e.map { " when " + $0.inputs.joined(separator: ", ") } ?? ""
                out.append("  ✗ \(f.name)\(place(f)) — \(e?.failure ?? f.status.rawValue)\(when)")
            }
        }
        let cannotTrap = logic.count { $0.function.status == .safe }
        if !showProved, cannotTrap > 0 {
            let assuming = logic.count { $0.function.status == .safe && $0.function.assumptions != nil }
            out.append(
                "  ✓ \(cannotTrap) function\(cannotTrap == 1 ? "" : "s") cannot trap for any input ("
                    + (assuming > 0 ? "\(assuming) assuming calls with no body; " : "") + "--show-proved lists them)")
        }
        // Only `@Verify`: a hand-written contract is never read, and never left unsaid.
        for entry in entries {
            if let message = entry.function.ignoredContractMessage {
                out.append("  ! \(entry.function.name)\(place(entry.function)) — contract not read: \(message)")
            }
        }
        return out
    }

    /// ", assuming N calls with no body" when the proof of `f` trusts calls it cannot read (`FunctionReport.assumptions`).
    static func assuming(_ f: FunctionReport) -> String {
        guard let n = f.assumptions?.count else { return "" }
        return ", assuming \(n) call\(n == 1 ? "" : "s") with no body"
    }
}

// The walk part of `text()`.
extension CheckReport {
    /// One block per walk that ran, with every function it covers.
    private func walkSection() -> [String] {
        var byWalk: [String: (result: CheckEntry.WalkResult, functions: [String])] = [:]
        var order: [String] = []
        for entry in entries {
            for result in entry.walks {
                let key = result.walk.place
                if byWalk[key] == nil { order.append(key); byWalk[key] = (result, []) }
                byWalk[key]?.functions.append(entry.function.name)
            }
        }
        var out = [
            "",
            "Walks — the real code over every listed input, run unless logic already found a failing input: \(ranWalks) of \(totalWalks)",
        ]
        for key in order {
            guard let (result, functions) = byWalk[key] else { continue }
            out += walkLines(result, covering: functions)
        }
        return out
    }

    /// Walks skipped because logic found a failing input, each with why it did not run and the scanned function it
    /// names, if any.
    private func notRunSection() -> [String] {
        guard !notRunWalks.isEmpty else { return [] }
        let names = entries.map(\.function.name)
        var out = ["", "Seen, not run:"]
        for walk in notRunWalks {
            let key = Check.subjectKey(walk.subject)
            let named = names.filter { Check.functionKey($0) == key }
            let link = named.isEmpty ? "" : "; names \(named.joined(separator: ", "))"
            out.append("  · \"\(walk.subject)\" (\(walk.place)) — \(walk.notRunReason ?? "not run")\(link)")
        }
        return out
    }

    private func rank(_ status: ScanStatus) -> Int {
        switch status {
        case .contractFails: 0
        case .mayTrap: 1
        case .contractHolds: 2
        default: 3
        }
    }

    private func place(_ f: FunctionReport) -> String {
        f.location.map { " (\(URL(fileURLWithPath: $0.file).lastPathComponent):\($0.line))" } ?? ""
    }

    private func walkLines(_ result: CheckEntry.WalkResult, covering functions: [String]) -> [String] {
        let shown = functions.prefix(3).joined(separator: ", ") + (functions.count > 3 ? ", +\(functions.count - 3) more" : "")
        guard !result.records.isEmpty else {
            return ["  ? \"\(result.walk.subject)\" (\(result.walk.place)) — did not report; covers \(shown)"]
        }
        var out: [String] = []
        for record in result.records {
            let mark = record.verdict == "failed" ? (result.knownIssue ? "!" : "✗") : record.verdict == "proved" ? "✓" : "~"
            let domain = record.domainSize == Int.max ? "more than 2^63" : "\(record.domainSize)"
            let verdict = record.verdict == "failed" ? (result.knownIssue ? "broken (known issue)" : "BROKEN") : record.verdict
            let byLogic = record.verdict == "proved" && !record.properties.isEmpty && record.properties.allSatisfy { $0.logic == "proved" }
            let inputs =
                byLogic
                ? " for every input, by logic"
                : record.verdict == "proved" && record.evaluated == record.domainSize
                    ? " over its \(domain) inputs (not every input)" : ", \(record.evaluated) of \(domain) inputs"
            out.append("  \(mark) \"\(record.subject)\" (\(result.walk.place)) — \(verdict)\(inputs)")
            out.append("      covers \(functions.count == 1 ? "" : "\(functions.count) functions: ")\(shown)")
            if result.wholeType == true, record.verdict != "failed" {
                out.append(
                    "      a walk over its whole type proves no member: start the subject with the member it calls (\"Type.member\")")
            }
            for property in record.properties where property.verdict != "proved" || property.logic != nil {
                let input = property.input.map { " for \($0)" } ?? ""
                out.append("      \(property.verdict): \(property.name)\(input)\(property.detail.map { " — \($0)" } ?? "")")
            }
        }
        return out
    }
}
