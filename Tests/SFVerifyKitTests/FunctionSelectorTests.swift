import Foundation
import SFVerifyKit
import Testing

/// `--at <file>:<line>` and `--symbol <name>`: exactly one function, or an error; never "nothing to prove".
@Suite struct FunctionSelectorTests {
    /// Debug locations as the compiler puts them: the name of a `func`, the `{` of a computed property, `get`/`set`.
    private static let source = """
        import Foundation

        struct Score {
            var value: Int

            /// Clamps.
            @inlinable
            func clamp(_ x: Int) -> Int {
                let text = "}"  // a brace in a string } and a comment
                /* { */
                if x < 0 { return 0 }
                return x
            }

            var doubled: Int {
                value * 2
            }

            func outer(_ x: Int) -> Int {
                func inner(_ y: Int) -> Int {
                    y + 1
                }
                return inner(x)
            }

            func clamp_requires(_ x: Int) -> Bool { x < 100 }

            func spread(
                _ x: Int,
                by y: Int
            ) throws -> Int
            {
                x + y
            }
        }

        class Cache {
            var hits = 0

            // MARK: lifetime

            deinit {
                hits = 0
            }

            struct Entry {
                var key: Int

            }

            func lookup() -> () -> Int {
                let read = { [hits] in
                    hits + 1
                }
                return read
            }
        }

        final class HotCache: Cache {}
        """

    private static func candidates(_ file: String) -> [FunctionSelector.Candidate] {
        func at(_ line: Int, _ column: Int) -> SFVerifyKit.SourceLocation { SourceLocation(file: file, line: line, column: column) }
        return [
            .init(name: "Score.clamp(_:)", location: at(8, 10), isSpec: false),
            .init(name: "Score.doubled.getter", location: at(15, 22), isSpec: false),
            .init(name: "Score.outer(_:)", location: at(19, 10), isSpec: false),
            .init(name: "inner #1 (_:) in Score.outer(_:)", location: at(20, 14), isSpec: false),
            .init(name: "Score.clamp_requires(_:)", location: at(26, 10), isSpec: true),
            .init(name: "Score.spread(_:by:)", location: at(28, 10), isSpec: false),
            .init(name: "Score.value.getter", location: at(4, 9), isSpec: false),
            .init(name: "Score.value.setter", location: at(4, 9), isSpec: false),
            // Written by the compiler, placed at the type's name or, for an inherited init, at its `{`.
            .init(name: "Score.init(value:)", location: at(3, 8), isSpec: false),
            .init(name: "Cache.__allocating_init()", location: at(37, 7), isSpec: false),
            .init(name: "Cache.Entry.init(key:)", location: at(46, 12), isSpec: false),
            .init(name: "HotCache.__allocating_init()", location: at(59, 29), isSpec: false),
            .init(name: "HotCache.deinit", location: at(59, 13), isSpec: false),
            .init(name: "Cache.deinit", location: at(42, 5), isSpec: false),
            .init(name: "Cache.lookup()", location: at(51, 10), isSpec: false),
        ]
    }

