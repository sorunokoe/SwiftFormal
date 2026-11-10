import Foundation
import SFLanguageServer
import SFVerifyKit
import Testing

/// Lens titles, diagnostics and hovers from a `check --json` report.
@Suite struct RenderTests {
    func results(configurations: [String] = ["debug", "release"], pinned: Bool = true, optimization: String = "-Onone") throws
        -> [String: StoredResult]
    {
        let package = try FixturePackage()
        defer { package.remove() }
        let store = ResultStore()
        let json = checkJSON(file: package.source, configurations: configurations, pinned: pinned, optimization: optimization)
        store.publish(try finishedRun(package, generation: 0, json: json))
        return Dictionary(uniqueKeysWithValues: store.all.map { ($0.entry.function, $0) })
    }

    @Test func lensTitlesCarryTheConfigurationsTheyHoldIn() throws {
        let both = try results()
        #expect(Render.lensTitle(try #require(both["half(_:)"]), current: true) == "✓ cannot crash (debug, release asserts)")
        let release = try results(configurations: ["release"], pinned: false, optimization: "-O")
        #expect(
            Render.lensTitle(try #require(release["half(_:)"]), current: true) == "✓ cannot crash (release asserts, -O, unpinned compiler)")
    }

    @Test func aCounterexampleSaysWhichBuildItHoldsIn() throws {
        let add = try #require(try results()["add(_:_:)"])
        #expect(
            Render.lensTitle(add, current: true)
                == "✗ counterexample (release asserts): traps: arithmetic overflow when a = 9223372036854775807, b = 1")
        let diagnostic = try #require(Render.diagnostic(add, current: true))
        #expect(diagnostic.line == 2)  // where it traps, in the same file
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.message.contains("replay: add(9223372036854775807, 1)"))
    }

    @Test func uncheckedAndStaleNeverLookProved() throws {
        let all = try results()
        let pick = try #require(all["pick(_:)"])
        #expect(Render.lensTitle(pick, current: true) == "? unchecked: undecided (budget)")
        #expect(Render.diagnostic(pick, current: true) == nil)
        #expect(Render.hover(pick, current: true).contains("Fix: raise --budget"))
        for result in all.values {
            let stale = Render.lensTitle(result, current: false)
            #expect(stale == "⚠ stale: changed since the last check (save to check again)")
            #expect(Render.lensTitle(result, current: false, checkOn: .never).hasSuffix("(run SwiftFormal: Check Now)"))
            #expect(Render.diagnostic(result, current: false) == nil)
            #expect(!Render.hover(result, current: false).contains("✓"))
            #expect(!Render.hover(result, current: false).contains("Counterexample"))
        }
    }

    @Test func hoverShowsTheCounterexampleAndTheCompiler() throws {
        let hover = Render.hover(try #require(try results(pinned: false)["add(_:_:)"]), current: true)
        #expect(hover.contains("- input: `a = 9223372036854775807, b = 1`"))
        #expect(hover.contains("- at: Lib.swift:2:7"))
        #expect(hover.contains("unpinned compiler"))
    }

    @Test func walksAreCountedAndOnlyACompleteDomainIsAProof() throws {
        func entry(_ outcome: String, logic: String, verdict: String, complete: Bool) throws -> CheckResults.Entry {
            let json = """
                {"schemaVersion": 1, "entries": [{"module": "M", "function": "f(_:)", "logic": "\(logic)", "outcome": "\(outcome)",
                 "walks": [{"knownIssue": false, "walk": {"subject": "f", "file": "/w/T.swift", "line": 3},
                   "records": [{"subject": "f", "verdict": "\(verdict)", "evaluated": 12, "domainSize": \(complete ? 12 : 1000),
                     "domainComplete": \(complete), "properties": [], "file": "/w/T.swift", "line": 3}]}]}]}
                """
            return try CheckResults.read(Data(json.utf8)).entries[0]
        }
        #expect(
            Render.walked(try entry("provedByWalk", logic: "unsupported", verdict: "proved", complete: true))
                == "walked 12/12 (complete domain)")
        #expect(Render.walked(try entry("bounded", logic: "unsupported", verdict: "bounded", complete: false)) == "walked 12/1000 (sample)")
        // A report claiming a walk proof over a sample is not shown as proved.
        #expect(try entry("provedByWalk", logic: "unsupported", verdict: "bounded", complete: false).checkedOutcome == .unchecked)
    }

    @Test func shortNamesTellFunctionsOnOneLineApart() {
        #expect(Render.shortName("Box.value.getter") == "value.getter")
        #expect(Render.shortName("Box.init(value:)") == "init(value:)")
        #expect(Render.shortName("static Box.make(_:)") == "make(_:)")
        #expect(Render.shortName("Box.value.setter, scope Box") == "value.setter")
    }
}

