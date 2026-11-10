import Foundation
import SFSIL
import Testing

@testable import SFVerifyKit

/// Plan items D4, S5, X6: Scan's proof cache. A function's answer comes from the cache only while everything its claim
/// is made from is unchanged; a cached answer still goes through everything after the solve; an entry that is not
/// the user's own, or that does not replay, is never used.
@Suite struct ScanProofCacheTests {
    static let source = """
        func helper(_ x: Int8) -> Int8 { x &+ 1 }
        func other(_ x: Int8) -> Int8 { x &- 1 }
        func bound(_ x: Int8) -> Bool { x < 100 }
        func f(_ x: Int8) -> Int8 { helper(x) }
        #sourceLocation(file: "@__swiftmacro_3App1f6VerifyfMp_.swift", line: 1)
        func f_requires(_ x: Int8) -> Bool { bound(x) }
        func f_ensures(_ x: Int8, _ r: Int8) -> Bool { r != x }
        #sourceLocation()
        func g(_ x: Int8) -> Int8 { other(x) }
        func traps(_ x: Int8) -> Int8 { x + 1 }
        func broken(_ x: UInt8) -> UInt8 { x &+ 1 }
        #sourceLocation(file: "@__swiftmacro_3App6broken6VerifyfMp_.swift", line: 1)
        func broken_ensures(_ x: UInt8, _ r: UInt8) -> Bool { r > x }
        #sourceLocation()
        func generic<T: FixedWidthInteger>(_ x: T) -> T { x }
        func usesGeneric(_ x: Int8) -> Int8 { generic(x) }
        func onlyIfLong(_ s: String, _ x: Int8) -> Int8 { s.count > 3 ? x + 1 : x }
        protocol Valued { func value() -> Int8 }
        struct One: Valued { func value() -> Int8 { 1 } }
        func viaWitness<V: Valued>(_ v: V) -> Int8 { v.value() }
        func callsWitness() -> Int8 { viaWitness(One()) }
        struct Pair: Equatable {
            var a: Int8
            static func == (l: Pair, r: Pair) -> Bool { l.a == r.a }
        }
        """

    /// Stands for the tool's versions (`ScanToolIdentity.versions`, whose digest takes seconds in a debug build).
    static let versions = "test versions"

    /// A directory of its own, removed afterwards; the source file keeps its path across the runs of one test, since
    /// the path is part of the compilation's identity.
    final class Workspace {
        let path = NSTemporaryDirectory() + "sfv-cache-\(UUID().uuidString)"
        var file: String { path + "/Demo.swift" }
        var cache: String { path + "/proofs" }

        init() throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        func compile(_ source: String, configuration: BuildConfiguration = .debug) throws -> CompiledModule {
            try source.write(toFile: file, atomically: true, encoding: .utf8)
            var options = CompileOptions(files: [file], moduleName: "Demo")
            options.configuration = configuration
            return try ModuleCompiler.compile(options)
        }

        /// The keys of `compiled`'s functions by name (`f(_:)`).
        func keys(_ compiled: CompiledModule, versions: String = ScanProofCacheTests.versions, budget: Int = 300_000) -> [String: String] {
            let names = Dictionary(compiled.functions.map { ($0.symbol, $0.displayName) }, uniquingKeysWith: { a, _ in a })
            let options = VerifyOptions(conflictBudget: budget)
            return Dictionary(
                Verifier.proofCacheKeys(compiled, options: options, versions: versions).map { (names[$0.key] ?? $0.key, $0.value) },
                uniquingKeysWith: { a, _ in a })
        }

        func scan(
            _ source: String, cache: String? = nil, budget: Int = 300_000, extra: [String] = [],
            versions: String = ScanProofCacheTests.versions
        ) throws -> ScanReport {
            try source.write(toFile: file, atomically: true, encoding: .utf8)
            var options = VerifyOptions(conflictBudget: budget)
            options.configurations = [.debug]
            options.proofCache = ScanProofCache(directory: cache ?? self.cache, versions: versions)
            return try SFVerify.run(CompileOptions(files: [file], moduleName: "Demo", extraArguments: extra), options)
        }

        /// Writes `entry` where the cache looks for its key, readable by the user only.
        func forge(_ entry: ScanProofEntry) throws -> String {
            let directory = cache + "/scan-v1"
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = directory + "/" + entry.key.dropFirst("sha256:".count) + ".json"
            try JSONEncoder().encode(entry).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return path
        }
    }

