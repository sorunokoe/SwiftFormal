import Foundation
import Testing
import SFVerifyKit

/// The `sfverify` pipeline end to end on real `swiftc` output: compile, locate, prove or refute, report.
private enum VerifyFixture {
    static let source = """
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
        public func bad(_ x: UInt8) -> UInt8 { x &+ 1 }
        #sourceLocation(file: "@__swiftmacro_3App3bad6VerifyfMp_.swift", line: 1)
        public func bad_ensures(_ x: UInt8, _ r: UInt8) -> Bool { r > x }
        #sourceLocation()
        public struct Counter { public var value: UInt8 }
        extension Counter {
            public struct Step { public var by: UInt8 }
            public func advanced(_ s: Step) -> UInt8 { value &+ s.by }
        }
        public func greet(_ name: String) -> String { "hi " + name }
        """

    static func run(
        _ source: String = source, alsoFiles: [String] = [], extra: [String] = [], options: VerifyOptions = VerifyOptions()
    ) throws -> ScanReport {
        let dir = NSTemporaryDirectory() + "sfv-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var files: [String] = []
        for (index, text) in ([source] + alsoFiles).enumerated() {
            files.append(dir + (index == 0 ? "/demo.swift" : "/demo\(index).swift"))
            try text.write(toFile: files[index], atomically: true, encoding: .utf8)
        }
        return try SFVerify.run(CompileOptions(files: files, moduleName: "Demo", extraArguments: extra), options)
    }
}

@Suite struct SFVerifyTests {
    @Test func findsTrapsProvesSafetyAndChecksContracts() throws {
        let report = try VerifyFixture.run()
        func fn(_ name: String) throws -> FunctionReport {
            try #require(report.functions.first { $0.name.hasPrefix(name + "(") })
        }

        let abs = try fn("absA")
        #expect(abs.status == .mayTrap)
        #expect(abs.counterexample?.inputs == ["x = -128"])
        #expect(abs.counterexample?.at?.line == 2)
        #expect(abs.counterexample?.replay == "absA(-128)")

        #expect(try fn("safeAdd").status == .safe)
        #expect(try fn("clamp").status == .contractHolds)

        let bad = try fn("bad")
        #expect(bad.status == .contractFails)
        #expect(bad.counterexample?.inputs == ["x = 255"])

        #expect(try fn("greet").status == .safe)
        #expect(report.functions.allSatisfy { $0.seconds > 0 }, "every function reports the time it took")
        #expect(!report.functions.contains { $0.name.hasPrefix("clamp_requires") || $0.name.hasPrefix("bad_ensures") })
        #expect(report.hasFailures)
    }

    @Test func aRejectedClassIsCountedAsAClassNotAGeneric() throws {
        let report = try VerifyFixture.run(
            """
            public class Box { public var n: Int8 = 0 }
            public func same(_ b: Box) -> Box { b }
            """)
        let same = try #require(report.functions.first { $0.name.hasPrefix("same(") })
        #expect(same.status == .unsupported)
        #expect(same.category == "classes and objects", "\(same.detail ?? "")")
    }

    @Test func aSomeViewBodyIsNotCountedAsAClosure() throws {
        let report = try VerifyFixture.run(
            """
            import SwiftUI
            public struct Hello: View { public var body: some View { Text("hi") } }
            """)
        let body = try #require(report.functions.first { $0.name == "Hello.body.getter" })
        #expect(body.category == "opaque result types (some …)", "\(body.detail ?? "")")
    }

    /// SIL prints both private `Row`s as `Row`. Picking either layout for both once proved `fa` safe although
    /// `fa(127)` overflows (the fields are in a different order).
    @Test func typesThatShareANameAreNeverGuessed() throws {
        let report = try VerifyFixture.run(
            """
            private struct Row { var a: Int8; var b: Int8 }
            func fa(_ x: Int8) -> Int8 { Row(a: x, b: 0).a + 1 }
            """,
            alsoFiles: [
                """
                private struct Row { var b: Int8; var a: Int8 }
                func fb(_ x: Int8) -> Int8 { Row(b: 0, a: x).a }
                """
            ])
        for name in ["fa(", "fb("] {
            let f = try #require(report.functions.first { $0.name.hasPrefix(name) })
            #expect(f.status == .unsupported, "\(name) \(f.status)")
            #expect(f.category == "ambiguous type names", "\(f.detail ?? "")")
        }
    }