/// The edits offered on a checked function.
@Suite struct CodeActionsTests {
    func stored(_ function: String) throws -> (StoredResult, FixturePackage) {
        let package = try FixturePackage()
        let store = ResultStore()
        store.publish(try finishedRun(package, generation: 0))
        return (try #require(store.all.first { $0.entry.function == function }), package)
    }

    @Test func replaysACounterexampleAsATestInANewFile() throws {
        let (add, package) = try stored("add(_:_:)")
        defer { package.remove() }
        let tests = package.root + "/Tests/LibTests"
        let action = try #require(CodeActions.replayTest(add, text: FixturePackage.libText, testDirectory: tests))
        #expect(action.create == tests + "/LibReplayTests.swift")
        let text = try #require(action.insertions.first?.text)
        #expect(text.contains("#if (os(macOS) || os(Linux)) && compiler(>=6.3)\nimport Testing\n@testable import Lib"))
        #expect(text.contains("#if !DEBUG"))  // it reproduces only without asserts
        #expect(text.contains("func playback_1_add() async"))
        #expect(text.contains("await #expect(processExitsWith: .failure) { _ = add(9223372036854775807, 1) }"))
        #expect(text.hasSuffix("#endif\n"))
    }

    @Test func aSecondReplayGoesBeforeTheFilesEndif() throws {
        let (add, package) = try stored("add(_:_:)")
        defer { package.remove() }
        let tests = package.root + "/Tests/LibTests"
        try FileManager.default.createDirectory(atPath: tests, withIntermediateDirectories: true)
        try "#if os(macOS)\nimport Testing\n@Test func playback_1_add() {}\n#endif\n".write(
            toFile: tests + "/LibReplayTests.swift", atomically: true, encoding: .utf8)
        let action = try #require(CodeActions.replayTest(add, text: FixturePackage.libText, testDirectory: tests))
        #expect(action.create == nil)
        #expect(action.insertions.first?.position == Position(line: 3, character: 0))
        #expect(action.insertions.first?.text.contains("func playback_2_add()") == true)
    }

    @Test func addsAContractAndTheImport() throws {
        let (half, package) = try stored("half(_:)")
        defer { package.remove() }
        let action = try #require(CodeActions.addContract(half, lines: FixturePackage.libText.components(separatedBy: "\n")))
        #expect(action.insertions.map(\.position.line) == [0, 4, 5])
        #expect(
            action.insertions.map(\.text) == [
                "import SwiftFormal\n", "@Verify\n",
                "    #requires(true)  // the inputs callers may pass\n    #ensures { _ in true }  // what it returns\n",
            ])
    }