    static func function(_ report: ScanReport, _ name: String) throws -> FunctionReport {
        try #require(report.functions.first { $0.name.hasPrefix(name + "(") }, "\(report.functions.map(\.name))")
    }

    static func verdicts(_ report: ScanReport) -> [String: String] {
        Dictionary(
            report.functions.map { ($0.symbol, "\($0.status) \($0.category ?? "") \($0.counterexample?.inputs ?? [])") },
            uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Keys

    @Test func keysAreTheSameForTheSameCode() throws {
        let workspace = try Workspace()
        let first = workspace.keys(try workspace.compile(Self.source))
        let second = workspace.keys(try workspace.compile(Self.source))
        #expect(first["f(_:)"] != nil && first["g(_:)"] != nil)
        #expect(first == second)
    }

    /// Each change reaches the claim of `f` (or of `usesGeneric`, `callsWitness`) but not that of `g`, unless it
    /// changes what every claim hashes (a witness the encoder looks up by type alone, as for `==`).
    @Test(arguments: [
        ("body", "func f(_ x: Int8) -> Int8 { helper(x) }", "func f(_ x: Int8) -> Int8 { helper(x) &+ 0 }", "f(_:)", false),
        ("callee", "func helper(_ x: Int8) -> Int8 { x &+ 1 }", "func helper(_ x: Int8) -> Int8 { x &+ 2 }", "f(_:)", false),
        ("ensures", "{ r != x }", "{ r != x || x == 0 }", "f(_:)", false),
        ("requires helper", "{ x < 100 }", "{ x < 99 }", "f(_:)", false),
        ("pairing", "func f_requires(", "func h_requires(", "f(_:)", false),
        ("generic header", "func generic<", "@inline(never) func generic<", "usesGeneric(_:)", false),
        ("witness", "func value() -> Int8 { 1 }", "func value() -> Int8 { 2 }", "callsWitness()", false),
        ("encoder's witness", "l.a == r.a", "l.a != r.a", "f(_:)", true),
    ])
    func aChangeToWhatTheClaimIsMadeOfChangesItsKey(
        _ what: String, _ old: String, _ new: String, _ function: String, _ changesEveryKey: Bool
    ) throws {
        let workspace = try Workspace()
        #expect(Self.source.contains(old), "\(what)")
        let before = workspace.keys(try workspace.compile(Self.source))
        let after = workspace.keys(try workspace.compile(Self.source.replacingOccurrences(of: old, with: new)))
        #expect(before[function] != nil && after[function] != nil, "\(what)")
        #expect(before[function] != after[function], "\(what)")
        #expect((before["g(_:)"] != after["g(_:)"]) == changesEveryKey, "\(what)")
    }

    @Test func theCompilerTheVersionsTheConfigurationAndTheBudgetAreInTheKey() throws {
        let workspace = try Workspace()
        var compiled = try workspace.compile(Self.source)
        let keys = workspace.keys(compiled)
        let identity = try #require(compiled.identity)
        let toolchain = try ScanToolchain.current()
        #expect(identity.contains("swiftc=\(toolchain.swiftc)") && identity.contains("version=\(toolchain.toolchain.swiftcVersion)"))
        #expect(identity.contains("configuration=debug"))

        #expect(workspace.keys(compiled, versions: Self.versions + " claim=next")["f(_:)"] != keys["f(_:)"])
        #expect(workspace.keys(compiled, budget: 1_000)["f(_:)"] != keys["f(_:)"])
        let release = try workspace.compile(Self.source, configuration: .release)
        #expect(workspace.keys(release)["f(_:)"] != keys["f(_:)"])

        compiled.identity = identity.replacingOccurrences(
            of: "version=\(toolchain.toolchain.swiftcVersion)", with: "version=Apple Swift version 99")
        #expect(workspace.keys(compiled)["f(_:)"] != keys["f(_:)"])
        compiled.identity = nil
        #expect(workspace.keys(compiled).isEmpty, "an unknown compilation gives no keys")
    }

    // MARK: - Runs

    @Test func anUnchangedModuleIsAnsweredFromTheCacheWithTheSameVerdicts() throws {
        let workspace = try Workspace()
        let cold = try workspace.scan(Self.source)
        let use = try #require(cold.proofCache)
        #expect(use.trusted && use.hits == 0 && use.stored > 0 && use.ioErrors == 0)
        #expect(try Self.function(cold, "traps").status == .mayTrap)
        #expect(try Self.function(cold, "broken").status == .contractFails)
        #expect(try Self.function(cold, "f").status == .contractHolds)
        #expect(try Self.function(cold, "onlyIfLong").status == .undecided)

        let warm = try workspace.scan(Self.source)
        #expect(Self.verdicts(warm) == Self.verdicts(cold))
        #expect(warm.proofCache?.hits == use.stored)
        #expect(warm.proofCache?.stored == 0)
        #expect(try Self.function(warm, "traps").fromCache == true)
        #expect(try Self.function(warm, "traps").counterexample?.replay == Self.function(cold, "traps").counterexample?.replay)
        #expect(try Self.function(warm, "f").fromCache == true)
        #expect(try Self.function(warm, "onlyIfLong").fromCache == nil, "an undecided answer is not stored")

        let edited = try workspace.scan(Self.source.replacingOccurrences(of: "{ x < 100 }", with: "{ x < 99 }"))
        #expect(try Self.function(edited, "f").fromCache == nil)
        #expect(try Self.function(edited, "bound").fromCache == nil)
        #expect(try Self.function(edited, "g").fromCache == true)
        #expect(edited.proofCache?.stored == 2, "f and bound, whose code changed")
    }

    @Test func anAnswerTheBudgetCutShortIsNotStored() throws {
        let workspace = try Workspace()
        let source = """
            func commutes(_ a: UInt16, _ b: UInt16) -> UInt16 { precondition(a &* b == b &* a); return a }
            """
        let cold = try workspace.scan(source, budget: 1)
        #expect(try Self.function(cold, "commutes").status == .undecided)
        #expect(cold.proofCache?.stored == 0)
        let again = try workspace.scan(source, budget: 1)
        #expect(again.proofCache?.hits == 0)
    }

    /// The caller-exclusivity downgrade runs after the cache: a cached `proved` of a method on a class parameter is
    /// still `undecided`.
    @Test func aCachedProofStillGoesThroughTheCallerExclusivityCheck() throws {
        let workspace = try Workspace()
        let cold = try workspace.scan(ClassScanTests.source)
        let warm = try workspace.scan(ClassScanTests.source)
        #expect((warm.proofCache?.hits ?? 0) > 0)
        for report in [cold, warm] {
            let held = try Self.function(report, "addOnParameter")
            #expect(held.status == .undecided && held.category == "exclusivity", "\(held.status)")
        }
        #expect(try Self.function(warm, "addOnParameter").fromCache == true)
    }

    /// The trust model: an entry the user wrote in directories only the user (or root) can change is believed. The
    /// same entry as a symlink, writable by others, or in a directory others can write to is not.
    @Test(arguments: ["trusted", "symlink", "shared entry", "shared directory", "shared parent"])
    func aForgedProofIsUsedOnlyFromTheUsersOwnFiles(_ how: String) throws {
        let workspace = try Workspace()
        let compiled = try workspace.compile(Self.source)
        let symbol = try #require(compiled.functions.first { $0.displayName == "traps(_:)" }?.symbol)
        let key = try #require(workspace.keys(compiled)["traps(_:)"])
        let path = try workspace.forge(ScanProofEntry(key: key, symbol: symbol))
        let manager = FileManager.default
        switch how {
        case "symlink":
            try manager.moveItem(atPath: path, toPath: workspace.path + "/elsewhere.json")
            try manager.createSymbolicLink(atPath: path, withDestinationPath: workspace.path + "/elsewhere.json")
        case "shared entry": try manager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: path)
        case "shared directory": try manager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: workspace.cache + "/scan-v1")
        case "shared parent": try manager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: workspace.path)
        default: break
        }
        let report = try workspace.scan(Self.source)
        let traps = try Self.function(report, "traps")
        if how == "trusted" {
            // What makes the others matter: a trusted entry is not proved again.
            #expect(traps.status == .safe && traps.fromCache == true)
        } else {
            #expect(traps.status == .mayTrap && traps.fromCache == nil, "\(how)")
            #expect(report.proofCache?.hits == 0, "\(how)")
        }
        if how.hasPrefix("shared d") || how == "shared parent" { #expect(report.proofCache?.trusted == false) }
    }