    /// `App` imports `Core`. Linked, Core's types, conformances and bodies are known; a name both declare is refused.
    /// Not linked, the clash is still found (by asking the compiler) and Core's types stay unknown. SIL keeps the
    /// attributes and access level of an import; a spelling the parser skipped once left Core unlinked and unchecked.
    @Test(arguments: ["import Core", "public import Core", "package import Core", "@preconcurrency internal import Core"])
    func importedModulesOfTheSameBuildAreLinked(_ importLine: String) throws {
        let dir = NSTemporaryDirectory() + "sfv-link-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let core = dir + "/Core.swift"
        let app = dir + "/App.swift"
        try """
        public struct Score { public var strokes: Int8; public var par: Int8 }
        public enum Load<T> { case idle, loaded(T), failed(code: Int8) }
        public enum Mode: Equatable { case stroke, match }
        public struct Shared { public var x: Int8 }
        public func toPar(_ s: Score) -> Int8 { s.strokes - s.par }
        """.write(toFile: core, atomically: true, encoding: .utf8)
        try """
        \(importLine)
        struct Shared { var y: Int8 }
        func overPar(_ s: Score) -> Int8 { toPar(s) }
        func value(_ l: Load<Int8>) -> Int8 { if case .loaded(let v) = l { return v } else { return 0 } }
        func isMatch(_ m: Mode) -> Bool { m == .match }
        func sharedY(_ v: Int8) -> Int8 { Shared(y: v).y }
        """.write(toFile: app, atomically: true, encoding: .utf8)
        let module = Process()
        module.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        module.arguments = [
            "swiftc", "-emit-module", "-parse-as-library", "-module-name", "Core", "-package-name", "SFV", core,
            "-emit-module-path", dir + "/Core.swiftmodule",
        ]
        try module.run()
        module.waitUntilExit()
        try #require(module.terminationStatus == 0)

        let options = CompileOptions(files: [app], moduleName: "App", extraArguments: ["-I", dir, "-package-name", "SFV"])
        func status(_ report: ScanReport, _ name: String) throws -> FunctionReport {
            try #require(report.functions.first { $0.name.hasPrefix(name + "(") })
        }
        let linked = try SFVerify.run(options, linking: { $0 == "Core" ? CompileOptions(files: [core], moduleName: "Core") : nil })
        #expect(try status(linked, "overPar").status == .mayTrap)
        #expect(try status(linked, "value").status == .safe)
        #expect(try status(linked, "isMatch").status == .safe)
        #expect(try status(linked, "sharedY").category == "ambiguous type names")

        let alone = try SFVerify.run(options)
        #expect(try status(alone, "overPar").status == .unsupported)
        #expect(try status(alone, "sharedY").category == "ambiguous type names")
    }

    @Test func structsNestedInExtensionsAreModelled() throws {
        let report = try VerifyFixture.run()
        let advanced = try #require(report.functions.first { $0.name.contains("advanced") })
        #expect(advanced.status == .safe)
    }

    @Test func extensionsOnTypesFromOtherModulesAreScanned() throws {
        let report = try VerifyFixture.run(
            """
            extension Int8 {
                public func halved() -> Int8 { self / 2 }
                public func negated() -> Int8 { -self }
            }
            """)
        #expect(report.functions.first { $0.name.hasPrefix("Int8.halved(") }?.status == .safe)
        #expect(report.functions.first { $0.name.hasPrefix("Int8.negated(") }?.counterexample?.inputs == ["self = -128"])
    }

    @Test func reportRoundTripsThroughJSON() throws {
        let report = try VerifyFixture.run()
        let decoded = try JSONDecoder().decode(ScanReport.self, from: Data(report.json().utf8))
        #expect(decoded.functions.count == report.functions.count)
        #expect(decoded.summary.contractFails == 1)
        #expect(report.diagnostics().contains("demo.swift:2:"))
    }

