import Foundation
import SFVerifyKit
import Testing

/// Plan item U8: SARIF 2.1.0 and GitHub Actions annotations, from the same findings as `--xcode`.
@Suite struct ReportFormatsTests {
    static let root = "/work/repo"

    static func report() throws -> ScanReport {
        let json = """
            {"schemaVersion": 1, "module": "Kernels", "optimization": "-Onone",
             "timing": {"compileSeconds": 0, "parseSeconds": 0, "verifySeconds": 0, "silBytes": 0},
             "summary": {"total": 0, "safe": 0, "mayTrap": 0, "contractHolds": 0, "contractFails": 0, "undecided": 0,
                         "unsupported": 0, "internalErrors": 0, "compilerGenerated": 0, "unsupportedByCategory": {}},
             "functions": [
              {"name": "percent(_:_:)", "symbol": "$s1", "status": "mayTrap", "hasContract": false, "seconds": 0,
               "location": {"file": "/work/repo/Sources/Kernels/K.swift", "line": 18, "column": 13},
               "counterexample": {"inputs": ["part = 0", "whole = 0"], "failure": "traps: Division by zero",
                                  "at": {"file": "/work/repo/Sources/Kernels/K.swift", "line": 19, "column": 36},
                                  "replay": "percent(0, 0)"}},
              {"name": "clamp(_:)", "symbol": "$s2", "status": "contractFails", "hasContract": true, "seconds": 0,
               "location": {"file": "/elsewhere/C.swift", "line": 3, "column": 1},
               "counterexample": {"inputs": ["x = 1"], "failure": "ensures is false, 100%: a,b", "result": "0"}},
              {"name": "viaCallee(_:)", "symbol": "$s3", "status": "unsupported", "hasContract": false, "seconds": 0,
               "category": "generics", "detail": "UNSUPPORTED: generic call to abs<A>(_:) with <Int16>",
               "location": {"file": "/work/repo/Sources/Kernels/K.swift", "line": 4, "column": 13},
               "at": {"file": "/work/repo/Sources/Kernels/K.swift", "line": 2, "column": 5},
               "calledFrom": [{"file": "/work/repo/Sources/Kernels/K.swift", "line": 5, "column": 5}],
               "hint": "write it without abs"},
              {"name": "noWhere(_:)", "symbol": "$s4", "status": "mayTrap", "hasContract": false, "seconds": 0,
               "counterexample": {"inputs": ["x = 0"], "failure": "the function traps"}},
              {"name": "fine(_:)", "symbol": "$s5", "status": "safe", "hasContract": false, "seconds": 0}
             ]}
            """
        return try JSONDecoder().decode(ScanReport.self, from: Data(json.utf8))
    }

    @Test func sarifHasTheRequiredShapeOf210() throws {
        let text = try Self.report().sarif(baseDirectory: Self.root, showUnsupported: true)
        let log = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(log["version"] as? String == "2.1.0")
        #expect((log["$schema"] as? String)?.contains("sarif") == true)
        let runs = try #require(log["runs"] as? [[String: Any]])
        #expect(runs.count == 1)
        let run = runs[0]
        let driver = try #require((run["tool"] as? [String: Any])?["driver"] as? [String: Any])
        #expect(driver["name"] as? String == "sfverify")
        let rules = try #require(driver["rules"] as? [[String: Any]])
        let ruleIDs = rules.compactMap { $0["id"] as? String }
        #expect(Set(ruleIDs).count == ruleIDs.count)
        let results = try #require(run["results"] as? [[String: Any]])
        #expect(results.count == 4)  // `safe` is not a result
        for result in results {
            let message = try #require(result["message"] as? [String: Any])
            #expect(message["text"] is String)
            let ruleID = try #require(result["ruleId"] as? String)
            let index = try #require(result["ruleIndex"] as? Int)
            #expect(ruleIDs[index] == ruleID)
            #expect(["none", "note", "warning", "error"].contains(result["level"] as? String ?? ""))
            for location in result["locations"] as? [[String: Any]] ?? [] {
                // A location has a physical place, a logical one (the function), or both.
                #expect(location["physicalLocation"] != nil || location["logicalLocations"] != nil)
                guard let physical = location["physicalLocation"] as? [String: Any] else { continue }
                let artifact = try #require(physical["artifactLocation"] as? [String: Any])
                #expect(artifact["uri"] is String)
                if let region = physical["region"] as? [String: Any] {
                    #expect((region["startLine"] as? Int ?? 0) >= 1)
                    #expect((region["startColumn"] as? Int ?? 1) >= 1)
                }
            }
        }
        let trap = try #require(results.first { $0["ruleId"] as? String == "mayTrap" })
        let location = try #require((trap["locations"] as? [[String: Any]])?.first?["physicalLocation"] as? [String: Any])
        let artifact = try #require(location["artifactLocation"] as? [String: Any])
        #expect(artifact["uri"] as? String == "Sources/Kernels/K.swift")
        #expect(artifact["uriBaseId"] as? String == "SRCROOT")
        #expect((location["region"] as? [String: Any])?["startLine"] as? Int == 19)
        let properties = try #require(trap["properties"] as? [String: Any])
        #expect(properties["replay"] as? String == "percent(0, 0)")
        let roots = try #require(run["originalUriBaseIds"] as? [String: Any])
        #expect((roots["SRCROOT"] as? [String: Any])?["uri"] as? String == "file:///work/repo/")
        let outside = try #require(results.first { $0["ruleId"] as? String == "contractFails" })
        let outsideURI =
            ((outside["locations"] as? [[String: Any]])?.first?["physicalLocation"] as? [String: Any])
            .flatMap { $0["artifactLocation"] as? [String: Any] }?["uri"] as? String
        #expect(outsideURI == "file:///elsewhere/C.swift")
        let unsupported = try #require(results.first { $0["ruleId"] as? String == "unsupported" })
        #expect((unsupported["relatedLocations"] as? [[String: Any]])?.count == 1)
    }

