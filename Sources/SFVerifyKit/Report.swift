import Foundation

public struct ScanReport: Codable, Sendable {
    public struct Summary: Codable, Sendable {
        public var total = 0
        public var safe = 0
        public var mayTrap = 0
        public var contractHolds = 0
        public var contractFails = 0
        public var undecided = 0
        public var unsupported = 0
        public var internalErrors = 0
        /// Functions the compiler synthesized (not counted in `total`).
        public var compilerGenerated = 0
        /// Functions from macro expansions and build-generated files (`FunctionReport.origin`): listed in `functions`,
        /// not counted in `total` or the verdict counts. Absent when there are none.
        public var generatedCode: Int?
        public var unsupportedByCategory: [String: Int] = [:]
        /// Of `unsupported`: functions that are plumbing, not logic (property wrappers, dependency injection, view
        /// bodies; `Plumbing`). Absent when there are none.
        public var plumbing: Int?
        /// With `--mutate`: the functions whose proved contract some edit of the code also satisfies
        /// (`FunctionReport.weakContract`). Absent without `--mutate`.
        public var weakContracts: Int?
        /// Of `safe` and `contractHolds`: proofs that rest on assumptions about calls with no body
        /// (`FunctionReport.assumptions`). Absent when there are none.
        public var withAssumptions: Int?
        /// Of `undecided`: functions proved only for arrays of at most 8 elements (`FunctionReport.bounded`), never
        /// counted as proved. Absent when there are none.
        public var bounded: Int?
        /// Share of functions the engine could decide or refute (everything except unsupported).
        public var coverage: Double {
            total == 0 ? 0 : Double(total - unsupported) / Double(total)
        }
    }

    public struct Timing: Codable, Sendable {
        public var compileSeconds: Double
        public var parseSeconds: Double
        public var verifySeconds: Double
        public var silBytes: Int
    }