    @Test func solverCountsAppearOnlyWhenAskedForAndAreExact() throws {
        let plain = try VerifyFixture.run()
        #expect(plain.functions.allSatisfy { $0.solverConflicts == nil && $0.cnfVariables == nil && $0.cnfClauses == nil })
        #expect(!(try plain.json().contains("cnfClauses")))

        var options = VerifyOptions()
        options.collectStats = true
        let first = try VerifyFixture.run(options: options)
        let second = try VerifyFixture.run(options: options)
        let proved = try #require(first.functions.first { $0.name.hasPrefix("safeAdd(") })
        #expect(proved.status == .safe)
        #expect((proved.cnfVariables ?? 0) > 0 && (proved.cnfClauses ?? 0) > 0)
        #expect(first.functions.map(\.status) == plain.functions.map(\.status))
        let counts = { (r: ScanReport) in r.functions.map { [$0.name: [$0.solverConflicts, $0.cnfVariables, $0.cnfClauses]] } }
        #expect(counts(first) == counts(second))
    }

    /// Frozen from a `--stats` report of schema version 1. A renamed or dropped key makes decoding fail; docs/schemas/scan-report.schema.json
    /// closes the same set of keys, and `Scripts/metrics.py` validates real output against it.
    @Test func aFrozenSchemaVersion1ReportStillDecodes() throws {
        let frozen = """
            {"schemaVersion": 1, "module": "Demo", "optimization": "-Onone",
             "summary": {"total": 2, "safe": 0, "mayTrap": 1, "contractHolds": 0, "contractFails": 0, "undecided": 0,
                         "unsupported": 1, "internalErrors": 0, "compilerGenerated": 0, "unsupportedByCategory": {"strings": 1}},
             "timing": {"compileSeconds": 0.5, "parseSeconds": 0.1, "verifySeconds": 0.2, "silBytes": 1024},
             "functions": [
               {"name": "absA(_:)", "symbol": "$s4Demo4absAys4Int8VADF", "status": "mayTrap", "hasContract": false, "seconds": 0,
                "location": {"file": "demo.swift", "line": 1, "column": 13},
                "solverConflicts": 3, "cnfVariables": 120, "cnfClauses": 400,
                "counterexample": {"inputs": ["x = -128"], "result": "-128", "failure": "arithmetic overflow",
                                   "at": {"file": "demo.swift", "line": 2, "column": 30}, "replay": "absA(-128)"}},
               {"name": "greet(_:)", "symbol": "$s4Demo5greetyS2SF", "status": "unsupported", "hasContract": false, "seconds": 0,
                "category": "strings", "detail": "UNSUPPORTED: type String"}]}
            """
        let report = try JSONDecoder().decode(ScanReport.self, from: Data(frozen.utf8))
        #expect(report.schemaVersion == 1)
        #expect(report.summary.unsupportedByCategory == ["strings": 1])
        #expect(report.timing.silBytes == 1024)
        let absA = try #require(report.functions.first)
        #expect(absA.status == .mayTrap && absA.solverConflicts == 3 && absA.cnfVariables == 120 && absA.cnfClauses == 400)
        #expect(absA.counterexample?.replay == "absA(-128)" && absA.counterexample?.at?.line == 2)
        #expect(report.functions[1].category == "strings")

        let encoded = try #require(JSONSerialization.jsonObject(with: Data(report.json().utf8)) as? [String: Any])
        let original = try #require(JSONSerialization.jsonObject(with: Data(frozen.utf8)) as? [String: Any])
        #expect(Set(encoded.keys) == Set(original.keys))
        let encodedFunctions = try #require(encoded["functions"] as? [[String: Any]])
        let originalFunctions = try #require(original["functions"] as? [[String: Any]])
        #expect(zip(encodedFunctions, originalFunctions).allSatisfy { Set($0.keys) == Set($1.keys) })
    }