    @Test func aStoredCounterexampleThatDoesNotReplayIsDropped() throws {
        let workspace = try Workspace()
        let compiled = try workspace.compile(Self.source)
        let symbol = try #require(compiled.functions.first { $0.displayName == "g(_:)" }?.symbol)
        let key = try #require(workspace.keys(compiled)["g(_:)"])
        _ = try workspace.forge(ScanProofEntry(key: key, values: [0], symbol: symbol))
        let report = try workspace.scan(Self.source)
        let g = try Self.function(report, "g")
        #expect(g.status == .safe && g.fromCache == nil)
        #expect(report.proofCache?.rejected == 1)
    }

    @Test func aCacheThatCannotBeWrittenFallsBackToProving() throws {
        let workspace = try Workspace()
        let blocked = workspace.path + "/not-a-directory"
        try "x".write(toFile: blocked, atomically: true, encoding: .utf8)
        let report = try workspace.scan(Self.source, cache: blocked)
        let plain = try workspace.scan(Self.source, cache: workspace.cache)
        #expect(Self.verdicts(report) == Self.verdicts(plain))
        #expect(report.proofCache?.hits == 0 && report.proofCache?.stored == 0)
        #expect((report.proofCache?.ioErrors ?? 0) > 0)
    }

    /// `swiftformal check --gate` checks every target again (no stamps): a marked caller whose own file did not change is
    /// not answered from the cache once a linked dependency it calls starts to trap.
    @Test func aCallerIsProvedAgainWhenALinkedDependencyChanges() throws {
        let workspace = try Workspace()
        let core = workspace.path + "/Core.swift"
        func emitCore(_ body: String) throws {
            try "public func toPar(_ strokes: Int8, _ par: Int8) -> Int8 { \(body) }".write(
                toFile: core, atomically: true, encoding: .utf8)
            let module = Process()
            module.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            module.arguments = [
                "swiftc", "-emit-module", "-parse-as-library", "-module-name", "Core", core,
                "-emit-module-path", workspace.path + "/Core.swiftmodule",
            ]
            try module.run()
            module.waitUntilExit()
            try #require(module.terminationStatus == 0)
        }
        let app = "import Core\n// checked by name\nfunc overPar(_ s: Int8, _ p: Int8) -> Int8 { toPar(s, p) }\n"
        func scan() throws -> ScanReport {
            try app.write(toFile: workspace.file, atomically: true, encoding: .utf8)
            var options = VerifyOptions(only: ["overPar"])
            options.configurations = [.debug]
            options.proofCache = ScanProofCache(directory: workspace.cache, versions: Self.versions)
            return try SFVerify.run(
                CompileOptions(files: [workspace.file], moduleName: "App", extraArguments: ["-I", workspace.path]), options,
                linking: { $0 == "Core" ? CompileOptions(files: [core], moduleName: "Core") : nil })
        }
        try emitCore("strokes &- par")
        #expect(try Self.function(scan(), "overPar").status == .safe)
        #expect(try Self.function(scan(), "overPar").fromCache == true)
        try emitCore("strokes - par")
        let after = try Self.function(scan(), "overPar")
        #expect(after.status == .mayTrap && after.fromCache == nil)
    }
}