    /// Version of the JSON layout (`docs/schemas/scan-report.schema.json`). Changes only when a key is removed or changes meaning.
    public var schemaVersion = 1
    public var module: String
    public var optimization: String
    public var functions: [FunctionReport]
    public var summary: Summary
    public var timing: Timing
    /// The `assert` configurations every verdict holds in (`debug`, `release`); `-O` builds only `release`.
    public var configurations: [String]?
    /// First line of `swiftc -version` of the compiler that produced the SIL.
    public var compiler: String?
    /// False when that compiler is not one the reader was validated against (`docs/TRUST.md` does not cover the
    /// verdicts then); the build gate fails instead of reporting. Optional: reports written before it still decode.
    public var pinned: Bool?  // swiftlint:disable:this discouraged_optional_boolean
    /// Things the user should know that are not about one function (for example functions that may be missing).
    /// Omitted from the JSON when there are none.
    public var warnings: [String]?
    /// The selector (`--at`, `--symbol`) the scan verified one function for; absent from the JSON without one.
    public var selection: Selection?
    /// The functions a selector left out: not verified, not in `functions`, not in the JSON; walks still link to them.
    public var unselected: [UnselectedFunction] = []
    /// What the proof cache did (`VerifyOptions.proofCache`); absent when the run had none.
    public var proofCache: ProofCacheUse?
    /// The walks' relational claims `VerifyOptions.relational` asked for, decided for every input (`RelationalProofs.swift`).
    public var relational: [RelationalResult]?
    /// Imported modules that should have been linked but could not be, in either configuration (not in the JSON: the
    /// warnings say it). `swiftformal check --gate` stamps no target that has one.
    package var unlinkedModules: [String] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, module, optimization, functions, summary, timing, configurations, compiler, pinned, warnings, selection
        case proofCache, relational
    }

    public init(module: String, optimization: String, functions: [FunctionReport], compilerGenerated: Int = 0, timing: Timing) {
        self.module = module
        self.optimization = optimization
        self.functions = functions
        self.timing = timing
        var s = Summary()
        let written = functions.filter { $0.origin == nil }
        s.total = written.count
        s.compilerGenerated = compilerGenerated
        if written.count < functions.count { s.generatedCode = functions.count - written.count }
        for f in written {
            switch f.status {
            case .safe: s.safe += 1
            case .mayTrap: s.mayTrap += 1
            case .contractHolds: s.contractHolds += 1
            case .contractFails: s.contractFails += 1
            case .undecided: s.undecided += 1
            case .unsupported:
                s.unsupported += 1
                s.unsupportedByCategory[f.category ?? "other", default: 0] += 1
                if Plumbing.isPlumbing(f) { s.plumbing = (s.plumbing ?? 0) + 1 }
            case .internalError: s.internalErrors += 1
            }
        }
        s.withAssumptions = Self.assuming(written)
        let bounded = written.count { $0.status == .undecided && $0.bounded != nil }
        s.bounded = bounded > 0 ? bounded : nil
        summary = s
    }

    /// The line of a `--modular` proof: `used the contract of g(_:)`, `used the contracts of g(_:), h()`.
    static func usedContracts(_ used: [String]) -> String {
        "used the contract\(used.count == 1 ? "" : "s") of \(used.joined(separator: ", "))"
    }

    /// How many of `functions` are proofs that rest on assumptions (`Summary.withAssumptions`); nil for none.
    private static func assuming(_ functions: [FunctionReport]) -> Int? {
        let k = functions.count { [.safe, .contractHolds].contains($0.status) && $0.assumptions != nil }
        return k > 0 ? k : nil
    }

    /// True when a contract is violated or the prover failed. A function that merely *may trap* is a finding, not a failure.
    public var hasFailures: Bool { summary.contractFails > 0 || summary.internalErrors > 0 }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    // MARK: text

    /// The first line, and a warning line for an unpinned compiler.
    private func header() -> [String] {
        let builds = configurations.map { "; " + $0.joined(separator: " and ") + " asserts" } ?? ""
        var lines = [
            "sfverify · module \(module) (\(optimization)\(builds)) · \(summary.total) functions written by hand"
                + (summary.compilerGenerated > 0 ? " (+\(summary.compilerGenerated) compiler-generated, skipped)" : "")
                + (summary.generatedCode.map { " (+\($0) from macros or generated files, not counted)" } ?? "")
        ]
        if pinned == false, let compiler {
            lines.append("warning: unpinned compiler '\(compiler)': these verdicts are not covered by docs/TRUST.md")
        }
        if let selection {
            lines.append(
                "\(selection.selector): \(selection.function ?? "no function") selected; the other \(unselected.count) not verified")
        }
        return lines
    }

    /// " (k with assumptions)" when k of the hand-written functions proved `status` by trusting calls with no body.
    private func assuming(_ status: ScanStatus) -> String {
        let k = functions.count { $0.origin == nil && $0.status == status && $0.assumptions != nil }
        return k > 0 ? " (\(k) with assumptions)" : ""
    }

    /// The counterexample of `f` and its other trap sites, indented under its line.
    private func counterexampleLines(_ f: FunctionReport) -> [String] {
        var out: [String] = []
        if let e = f.counterexample {
            out.append("      inputs:  \(e.inputs.joined(separator: ", "))")
            out.append("      problem: \(e.failure)\(e.at.map { " at \($0)" } ?? "")")
            if let r = e.result { out.append("      returns: \(r)") }
            if let r = e.replay { out.append("      replay:  \(r)") }
            if e.foreignResults != nil {
                out.append("      note:    the values Objective-C calls returned come from code Scan does not read")
            }
        }
        for other in f.moreTraps ?? [] {
            out.append(
                "      also:    \(other.failure)\(other.at.map { " at \($0)" } ?? "") (\(other.inputs.joined(separator: ", ")))")
        }
        return out
    }

    public func text(showUnsupported: Bool = false) -> String {
        var out = header()
        out.append("")
        let order: [ScanStatus] = [.contractFails, .mayTrap, .internalError, .undecided, .contractHolds, .safe]
        for status in order {
            for f in functions where f.status == status {
                out.append("\(mark(status)) \(label(status)) \(f.name)\(position(f.location))\(f.origin.map { " [\($0)]" } ?? "")")
                out += counterexampleLines(f)
                if let d = f.detail, f.status != .unsupported { out.append("      \(d)") }
                if let used = f.usesContracts { out.append("      \(Self.usedContracts(used))") }
                out += f.assumptions.map { ["      assumes: \($0.joined(separator: "; "))"] } ?? []
                out += f.bounded.map { ["      bounded: \($0.joined(separator: "; "))"] } ?? []
                out += ignoredContractLines(f)
                out += weakContractLines(f)
                out += undecidedFix(f)
            }
        }
        if showUnsupported {
            for f in functions where f.status == .unsupported {
                let contract = f.hasContract ? "; its contract is not checked" : ""
                out.append(
                    "\(mark(.unsupported)) \(label(.unsupported)) \(f.name)\(position(f.location)) — \(f.category ?? "other")\(contract)")
                out += explanation(f)
                out += ignoredContractLines(f)
            }
        }
        out.append("")
        out.append("Proved safe (cannot trap for any input): \(summary.safe)\(assuming(.safe))")
        // A contract on a function logic cannot read or decide is not checked; say so, the function may be listed only
        // with --show-unsupported (app study round 6, L9).
        let unchecked = functions.count { $0.hasContract && $0.origin == nil && [.unsupported, .undecided].contains($0.status) }
        let ignored = functions.count { $0.ignoredContracts != nil && $0.origin == nil }
        if summary.contractHolds + summary.contractFails + unchecked + ignored > 0 {
            let weak = summary.weakContracts.map { $0 == 0 ? " (none weak)" : " (\($0) weak: an edit of the code still satisfies it)" }
            out.append(
                "Contracts: \(summary.contractHolds) hold\(assuming(.contractHolds))\(weak ?? ""), \(summary.contractFails) fail"
                    + (unchecked > 0 ? ", \(unchecked) not checked (logic cannot read or decide the function or its contract)" : "")
                    + (ignored > 0 ? ", \(ignored) written by hand and not read (write them in place with @Verify)" : ""))
        }
        out.append("Can trap (with a concrete input): \(summary.mayTrap)")
        out += undecidedSummary()
        if summary.internalErrors > 0 { out.append("Prover errors: \(summary.internalErrors)") }
        out.append(
            "Outside the supported subset: \(summary.unsupported) of \(summary.total) (coverage \(Int((summary.coverage * 100).rounded()))%)"
        )
        if let plumbing = summary.plumbing {
            out.append("    \(plumbing) of them plumbing (property wrappers, dependency injection, view bodies)")
        }
        for (category, count) in summary.unsupportedByCategory.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }) {
            out.append("    \(count) × \(category)")
        }
        out += timingLines()
        return out.joined(separator: "\n")
    }

    /// The time each phase took, then what the proof cache did (when the run had one).
    private func timingLines() -> [String] {
        [
            "",
            "Time: compile \(Self.seconds(timing.compileSeconds))s · parse \(Self.seconds(timing.parseSeconds))s "
                + "(\(timing.silBytes / 1024) KB SIL) · verify \(Self.seconds(timing.verifySeconds))s",
        ] + (proofCache.map { [$0.summary] } ?? [])
    }

    /// `1.50` for 1.5: two decimals and a point whatever the user's locale, as `String(format: "%.2f")` printed them
    /// (that C variadic call is what `-strict-memory-safety` reports; plan item H7).
    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    private func mark(_ s: ScanStatus) -> String {
        switch s {
        case .safe, .contractHolds: "✓"
        case .mayTrap, .contractFails, .internalError: "✗"
        case .undecided: "?"
        case .unsupported: "·"
        }
    }

    private func label(_ s: ScanStatus) -> String {
        switch s {
        case .safe: "safe          "
        case .contractHolds: "contract holds"
        case .mayTrap: "may trap      "
        case .contractFails: "contract FAILS"
        case .undecided: "undecided     "
        case .unsupported: "unsupported   "
        case .internalError: "prover error  "
        }
    }

    private func position(_ l: SourceLocation?) -> String { l.map { "  (\($0.file):\($0.line))" } ?? "" }

    /// `Undecided: N`, then the count of each reason (`budget`, `unmodelled results`); nothing when none is.
    private func undecidedSummary() -> [String] {
        guard summary.undecided > 0 else { return [] }
        let reasons = Dictionary(grouping: functions.filter { $0.status == .undecided && $0.origin == nil }) { $0.category ?? "other" }
        return ["Undecided: \(summary.undecided)"]
            + reasons.sorted { ($1.value.count, $0.key) < ($0.value.count, $1.key) }.map { "    \($1.count) × \($0)" }
    }

    /// One line per edit of `f` that its contract does not notice (`--mutate`), and an input that tells them apart.
    private func weakContractLines(_ f: FunctionReport) -> [String] {
        guard let weak = f.weakContract else { return [] }
        let shown = 3
        let more = weak.survivors.count - shown
        return weak.survivors.prefix(shown).flatMap { survivor -> [String] in
            let place = survivor.at.map { " (\($0))" } ?? ""
            var lines = ["      weak: the contract still holds when \(survivor.mutation)\(place)"]
            let verb = survivor.mayBeEquivalent == true ? "may differ" : "differ"
            if let inputs = survivor.differsOn {
                lines.append("            the function and the edited one \(verb) on \(inputs.joined(separator: ", "))")
            }
            if let reason = survivor.reason { lines.append("            (\(reason))") }
            return lines
        } + (more > 0 ? ["      weak: and \(more) more edit\(more == 1 ? "" : "s") (--json lists them)"] : [])
    }

    /// What Scan did not read: the hand-written `f_requires` / `f_ensures` next to `f`.
    private func ignoredContractLines(_ f: FunctionReport) -> [String] {
        f.ignoredContractMessage.map { ["      contract not read: \($0)"] } ?? []
    }

    /// The fix line of an undecided function.
    private func undecidedFix(_ f: FunctionReport) -> [String] {
        guard f.status == .undecided, let hint = f.hint else { return [] }
        return ["      fix: \(hint)"]
    }

    /// Where an unsupported construct is, the calls that lead there, and what to change (U7).
    private func explanation(_ f: FunctionReport) -> [String] {
        var lines: [String] = []
        let what = (f.detail ?? "").replacingOccurrences(of: "UNSUPPORTED: ", with: "")
        if let at = f.at {
            lines.append("      at \(at): \(what)")
        } else if !what.isEmpty {
            lines.append("      \(what)")
        }
        if let path = f.typePath { lines.append("      where: \(path)") }
        for call in f.calledFrom ?? [] { lines.append("      called from \(call)") }
        if let hint = f.hint { lines.append("      fix: \(hint)") }
        return lines
    }
}
