import Foundation
import SFVerifyKit
import Testing

/// `swiftformal check --format xcode`: one compiler-format line per function with something to say, notes at the
/// walk, the replay and the call chain; an `error` exactly where the run fails.
@Suite struct CheckDiagnosticsTests {
    private func function(_ name: String, _ status: ScanStatus, line: Int, extra: String = "") throws -> FunctionReport {
        let json =
            #"{"name":"\#(name)","symbol":"s","status":"\#(status.rawValue)","hasContract":false,"seconds":0,"location":{"file":"/s/A.swift","line":\#(line),"column":6}\#(extra)}"#
        return try JSONDecoder().decode(FunctionReport.self, from: Data(json.utf8))
    }

    private func record(_ line: Int, _ verdict: String, evaluated: Int = 4, properties: String = "[]") throws -> WalkRecord {
        let json =
            #"{"subject":"s","verdict":"\#(verdict)","evaluated":\#(evaluated),"domainSize":1000,"domainComplete":false,"properties":\#(properties),"file":"/x/AppTests.swift","line":\#(line)}"#
        return try JSONDecoder().decode(WalkRecord.self, from: Data(json.utf8))
    }

    /// One function per outcome kind, the walks that cover them, and a walk that names nothing scanned.
    private func report() throws -> CheckReport {
        let functions = [
            try function(
                "clamp(_:_:_:)", .contractFails, line: 3,
                extra:
                    #","counterexample":{"inputs":["x = 1","lo = 2","hi = 0"],"result":"2","failure":"ensures is false","replay":"clamp(1, 2, 0)","at":{"file":"/s/A.swift","line":5,"column":9}}"#
            ),
            try function(
                "div(_:_:)", .mayTrap, line: 8,
                extra: #","counterexample":{"inputs":["a = 1","b = 0"],"failure":"traps: Division by zero"}"#),
            try function("Surface.label", .safe, line: 12),
            try function("Surface.code", .safe, line: 13),
            try function("Surface.id", .safe, line: 14),
            try function("Surface.rank", .unsupported, line: 15),
            try function(
                "parse(_:)", .undecided, line: 16,
                extra: #","category":"budget","detail":"no answer within 9 solver conflicts","hint":"raise --budget""#),
            try function(
                "fmt(_:)", .unsupported, line: 17,
                extra:
                    #","detail":"UNSUPPORTED: generic call","hint":"call a concrete version","at":{"file":"/s/B.swift","line":2,"column":5},"calledFrom":[{"file":"/s/A.swift","line":18,"column":5}]"#
            ),
            try function("ok(_:)", .safe, line: 19),
        ]
        let scan = ScanReport(module: "App", optimization: "-Onone", functions: functions, timing: try timing())
        let walks =
            [2, 3, 4, 5].map {
                WalkCheck(
                    subject: ["Surface.label", "Surface.code", "Surface.id", "Surface.rank"][$0 - 2], file: "/t/AppTests.swift", line: $0,
                    suite: "AppTests", test: "t\($0)")
            }
            + [WalkCheck(subject: "nothing here", file: "/t/AppTests.swift", line: 6, suite: "AppTests", test: "t6")]
        let failing = #"[{"name":"has text","verdict":"failed","input":".water","detail":"empty"}]"#
        let records = [try record(2, "failed", properties: failing), try record(4, "failed"), try record(5, "bounded", evaluated: 100)]
        return Check.merge(
            scans: [scan], plan: Check.plan(scans: [scan], walks: walks), records: records,
            knownIssues: Check.knownIssues(inTestOutput: "Test \"t\" recorded a known issue at AppTests.swift:4:9: Issue recorded"))
    }

    private func timing() throws -> ScanReport.Timing {
        try JSONDecoder().decode(
            ScanReport.Timing.self, from: Data(#"{"compileSeconds":0,"parseSeconds":0,"verifySeconds":0,"silBytes":0}"#.utf8))
    }

    @Test func everyOutcomeKindHasItsSeverityAndNotes() throws {
        let report = try report()
        #expect(
            report.entries.map(\.outcome) == [
                .counterexample, .counterexample, .counterexample, .walkMissing, .knownIssue, .bounded, .unchecked, .unchecked, .cannotTrap,
            ])
        let lines = report.diagnostics().components(separatedBy: "\n")
        #expect(
            lines == [
                "/s/A.swift:5:9: error: [swiftformal] clamp(_:_:_:) ensures is false when x = 1, lo = 2, hi = 0 — concrete counterexample (logic, every input)",
                "/s/A.swift:5:9: note: [swiftformal] returns 2",
                "/s/A.swift:5:9: note: [swiftformal] replay: clamp(1, 2, 0)",
                "/s/A.swift:3:6: note: [swiftformal] in clamp(_:_:_:)",
                "/s/A.swift:8:6: warning: [swiftformal] div(_:_:) traps: Division by zero when a = 1, b = 0 — concrete counterexample (logic, every input)",
                "/s/A.swift:12:6: error: [swiftformal] Surface.label is broken: walk \"Surface.label\" (AppTests.swift:2) found a failing input — concrete counterexample (walk)",
                "/t/AppTests.swift:2:1: note: [swiftformal] has text fails for .water — empty",
                "/t/AppTests.swift:2:1: note: [swiftformal] replay: swift test --filter 'AppTests/t2'",
                "/s/A.swift:13:6: error: [swiftformal] Surface.code is not checked: its linked walk did not report (test filtered out, or it did not reach the walk)",
                "/t/AppTests.swift:3:1: note: [swiftformal] walk \"Surface.code\" wrote no result",
                "/s/A.swift:14:6: note: [swiftformal] Surface.id fails a walk marked as a known issue",
                "/t/AppTests.swift:4:1: note: [swiftformal] walk \"s\" failed",
                "/t/AppTests.swift:4:1: note: [swiftformal] replay: swift test --filter 'AppTests/t4'",
                "/s/A.swift:15:6: note: [swiftformal] Surface.rank is not proved: walks sampled its inputs",
                "/t/AppTests.swift:5:1: note: [swiftformal] walk \"s\" found no failing input in 100 of 1000",
                "/t/AppTests.swift:6:1: warning: [swiftformal] walk \"nothing here\" was not run: its subject names no scanned function (start it with one, e.g. \"Type.member: …\")",
            ])
        // Errors are exactly what fails the run: with --strict a trap is one too.
        #expect(report.hasFailures(strict: false))
        #expect(report.diagnostics(strict: true).contains("/s/A.swift:8:6: error: [swiftformal] div(_:_:) traps"))
    }

    @Test func undecidedAndUnsupportedAreNotesThatSayWhyOnlyWhenAsked() throws {
        let report = try report()
        let lines = report.diagnostics(showUnchecked: true).components(separatedBy: "\n")
        let undecided = try #require(lines.firstIndex { $0.contains("parse(_:)") })
        #expect(
            Array(lines[undecided...].prefix(5)) == [
                "/s/A.swift:16:6: note: [swiftformal] parse(_:) undecided — no proof and no counterexample: no answer within 9 solver conflicts",
                "/s/A.swift:16:6: note: [swiftformal] fix: raise --budget",
                "/s/B.swift:2:5: note: [swiftformal] fmt(_:) is outside what logic reads: generic call",
                "/s/A.swift:18:5: note: [swiftformal] called from here",
                "/s/B.swift:2:5: note: [swiftformal] fix: call a concrete version",
            ])
        #expect(!report.diagnostics().contains("parse(_:)"))
        #expect(!report.diagnostics().contains("ok(_:)"))
        #expect(
            report.diagnostics(showProved: true).contains("/s/A.swift:19:6: note: [swiftformal] ok(_:): cannot trap for any input (logic)"))
    }

