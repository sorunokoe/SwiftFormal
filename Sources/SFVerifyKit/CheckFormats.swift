import Foundation

/// `swiftformal check --format sarif|github`: the same findings as `--format xcode`, in the formats code scanning and
/// GitHub Actions read. All three come from `diagnostics(strict:showUnchecked:showProved:)`, so they cannot disagree,
/// and the exit code is `hasFailures(strict:)` whatever the format.
extension CheckReport {
    /// One diagnostic line read back: where, how serious, what, and the notes that follow it.
    struct Finding {
        var file: String?
        var line: Int
        var column: Int
        var severity: CompilerDiagnostic.Severity
        var message: String
        var notes: [Finding] = []
    }

    /// The diagnostics as findings: each `note:` line belongs to the error or warning before it.
    func findings(strict: Bool, showUnchecked: Bool, showProved: Bool) -> [Finding] {
        var found: [Finding] = []
        let text = diagnostics(strict: strict, showUnchecked: showUnchecked, showProved: showProved)
        for line in text.split(separator: "\n") {
            guard let finding = Self.finding(String(line)) else { continue }
            if finding.severity == .note, !found.isEmpty {
                found[found.count - 1].notes.append(finding)
            } else {
                found.append(finding)
            }
        }
        return found
    }

    /// `file:line:col: severity: message`, or `place: severity: message` without a source place.
    static func finding(_ line: String) -> Finding? {
        for severity in [CompilerDiagnostic.Severity.error, .warning, .note] {
            guard let range = line.range(of: ": \(severity.rawValue): ") else { continue }
            let place = line[..<range.lowerBound].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let message = String(line[range.upperBound...])
            if place.count >= 3, let number = Int(place[place.count - 2]), let column = Int(place[place.count - 1]) {
                let file = place.dropLast(2).joined(separator: ":")
                return Finding(file: file, line: number, column: column, severity: severity, message: message)
            }
            return Finding(file: nil, line: 0, column: 0, severity: severity, message: "\(place.joined(separator: ":")): \(message)")
        }
        return nil
    }

    /// A SARIF 2.1.0 log of the findings, for GitHub code scanning and SARIF viewers: one rule per severity, the notes
    /// as related locations. Files under `baseDirectory` get a relative URI with the base id `SRCROOT`.
    public func sarif(baseDirectory: String, strict: Bool = false, showUnchecked: Bool = false, showProved: Bool = false) throws
        -> String
    {
        let base = Self.prefix(baseDirectory)
        let found = findings(strict: strict, showUnchecked: showUnchecked, showProved: showProved)
        let levels = ["error", "warning", "note"].filter { level in found.contains { $0.severity.rawValue == level } }
        let rules: [[String: Any]] = levels.map { level in
            [
                "id": "swiftformal.\(level)", "name": "swiftformal.\(level)",
                "shortDescription": ["text": Self.ruleText(level)], "defaultConfiguration": ["level": level],
            ]
        }
        let results: [[String: Any]] = found.map { finding in
            var result: [String: Any] = [
                "ruleId": "swiftformal.\(finding.severity.rawValue)",
                "ruleIndex": levels.firstIndex(of: finding.severity.rawValue) ?? 0,
                "level": finding.severity.rawValue, "message": ["text": finding.message],
            ]
            if let location = Self.physical(finding, base: base) { result["locations"] = [["physicalLocation": location]] }
            let related = finding.notes.enumerated().compactMap { index, note -> [String: Any]? in
                var entry: [String: Any] = ["id": index + 1, "message": ["text": note.message]]
                if let location = Self.physical(note, base: base) { entry["physicalLocation"] = location }
                return entry
            }
            if !related.isEmpty { result["relatedLocations"] = related }
            return result
        }
        let run: [String: Any] = [
            "tool": ["driver": ["name": "swiftformal", "rules": rules]],
            "originalUriBaseIds": ["SRCROOT": ["uri": URL(fileURLWithPath: base, isDirectory: true).absoluteString]],
            "results": results,
        ]
        let log: [String: Any] = ["$schema": ScanReport.sarifSchema, "version": "2.1.0", "runs": [run]]
        let data = try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// GitHub Actions workflow commands, one per finding (`::error file=…,line=…,col=…,title=…::message`), with the
    /// notes in the message. Paths under `baseDirectory` are made relative to it.
    public func githubAnnotations(baseDirectory: String, strict: Bool = false, showUnchecked: Bool = false, showProved: Bool = false)
        -> String
    {
        let base = Self.prefix(baseDirectory)
        return findings(strict: strict, showUnchecked: showUnchecked, showProved: showProved).map { finding in
            let command = finding.severity == .note ? "notice" : finding.severity.rawValue
            var properties: [String] = []
            if let file = finding.file {
                properties.append("file=\(ScanReport.escapeProperty(Self.relative(file, base: base)))")
                properties.append("line=\(finding.line)")
                properties.append("col=\(finding.column)")
            }
            properties.append("title=\(ScanReport.escapeProperty("swiftformal"))")
            var message = finding.message
            for note in finding.notes {
                let place = note.file.map { " (\(Self.relative($0, base: base)):\(note.line))" } ?? ""
                message += "\n\(note.message)\(place)"
            }
            return "::\(command) \(properties.joined(separator: ","))::\(ScanReport.escapeData(message))"
        }.joined(separator: "\n")
    }

    private static func ruleText(_ level: String) -> String {
        switch level {
        case "error": "What fails the run: a broken promise, a walk that did not report (a trap only with --strict)."
        case "warning": "What logic and the walks could not settle, or a contract that is not read."
        default: "Where, the input, the replay and the call chain of a finding."
        }
    }

    private static func prefix(_ base: String) -> String {
        let path = URL(fileURLWithPath: base).standardizedFileURL.path
        return path.hasSuffix("/") ? path : path + "/"
    }

    private static func relative(_ file: String, base: String) -> String {
        let path = URL(fileURLWithPath: file).standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    private static func physical(_ finding: Finding, base: String) -> [String: Any]? {
        guard let file = finding.file else { return nil }
        let path = URL(fileURLWithPath: file).standardizedFileURL.path
        let artifact: [String: Any] =
            path.hasPrefix(base)
            ? ["uri": String(path.dropFirst(base.count)), "uriBaseId": "SRCROOT"] : ["uri": URL(fileURLWithPath: path).absoluteString]
        return ["artifactLocation": artifact, "region": ["startLine": max(finding.line, 1), "startColumn": max(finding.column, 1)]]
    }
}

extension Check {
    /// `swiftformal check --emit-tests <dir>`: one `<Module>ScanPlaybackTests.swift` per scanned module, with a Swift
    /// Testing test per counterexample that replays the input on the real function. Returns each file and its number
    /// of tests.
    package static func emitPlaybackTests(_ reports: [ScanReport], to directory: String) throws -> [(path: String, tests: Int)] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return try reports.map { report in
            let path = (directory as NSString).appendingPathComponent(Playback.fileName(module: report.module))
            try Playback.file(for: report).write(toFile: path, atomically: true, encoding: .utf8)
            return (path, Playback.tests(for: report).tests.count)
        }
    }
}
