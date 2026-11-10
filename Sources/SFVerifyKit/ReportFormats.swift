import Foundation

/// One thing a report says about a function, in the shape every editor and CI format needs: a level, a place, a
/// message, notes at other places, and a fix. `--xcode`, SARIF and GitHub annotations are all printed from these.
package struct ScanFinding: Sendable {
    /// `error`, `warning` or `note`.
    package var level: CompilerDiagnostic.Severity
    package var status: ScanStatus
    package var function: String
    package var location: SourceLocation?
    package var message: String
    /// Notes at other places, for example `called from here` at each call that leads to the construct.
    package var related: [(location: SourceLocation, message: String)] = []
    /// What to change, when the report says.
    package var fix: String?
    package var counterexample: ScanCounterexample?
    /// The SARIF rule and the title, when it is not the verdict's: `contractNotRead` for a hand-written contract.
    package var rule: String?
}

extension ScanReport {
    /// The findings of this report, in function order: traps and broken contracts, undecided functions, and with
    /// `showUnsupported` unsupported ones. `safe`, `contractHolds` and `internalError` give none. A function with a
    /// hand-written contract Scan did not read (`ignoredContracts`) also gets a warning, whatever its verdict.
    package func findings(showUnsupported: Bool = false) -> [ScanFinding] {
        functions.flatMap { f in
            [verdictFinding(f, showUnsupported: showUnsupported), Self.ignoredContractFinding(f)].compactMap { $0 }
        }
    }

    /// The warning for a hand-written contract next to `f`, which is not read; nil without one.
    private static func ignoredContractFinding(_ f: FunctionReport) -> ScanFinding? {
        f.ignoredContractMessage.map { message in
            ScanFinding(
                level: .warning, status: f.status, function: f.name, location: f.location,
                message: "\(f.name): contract not read: \(message)", rule: "contractNotRead")
        }
    }

    /// The finding of `f`'s verdict; nil for one that needs none.
    private func verdictFinding(_ f: FunctionReport, showUnsupported: Bool) -> ScanFinding? {
        switch f.status {
        case .contractFails, .mayTrap:
            guard let e = f.counterexample else { return nil }
            return ScanFinding(
                level: f.status == .contractFails ? .error : .warning, status: f.status, function: f.name,
                location: e.at ?? f.location, message: "\(f.name) \(e.failure) when \(e.inputs.joined(separator: ", "))",
                counterexample: e)
        case .undecided:
            return ScanFinding(
                level: .note, status: .undecided, function: f.name, location: f.location,
                message: "\(f.name) undecided: \(f.detail ?? "")", fix: f.hint)
        case .unsupported where showUnsupported:
            let what = (f.detail ?? f.category ?? "").replacingOccurrences(of: "UNSUPPORTED: ", with: "")
            return ScanFinding(
                level: .note, status: .unsupported, function: f.name, location: f.at ?? f.location,
                message: "\(f.name) is outside what Scan reads: \(what)",
                related: (f.calledFrom ?? []).map { ($0, "called from here") }, fix: f.hint)
        default:
            return nil
        }
    }

    // MARK: Xcode / editor diagnostics

