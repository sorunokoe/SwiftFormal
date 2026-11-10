import Foundation
import SFVerifyKit
import Testing

/// `swiftformal check`: which walks run, and how logic and walks merge into one verdict per function.
@Suite struct CheckTests {
    private func function(_ name: String, _ status: ScanStatus) throws -> FunctionReport {
        let json = #"{"name":"\#(name)","symbol":"s","status":"\#(status.rawValue)","hasContract":false,"seconds":0}"#
        return try JSONDecoder().decode(FunctionReport.self, from: Data(json.utf8))
    }

    private func scan(_ functions: [FunctionReport]) throws -> ScanReport {
        let timing = try JSONDecoder().decode(
            ScanReport.Timing.self, from: Data(#"{"compileSeconds":0,"parseSeconds":0,"verifySeconds":0,"silBytes":0}"#.utf8))
        return ScanReport(module: "App", optimization: "-Onone", functions: functions, timing: timing)
    }

    private func walk(_ subject: String, line: Int = 1) -> WalkCheck {
        WalkCheck(subject: subject, file: "/t/AppTests.swift", line: line, suite: "AppTests", test: "t\(line)")
    }

    @Test func subjectsLinkToTheFunctionsTheyName() {
        #expect(Check.functionKey("static UnitSystemType.id.getter") == "UnitSystemType.id")
        #expect(Check.functionKey("SupportedLocale.matching(identifier:)") == "SupportedLocale.matching")
        #expect(Check.functionKey("Box.map<A>(_:), scope 12") == "Box.map")
        #expect(Check.subjectKey("SupportedLocale.matching(identifier:)") == "SupportedLocale.matching")
        #expect(Check.subjectKey("CustomStore without overlay") == "CustomStore")
        #expect(Check.subjectKey("rating trend text") == "rating")

        #expect(Check.covers(subjectKey: "UnitSystemType.id", functionKey: "UnitSystemType.id"))
        #expect(Check.covers(subjectKey: "CustomStore", functionKey: "CustomStore.reduce"))
        #expect(!Check.covers(subjectKey: "UnitSystemType.id", functionKey: "UnitSystemType.idText"))
        #expect(!Check.covers(subjectKey: "rating", functionKey: "rating.trend"))
        #expect(!Check.covers(subjectKey: "Custom", functionKey: "CustomStore.reduce"))
    }

    /// App study round 7: `LoadingState.==` was read as the whole type `LoadingState`, and a scanned `static Rank.< infix(_:_:)`
    /// lost its operator at the `<` (taken for generic parameters), so it was keyed as `Rank`.
    @Test func operatorSubjectsLinkToTheOperator() {
        #expect(Check.functionKey("static LoadingState.== infix(_:_:)") == "LoadingState.==")
        #expect(Check.functionKey("static Rank.< infix(_:_:)") == "Rank.<")
        #expect(Check.functionKey("static Box.== infix<A>(_:_:)") == "Box.==")
        #expect(Check.functionKey("static Money.+= infix(_:_:)") == "Money.+=")
        #expect(Check.functionKey("static Version.... prefix(_:)") == "Version....")
        #expect(Check.subjectKey("LoadingState.==") == "LoadingState.==")
        #expect(Check.subjectKey("Rank.< sorts by points") == "Rank.<")
        #expect(Check.subjectKey("Money.+=") == "Money.+=")
        #expect(Check.covers(subjectKey: "LoadingState.==", functionKey: "LoadingState.=="))
        #expect(!Check.covers(subjectKey: "LoadingState.==", functionKey: "LoadingState.load"))
        #expect(!Check.covers(subjectKey: "Rank.<", functionKey: "Rank.<="))
    }

    @Test func findsWalksWithTheirSuiteAndTest() throws {
        let dir = NSTemporaryDirectory() + "sfc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/LocaleTests.swift"
        try """
        @Suite("Locale")
        struct LocaleTests {
            @Test("picked language wins")
            func languageWins() {
                Prove("SupportedLocale.matching(identifier:)", it: { $0 }, over: .all) {}
            }
        }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        #expect(
            Check.findWalks(in: [file]) == [
                WalkCheck(subject: "SupportedLocale.matching(identifier:)", file: file, line: 5, suite: "LocaleTests", test: "languageWins")
            ])
    }

    @Test func findsWalksWhoseAttributesShareTheDeclarationLine() throws {
        let dir = NSTemporaryDirectory() + "sfc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/ShippingTests.swift"
        try """
        @Test func everySpeedHasItsLabel() {
            Prove("label(for:)", it: { $0 }, over: .all) {}
        }
        @Suite(.serialized) struct RateTests {
            @Test("rates are positive") @MainActor func positive() {
                Prove("rate(for:)", it: { $0 }, over: .all) {}
            }
        }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        #expect(
            Check.findWalks(in: [file]) == [
                WalkCheck(subject: "label(for:)", file: file, line: 2, suite: nil, test: "everySpeedHasItsLabel"),
                WalkCheck(subject: "rate(for:)", file: file, line: 6, suite: "RateTests", test: "positive"),
            ])
    }

    @Test func findsProveWalksAndReadsTheFunctionFromTheClosure() throws {
        let dir = NSTemporaryDirectory() + "sfc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/SurfaceTests.swift"
        try """
        @Suite struct SurfaceTests {
            @Test func text() {
                Prove(it: { SurfaceTextRule(input: $0).execute() }, over: .allCases) {
                    Satisfies("never empty") { _, text in !text.isEmpty }
                }
            }
            @Test func named() {
                Prove("Surface.label", it: { $0.label }) {}
            }
            @Test func overSeveralLines() {
                let prove = Prove(
                    it: { surface in
                        try await Formatter.shared.text(for: surface)
                    },
                    over: .allCases
                ) {}
            }
            @Test func references() { Prove(it: label(for:)) {}; Prove(it: { Rule($0) }) {} }
            @Test func typedParameter() { Prove(it: { (type: UnitSystemType) in type.id }, over: .all) {} }
            @Test func inputMembers() {
                Prove(it: { $0.label }) {}
                // Prove(it: { Commented.out($0) }) {}
                Prove("Old.style", it: { $0 }) {}
                Prove(it: { surface in surface.label.uppercased() }) {}; Prove(it: \\.label) {}; Prove(it: \\Surface.label) {}
                Prove(it: { $0 }) {}
            }
        }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        let walks = Check.findWalks(in: [file])
        #expect(
            walks.map(\.subject) == [
                "SurfaceTextRule.execute()", "Surface.label", "Formatter.text(for:)", "label(for:)", "Rule.init(_:)", "UnitSystemType.id",
                "$0.label", "Old.style", "$0.label", "$0.label", "Surface.label", "{ $0 }",
            ])
        #expect(walks.map(\.line) == [3, 8, 11, 18, 18, 19, 21, 23, 24, 24, 24, 25])
        #expect(walks.map(\.test).allSatisfy { $0 != nil })
        #expect(Check.covers(subjectKey: Check.subjectKey(walks[0].subject), functionKey: "SurfaceTextRule.execute"))
        #expect(Check.inputMember(walks[6].subject) == "label")
        #expect(Check.subjectKey(walks[11].subject).isEmpty)
    }

    /// A walk may state a promise the contract does not (a table, injectivity): it runs unless logic already found a
    /// failing input.
    @Test func runsWalksUnlessLogicFoundAFailingInput() throws {
        let report = try scan([
            try function("Score.clamp(_:)", .contractHolds),
            try function("Score.total(_:)", .safe),
            try function("Score.label(_:)", .unsupported),
            try function("Score.broken(_:)", .contractFails),
        ])
        let walks = [
            walk("Score.clamp", line: 1), walk("Score.total", line: 2), walk("Score.label", line: 3), walk("rating text", line: 4),
            walk("Score.broken", line: 5),
        ]
        let plan = Check.plan(scans: [report], walks: walks)
        #expect(plan.run == [0, 1, 2])
        #expect(plan.skippedByLogic == [4])
        #expect(plan.unlinked == [3])
    }

    @Test func aWalkOverAMemberOfItsInputIsLinkedByTheTypeItReports() throws {
        let report = try scan([
            try function("Surface.label.getter", .safe), try function("Club.label.getter", .safe), try function("Surface.text(_:)", .safe),
        ])
        let walks = [walk("$0.label", line: 1), walk("$0.label", line: 2), walk("$0.label", line: 3), walk("$0.id", line: 4)]
        let plan = Check.plan(scans: [report], walks: walks)
        #expect(plan.run == [0, 1, 2])
        #expect(plan.unlinked == [3])
        func record(_ line: Int, _ type: String) throws -> WalkRecord {
            let json =
                #"{"subject":"t","verdict":"proved","evaluated":3,"domainSize":3,"domainComplete":true,"properties":[],"file":"/x/AppTests.swift","line":\#(line),"inputType":"\#(type)"}"#
            return try JSONDecoder().decode(WalkRecord.self, from: Data(json.utf8))
        }
        // Walk 1 runs over `Surface`, walk 2 over a type nobody scanned, walk 3 never reports.
        let merged = Check.merge(
            scans: [report], plan: plan, records: [try record(1, "Feature.Surface"), try record(2, "Other.Shot<Swift.Int>")],
            knownIssues: [])
        #expect(merged.entries.map(\.outcome) == [.walkMissing, .walkMissing, .cannotTrap])
        #expect(merged.entries[0].walks.map(\.walk.subject) == ["Surface.label", "$0.label"])
        #expect(merged.entries[1].walks.map(\.walk.subject) == ["$0.label"])
        #expect(merged.unlinkedWalks.map(\.subject) == ["$0.id", "Shot.label"])
        #expect(Check.typeKey(reflecting: "M.Outer.(unknown context at $1a2b).Surface<Swift.Int>") == "Outer.Surface")
    }

    @Test func argumentLabelsKeepAWalkOnTheOverloadItCalls() throws {
        let names = [
            "LanguageOption.init(from:)", "LanguageOption.init(rawValue:), scope 7", "Formatter.text(for:style:)",
            "Store.send(_:)", "Store.send(_:animation:)", "Surface.label.getter",
        ]
        let report = try scan(names.map { try function($0, .unsupported) })
        func linked(_ source: String) throws -> [String] {
            let file = NSTemporaryDirectory() + "sfc-\(UUID().uuidString).swift"
            defer { try? FileManager.default.removeItem(atPath: file) }
            try ("Prove(" + source).write(toFile: file, atomically: true, encoding: .utf8)
            let subject = try #require(Check.findWalks(in: [file]).first).subject
            let plan = Check.plan(scans: [report], walks: [walk(subject)])
            let merged = Check.merge(scans: [report], plan: plan, records: [], knownIssues: [])
            return merged.entries.filter { !$0.walks.isEmpty }.map { $0.function.name }
        }
        #expect(try linked("it: LanguageOption.init(from:)) {}") == ["LanguageOption.init(from:)"])
        #expect(try linked("it: { LanguageOption(rawValue: $0) }) {}") == ["LanguageOption.init(rawValue:), scope 7"])
        // A call may leave out a defaulted argument; an exact overload wins over one with more labels.
        #expect(try linked("it: { Formatter.shared.text(for: $0) }) {}") == ["Formatter.text(for:style:)"])
        #expect(try linked("it: { store.send($0) }) {}").isEmpty)
        #expect(try linked("it: { Store.make().send($0) }) {}") == ["Store.send(_:)"])
        #expect(try linked("it: { Store.make().send($0) { 1 } }) {}") == ["Store.send(_:animation:)"])
        #expect(try linked(#"it: { Formatter.shared.text(for: $0, style: "a, b") }) {}"#) == ["Formatter.text(for:style:)"])
        #expect(try linked(#"it: { Formatter.shared.text(for: $0, mode: .x) }) {}"#).isEmpty)
        // A string subject without labels covers every function of that name.
        #expect(try linked(#""LanguageOption.init", it: { $0 }) {}"#).count == 2)
        #expect(Check.argumentLabels("Surface.label.getter") == nil)
        #expect(Check.argumentLabels("static Foo<T>.make(_:with:)") == ["_", "with"])
    }

    @Test func aWalkOverATypeDoesNotClaimMacroWrittenCode() throws {
        let json =
            #"{"name":"Store.State.values.getter","symbol":"s","status":"unsupported","hasContract":false,"seconds":0,"location":{"file":"@__swiftmacro_5Store.swift","line":1,"column":1}}"#
        let generated = try JSONDecoder().decode(FunctionReport.self, from: Data(json.utf8))
        let plan = Check.plan(scans: [try scan([generated])], walks: [walk("Store")])
        #expect(plan.run.isEmpty)
        #expect(plan.unlinked == [0])
    }

    @Test func mergesOneVerdictPerFunction() throws {
        let report = try scan([
            try function("Score.clamp(_:)", .contractHolds),
            try function("Score.total(_:)", .safe),
            try function("Score.label(_:)", .unsupported),
            try function("Score.text(_:)", .unsupported),
            try function("Score.other(_:)", .unsupported),
        ])
        let walks = [walk("Score.total", line: 2), walk("Score.label", line: 3), walk("Score.text", line: 4)]
        let plan = Check.plan(scans: [report], walks: walks)
        func record(_ line: Int, _ verdict: String) throws -> WalkRecord {
            let json =
                #"{"subject":"s","verdict":"\#(verdict)","evaluated":4,"domainSize":4,"domainComplete":true,"properties":[],"file":"/x/AppTests.swift","line":\#(line)}"#
            return try JSONDecoder().decode(WalkRecord.self, from: Data(json.utf8))
        }
        let merged = Check.merge(
            scans: [report], plan: plan, records: [try record(2, "proved"), try record(3, "failed"), try record(4, "failed")],
            knownIssues: Check.knownIssues(inTestOutput: "􀄣 Test \"t\" recorded a known issue at AppTests.swift:4:9: Issue recorded")
        )
        #expect(merged.entries.map(\.outcome) == [.provedByLogic, .provedByLogicAndWalk, .counterexample, .knownIssue, .unchecked])
        #expect(merged.ranWalks == 3)
        #expect(merged.hasFailures(strict: false))
    }

    /// On a real app most functions logic proves are accessors that cannot trap; listing each one hid what mattered
    /// (app study round 5: 1,955 lines before the walks). They are counted unless asked for.
    @Test func cannotTrapFunctionsAreCountedNotListed() throws {
        let report = try scan([
            try function("Score.clamp(_:)", .contractHolds),
            try function("Score.total.getter", .safe),
            try function("Score.count.getter", .safe),
            try function("Score.next(_:)", .mayTrap),
        ])
        let merged = Check.merge(scans: [report], plan: Check.plan(scans: [report], walks: []), records: [], knownIssues: [])
        let text = merged.text()
        #expect(text.contains("Score.clamp(_:)"))
        #expect(text.contains("Score.next(_:)"))
        #expect(!text.contains("Score.total.getter"))
        #expect(text.contains("2 functions cannot trap for any input (--show-proved lists them)"))
        let full = merged.text(showProved: true)
        #expect(full.contains("Score.total.getter") && full.contains("Score.count.getter"))
        #expect(!full.contains("--show-proved lists them"))
    }
}

extension CheckTests {
    @Test func aWeakContractIsListedWithTheEditsItMisses() throws {
        var weak = try function("State.discardEdit()", .contractHolds)
        weak.weakContract = try JSONDecoder().decode(
            WeakContract.self,
            from: Data(
                #"{"mutantsTried":1,"survivors":[{"mutation":"the call to State.show(_:) is skipped","kind":"skippedCall"}]}"#.utf8))
        let report = try scan([weak, try function("Score.clamp(_:)", .contractHolds)])
        let merged = Check.merge(scans: [report], plan: Check.plan(scans: [report], walks: []), records: [], knownIssues: [])
        let text = merged.text()
        #expect(text.contains("  ✓ State.discardEdit() — contract holds for every input, but is weak:"))
        #expect(text.contains("      still holds when the call to State.show(_:) is skipped"))
        #expect(text.contains("  ✓ Score.clamp(_:) — contract holds for every input\n"))
        let json = try merged.json()
        #expect(json.contains("\"weakContract\""))
        #expect(json.components(separatedBy: "weakContract").count == 2, "only the weak one has the key")
    }

    /// Two packages may each have a target named `Core`; the JSON says which package each module and verdict is of.
    @Test func theJSONNamesThePackageOfEachModuleAndVerdict() throws {
        let a = try scan([try function("Score.total(_:)", .safe)])
        let b = try scan([try function("Score.total(_:)", .mayTrap)])
        let merged = Check.merge(
            scans: [a, b], plan: Check.plan(scans: [a, b], walks: []), records: [], knownIssues: [], packages: ["A", "B"])
        #expect(merged.entries.map(\.package) == ["A", "B"])
        #expect(merged.modules.map(\.package) == ["A", "B"])
        let json = try JSONSerialization.jsonObject(with: Data(try merged.json().utf8)) as? [String: Any]
        let entries = json?["entries"] as? [[String: Any]]
        let modules = json?["modules"] as? [[String: Any]]
        #expect(entries?.compactMap { $0["package"] as? String } == ["A", "B"])
        #expect(modules?.compactMap { $0["package"] as? String } == ["A", "B"])
        let unnamed = Check.merge(scans: [a], plan: Check.plan(scans: [a], walks: []), records: [], knownIssues: [])
        #expect(!(try unnamed.json()).contains("\"package\""))
    }
}