extension ScanProofCacheTests {
    /// Only `@Verify` changed what a claim means: a hand-written `guarded_requires` no longer narrows `guarded`'s
    /// inputs. A proof stored under the claim version before that change, whose key the new claim would otherwise
    /// compute again, is not read: `guarded` traps.
    @Test func anAnswerStoredBeforeOnlyVerifyIsNotRead() throws {
        let workspace = try Workspace()
        let source = "func guarded(_ x: Int8) -> Int8 { x + 1 }\nfunc guarded_requires(_ x: Int8) -> Bool { x < 100 }\n"
        let compiled = try workspace.compile(source)
        // As `ScanKeyContext.versions(tool:)` writes them, without the digest that takes seconds in a debug build.
        let current = "claim=\(ScanClaimVersion.current) " + Self.versions
        let before = "claim=2 " + Self.versions
        let symbol = try #require(compiled.functions.first { $0.displayName == "guarded(_:)" }?.symbol)
        let key = try #require(workspace.keys(compiled, versions: before)["guarded(_:)"])
        _ = try workspace.forge(ScanProofEntry(key: key, symbol: symbol))
        let report = try workspace.scan(source, versions: current)
        let guarded = try Self.function(report, "guarded")
        #expect(guarded.status == .mayTrap && guarded.fromCache == nil, "\(guarded.status)")
        #expect(report.proofCache?.hits == 0)
    }
}

