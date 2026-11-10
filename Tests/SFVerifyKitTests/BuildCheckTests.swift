import Foundation
import Testing
@testable import SFVerifyKit

/// `swiftformal check --gate`: which functions the build checks, and which verdicts fail it.
@Suite struct BuildCheckTests {
    private func temporaryDirectory() throws -> String {
        let dir = NSTemporaryDirectory() + "sfbuildcheck-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func function(
        _ name: String, _ status: ScanStatus, file: String = "/p/Shop.swift", line: Int, contract: Bool = false,
        category: String? = nil, example: ScanCounterexample? = nil
    ) -> FunctionReport {
        FunctionReport(
            name: name, symbol: "$s" + name, location: SourceLocation(file: file, line: line, column: 6), status: status,
            category: category, detail: nil, counterexample: example, hasContract: contract, seconds: 0)
    }

    private func report(_ functions: [FunctionReport]) -> ScanReport {
        ScanReport(
            module: "Shop", optimization: "-Onone", functions: functions,
            timing: .init(compileSeconds: 0, parseSeconds: 0, verifySeconds: 0, silBytes: 0))
    }

    private func promise(_ name: String, _ kind: Promise.Kind, line: Int) -> Promise {
        Promise(
            file: "/p/Shop.swift", firstLine: line, declarationLine: line + 1, name: name, kind: kind,
            walk: kind == .verify ? "verify_\(name)()" : nil)
    }