    private func sourceFile() throws -> String {
        let file = NSTemporaryDirectory() + "sfsel-\(UUID().uuidString).swift"
        try Self.source.write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    private func selected(_ file: String, line: Int) throws -> [String] {
        let candidates = Self.candidates(file)
        return try FunctionSelector.at(file: file, line: line).resolve(candidates, module: "App").map { candidates[$0].name }
    }

    @Test func aLineInsideABodyOnTheDeclarationOrOnItsAttributesSelectsThatFunction() throws {
        let file = try sourceFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        for line in [6, 7, 8, 9, 10, 11, 13] { #expect(try selected(file, line: line) == ["Score.clamp(_:)"], "line \(line)") }
        for line in [15, 16, 17] { #expect(try selected(file, line: line) == ["Score.doubled.getter"], "line \(line)") }
        for line in [28, 30, 31, 32, 33] { #expect(try selected(file, line: line) == ["Score.spread(_:by:)"], "line \(line)") }
    }

    /// A memberwise or inherited init is placed at its type, but its body is not the type's: a line in a type that no
    /// function's body holds is no function's, and the type's own line is the init's.
    @Test func aFunctionTheCompilerWritesCoversOnlyItsTypesLine() throws {
        let file = try sourceFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        for line in [5, 18, 35, 36, 38, 39, 40, 41, 45, 48, 49, 50, 57, 58] {
            let error = #expect(throws: ScanUsageError.self, "line \(line)") { try selected(file, line: line) }
            #expect(error?.description.contains("no function of App") == true, "line \(line): \(String(describing: error))")
        }
        #expect(try selected(file, line: 3) == ["Score.init(value:)"])
        #expect(try selected(file, line: 37) == ["Cache.__allocating_init()"])
        #expect(try selected(file, line: 46) == ["Cache.Entry.init(key:)"])
        #expect(throws: ScanUsageError.self) { try selected(file, line: 59) }
        for line in [42, 43, 44] { #expect(try selected(file, line: line) == ["Cache.deinit"], "line \(line)") }
        for line in [51, 52, 53, 54, 55, 56] { #expect(try selected(file, line: line) == ["Cache.lookup()"], "line \(line)") }
    }

    /// `struct` after `import`, or `actor` as a name, declares no type: the function's body is found as usual.
    @Test func aTypeKeywordThatDeclaresNoTypeKeepsTheBody() throws {
        let source = """
            import struct Foundation.Date

            func stamp(_ d: Date) -> Int {
                let actor = 1
                let k = { [actor] in
                    actor + 1
                }
                return k()
            }
            """
        let file = NSTemporaryDirectory() + "sfsel-\(UUID().uuidString).swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        let candidates: [FunctionSelector.Candidate] = [
            .init(name: "stamp(_:)", location: SFVerifyKit.SourceLocation(file: file, line: 3, column: 6), isSpec: false),
            .init(
                name: "closure #1 in stamp(_:)", location: SFVerifyKit.SourceLocation(file: file, line: 5, column: 13), isSpec: false),
        ]
        func names(_ line: Int) throws -> [String] {
            try FunctionSelector.at(file: file, line: line).resolve(candidates, module: "App").map { candidates[$0].name }
        }
        for line in [3, 4, 8, 9] { #expect(try names(line) == ["stamp(_:)"], "line \(line)") }
        for line in [5, 6, 7] { #expect(try names(line) == ["closure #1 in stamp(_:)"], "line \(line)") }
    }

    @Test func theInnermostFunctionWins() throws {
        let file = try sourceFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        #expect(try selected(file, line: 21) == ["inner #1 (_:) in Score.outer(_:)"])
        #expect(try selected(file, line: 23) == ["Score.outer(_:)"])
    }

    @Test func aLineNoFunctionCoversAContractOrATieIsAnError() throws {
        let file = try sourceFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        #expect(throws: ScanUsageError.self) { try selected(file, line: 2) }
        #expect(throws: ScanUsageError.self) { try selected(file, line: 18) }
        let contract = #expect(throws: ScanUsageError.self) { try selected(file, line: 26) }
        #expect(contract?.description.contains("select Score.clamp instead") == true, "\(String(describing: contract))")
        let tie = #expect(throws: ScanUsageError.self) { try selected(file, line: 4) }
        #expect(tie?.description.contains("2 functions fit") == true, "\(String(describing: tie))")
        // A file of another module: no function here, which is not an error for this module.
        let other = Self.candidates("/elsewhere/Score.swift")
        #expect(try FunctionSelector.at(file: file, line: 9).resolve(other, module: "App").isEmpty)
    }

    @Test func aSymbolNamesOneFunctionExactlyOrByTypeMemberAndLabels() throws {
        let candidates =
            Self.candidates("/x/Score.swift") + [
                .init(name: "static Score.make(_:)", location: nil, isSpec: false),
                .init(name: "Score.make(_:using:)", location: nil, isSpec: false),
                .init(
                    name: "Box.map<A>(_:)", location: SFVerifyKit.SourceLocation(file: "/x/Box.swift", line: 3, column: 1), isSpec: false),
                .init(
                    name: "Box.map<A>(_:)", location: SFVerifyKit.SourceLocation(file: "/x/Box.swift", line: 3, column: 1), isSpec: false),
            ]
        func names(_ symbol: String) throws -> [String] {
            try FunctionSelector.symbol(symbol).resolve(candidates, module: "App").map { candidates[$0].name }
        }
        #expect(try names("Score.clamp(_:)") == ["Score.clamp(_:)"])
        #expect(try names("Score.clamp") == ["Score.clamp(_:)"])
        #expect(try names("Score.make(_:)") == ["static Score.make(_:)"])
        #expect(try names("Score.make(_:using:)") == ["Score.make(_:using:)"])
        #expect(try names("Score.doubled") == ["Score.doubled.getter"])
        #expect(try names("Box.map(_:)") == ["Box.map<A>(_:)", "Box.map<A>(_:)"], "two copies of one function are one")
        #expect(try names("Score.missing").isEmpty)
        #expect(throws: ScanUsageError.self) { try names("Score.make") }
        #expect(throws: ScanUsageError.self) { try names("Score.value") }
        #expect(throws: ScanUsageError.self) { try names("Score.clamp_requires(_:)") }
    }

    @Test func atNeedsAFileAndALine() throws {
        let file = try sourceFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        #expect(try FunctionSelector(at: file + ":12") == .at(file: file, line: 12))
        #expect(try FunctionSelector(at: file + ":12:5") == .at(file: file, line: 12))
        #expect(throws: ScanUsageError.self) { try FunctionSelector(at: file) }
        #expect(throws: ScanUsageError.self) { try FunctionSelector(at: file + ":0") }
        #expect(throws: ScanUsageError.self) { try FunctionSelector(at: "/no/such/File.swift:3") }
    }

    // MARK: walks

    private func scan(_ selected: [String], unselected: [String]) throws -> ScanReport {
        let functions = try selected.map { name in
            let json = #"{"name":"\#(name)","symbol":"s","status":"safe","hasContract":false,"seconds":0}"#
            return try JSONDecoder().decode(FunctionReport.self, from: Data(json.utf8))
        }
        let timing = try JSONDecoder().decode(
            ScanReport.Timing.self, from: Data(#"{"compileSeconds":0,"parseSeconds":0,"verifySeconds":0,"silBytes":0}"#.utf8))
        var report = ScanReport(module: "App", optimization: "-Onone", functions: functions, timing: timing)
        report.unselected = unselected.map { ScanReport.UnselectedFunction(name: $0, location: nil) }
        return report
    }

    /// `text(for:)` exists, so a walk over it is not the defaulted call `text(for:style:)` makes, whether or not
    /// `text(for:)` was selected: linking to `text(for:style:)` would count that walk as its proof.
    @Test func aWalkLinksToTheSameOverloadWhicheverFunctionIsSelected() throws {
        let walk = WalkCheck(subject: "Formatter.text(for:)", file: "/t/AppTests.swift", line: 1, suite: "AppTests", test: "t")
        let all = try scan(["Formatter.text(for:style:)", "Formatter.text(for:)"], unselected: [])
        let selected = try scan(["Formatter.text(for:style:)"], unselected: ["Formatter.text(for:)"])
        let plan = Check.plan(scans: [selected], walks: [walk])
        #expect(plan.run.isEmpty)
        #expect(plan.unlinked.isEmpty)
        #expect(plan.notSelected == [0])
        let merged = Check.merge(scans: [selected], plan: plan, records: [], knownIssues: [])
        #expect(merged.entries.map(\.function.name) == ["Formatter.text(for:style:)"])
        #expect(merged.entries[0].walks.isEmpty)
        #expect(Check.plan(scans: [all], walks: [walk]).run == [0], "without a selector the walk runs for text(for:)")
    }
}

// MARK: end to end

extension FunctionSelectorTests {
    private static let module = """
        public func absA(_ x: Int8) -> Int8 {
            if x < 0 { return -x }
            return x
        }
        public func safeAdd(_ a: Int8, _ b: Int8) -> Int8 { a &+ b }
        public func clamp(_ x: Int8, _ lo: Int8, _ hi: Int8) -> Int8 {
            if x < lo { return lo }
            if x > hi { return hi }
            return x
        }
        #sourceLocation(file: "@__swiftmacro_3App5clamp6VerifyfMp_.swift", line: 1)
        public func clamp_requires(_ x: Int8, _ lo: Int8, _ hi: Int8) -> Bool { lo <= hi }
        public func clamp_ensures(_ x: Int8, _ lo: Int8, _ hi: Int8, _ r: Int8) -> Bool { r >= lo && r <= hi }
        #sourceLocation()
        """

    private func run(_ selector: (String) -> FunctionSelector) throws -> ScanReport {
        let dir = NSTemporaryDirectory() + "sfsel-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/demo.swift"
        try Self.module.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.selector = selector(file)
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Demo"), options)
    }

    /// `check` goes on only when exactly one scanned module holds the function; otherwise a usage error, thrown (not an
    /// exit) so that the command stops the tests it is building in the background first.
    @Test func checkNeedsTheSelectedFunctionInExactlyOneModule() throws {
        let abs = try run { .at(file: $0, line: 2) }
        let none = try run { _ in .symbol("missing") }
        #expect(throws: Never.self) { try Check.requireOneSelected([abs, none], by: .symbol("absA")) }
        let missing = #expect(throws: ScanUsageError.self) { try Check.requireOneSelected([none], by: .symbol("missing")) }
        #expect(missing?.description == "--symbol missing: no function of Demo that Scan verifies is there")
        let two = #expect(throws: ScanUsageError.self) { try Check.requireOneSelected([abs, abs], by: .symbol("absA")) }
        #expect(two?.description.contains("2 functions fit: absA(_:) in Demo, absA(_:) in Demo") == true)
    }

    @Test func scanVerifiesOnlyTheSelectedFunctionAndKeepsTheOthersAsInventory() throws {
        let abs = try run { .at(file: $0, line: 2) }
        #expect(abs.functions.map(\.name) == ["absA(_:)"])
        #expect(abs.functions.first?.status == .mayTrap)
        #expect(abs.selection?.function == "absA(_:)")
        #expect(Set(abs.unselected.map(\.name)) == ["safeAdd(_:_:)", "clamp(_:_:_:)"])
        #expect(abs.configurations == ["debug", "release"])
        #expect(try abs.json().contains(#""selection""#))

        let clamp = try run { _ in .symbol("clamp") }
        #expect(clamp.functions.map(\.name) == ["clamp(_:_:_:)"])
        #expect(clamp.functions.first?.status == .contractHolds, "the contract is still paired")

        let none = try run { _ in .symbol("nowhere") }
        #expect(none.functions.isEmpty)
        #expect(none.selection?.function == nil)
        #expect(none.unselected.count == 3)
        #expect(throws: ScanUsageError.self) { try run { .at(file: $0, line: 11) } }
    }

    /// `ratio` divides by zero only in a release build (the assert that sets `y` is gone). Its debug location is another
    /// file (`#sourceLocation`), so `--at` that file is not a file of the module: it must not select `ratio` and then
    /// verify it in the debug build alone while the report says both builds.
    @Test func atSelectsOnlyInTheModulesFilesAndReportsTheBuildsItCompiled() throws {
        let dir = NSTemporaryDirectory() + "sfsel-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let generated = dir + "/ratio.swift.gyb"
        let ratio = """
            public func ratio(_ x: Int8) -> Int8 {
                var y: Int8 = 0
                assert(arm(&y))
                return x / y
            }
            """
        try ratio.write(toFile: generated, atomically: true, encoding: .utf8)
        let file = dir + "/ratio.swift"
        let source = """
            func arm(_ y: inout Int8) -> Bool {
                y = 1
                return true
            }
            #sourceLocation(file: "\(generated)", line: 1)
            \(ratio)
            #sourceLocation()
            """
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        func scan(_ selector: FunctionSelector) throws -> ScanReport {
            var options = VerifyOptions()
            options.selector = selector
            return try SFVerify.run(CompileOptions(files: [file], moduleName: "Ratio"), options)
        }
        let atGenerated = try scan(.at(file: generated, line: 4))
        #expect(atGenerated.selection?.function == nil)
        #expect(atGenerated.functions.isEmpty)
        #expect(atGenerated.configurations == ["debug"], "only the debug build was compiled")
        let bySymbol = try scan(.symbol("ratio"))
        #expect(bySymbol.functions.map(\.status) == [.mayTrap])
        #expect(bySymbol.configurations == ["debug", "release"])
    }
}
