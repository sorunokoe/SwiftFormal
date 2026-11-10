import Foundation
import SFVerifyKit
import Testing

/// How `swiftformal check` links each `Prove` form to the function it calls. A wrong link makes a walk prove a function
/// it never calls (a false `provedByWalk`), so every reading fails closed: what cannot be read is unlinked.
@Suite struct ProveLinkingTests {
    /// One walk of each form; a step whose call starts at the action (not the state), a `call` that is a subscript, and a
    /// named first parameter (the input); then subjects that name only a type.
    private static let tests = """
        @Suite struct FormTests {
            private let reducer = TabsReducer()
            @Test func domain() {
                Prove(it: { $0.label }, over: .allCases) { Deterministic() }
            }
            @Test func finite() {
                Prove(it: { (surface: Surface) in SurfaceTextRule(input: surface).execute() }) { Deterministic() }
            }
            @Test func sessions() {
                Prove(it: { reducer.reduce(into: &$0, action: $1) }, over: .sessions(from: TabsState(), actions: actions, upTo: 4)) {
                    Always("on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
                }
            }
            @Test func sessionsOfAModel() {
                Prove(it: { $0.send($1) }, over: .sessions(from: TabsState(), actions: actions, upTo: 2)) {}
            }
            @Test func neverTraps() async {
                await Prove(neverTraps: SelectedTab.self)
            }
            @Test func unreadableOrNamedByTheFirstParameter() async {
                Prove(it: { state, action in action.apply(to: &state) }, over: .sessions(from: TabsState(), actions: actions, upTo: 2))
                await Prove(neverTraps: RawIndex.self)
                Prove(it: { other in other.label }, over: .allCases)
            }
            @Test func wholeTypes() async {
                Prove("TabsReducer", it: { _, _ in }, over: .sessions(from: TabsState(), actions: actions, upTo: 2)) {}
                await Prove(
                    "TabsState", neverTraps: SelectedTab.self)
            }
        }
        """

    /// In another file: the trap walks, and a second `label` closure parameter that hides the name's type.
    private static let walks = """
        enum SelectedTab: ExitTestWalk {
            static let inputs: Domain<Int> = .of([0, 1, 2, -1])
            static func call(_ index: Int) -> String {
                TabsState(selectedTabIndex: index).selectedTab
            }
        }

        enum RawIndex: ExitTestWalk {
            static let inputs: Domain<Int> = .of([0, 1])
            static func call(_ index: Int) -> String { tabs[index] }
        }
        """

    private func findWalks() throws -> [WalkCheck] {
        let dir = NSTemporaryDirectory() + "sfc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Self.tests.write(toFile: dir + "/FormTests.swift", atomically: true, encoding: .utf8)
        try Self.walks.write(toFile: dir + "/Walks.swift", atomically: true, encoding: .utf8)
        return Check.findWalks(in: [dir + "/FormTests.swift", dir + "/Walks.swift"])
    }