/// How a function's SIL text is read for its key: the names it reaches, and the text that two compilations of the same
/// code share.
@Suite struct ScanKeyTextTests {
    @Test func referencedSymbolsFollowEveryNameAfterAnAt() {
        #expect(
            ScanKeyContext.referencedSymbols(in: "%1 = function_ref @f : $@convention(thin) () -> ()") == [
                "f", "convention(thin)", "convention(thin",
            ])
        #expect(ScanKeyContext.referencedSymbols(in: "#P.m: @g, @h:") == ["g,", "g", "h:", "h"])
        #expect(ScanKeyContext.referencedSymbols(in: "%2 = function_ref @\"quoted\"") == nil)
        // In a string literal `@"` is no quoted name (`"%@"`, a format string); its other names are kept.
        #expect(ScanKeyContext.referencedSymbols(in: #"%3 = string_literal utf8 "%@ \" @x" // user: %4"#) == [#"x""#, "x"])
        #expect(ScanKeyContext.referencedSymbols(in: #"%5 = string_literal utf8 "a\\" // @"g""#) == nil)
        #expect(ScanKeyContext.referencedSymbols(in: #"%6 = string_literal utf8 "unterminated %@"#) == nil)
        #expect(ScanKeyContext.referencedSymbols(in: #"cond_fail %1 : $Builtin.Int1, "%@""#) == nil)
    }

    @Test func freshArchetypeIdentifiersAreNumberedInOrder() {
        let first = [
            #"%4 = open_existential_ref %3 to $@opened("6BE72004-DBBE-11F1-BC5C-8D04DFA387C3", any P) Self"#,
            #"%5 = open_pack_element %4 of <each C> at <Pack{Int}>, shape $each C, uuid "6C068912-DBBE-11F1-BC5C-8D04DFA387C3""#,
            #"%6 = pack_element_get %4 of %2 as $*@pack_element("6C068912-DBBE-11F1-BC5C-8D04DFA387C3") each C"#,
            #"%7 = string_literal utf8 "6BE72004-DBBE-11F1-BC5C-8D04DFA387C3""#,
        ]
        let renamed = first.map {
            $0.replacingOccurrences(of: "6BE72004-DBBE-11F1-BC5C-8D04DFA387C3", with: "6FC4A67E-DBBE-11F1-983B-01AFBF77B263")
                .replacingOccurrences(of: "6C068912-DBBE-11F1-BC5C-8D04DFA387C3", with: "6FE0D5C4-DBBE-11F1-983B-01AFBF77B263")
        }
        let canonical = ScanKeyContext.canonicalArchetypes(in: first)
        #expect(canonical[0] == #"%4 = open_existential_ref %3 to $@opened("archetype-0", any P) Self"#)
        #expect(canonical[2] == #"%6 = pack_element_get %4 of %2 as $*@pack_element("archetype-1") each C"#)
        // Only the archetypes are renamed: a string literal keeps its text.
        #expect(Array(ScanKeyContext.canonicalArchetypes(in: renamed).prefix(3)) == Array(canonical.prefix(3)))
        #expect(ScanKeyContext.canonicalArchetypes(in: renamed)[3] != canonical[3])
        // One archetype opened twice is not two archetypes.
        let merged = first.map {
            $0.replacingOccurrences(of: "6C068912-DBBE-11F1-BC5C-8D04DFA387C3", with: "6BE72004-DBBE-11F1-BC5C-8D04DFA387C3")
        }
        #expect(ScanKeyContext.canonicalArchetypes(in: merged) != canonical)
    }
}

/// Keys that must not change when the code a claim is made of does not.
@Suite struct ScanKeyStabilityTests {
    /// Compiler-written functions are named by their debug scope (`Mode.hash(into:), scope 7`), which an edit before
    /// them renumbers; their claims stay the same, and so do their keys.
    @Test func renumberedDebugScopesLeaveTheKeysOfOtherFunctionsAlone() throws {
        let workspace = try ScanProofCacheTests.Workspace()
        let old = "enum Mode: Hashable {\n    case a, b\n    var isA: Bool { self == .a }\n}\n"
        let new = "enum Mode: Hashable {\n    case a, b\n    var isA: Bool { do { return self == .a } }\n}\n"
        let (before, after) = (try workspace.compile(old), try workspace.compile(new))
        let options = VerifyOptions(conflictBudget: 300_000)
        let (keysBefore, keysAfter) = (
            Verifier.proofCacheKeys(before, options: options, versions: ScanProofCacheTests.versions),
            Verifier.proofCacheKeys(after, options: options, versions: ScanProofCacheTests.versions)
        )
        let renamed = before.functions.filter { info in
            info.displayName.contains(", scope ") && !after.functions.contains { $0.displayName == info.displayName }
        }
        #expect(!renamed.isEmpty, "\(before.functions.map(\.displayName))")
        for info in renamed {
            #expect(keysBefore[info.symbol] != nil && keysBefore[info.symbol] == keysAfter[info.symbol], "\(info.displayName)")
        }
    }
}