    /// Only `@Verify`: a `// sf:verify` comment is no promise; it is a problem (an error) at its line.
    @Test func findsVerifyAttributesButNotLookalikesAndReportsMarkers() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/Shop.swift"
        try write(
            """
            @Verify
            func a(_ x: Int8) -> Int8 { x }
            @Verify(over: .allCases)
            public func b(_ x: Bool) -> Bool { x }
            @VerifyLater
            func c() {}
            // sf:verify
            func d(_ x: UInt8) -> UInt8 { x }
            struct S {
                @Verify mutating func e() {}
            }
            """, to: file)
        let found = BuildCheck.promises(in: [file])
        #expect(found.promises.map(\.name).sorted() == ["a", "b", "e"])
        #expect(found.problems.count == 1)
        #expect(found.problems.first?.contains("Shop.swift:7:1: error: [SwiftFormal] `// sf:verify` is no longer read") == true)
        #expect(found.problems.first?.contains("write the contract in place with @Verify, #requires and #ensures") == true)
        #expect(found.promises.first { $0.name == "b" }?.declarationLine == 4)
        #expect(found.promises.first { $0.name == "a" }?.walk == "verify_a()")
        #expect(found.promises.first { $0.name == "e" }.map { $0.walk == nil } == true)
    }

    /// `@Verify` on a computed property promises its getter (Scan reports `Rule.body.getter`, which `only: ["body"]`
    /// keeps); `@Verify get` promises the property above it. Neither has a walk, nor has a function with nothing to walk
    /// (no parameters, `inout`, or a parameter that is surely not `Finite` and no `over:`): the hint names no
    /// `verify_` function that does not exist.
    @Test func aComputedPropertyIsAPromiseAndOnlyWalkableFunctionsNameAWalk() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/Rule.swift"
        try write(
            """
            struct Rule {
                @Verify
                var body: String {
                    #ensures { !$0.isEmpty }
                    title
                }
                @Verify static var limit: Int8 { 3 }
                var label: String {
                    @Verify get { title }
                    set { title = newValue }
                }
                @Verify
                func zero() -> Int8 { 0 }
                @Verify func greet(_ name: String?, times: Int = 1) -> String { name ?? "" }
                @Verify(over: .int(0...3)) func counted(_ n: Int) -> Int { n }
                @Verify func bump(_ x: inout Int8) -> Bool { true }
                @Verify
                func pick(
                    _ surface: Surface,
                    flag: Bool
                ) -> Bool { flag }
                @Verify func local(_ x: Int8) -> Int8 { var y = x; y += 1; return y }
                var count: Int {
                    @Verify(checks: .always) get { 1 }
                    set {}
                }
            }
            """, to: file)
        let found = BuildCheck.promises(in: [file])
        #expect(found.problems.isEmpty)
        let byName = Dictionary(found.promises.map { ($0.name, $0) }) { first, _ in first }
        #expect(
            found.promises.map(\.name).sorted() == ["body", "bump", "count", "counted", "greet", "label", "limit", "local", "pick", "zero"])
        #expect(byName["body"]?.declarationLine == 3 && byName["body"]?.firstLine == 2)
        #expect(byName["limit"]?.declarationLine == 7)
        #expect(byName["label"]?.firstLine == 8 && byName["label"]?.declarationLine == 9)
        for name in ["body", "limit", "label", "zero", "greet", "bump"] {
            #expect(byName[name].map { $0.walk == nil } == true, "\(name): \(String(describing: byName[name]?.walk))")
        }
        #expect(byName["counted"]?.walk == "verify_counted()")
        #expect(byName["pick"]?.walk == "verify_pick()")
        #expect(byName["local"]?.walk == "verify_local()", "a `var` in a function body is not a property")
        #expect(byName["count"]?.walk == nil && byName["count"]?.declarationLine == 24)
    }

    @Test func aBrokenPromiseIsAnErrorWithItsInputAndReplay() {
        let example = ScanCounterexample(
            inputs: ["price = 524288", "percent = 100"], result: nil, failure: "ensures failed",
            at: SourceLocation(file: "/p/Shop.swift", line: 7, column: 20), replay: "discounted(price: 524288, percent: 100)")
        let result = BuildCheck.evaluate(
            report([function("discounted(price:percent:)", .contractFails, line: 5, example: example)]),
            promises: [promise("discounted", .verify, line: 4)])
        #expect(!result.passed)
        #expect(result.broken == 1 && result.checked == 1)
        #expect(result.diagnostics.first?.hasPrefix("/p/Shop.swift:7:20: error: [SwiftFormal]") == true)
        #expect(result.diagnostics.first?.contains("when price = 524288, percent = 100") == true)
        #expect(result.diagnostics.contains { $0.contains(": note: [SwiftFormal] replay: discounted(") })
    }

    @Test func aTrapInsideMacroCodeIsShownAtTheFunction() {
        let example = ScanCounterexample(
            inputs: ["a = 1"], result: nil, failure: "overflow",
            at: SourceLocation(file: "/tmp/@__swiftmacro_4Shop7averageV.swift", line: 3, column: 1), replay: nil)
        let result = BuildCheck.evaluate(
            report([function("average(_:_:)", .mayTrap, line: 9, example: example)]),
            promises: [promise("average", .verify, line: 8)])
        #expect(result.diagnostics.first?.hasPrefix("/p/Shop.swift:9:6: error:") == true)
    }

    @Test func notProvedByLogicIsAWarningForVerifyAndAnErrorWithStrict() {
        let boxed = function("boxed(_:)", .unsupported, line: 21, category: "classes and objects")
        let asVerify = BuildCheck.evaluate(report([boxed]), promises: [promise("boxed", .verify, line: 20)])
        #expect(asVerify.passed && asVerify.unproved == 1)
        #expect(asVerify.diagnostics.first?.contains(": warning: [SwiftFormal] boxed(_:) is not proved") == true)
        #expect(asVerify.diagnostics.first?.contains("only a test can check it now, e.g. #expect(verify_boxed().isProved)") == true)

        let strict = BuildCheck.evaluate(
            report([boxed]), promises: [promise("boxed", .verify, line: 20)], strict: true)
        #expect(!strict.passed)
    }

    /// App study round 6, L8: an undecided function gives the reason Scan gave. "Within the budget" only for the budget;
    /// results logic does not model are named, with the fix hint, because a larger budget would not help.
    @Test func anUndecidedPromiseSaysWhetherTheBudgetOrAnUnmodelledResultStoppedIt() {
        var unmodelled = function("NumberPickerModel.selection.getter", .undecided, line: 12, contract: true)
        unmodelled.category = Verifier.unmodelledCategory
        unmodelled.detail = "can fail only for some results of String(stringInterpolation:); logic does not model what these return"
        unmodelled.hint = Verifier.hint(forCategory: Verifier.unmodelledCategory)
        var budget = function("Grid.cell(_:_:)", .undecided, line: 30, contract: true)
        budget.category = Verifier.budgetCategory
        budget.detail = "no answer within 300000 solver conflicts"
        budget.hint = Verifier.hint(forCategory: Verifier.budgetCategory)
        let result = BuildCheck.evaluate(report([unmodelled, budget]), promises: [])
        #expect(result.passed && result.unproved == 2)
        let first = result.diagnostics.first { $0.contains("selection") } ?? ""
        #expect(!first.contains("budget"), "\(first)")
        #expect(
            first.contains("String(stringInterpolation:)") && first.contains("fix: the answer depends on what these calls return"),
            "\(first)")
        let second = result.diagnostics.first { $0.contains("Grid.cell") } ?? ""
        #expect(second.contains("within the budget") && second.contains("fix: raise --budget"), "\(second)")
    }

    @Test func onlyFunctionsWithAPromiseOrAPairedContractAreChecked() {
        let result = BuildCheck.evaluate(
            report([
                function("next(_:)", .mayTrap, line: 30),
                function("Store.load(_:)", .unsupported, line: 40),
                function("Strokes.add(_:)", .contractHolds, line: 50, contract: true),
            ]),
            promises: [])
        #expect(result.passed && result.diagnostics.isEmpty)
        #expect(result.checked == 1 && result.proved == 1)
    }

    /// A peer `@Verify` wrote in a shape Scan cannot pair is reported (as macro code) and is an error.
    @Test func aContractScanCouldNotPairIsAnError() {
        var peer = function("Strokes.add_ensures(_:_:old:)", .safe, line: 70)
        peer.origin = "macro"
        let result = BuildCheck.evaluate(report([peer]), promises: [])
        #expect(!result.passed)
        #expect(result.diagnostics.first?.contains("Strokes.add_ensures(_:_:old:) checks nothing: no add in the same type") == true)
    }

    /// Only `@Verify`: a hand-written contract, paired or not, is an error that says to write it in place.
    @Test func aHandWrittenContractIsAnError() {
        var paired = function("wrong(_:)", .safe, line: 10)
        paired.ignoredContracts = ["wrong_ensures(_:_:)"]
        let result = BuildCheck.evaluate(
            report([
                paired, function("wrong_ensures(_:_:)", .safe, line: 11), function("Strokes.add_ensures(_:_:old:)", .safe, line: 70),
            ]), promises: [])
        #expect(!result.passed && result.proved == 0)
        #expect(result.diagnostics.count == 2, "\(result.diagnostics)")
        #expect(
            result.diagnostics[0].contains(
                "Shop.swift:10:6: error: [SwiftFormal] wrong(_:): contract not read: wrong_ensures(_:_:) is written by hand"))
        #expect(result.diagnostics.allSatisfy { $0.contains("write the contract in place with @Verify, #requires and #ensures") })
        #expect(result.diagnostics[1].contains("Strokes.add_ensures(_:_:old:) checks nothing: it is written by hand"))
    }

    @Test func aPromiseLogicNeverSawIsReported() {
        let result = BuildCheck.evaluate(
            report([]), promises: [promise("generic", .verify, line: 60)])
        #expect(result.passed && result.unproved == 1)
        #expect(result.diagnostics.first?.hasPrefix("/p/Shop.swift:61:1: warning:") == true)
    }

    @Test func findsTargetsWithPromisesAndSkipsTestsAndBuildFolders() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("@Verify\nfunc a() -> Int { 1 }\n", to: root + "/Sources/Shop/A.swift")
        try write("func plain() {}\n", to: root + "/Sources/Plain/P.swift")
        try write("@Verify\nfunc t() {}\n", to: root + "/Tests/ShopTests/T.swift")
        try write("@Verify\nfunc b() {}\n", to: root + "/.build/checkouts/x/Sources/X/B.swift")
        try write("// sf:verify\nfunc m() {}\n", to: root + "/Features/Cart/Sources/Cart/M.swift")
        let targets = BuildCheck.targets(under: root)
        #expect(targets.map(\.name) == ["Cart", "Shop"])
        #expect(BuildCheck.target(named: "Cart", under: root)?.files.count == 1)
        #expect(BuildCheck.target(named: "Missing", under: root) == nil)
    }

    @Test func theFingerprintChangesWhenASourceChanges() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/A.swift"
        try write("func a() {}\n", to: file)
        let before = BuildCheck.fingerprint(of: [file], salt: "strict=false")
        #expect(before == BuildCheck.fingerprint(of: [file], salt: "strict=false"))
        #expect(before != BuildCheck.fingerprint(of: [file], salt: "strict=true"))
        try write("func a() { _ = 1 }\n", to: file)
        #expect(before != BuildCheck.fingerprint(of: [file], salt: "strict=false"))
    }
}