    /// `file:line:col: error: message` lines that Xcode and most editors turn into annotations. With
    /// `showUnsupported`, each unsupported function also gets a `note:` at the construct, `called from here` notes up
    /// the call chain, and its fix. A note without a source location is left out; an error or warning without one
    /// starts with the module name.
    public func diagnostics(showUnsupported: Bool = false) -> String {
        var lines: [String] = []
        for finding in findings(showUnsupported: showUnsupported) {
            guard let l = finding.location else {
                if finding.level != .note { lines.append(CompilerDiagnostic.line(nil, finding.level, finding.message, fallback: module)) }
                continue
            }
            lines.append(CompilerDiagnostic.line(l, finding.level, finding.message, fallback: module))
            for (call, message) in finding.related { lines.append(CompilerDiagnostic.line(call, .note, message, fallback: module)) }
            if let fix = finding.fix, finding.status == .unsupported {
                lines.append(CompilerDiagnostic.line(l, .note, "fix: \(fix)", fallback: module))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: SARIF 2.1.0

    /// A SARIF 2.1.0 log (`--format sarif`) for GitHub code scanning and SARIF viewers: one rule per verdict, one
    /// result per finding. Files under `baseDirectory` get a relative URI with the base id `SRCROOT`; others an
    /// absolute `file://` URI. The inputs, result and replay of a counterexample and the fix are in `properties`.
    public func sarif(baseDirectory: String, showUnsupported: Bool = false) throws -> String {
        let found = findings(showUnsupported: showUnsupported)
        let ruleIDs = Self.sarifRules.map(\.id).filter { id in found.contains { ($0.rule ?? $0.status.rawValue) == id } }
        let rules: [[String: Any]] = Self.sarifRules.filter { ruleIDs.contains($0.id) }.map { rule in
            [
                "id": rule.id, "name": rule.id, "shortDescription": ["text": rule.text],
                "defaultConfiguration": ["level": rule.level],
            ]
        }
        let base = Self.directoryPrefix(baseDirectory)
        let results: [[String: Any]] = found.map { finding in
            var result: [String: Any] = [
                "ruleId": finding.rule ?? finding.status.rawValue,
                "ruleIndex": ruleIDs.firstIndex(of: finding.rule ?? finding.status.rawValue) ?? 0,
                "level": finding.level.rawValue, "message": ["text": finding.message],
            ]
            var logical: [String: Any] = ["logicalLocations": [["fullyQualifiedName": finding.function, "kind": "function"]]]
            if let location = finding.location { logical["physicalLocation"] = Self.sarifPhysical(location, base: base) }
            result["locations"] = [logical]
            if !finding.related.isEmpty {
                result["relatedLocations"] = finding.related.enumerated().map { index, note in
                    ["id": index + 1, "physicalLocation": Self.sarifPhysical(note.location, base: base), "message": ["text": note.message]]
                }
            }
            var properties: [String: Any] = [:]
            if let e = finding.counterexample {
                properties["inputs"] = e.inputs
                if let r = e.result { properties["result"] = r }
                if let r = e.replay { properties["replay"] = r }
            }
            if let fix = finding.fix { properties["fix"] = fix }
            if !properties.isEmpty { result["properties"] = properties }
            return result
        }
        let run: [String: Any] = [
            "tool": ["driver": ["name": "sfverify", "rules": rules]],
            "originalUriBaseIds": ["SRCROOT": ["uri": URL(fileURLWithPath: base, isDirectory: true).absoluteString]],
            "results": results,
        ]
        let log: [String: Any] = ["$schema": Self.sarifSchema, "version": "2.1.0", "runs": [run]]
        let data = try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    static let sarifSchema = "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json"

    /// One SARIF rule: a verdict that gives findings, its default level, and what it means.
    struct SARIFRule {
        let id: String
        let level: String
        let text: String
    }

    static let sarifRules: [SARIFRule] = [
        SARIFRule(
            id: "contractFails", level: "error", text: "The contract (f_requires ⇒ f_ensures, no trap) is false for a concrete input."),
        SARIFRule(id: "mayTrap", level: "warning", text: "The function traps for a concrete input."),
        SARIFRule(id: "undecided", level: "note", text: "Scan could not decide the function."),
        SARIFRule(id: "unsupported", level: "note", text: "The function uses a construct Scan does not read."),
        SARIFRule(
            id: "contractNotRead", level: "warning",
            text: "A contract written by hand (f_requires / f_ensures) is not read: only the contract @Verify writes counts."),
    ]

    /// `base` with a trailing slash, in the spelling `canonical` gives.
    private static func directoryPrefix(_ base: String) -> String {
        let standard = canonical(base)
        return standard.hasSuffix("/") ? standard : standard + "/"
    }

    /// One spelling per folder: standardized, and `/private/tmp` (`/private/var`) as `/tmp` (`/var`), as macOS links them.
    private static func canonical(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        for linked in ["/private/tmp/", "/private/var/", "/private/etc/"] where standard.hasPrefix(linked) {
            return String(standard.dropFirst("/private".count))
        }
        return standard
    }

    /// The path of `file` relative to `base`, or nil when it is outside it. A relative `file` (the compiler was given
    /// a relative path) is relative to the working directory already, and is kept.
    private static func relative(_ file: String, base: String) -> String? {
        guard file.hasPrefix("/") else { return file }
        let path = canonical(file)
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    private static func sarifPhysical(_ location: SourceLocation, base: String) -> [String: Any] {
        var artifact: [String: Any]
        if let path = relative(location.file, base: base) {
            artifact = ["uri": path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path, "uriBaseId": "SRCROOT"]
        } else {
            artifact = ["uri": URL(fileURLWithPath: location.file).absoluteString]
        }
        var physical: [String: Any] = ["artifactLocation": artifact]
        if location.line >= 1 {
            physical["region"] =
                location.column >= 1 ? ["startLine": location.line, "startColumn": location.column] : ["startLine": location.line]
        }
        return physical
    }

    // MARK: GitHub Actions

    /// GitHub Actions workflow commands (`--format github`): `::warning file=…,line=…,col=…,title=…::message`, one
    /// per finding, which the runner shows as annotations on the pull request. Paths under `baseDirectory` (the
    /// repository root, normally the working directory) are made relative to it.
    public func githubAnnotations(baseDirectory: String, showUnsupported: Bool = false) -> String {
        let base = Self.directoryPrefix(baseDirectory)
        return findings(showUnsupported: showUnsupported).map { finding in
            let command = finding.level == .note ? "notice" : finding.level.rawValue
            var properties: [String] = []
            if let l = finding.location {
                properties.append("file=\(Self.escapeProperty(Self.relative(l.file, base: base) ?? l.file))")
                if l.line >= 1 { properties.append("line=\(l.line)") }
                if l.column >= 1 { properties.append("col=\(l.column)") }
            }
            properties.append(
                "title=\(Self.escapeProperty("sfverify: " + (finding.rule == nil ? Self.title(finding.status) : "contract not read")))")
            var message = finding.message
            for (call, note) in finding.related {
                message += "\n\(note): \(Self.relative(call.file, base: base) ?? call.file):\(call.line)"
            }
            if let fix = finding.fix { message += "\nfix: \(fix)" }
            return "::\(command) \(properties.joined(separator: ","))::\(Self.escapeData(message))"
        }.joined(separator: "\n")
    }

    private static func title(_ status: ScanStatus) -> String {
        switch status {
        case .mayTrap: "may trap"
        case .contractFails: "contract fails"
        case .undecided: "undecided"
        case .unsupported: "unsupported"
        default: status.rawValue
        }
    }

    /// The message of a workflow command: `%`, CR and LF are escaped.
    static func escapeData(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    /// A property of a workflow command: as a message, and `:` and `,` too.
    static func escapeProperty(_ text: String) -> String {
        escapeData(text).replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: ",", with: "%2C")
    }
}