    /// SIL prints `ObservationStateRegistrar` without its module. Logic reads TCA's state registrar only when the
    /// compiler confirms that the bare name means `ComposableArchitecture.ObservationStateRegistrar`; a second imported
    /// module that declares the same name makes it ambiguous, and nothing that touches it is read.
    @Test func aPackageTypeIsReadOnlyWhenTheCompilerConfirmsItsName() throws {
        let dir = NSTemporaryDirectory() + "sfv-tca-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func stub(_ name: String, _ source: String) throws {
            try source.write(toFile: "\(dir)/\(name).swift", atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "swiftc", "-emit-module", "-parse-as-library", "-module-name", name, "-emit-module-path", "\(dir)/\(name).swiftmodule",
                "\(dir)/\(name).swift",
            ]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, "stub \(name)")
        }
        try stub(
            "ComposableArchitecture",
            """
            import Observation
            public struct ObservableStateID: Hashable, Sendable { public init() {} }
            public final class PerceptionRegistrar: @unchecked Sendable { public init() {} }
            public struct ObservationStateRegistrar: Sendable {
                public private(set) var id = ObservableStateID()
                @usableFromInline let registrar = PerceptionRegistrar()
                public init() {}
                public func access<Subject: Observable, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {}
            }
            """)
        try stub("Other", "public struct ObservationStateRegistrar { public var n: Int8 = 0 }")

        func run(_ imports: String) throws -> [String: FunctionReport] {
            let report = try VerifyFixture.run(
                imports + """

                    import Observation
                    public struct Counter: Observable {
                        var _count: Int8 = 0
                        var _$observationRegistrar = ComposableArchitecture.ObservationStateRegistrar()
                        public var count: Int8 { _$observationRegistrar.access(self, keyPath: \\.count); return _count }
                    }
                    public func next(_ s: Counter) -> Int8 { s.count + 1 }
                    """, extra: ["-I", dir])
            return Dictionary(report.functions.map { ($0.name, $0) }) { a, _ in a }
        }
        let confirmed = try run("import ComposableArchitecture")
        let next = try #require(confirmed["next(_:)"], "\(confirmed.keys.sorted())")
        #expect(next.status == .mayTrap, "\(next.detail ?? "")")
        #expect(confirmed["Counter.count.getter"]?.status == .safe, "\(confirmed["Counter.count.getter"]?.detail ?? "")")

        let clash = try run("import ComposableArchitecture\nimport Other")
        let blocked = try #require(clash["next(_:)"])
        #expect(blocked.status == .unsupported && blocked.detail?.contains("ObservationStateRegistrar") == true, "\(blocked.detail ?? "")")
    }

    @Test func compilerFlagsAreSplitLikeAShellAndFilteredForTheFrontend() {
        let line =
            #"/x/swiftc -parse-as-library -module-name M -Onone -DFOO -enable-experimental-feature AvailabilityMacro=A\ 1:\ B -j8 -o /tmp/o -package-name pkg 'a b.swift'"#
        let tokens = SwiftPMBuild.tokenize(line)
        #expect(tokens.contains("AvailabilityMacro=A 1: B"))
        #expect(tokens.contains("a b.swift"))
        let kept = SwiftPMBuild.filter(Array(tokens.dropFirst()))
        #expect(kept.contains("-DFOO") && kept.contains("-package-name"))
        #expect(!kept.contains("-module-name") && !kept.contains("-Onone") && !kept.contains("-o") && !kept.contains("-j8"))
    }

    /// The scan compiles inside the developer's `.build`; writing into the build's module caches made the next
    /// `swift build` recompile the target, so those flags are dropped (the scan adds a cache of its own).
    @Test func aGateLineInsertedInTheMiddleOfTheCompileCommandIsRemoved() throws {
        let log =
            "/x/swiftc -module-name M -DFOO -serialisfverify: gate passed: 1 of 1 gated functions proved (5 ms)\nze-diagnostics -package-name pkg a.swift\n"
        let command = try #require(SwiftPMBuild.compileCommand(in: log, module: "M"))
        #expect(command == ["-module-name", "M", "-DFOO", "-serialize-diagnostics", "-package-name", "pkg", "a.swift"])
    }
}

extension SFVerifyTests {
    @Test func theBuildsModuleCachesAreNotShared() {
        let tokens = SwiftPMBuild.tokenize(
            "-module-cache-path /b/ModuleCache.noindex -DFOO -clang-build-session-file /b/Session -validate-clang-modules-once "
                + "-sdk-module-cache-path /b/SDK -clang-scanner-module-cache-path /b/Scan -package-name pkg")
        #expect(SwiftPMBuild.filter(tokens) == ["-DFOO", "-package-name", "pkg"])
    }