    @Test func putsTheContractInsideAOneLineBody() throws {
        let text = "public func half(_ n: Int) -> Int { n / 2 }\n"
        let edited = try withContract(text, line: 1)
        #expect(
            edited == """
                import SwiftFormal
                @Verify
                public func half(_ n: Int) -> Int {
                    #requires(true)  // the inputs callers may pass
                    #ensures { _ in true }  // what it returns
                    n / 2 }

                """)
    }

    @Test func aClosureInTheSignatureIsNotTheBody() throws {
        let text = """
            import Foundation

            public func run(
                _ n: Int,
                make: () -> Int = { 0 }
            ) -> Int {
                n + make()
            }

            """
        let edited = try withContract(text, line: 3)
        #expect(
            edited == """
                import Foundation
                import SwiftFormal

                @Verify
                public func run(
                    _ n: Int,
                    make: () -> Int = { 0 }
                ) -> Int {
                    #requires(true)  // the inputs callers may pass
                    #ensures { _ in true }  // what it returns
                    n + make()
                }

                """)
    }

    /// A file that already imports the macros (`SwiftFormal`) gets no second import; `SwiftFormalTesting` does not re-export them, so it still does.
    @Test func theImportIsAddedOnlyWhenTheMacrosAreNotImported() throws {
        let body = "public func half(_ n: Int) -> Int { n / 2 }\n"
        for imported in ["import SwiftFormal", "@testable import SwiftFormal", "public import SwiftFormal"] {
            let edited = try withContract(imported + "\n" + body, line: 2)
            #expect(edited.components(separatedBy: "import SwiftFormal").count == 2, "\(imported): \(edited)")
        }
        let edited = try withContract("import SwiftFormalTesting\n" + body, line: 2)
        #expect(edited.hasPrefix("import SwiftFormalTesting\nimport SwiftFormal\n@Verify\n"), "\(edited)")
    }

    @Test func noContractWithoutABody() throws {
        let (half, package) = try stored("half(_:)")
        defer { package.remove() }
        var declared = half
        declared.entry.location = SourceLocation(file: package.source, line: 1, column: 13)
        #expect(CodeActions.addContract(declared, lines: ["public func half(_ n: Int) -> Int", ""]) == nil)
        #expect(CodeActions.addContract(declared, lines: ["public func half(_ n: Int) -> Int {", "    n / 2", ""]) == nil)
    }

    /// `text` with the contract action of the function declared (name at column 13) on `line` applied.
    private func withContract(_ text: String, line: Int) throws -> String {
        let (half, package) = try stored("half(_:)")
        defer { package.remove() }
        var result = half
        result.entry.location = SourceLocation(file: package.source, line: line, column: 13)
        let action = try #require(CodeActions.addContract(result, lines: text.components(separatedBy: "\n")))
        return apply(action.insertions, to: text)
    }

    /// The edits applied as an editor does: each range is in the original text; at one place, in the given order.
    private func apply(_ insertions: [Insertion], to text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { Array($0.utf16) }
        let ordered = insertions.enumerated().sorted { a, b in
            let (x, y) = (a.element.position, b.element.position)
            return (x.line, x.character, a.offset) > (y.line, y.character, b.offset)
        }
        for (_, insertion) in ordered {
            let start = insertion.position
            let end = insertion.end ?? start
            let line = lines[start.line]
            let replaced = Array(line[..<start.character]) + Array(insertion.text.utf16) + Array(line[end.character...])
            lines[start.line] = replaced
        }
        return lines.map { String(decoding: $0, as: UTF16.self) }.joined(separator: "\n")
    }

    /// Only `@Verify`: the editor no longer offers `// sf:verify`; the contract action writes `@Verify` with
    /// `#requires` / `#ensures` instead.
    @Test func offersAContractInPlaceAndNoSfVerifyMarker() throws {
        let (half, package) = try stored("half(_:)")
        defer { package.remove() }
        let actions = CodeActions.actions(for: half, text: FixturePackage.libText, testDirectory: nil)
        #expect(!actions.contains { $0.insertions.contains { $0.text.contains("sf:verify") } }, "\(actions.map(\.title))")
        let contract = try #require(actions.first { $0.title.contains("@Verify") })
        #expect(contract.insertions.contains { $0.text.contains("@Verify") })
        #expect(contract.insertions.contains { $0.text.contains("#requires") && $0.text.contains("#ensures") })
    }

    /// A `// sf:verify` comment is shown as a warning on its line: it is no longer read.
    @Test func warnsAtEachSfVerifyComment() {
        let text = "import Foundation\n// sf:verify\nfunc half(_ x: Int8) -> Int8 { x / 2 }\nlet note = \"sf:verify\"\n"
        let diagnostics = Render.markerDiagnostics(text)
        #expect(diagnostics.map(\.line) == [2])
        #expect(diagnostics.first?.severity == .warning)
        #expect(diagnostics.first?.message.contains("mark the function @Verify instead") == true)
    }

    /// A hand-written `half_ensures` next to a function that cannot trap: still `✓ cannot crash`, with a warning that
    /// the contract was not read.
    @Test func warnsAboutAHandWrittenContract() throws {
        let (half, package) = try stored("half(_:)")
        defer { package.remove() }
        #expect(Render.diagnostic(half, current: true) == nil)
        var result = half
        result.entry.ignoredContracts = ["half_ensures(_:_:)"]
        let diagnostic = try #require(Render.diagnostic(result, current: true))
        #expect(diagnostic.severity == .warning && diagnostic.line == half.entry.location?.line)
        #expect(diagnostic.message.contains("half(_:): contract not read: half_ensures(_:_:) is written by hand"))
        #expect(diagnostic.message.contains("write the contract in place with @Verify, #requires and #ensures"))
    }

    @Test func offersAProveSkeletonForAFunctionWithoutWalks() throws {
        let (pick, package) = try stored("pick(_:)")
        defer { package.remove() }
        let action = try #require(CodeActions.proveSkeleton(pick, testDirectory: package.root + "/Tests/LibTests"))
        #expect(action.create == package.root + "/Tests/LibTests/PickProveTests.swift")
        let text = try #require(action.insertions.first?.text)
        #expect(text.contains(#"Prove("pick", it: { (input: <#Input#>) in <#call pick with input#> }, over: <#.allCases#>) {"#))
        #expect(text.contains("Deterministic()"))
    }
}

