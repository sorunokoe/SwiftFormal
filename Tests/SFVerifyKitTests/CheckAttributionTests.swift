import Foundation
import SFVerifyKit
import Testing

/// App study round 6: what `swiftformal check` may claim from a walk. A walk proves a function only over the inputs it
/// lists (L5); a failing walk is blamed only on the function it names, and a known issue does not outweigh other walks'
/// proofs (L18).
@Suite struct CheckAttributionTests {
    private func function(_ name: String, _ status: ScanStatus) throws -> FunctionReport {
        let json = #"{"name":"\#(name)","symbol":"s","status":"\#(status.rawValue)","hasContract":false,"seconds":0}"#
        return try JSONDecoder().decode(FunctionReport.self, from: Data(json.utf8))
    }

    private func scan(_ functions: [FunctionReport]) throws -> ScanReport {
        let timing = try JSONDecoder().decode(
            ScanReport.Timing.self, from: Data(#"{"compileSeconds":0,"parseSeconds":0,"verifySeconds":0,"silBytes":0}"#.utf8))
        return ScanReport(module: "App", optimization: "-Onone", functions: functions, timing: timing)
    }

    private func walk(_ subject: String, line: Int) -> WalkCheck {
        WalkCheck(subject: subject, file: "/t/AppTests.swift", line: line, suite: "AppTests", test: "t\(line)")
    }

    private func record(_ line: Int, _ verdict: String, size: Int = 2) throws -> WalkRecord {
        let json =
            #"{"subject":"s","verdict":"\#(verdict)","evaluated":\#(size),"domainSize":\#(size),"domainComplete":true,"properties":[],"file":"/x/AppTests.swift","line":\#(line)}"#
        return try JSONDecoder().decode(WalkRecord.self, from: Data(json.utf8))
    }

    /// L5: the spike's walk over indices 0…1 of a getter logic could not decide was reported "proved by walking a whole
    /// domain", next to "proved by logic for every input". It proves the getter over those two inputs only.
    @Test func aWalkProvesOnlyTheInputsItLists() throws {
        let report = try scan([
            try function("TabsStore.State.selectedTab.getter", .undecided),
            try function("Tabs.broken.getter", .contractFails),
        ])
        let walks = [walk("TabsStore.State.selectedTab", line: 1), walk("Tabs.broken", line: 2)]
        let plan = Check.plan(scans: [report], walks: walks)
        #expect(plan.run == [0])
        let merged = Check.merge(scans: [report], plan: plan, records: [try record(1, "proved")], knownIssues: [])
        #expect(merged.entries.map(\.outcome) == [.provedByWalk, .counterexample])
        let text = merged.text()
        #expect(!text.contains("whole domain"), "\(text)")
        #expect(text.contains(/proved over the walked inputs only +1\n/), "\(text)")
        #expect(text.contains("proved over its 2 inputs (not every input)"), "\(text)")
    }

    /// L18: a known-issue walk that names a function others prove is a conflict, not a broken function; a failing walk
    /// over a whole type is not blamed on each member, but a failure that is not a known issue still fails the run.
    @Test func aFailingWalkIsBlamedOnlyOnWhatItNames() throws {
        let report = try scan([
            try function("Double.withFormat(_:)", .unsupported),
            try function("Store.reduce(_:_:)", .unsupported),
            try function("Store.text.getter", .unsupported),
            try function("Store.count.getter", .safe),
        ])
        let walks = [
            walk("Double.withFormat(_:)", line: 1), walk("Double.withFormat(_:)", line: 2), walk("Double.withFormat(_:)", line: 3),
            walk("Store without overlay", line: 4), walk("Store.text", line: 5),
        ]
        let plan = Check.plan(scans: [report], walks: walks)
        let records = [
            try record(1, "proved"), try record(2, "proved"), try record(3, "failed"), try record(4, "failed"), try record(5, "proved"),
        ]
        let known: Set = ["AppTests.swift:3", "AppTests.swift:4"]
        let merged = Check.merge(scans: [report], plan: plan, records: records, knownIssues: known)
        #expect(merged.entries.map(\.outcome) == [.conflict, .typeWalkFailed, .provedByWalk, .typeWalkFailed])
        #expect(!merged.hasFailures(strict: false))
        let text = merged.text()
        #expect(text.contains(/walks disagree \(a known issue\) +1\n/), "\(text)")
        #expect(text.contains(/in a type whose walk failed +2 \(the/), "\(text)")
        #expect(merged.count(.counterexample) == 0 && merged.count(.knownIssue) == 0)
        #expect(text.contains("— broken (known issue), 2 of 2 inputs"), "\(text)")

        // The same walk over the type, not marked as a known issue, fails the run though no member is blamed.
        let unmarked = Check.merge(scans: [report], plan: plan, records: records, knownIssues: ["AppTests.swift:3"])
        #expect(unmarked.entries[1].outcome == .typeWalkFailed)
        #expect(unmarked.hasFailures(strict: false))
        // A walk that names the function and fails without a known issue always wins over proofs.
        let broken = Check.merge(scans: [report], plan: plan, records: records, knownIssues: ["AppTests.swift:4"])
        #expect(broken.entries[0].outcome == .counterexample)
    }

    /// The names that walked before `Prove` (`expectProved`, `expectNoTrap`, `walkInExitTest`, `partition`) do not compile
    /// for users any more, so `check` reads none of them: only `Prove(` is a walk.
    @Test func theRemovedWalkNamesAreNotRead() throws {
        let dir = NSTemporaryDirectory() + "sfc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/OldTests.swift"
        try """
        @Suite struct OldTests {
            @Test func old() async {
                expectProved("Tabs.selectedTab", { $0 }, over: indices)
                await expectNoTrap("Tabs.selectedTab", SelectedTab.self)
                walkInExitTest("Tabs.selectedTab", { $0 }, over: indices)
                let groups = partition({ key in format(key) }, over: keys)
            }
        }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        #expect(Check.findWalks(in: [file]).isEmpty)
    }
}

extension CheckAttributionTests {
    /// App study round 7: a walk whose subject names only a type was linked to every member, nested types' members too,
    /// and its proof made each of them `provedByWalk`, even a getter the walk never calls (one that traps). A walk over
    /// `LoadingState.==` proved `LoadingState.load`. A walk proves only what its subject names.
    @Test func aWalkOverATypeProvesNoMember() throws {
        let report = try scan([
            try function("Tabs.selectedTab.getter", .undecided),
            try function("Tabs.Row.title.getter", .unsupported),
            try function("Tabs.count.getter", .safe),
            try function("static LoadingState.== infix(_:_:)", .unsupported),
            try function("LoadingState.load()", .unsupported),
            try function("static Rank.< infix(_:_:)", .unsupported),
            try function("Rank.points.getter", .unsupported),
        ])
        let walks = [walk("Tabs", line: 1), walk("LoadingState.==", line: 2), walk("Rank.<", line: 3)]
        let plan = Check.plan(scans: [report], walks: walks)
        let records = [try record(1, "proved"), try record(2, "proved"), try record(3, "proved")]
        let merged = Check.merge(scans: [report], plan: plan, records: records, knownIssues: [])
        #expect(
            merged.entries.map(\.outcome) == [.unchecked, .unchecked, .cannotTrap, .provedByWalk, .unchecked, .provedByWalk, .unchecked])
        #expect(merged.entries[4].walks.isEmpty && merged.entries[6].walks.isEmpty)
        #expect(merged.count(.provedByWalk) == 2)
        let text = merged.text()
        #expect(text.contains(/proved over the walked inputs only +2\n/), "\(text)")
        #expect(text.contains("over its whole type proves no member"), "\(text)")
    }

    /// The trap check, `Prove("…", neverTraps: Walk.self)`, writes its record from the test process, so `check` runs and
    /// links it like any walk; a trap is a failure of "never traps" with the input. The session walk is a `Prove` too.
    @Test func trapChecksAndSessionWalksAreRunAndLinked() throws {
        let dir = NSTemporaryDirectory() + "sfc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/TabsTests.swift"
        try """
        @Suite struct TabsTests {
            @Test func selectedTabNeverTraps() async {
                await Prove("Tabs.selectedTab", neverTraps: SelectedTab.self, knownIssue: "unchecked index")
            }
            @Test func sessions() {
                Prove("TabsStore.body", it: { _ = reducer.reduce(into: &$0, action: $1) },
                      over: .sessions(from: TabsStore.State(), actions: actions, upTo: 4)) {
                    Always("on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
                }
            }
        }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        let walks = Check.findWalks(in: [file])
        #expect(walks.map(\.subject) == ["Tabs.selectedTab", "TabsStore.body"], "\(walks)")
        #expect(walks.map(\.line) == [3, 6])

        let report = try scan([try function("Tabs.selectedTab.getter", .undecided), try function("TabsStore.body.getter", .unsupported)])
        let plan = Check.plan(scans: [report], walks: walks)
        #expect(plan.run == [0, 1])
        let trapped = try JSONDecoder().decode(
            WalkRecord.self,
            from: Data(
                #"{"subject":"Tabs.selectedTab","verdict":"failed","evaluated":3,"domainSize":4,"domainComplete":false,"properties":[{"name":"never traps","verdict":"failed","input":"2","detail":"traps"}],"file":"/x/TabsTests.swift","line":3}"#
                    .utf8))
        let walked = try JSONDecoder().decode(
            WalkRecord.self,
            from: Data(
                #"{"subject":"TabsStore.body","verdict":"proved","evaluated":40,"domainSize":40,"domainComplete":true,"properties":[],"file":"/x/TabsTests.swift","line":6}"#
                    .utf8))
        let merged = Check.merge(scans: [report], plan: plan, records: [trapped, walked], knownIssues: ["TabsTests.swift:3"])
        #expect(merged.entries.map(\.outcome) == [.knownIssue, .provedByWalk])
    }

    /// `swift format` puts a long call's subject on the line after the call: `check` reads it there too, and keys the walk
    /// at the line of the call's name, where the test's record is.
    @Test func callsWithTheSubjectOnTheNextLineAreFound() throws {
        let dir = NSTemporaryDirectory() + "sfc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/AppStyleWalkTests.swift"
        try """
        struct AppStyleWalkTests {
            @Test("tabs")
            func selectedTabNeverOutOfRange() {
                Prove(
                    "EventDetailsStore.reduce(into:action:)",
                    it: { state, action in _ = reducer.reduce(into: &state, action: action) },
                    over: .sessions(from: EventDetailsStore.State(), actions: tabActions, upTo: 4)
                ) {
                    Always("the selected tab is on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
                }
            }

            @Test("bound label: no Double the type can hold traps")
            func boundLabelTraps() async {
                await Prove(
                    "boundLabel(_:)", neverTraps: BoundLabel.self,
                    knownIssue: KnownFailure("traps", inputs: [1e18]))
            }

            @Test func reports() {
                let walk = Prove(
                    "localized(_:)", it: localized, over: allKeysInAllLanguages, reporting: .everyFailure)
            }
        }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        let walks = Check.findWalks(in: [file])
        #expect(walks.map(\.subject) == ["EventDetailsStore.reduce(into:action:)", "boundLabel(_:)", "localized(_:)"])
        #expect(walks.map(\.line) == [4, 15, 21])
        #expect(walks.map(\.test) == ["selectedTabNeverOutOfRange", "boundLabelTraps", "reports"])
    }

    /// `check --format xcode` agrees with `hasFailures`: a failing walk over a whole type is one error at the walk, not
    /// one per member, and only a note when the test marks it as a known issue; a conflict is never an error.
    @Test func xcodeDiagnosticsFailOnceForAFailingWalkOverAType() throws {
        let report = try scan([
            try function("Double.withFormat(_:)", .unsupported),
            try function("Store.reduce(_:_:)", .unsupported),
            try function("Store.text.getter", .unsupported),
        ])
        let walks = [
            walk("Double.withFormat(_:)", line: 1), walk("Double.withFormat(_:)", line: 2), walk("Store without overlay", line: 4),
        ]
        let plan = Check.plan(scans: [report], walks: walks)
        let records = [try record(1, "proved"), try record(2, "failed"), try record(4, "failed")]
        let unmarked = Check.merge(scans: [report], plan: plan, records: records, knownIssues: ["AppTests.swift:2"])
        #expect(unmarked.entries.map(\.outcome) == [.conflict, .typeWalkFailed, .typeWalkFailed])
        let errors = unmarked.diagnostics().split(separator: "\n").filter { $0.contains(": error: ") }
        #expect(errors.count == 1 && errors[0].hasPrefix("/t/AppTests.swift:4:"), "\(errors)")
        let marked = Check.merge(scans: [report], plan: plan, records: records, knownIssues: ["AppTests.swift:2", "AppTests.swift:4"])
        #expect(!marked.hasFailures(strict: false))
        #expect(!marked.diagnostics().contains(": error: "))
    }
}

/// A proved contract says nothing about another promise a walk states (injectivity, a table): the walk still runs and
/// its failure counts. A walk not run because logic already found a failing input is listed with that reason.
extension CheckAttributionTests {
    @Test func aContractThatHoldsDoesNotHideAWalkOfAnotherPromise() throws {
        let report = try scan([try function("Codes.code(for:)", .contractHolds)])
        let plan = Check.plan(scans: [report], walks: [walk("Codes.code(for:) is injective", line: 1)])
        #expect(plan.run == [0])
        let broken = Check.merge(scans: [report], plan: plan, records: [try record(1, "failed")], knownIssues: [])
        #expect(broken.entries.map(\.outcome) == [.counterexample])
        #expect(broken.hasFailures(strict: false))
        #expect(broken.text().contains(/broken, with the input +1\n/), "\(broken.text())")
        #expect(broken.diagnostics().contains("Codes.code(for:) is broken: walk"), "\(broken.diagnostics())")
        let proved = Check.merge(scans: [report], plan: plan, records: [try record(1, "proved")], knownIssues: [])
        #expect(proved.entries.map(\.outcome) == [.provedByLogic])
        #expect(!proved.hasFailures(strict: false))
        let sampled = Check.merge(scans: [report], plan: plan, records: [try record(1, "bounded")], knownIssues: [])
        #expect(sampled.entries.map(\.outcome) == [.bounded])
    }

    @Test func aWalkThatFailsOnAFunctionThatMayTrapFailsTheRun() throws {
        let report = try scan([try function("Codes.next(_:)", .mayTrap)])
        let plan = Check.plan(scans: [report], walks: [walk("Codes.next(_:) is a table", line: 1)])
        #expect(plan.run == [0])
        let failed = Check.merge(scans: [report], plan: plan, records: [try record(1, "failed")], knownIssues: [])
        #expect(failed.hasFailures(strict: false))
        #expect(failed.diagnostics().contains(": error: "), "\(failed.diagnostics())")
        let held = Check.merge(scans: [report], plan: plan, records: [try record(1, "proved")], knownIssues: [])
        #expect(!held.hasFailures(strict: false))
        #expect(held.hasFailures(strict: true))
    }

    @Test func aWalkNotRunBecauseLogicFoundAFailureIsListed() throws {
        let report = try scan([try function("Codes.broken(_:)", .contractFails)])
        let plan = Check.plan(scans: [report], walks: [walk("Codes.broken(_:) is injective", line: 1)])
        #expect(plan.run.isEmpty)
        let merged = Check.merge(scans: [report], plan: plan, records: [], knownIssues: [])
        #expect(merged.notRunWalks.map(\.subject) == ["Codes.broken(_:) is injective"])
        let text = merged.text()
        #expect(text.contains("logic already found a failing input"), "\(text)")
        #expect(merged.diagnostics().contains("was not run: logic already found a failing input"), "\(merged.diagnostics())")
    }
}