    @Test func aStringEqualsItself() throws {
        let report = try VerifyFixture.run(
            """
            public func itself(_ s: String, _ x: Int8) -> Int8 { s == s ? x : x + 1 }
            public func copied(_ s: String, _ x: Int8) -> Int8 { let t = s; return t == s ? x : x + 1 }
            public func another(_ s: String, _ t: String, _ x: Int8) -> Int8 { s == t ? x : x + 1 }
            """)
        func fn(_ name: String) throws -> FunctionReport { try #require(report.functions.first { $0.name.hasPrefix(name + "(") }) }
        #expect(try fn("itself").status == .safe)
        #expect(try fn("copied").status == .safe)
        // Two strings may differ: a real bug, shown with two different texts that reproduce it.
        let another = try fn("another")
        #expect(another.status == .mayTrap)
        let inputs = another.counterexample?.inputs ?? []
        #expect(inputs.count == 3 && inputs[0].dropFirst(4) != inputs[1].dropFirst(4) && inputs[2] == "x = 127", "\(inputs)")
        #expect(another.counterexample?.replay?.hasPrefix("another(\"") == true, "\(another.counterexample?.replay ?? "")")
    }

    @Test func aStaticStoredPropertyIsNotAField() throws {
        let report = try VerifyFixture.run(
            """
            struct Helper { var k: Int8 = 3 }
            struct Pair {
                private static let helper = Helper()
                var a: Int8
                var b: Int8
            }
            func make(_ x: Int8) -> Int8 {
                let p = Pair(a: x, b: 1)
                return p.b == 1 ? 0 : x + 127
            }
            """)
        let make = try #require(report.functions.first { $0.name.hasPrefix("make(") })
        #expect(make.status == .safe, "\(make.detail ?? "")")
    }
}

extension SFVerifyTests {
    @Test func textIsCheckedExactlyAndShownAsText() throws {
        let report = try VerifyFixture.run(
            """
            public enum Surface { case grass, sand, water }
            public func label(_ surface: Surface) -> String { switch surface { case .grass: "Grass"; case .sand: "Sand"; case .water: "" } }
            public func unit(_ metric: Bool) -> String { metric ? "Celsius" : "Fahrenheit" }
            public func joined(_ a: String, _ b: String) -> String { a + b }
            #sourceLocation(file: "@__swiftmacro_3App5label6VerifyfMp_.swift", line: 1)
            public func label_ensures(_ surface: Surface, _ text: String) -> Bool { !text.isEmpty }
            public func unit_ensures(_ metric: Bool, _ text: String) -> Bool { text == (metric ? "Celsius" : "Fahrenheit") && text.count > 6 }
            public func joined_ensures(_ a: String, _ b: String, _ r: String) -> Bool { r.isEmpty == (a.isEmpty && b.isEmpty) }
            #sourceLocation()
            public func onlyIfEqual(_ s: String, _ x: Int8) -> Int8 { s == "go" ? x + 1 : x }
            public func onlyIfLong(_ s: String, _ x: Int8) -> Int8 { s.count > 3 ? x + 1 : x }
            """)
        func fn(_ name: String) throws -> FunctionReport { try #require(report.functions.first { $0.name.hasPrefix(name + "(") }) }
        let label = try fn("label")
        #expect(label.status == .contractFails)
        #expect(label.counterexample?.inputs == ["surface = .water"])
        #expect(label.counterexample?.result == #""""#)
        #expect(try fn("unit").status == .contractHolds)
        #expect(try fn("joined").status == .contractHolds)
        let equal = try fn("onlyIfEqual")
        #expect(equal.status == .mayTrap)
        #expect(equal.counterexample?.inputs == [#"s = "go""#, "x = 127"])
        #expect(equal.counterexample?.replay == #"onlyIfEqual("go", 127)"#)
        // The length of a string that is not a literal is not modelled: never a false bug.
        let long = try fn("onlyIfLong")
        #expect(long.status == .undecided)
        #expect(long.detail?.contains("String.count") == true, "\(long.detail ?? "")")
    }
}