    @Test func eachFormIsReadFromItsCall() throws {
        let walks = try findWalks()
        #expect(
            walks.map(\.subject) == [
                "$0.label", "SurfaceTextRule.execute()", "TabsReducer.reduce(into:action:)", "$0.send(_:)", "TabsState.selectedTab",
                "{ state, action in action.apply(to: &state) }", "tabs", "$0.label",
                "TabsReducer", "TabsState",
            ], "\(walks.map(\.subject))")
        #expect(walks.map(\.line) == [4, 7, 10, 15, 18, 21, 22, 23, 26, 27])
    }

    /// A session walk links `$0.send` with the state's type, which its record reports; a session walk or a trap check
    /// whose subject names only a type proves no member, even when it passes.
    @Test func eachFormProvesOnlyWhatItNames() throws {
        let walks = try findWalks()
        let report = try scan([
            "Surface.label.getter", "SurfaceTextRule.execute()", "TabsReducer.reduce(into:action:)", "TabsReducer.body.getter",
            "TabsState.send(_:)", "TabsState.selectedTab.getter", "TabsState.count.getter", "Action.apply(to:)",
        ])
        let plan = Check.plan(scans: [report], walks: walks)
        let types = [4: "App.Surface", 15: "App.TabsState", 21: "App.TabsState", 23: "App.Surface"]
        let records = try [4, 7, 10, 15, 18, 21, 22, 23, 26, 27].map { try record(line: $0, inputType: types[$0]) }
        let merged = Check.merge(scans: [report], plan: plan, records: records, knownIssues: [])
        #expect(
            merged.entries.map(\.outcome) == [
                .provedByWalk, .provedByWalk, .provedByWalk, .unchecked, .provedByWalk, .provedByWalk, .unchecked, .unchecked,
            ], "\(merged.text())")
    }

    /// A name declared with two types, or bound where its type is not written, names no type.
    @Test func aNameWhoseTypeIsNotCertainLinksNothing() throws {
        let twoTypes = """
            let reducer = TabsReducer()
            func other() { let reducer = OtherReducer() }
            @Test func t() { Prove(it: { reducer.reduce(into: &$0, action: $1) }, over: sessions) }
            """
        let hidden = """
            let reducer = TabsReducer()
            func other() { for reducer in reducers { _ = reducer } }
            @Test func t() { Prove(it: { reducer.reduce(into: &$0, action: $1) }, over: sessions) }
            """
        let untyped = """
            let reducer = makeReducer()
            @Test func t() { Prove(it: { reducer.reduce(into: &$0, action: $1) }, over: sessions) }
            """
        let labelled = """
            let reducer = TabsReducer()
            let store = Store(reducer: Other())
            @Test func t() { Prove(it: { reducer.reduce(into: &$0, action: $1) }, over: sessions) }
            """
        let parameter = """
            func send(_ reducer: TabsReducer) -> (inout TabsState, Action) -> Void { { reducer.reduce(into: &$0, action: $1) } }
            @Test func t() { Prove(it: { reducer.reduce(into: &$0, action: $1) }, over: sessions) }
            """
        // A written type is the static type: the call may run a subclass's override or another conformer's method.
        let annotatedSuper = """
            let reducer: BaseReducer = DerivedReducer()
            @Test func t() { Prove(it: { reducer.reduce(into: &$0, action: $1) }, over: sessions) }
            """
        let annotatedOnly = """
            let reducer: any Reducing = makeReducer()
            @Test func t() { Prove(it: { reducer.reduce(into: &$0, action: $1) }, over: sessions) }
            """
        let annotatedSame = """
            let reducer: TabsReducer = TabsReducer()
            @Test func t() { Prove(it: { reducer.reduce(into: &$0, action: $1) }, over: sessions) }
            """
        for (text, expected) in [
            (twoTypes, nil), (hidden, nil), (untyped, nil), (labelled, nil), (parameter, nil), (annotatedSuper, nil),
            (annotatedOnly, nil), (annotatedSame, "TabsReducer.reduce(into:action:)"),
        ] {
            let dir = NSTemporaryDirectory() + "sfc-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            try text.write(toFile: dir + "/T.swift", atomically: true, encoding: .utf8)
            let subjects = Check.findWalks(in: [dir + "/T.swift"]).map(\.subject)
            #expect(subjects == [expected ?? "{ reducer.reduce(into: &$0, action: $1) }"], "\(text)")
        }
    }

    /// A step written as `_ = reducer.reduce(…)`, as TCA tests do, links like the call itself.
    @Test func aDiscardedResultIsStillTheCall() throws {
        let dir = NSTemporaryDirectory() + "sfc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try """
        let reducer = TabsReducer()
        @Test func t() {
            Prove(it: { _ = reducer.reduce(into: &$0, action: $1) }, over: sessions)
            Prove(it: { state, action in _ = reducer.reduce(into: &state, action: action) }, over: sessions)
            Prove(it: { _ = TabsReducer().reduce(into: &$0, action: $1) }, over: sessions)
        }
        """.write(toFile: dir + "/T.swift", atomically: true, encoding: .utf8)
        #expect(Check.findWalks(in: [dir + "/T.swift"]).map(\.subject) == Array(repeating: "TabsReducer.reduce(into:action:)", count: 3))
    }

    /// `neverTraps: B.Halve.self` must not take the `call` of another `Halve`: a walk type is read only when its name is
    /// declared once in the test sources, whatever the other declaration conforms to.
    @Test func aWalkTypeWhoseNameIsDeclaredTwiceLinksNothing() throws {
        let dir = NSTemporaryDirectory() + "sfc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try
            "enum A { enum Halve: ExitTestWalk { static let inputs: Domain<Int> = .of([0]); static func call(_ i: Int) -> Int { Math.half(i) } } }"
            .write(toFile: dir + "/A.swift", atomically: true, encoding: .utf8)
        try
            "enum B { enum Halve {} }\nextension B.Halve: ExitTestWalk { static let inputs: Domain<Int> = .of([0]); static func call(_ i: Int) -> Int { Other.half(i) } }"
            .write(toFile: dir + "/B.swift", atomically: true, encoding: .utf8)
        try "@Test func t() async { await Prove(neverTraps: B.Halve.self) }".write(
            toFile: dir + "/T.swift", atomically: true, encoding: .utf8)
        let walks = Check.findWalks(in: ["A", "B", "T"].map { dir + "/\($0).swift" })
        #expect(walks.map(\.subject) == ["neverTraps: B.Halve"])
    }

    /// A trap walk whose type is not found once in the test sources (missing, or declared in two files) links nothing.
    @Test func aTrapWalkWhoseTypeIsNotFoundOnceLinksNothing() throws {
        let dir = NSTemporaryDirectory() + "sfc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let walk =
            "enum Twice: ExitTestWalk { static let inputs: Domain<Int> = .of([0]); static func call(_ i: Int) -> Int { Tabs.count(i) } }"
        try walk.write(toFile: dir + "/A.swift", atomically: true, encoding: .utf8)
        try walk.write(toFile: dir + "/B.swift", atomically: true, encoding: .utf8)
        try "@Test func t() async { await Prove(neverTraps: Missing.self); await Prove(neverTraps: Twice.self) }"
            .write(toFile: dir + "/T.swift", atomically: true, encoding: .utf8)
        let walks = Check.findWalks(in: ["A", "B", "T"].map { dir + "/\($0).swift" })
        #expect(walks.map(\.subject) == ["neverTraps: Missing", "neverTraps: Twice"])
    }

    private func scan(_ names: [String]) throws -> ScanReport {
        let functions = try names.map { name in
            let json = #"{"name":"\#(name)","symbol":"s","status":"unsupported","hasContract":false,"seconds":0}"#
            return try JSONDecoder().decode(FunctionReport.self, from: Data(json.utf8))
        }
        let timing = try JSONDecoder().decode(
            ScanReport.Timing.self, from: Data(#"{"compileSeconds":0,"parseSeconds":0,"verifySeconds":0,"silBytes":0}"#.utf8))
        return ScanReport(module: "App", optimization: "-Onone", functions: functions, timing: timing)
    }

    private func record(line: Int, inputType: String?) throws -> WalkRecord {
        let type = inputType.map { #","inputType":"\#($0)""# } ?? ""
        let json =
            #"{"subject":"s","verdict":"proved","evaluated":2,"domainSize":2,"domainComplete":true,"properties":[],"file":"/x/FormTests.swift","line":\#(line)\#(type)}"#
        return try JSONDecoder().decode(WalkRecord.self, from: Data(json.utf8))
    }
}
