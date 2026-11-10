#if (os(macOS) || os(Linux)) && compiler(>=6.3)
    import Foundation
    import SwiftFormal
    @testable import SwiftFormalTesting
    import Testing

    // `Prove(neverTraps:)`: the trap check in one call. The walk's type crosses into the exit test by its mangled name.

    private let tabs = ["Overview", "Ranking"]

    /// The app's `tabs[selectedTabIndex]`: traps for an index the tab control never sends. Internal: the child process
    /// cannot find a private type by its name.
    enum SelectedTab: ExitTestWalk {
        static let inputs: Domain<Int> = .of([0, 1, 2, -1])
        static func call(_ index: Int) -> String { tabs[index] }
    }

    enum CheckedTab: ExitTestWalk {
        static let inputs: Domain<Int> = .of([0, 1, 2, -1])
        static func call(_ index: Int) -> String { tabs.indices.contains(index) ? tabs[index] : tabs[0] }
    }

    enum Outer {
        /// A walk type inside another type is found by name too.
        enum Halve: ExitTestWalk {
            static let inputs = UInt8.domain
            static func call(_ value: UInt8) -> UInt8 { value / 2 }
        }
    }

    private enum PrivateWalk: ExitTestWalk {
        static let inputs: Domain<Int> = .of([0])
        static func call(_ value: Int) -> Int { value }
    }

    @Suite struct NoTrapTests {
        @Test func aWalkWithoutATrapPasses() async {
            let checked = await Prove(neverTraps: CheckedTab.self)
            #expect(checked.report.isProved && checked.report.evaluated == 4 && checked.failures.isEmpty)
            #expect(checked.report.subject == "CheckedTab.call", "the walk's call, not the test's name")
            #expect(checked.report.results.map(\.name) == ["total"])
            #expect(await Prove(neverTraps: Outer.Halve.self).report.isProved)
        }

        @Test func aTrapIsAKnownIssueOnItsInput() async {
            let walk = await Prove(
                "Tabs.selectedTab", neverTraps: SelectedTab.self, knownIssue: KnownFailure("tabs[selectedTabIndex]", inputs: [2]))
            #expect(!walk.report.isProved && !walk.report.hasNoCounterexample)
            #expect(walk.failures.map(\.property) == ["never traps"] && walk.failures.first?.counterexample.input == "2")
            #expect(walk.report.subject == "Tabs.selectedTab" && walk.report.evaluated == 3)
        }

        @Test func aBoundedTrapWalkIsNoProof() async {
            let walk = await Prove(neverTraps: Outer.Halve.self, budget: Budget(maxEvaluations: 10), allowBounded: true)
            #expect(!walk.report.isProved && walk.report.hasNoCounterexample && walk.report.evaluated == 10)
        }

        /// Without a subject the walk is named after its type's `call`, not the test: "SelectedTab.call traps for input 2",
        /// never "<test name> traps".
        @Test func withoutASubjectTheTrapNamesTheWalksCall() async {
            await withKnownIssue {
                let walk = await Prove(neverTraps: SelectedTab.self)
                #expect(walk.report.subject == "SelectedTab.call")
            } matching: { issue in
                issue.description.contains("SelectedTab.call traps for input 2 (step 2")
            }
        }

        @Test func theIssueNamesTheInputAndTheConfirmation() async {
            await withKnownIssue {
                await Prove("Tabs.selectedTab", neverTraps: SelectedTab.self)
            } matching: { issue in
                issue.description.contains("Tabs.selectedTab traps for input 2 (step 2")
                    && issue.description.contains("confirmed: it traps when called alone on this input")
            }
        }

        @Test func theWalkReportsWhatCheckReads() async throws {
            let request = NoTrapRequest(
                typeName: try #require(_mangledTypeName(SelectedTab.self)), subject: "Tabs.selectedTab", maxEvaluations: 100,
                seed: 1, allowBounded: false)
            let trapWalk = await NoTrapChild.run(request, over: SelectedTab.inputs)
            let line = trapWalk.checkLine(subject: "Tabs.selectedTab", inputType: Int.self, at: #_sourceLocation)
            #expect(line.verdict == "failed" && line.subject == "Tabs.selectedTab")
            #expect(line.properties.map(\.name) == ["never traps"] && line.properties[0].input == "2")
            #expect(line.file == #filePath && line.domainComplete == false && line.evaluated == 3)

            let clean = await NoTrapChild.run(
                NoTrapRequest(
                    typeName: try #require(_mangledTypeName(CheckedTab.self)), subject: "Tabs.checkedTab", maxEvaluations: 100, seed: 1,
                    allowBounded: false),
                over: CheckedTab.inputs)
            let proved = clean.checkLine(subject: "Tabs.checkedTab", inputType: Int.self, at: #_sourceLocation)
            #expect(proved.verdict == "proved" && proved.evaluated == 4 && proved.domainSize == 4 && proved.domainComplete)
            #expect(proved.inputType == "Swift.Int" && proved.line == #line - 2)
        }

        /// A record read back is never more of a proof than it says: no property, or a verdict that is not `proved`
        /// next to properties that are, is a failure.
        @Test func aRecordReadBackFailsClosed() {
            var line = WalkLog.Line(
                subject: "f", verdict: "failed", evaluated: 3, domainSize: 3, domainComplete: true, properties: [], file: "",
                line: 0, test: nil, inputType: nil)
            #expect(!line.report.isProved && !line.report.hasNoCounterexample)
            line.properties = [WalkLog.Property(name: "total", verdict: "proved", checked: 3)]
            #expect(!line.report.isProved)
            line.verdict = "proved"
            #expect(line.report.isProved)
            line.properties.append(WalkLog.Property(name: "never traps", verdict: "trapped", input: "2"))
            #expect(line.report.counterexamples.map(\.counterexample.input) == ["2"])
        }

        @Test func aTypeInsideAFunctionIsRefused() async {
            enum Local: ExitTestWalk {
                static let inputs: Domain<Int> = .of([0])
                static func call(_ value: Int) -> Int { value }
            }
            await withKnownIssue {
                let walk = await Prove(neverTraps: Local.self)
                #expect(!walk.report.isProved && walk.report.evaluated == 0)
            } matching: {
                $0.description.contains("declare it internal (not private or fileprivate)")
            }
        }

        @Test func aPrivateTypeIsRefused() async {
            await withKnownIssue {
                #expect(!(await Prove(neverTraps: PrivateWalk.self).report.isProved))
            } matching: {
                $0.description.contains("cannot be found by name in another process")
            }
        }
    }
#endif