    @Test func githubAnnotationsAreWorkflowCommands() throws {
        let lines = try Self.report().githubAnnotations(baseDirectory: Self.root, showUnsupported: false)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(
            lines[0]
                == "::warning file=Sources/Kernels/K.swift,line=19,col=36,title=sfverify%3A may trap::percent(_:_:) traps: Division by zero when part = 0, whole = 0"
        )
        // `%`, `:` and `,` in a property and `%` in the message are escaped.
        #expect(lines[1].hasPrefix("::error file=/elsewhere/C.swift,line=3,col=1,title=sfverify%3A contract fails::"))
        #expect(lines[1].contains("ensures is false, 100%25: a,b"))
        #expect(lines[2].hasPrefix("::warning title=sfverify%3A may trap::noWhere(_:)"))
    }

    @Test func theXcodeLinesAreUnchangedByTheSharedFindings() throws {
        let lines = try Self.report().diagnostics().split(separator: "\n").map(String.init)
        #expect(
            lines == [
                "/work/repo/Sources/Kernels/K.swift:19:36: warning: percent(_:_:) traps: Division by zero when part = 0, whole = 0",
                "/elsewhere/C.swift:3:1: error: clamp(_:) ensures is false, 100%: a,b when x = 1",
                "Kernels: warning: noWhere(_:) the function traps when x = 0",
            ])
    }
}

extension ReportFormatsTests {
    /// Only `@Verify`: a hand-written contract Scan did not read is a warning in every editor and CI format, never
    /// silent, while the function itself is `safe` (a false postcondition was `contractFails` before).
    @Test func aContractThatIsNotReadIsAWarningInEveryFormat() throws {
        let json = """
            {"schemaVersion": 1, "module": "Kernels", "optimization": "-Onone",
             "timing": {"compileSeconds": 0, "parseSeconds": 0, "verifySeconds": 0, "silBytes": 0},
             "summary": {"total": 0, "safe": 0, "mayTrap": 0, "contractHolds": 0, "contractFails": 0, "undecided": 0,
                         "unsupported": 0, "internalErrors": 0, "compilerGenerated": 0, "unsupportedByCategory": {}},
             "functions": [
              {"name": "wrong(_:)", "symbol": "$s1", "status": "safe", "hasContract": false, "seconds": 0,
               "location": {"file": "/work/repo/Sources/Kernels/W.swift", "line": 3, "column": 6},
               "ignoredContracts": ["wrong_ensures(_:_:)"]}
             ]}
            """
        let report = try JSONDecoder().decode(ScanReport.self, from: Data(json.utf8))
        let xcode = report.diagnostics()
        #expect(xcode.contains("/work/repo/Sources/Kernels/W.swift:3:6: warning:"), "\(xcode)")
        #expect(xcode.contains("wrong(_:): contract not read: wrong_ensures(_:_:) is written by hand"), "\(xcode)")

        let github = report.githubAnnotations(baseDirectory: Self.root)
        #expect(github.hasPrefix("::warning file=Sources/Kernels/W.swift,line=3,col=6,title=sfverify%3A contract not read::"), "\(github)")

        let sarif = try report.sarif(baseDirectory: Self.root)
        let log = try #require(try JSONSerialization.jsonObject(with: Data(sarif.utf8)) as? [String: Any])
        let run = try #require((log["runs"] as? [[String: Any]])?.first)
        let rules = try #require(((run["tool"] as? [String: Any])?["driver"] as? [String: Any])?["rules"] as? [[String: Any]])
        let results = try #require(run["results"] as? [[String: Any]])
        #expect(rules.compactMap { $0["id"] as? String } == ["contractNotRead"])
        #expect(results.count == 1 && results[0]["ruleId"] as? String == "contractNotRead" && results[0]["level"] as? String == "warning")
    }
}