    @Test func aLoopProofSaysItHoldsOnlyForRunsThatEnd() throws {
        let loop = try function("sum(_:)", .safe, line: 2, extra: #","proofScope":"partialCorrectness""#)
        let scan = ScanReport(module: "App", optimization: "-Onone", functions: [loop], timing: try timing())
        let report = Check.merge(scans: [scan], plan: Check.plan(scans: [scan], walks: []), records: [], knownIssues: [])
        #expect(
            report.diagnostics(showProved: true)
                == "/s/A.swift:2:6: note: [swiftformal] sum(_:): cannot trap for any input (logic), for every run that ends")
    }

    /// What an editor needs to qualify a verdict: the build it holds for, the compiler and its pin, a loop proof's
    /// scope, why logic did not decide, and whether a walk covered its whole domain.
    @Test func theJSONKeepsWhatEachVerdictHoldsUnder() throws {
        let loop = try function("sum(_:)", .safe, line: 2, extra: #","proofScope":"partialCorrectness""#)
        var scan = ScanReport(module: "App", optimization: "-Onone", functions: [loop], timing: try timing())
        scan.configurations = ["debug", "release"]
        scan.compiler = "swift-driver version: 1.0 Apple Swift version 6.2"
        scan.pinned = false
        let merged = Check.merge(scans: [scan], plan: Check.plan(scans: [scan], walks: []), records: [], knownIssues: [])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(merged.json().utf8)) as? [String: Any])
        let module = try #require((json["modules"] as? [[String: Any]])?.first)
        #expect(module["configurations"] as? [String] == ["debug", "release"])
        #expect(module["pinned"] as? Bool == false)
        #expect((module["compiler"] as? String)?.contains("6.2") == true)
        #expect(module["selection"] == nil)
        let entry = try #require((json["entries"] as? [[String: Any]])?.first)
        #expect(entry["proofScope"] as? String == "partialCorrectness")