extension RenderTests {
    /// Main's walk attribution (round 6, L18): a failing walk over the whole type does not undo a walk that names the
    /// function, but cannot prove it alone; that failure is an error only when no test marks it as a known issue.
    @Test func aFailedWalkOverTheTypeIsWeighedAsTheCLIWeighsIt() throws {
        func entry(_ outcome: String, named: String?, known: Bool = false) throws -> CheckResults.Entry {
            func walk(_ verdict: String, line: Int, wholeType: Bool) -> String {
                """
                {"knownIssue": \(wholeType && known), "wholeType": \(wholeType), "walk": {"subject": "S", "file": "/w/T.swift", "line": \(line)},
                 "records": [{"subject": "S", "verdict": "\(verdict)", "evaluated": 2, "domainSize": 2, "domainComplete": true,
                   "properties": [], "file": "/w/T.swift", "line": \(line)}]}
                """
            }
            let walks = [walk("failed", line: 3, wholeType: true)] + (named.map { [walk($0, line: 4, wholeType: false)] } ?? [])
            let json = """
                {"schemaVersion": 1, "entries": [{"module": "M", "function": "S.f(_:)", "logic": "unsupported", "outcome": "\(outcome)",
                 "walks": [\(walks.joined(separator: ","))]}]}
                """
            return try CheckResults.read(Data(json.utf8)).entries[0]
        }
        #expect(try entry("provedByWalk", named: "proved").checkedOutcome == .provedByWalk)
        #expect(try entry("provedByWalk", named: nil).checkedOutcome == .unchecked)
        #expect(try entry("provedByWalk", named: "bounded").checkedOutcome == .unchecked)
        #expect(try entry("typeWalkFailed", named: nil).typeWalkFailedUnmarked)
        #expect(try !entry("typeWalkFailed", named: nil, known: true).typeWalkFailedUnmarked)
    }

    /// App study round 7: a walk over the whole type proves no member, so a `provedByWalk` backed only by one is not shown as
    /// a proof, however the report was written.
    @Test func aPassingWalkOverTheTypeAloneIsNoProof() throws {
        let json = """
            {"schemaVersion": 1, "entries": [{"module": "M", "function": "S.f(_:)", "logic": "unsupported", "outcome": "provedByWalk",
             "walks": [{"knownIssue": false, "wholeType": true, "walk": {"subject": "S", "file": "/w/T.swift", "line": 3},
              "records": [{"subject": "S", "verdict": "proved", "evaluated": 2, "domainSize": 2, "domainComplete": true,
                "properties": [], "file": "/w/T.swift", "line": 3}]}]}]}
            """
        #expect(try CheckResults.read(Data(json.utf8)).entries[0].checkedOutcome == .unchecked)
    }
}