        let entries =
            try #require(
                try JSONSerialization.jsonObject(with: Data(report().json().utf8)) as? [String: Any])["entries"] as? [[String: Any]]
        let parse = try #require(entries?.first { $0["function"] as? String == "parse(_:)" })
        #expect(parse["category"] as? String == "budget")
        #expect(parse["hint"] as? String == "raise --budget")
        let fmt = try #require(entries?.first { $0["function"] as? String == "fmt(_:)" })
        #expect((fmt["calledFrom"] as? [Any])?.count == 1)
        let rank = try #require(entries?.first { $0["function"] as? String == "Surface.rank" })
        let walk = try #require((rank["walks"] as? [[String: Any]])?.first)
        #expect((walk["records"] as? [[String: Any]])?.first?["domainComplete"] as? Bool == false)
    }
}

extension CheckDiagnosticsTests {
    /// Only `@Verify`: `swiftformal check` says a hand-written contract was not read, in its text and as a warning in
    /// its diagnostics, next to the function's own verdict (here `cannot trap`).
    @Test func aContractThatIsNotReadIsSaidInTextAndDiagnostics() throws {
        let wrong = try function("wrong(_:)", .safe, line: 3, extra: #","ignoredContracts":["wrong_ensures(_:_:)"]"#)
        let scan = ScanReport(module: "App", optimization: "-Onone", functions: [wrong], timing: try timing())
        let report = Check.merge(scans: [scan], plan: Check.plan(scans: [scan], walks: []), records: [], knownIssues: [])
        #expect(report.entries.map(\.outcome) == [.cannotTrap])
        #expect(report.text().contains("! wrong(_:)"), "\(report.text())")
        #expect(report.text().contains("contract not read: wrong_ensures(_:_:) is written by hand"), "\(report.text())")
        #expect(
            report.diagnostics() == "/s/A.swift:3:6: warning: [swiftformal] wrong(_:): contract not read: wrong_ensures(_:_:) is written "
                + "by hand, and Scan reads only the contract @Verify writes: write the contract in place with @Verify, #requires and #ensures"
        )
    }
}

extension CheckDiagnosticsTests {
    /// `--format sarif` and `--format github` list the same findings as `--format xcode`, at the same places with the
    /// same severities: all three come from the diagnostics.
    @Test func sarifAndGitHubListWhatXcodeLists() throws {
        let report = try report()
        let xcode = report.diagnostics().split(separator: "\n").filter { !$0.contains(": note: ") }
        let github = report.githubAnnotations(baseDirectory: "/s").split(separator: "\n").filter { !$0.hasPrefix("::notice") }
        let sarifData = try #require(try report.sarif(baseDirectory: "/s").data(using: .utf8))
        let sarif = try #require(try JSONSerialization.jsonObject(with: sarifData) as? [String: Any])
        let runs = try #require(sarif["runs"] as? [[String: Any]])
        let results = try #require(runs.first?["results"] as? [[String: Any]]).filter { $0["level"] as? String != "note" }
        #expect(xcode.count == github.count && xcode.count == results.count, "\(xcode)\n\(github)\n\(results)")
        let xcodeErrors = xcode.filter { $0.contains(": error: ") }.count
        #expect(xcodeErrors > 0)
        #expect(github.filter { $0.hasPrefix("::error ") }.count == xcodeErrors)
        #expect(results.filter { $0["level"] as? String == "error" }.count == xcodeErrors)
        // A file under the base directory is relative, in both.
        #expect(github.contains { $0.contains("file=A.swift,line=") })
        let locations = results.compactMap { ($0["locations"] as? [[String: Any]])?.first?["physicalLocation"] as? [String: Any] }
        #expect(locations.contains { ($0["artifactLocation"] as? [String: Any])?["uri"] as? String == "A.swift" })
    }
}
