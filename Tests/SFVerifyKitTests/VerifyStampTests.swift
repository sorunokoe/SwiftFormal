import Foundation
import SFSIL
import Testing

@testable import SFVerifyKit

/// `swiftformal check --gate` skips a target that passed before only while nothing its check reads has changed: its files
/// and arguments, what those name (search paths, module maps, macro plugins), the local modules it links with their
/// files and arguments, the manifests, the compiler, the tool and the flags. A stamp nobody else could have written
/// is the only one read, and an edit made while the check runs is never stamped.
@Suite struct VerifyStampTests {
    /// A package `App` that imports `Core` (a module built into `modules/`, linked from `Core.swift`).
    final class Workspace {
        let path = NSTemporaryDirectory() + "sfv-stamp-\(UUID().uuidString)"
        var app: String { path + "/Sources/App/App.swift" }
        var core: String { path + "/Core/Core.swift" }
        var modules: String { path + "/modules" }
        var stamps: String { path + "/.build/swiftformal/proofs/verify-v1" }
        var manifest: String { path + "/Package.swift" }
        /// Whether the last `verify` wrote a stamp.
        var stored = false
        static let app = "import Core\n// checked by name\nfunc overPar(_ s: Int8, _ p: Int8) -> Int8 { toPar(s, p) }\n"
        /// `app` with `overPar` marked `@Verify`; it compiles with `extra` set to `VerifyMacroScanTests.macroArguments()`.
        static let verifiedApp = "import Core\nimport SwiftFormal\n@Verify\nfunc overPar(_ s: Int8, _ p: Int8) -> Int8 { toPar(s, p) }\n"
        /// More compiler arguments for `App`.
        var extra: [String] = []

        init() throws {
            for directory in [path + "/Sources/App", path + "/Core", modules] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            try "// swift-tools-version:6.0\n".write(toFile: manifest, atomically: true, encoding: .utf8)
            try Self.app.write(toFile: app, atomically: true, encoding: .utf8)
            try writeCore("strokes &- par")
            try emitCoreModule()
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        /// Changes `Core.swift` without building its module again: only the linked source tells the change.
        func writeCore(_ body: String) throws {
            try "public func toPar(_ strokes: Int8, _ par: Int8) -> Int8 { \(body) }".write(
                toFile: core, atomically: true, encoding: .utf8)
        }

        func emitCoreModule() throws {
            let module = Process()
            module.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            module.arguments = [
                "swiftc", "-emit-module", "-parse-as-library", "-module-name", "Core", core,
                "-emit-module-path", modules + "/Core.swiftmodule",
            ]
            try module.run()
            module.waitUntilExit()
            try #require(module.terminationStatus == 0)
        }

        var compile: CompileOptions { CompileOptions(files: [app], moduleName: "App", extraArguments: ["-I", modules] + extra) }

        func resolve(_ name: String) throws -> CompileOptions? {
            name == "Core" ? CompileOptions(files: [core], moduleName: "Core") : nil
        }

        func stampCheck(
            settings: String = "strict=false", toolchain: ScanToolchain? = nil, compile: CompileOptions? = nil, tool: String = "test tool"
        ) throws -> VerifyStampCheck? {
            VerifyStampCheck(
                directory: stamps, package: path, target: "App", settings: settings, compile: compile ?? self.compile,
                tool: tool, toolchain: try toolchain ?? ScanToolchain.current())
        }

        /// What `swiftformal check --gate` does for the target: nil when a stamp said it is unchanged, else the status of
        /// `function` (a passing target is stamped).
        func verify(
            settings: String = "strict=false", toolchain: ScanToolchain? = nil, compile: CompileOptions? = nil,
            function: String = "overPar", tool: String = "test tool", beforeStoring: () throws -> Void = {}
        ) throws -> ScanStatus? {
            let check = try #require(try stampCheck(settings: settings, toolchain: toolchain, compile: compile, tool: tool))
            if check.unchanged(resolve: resolve) != nil { return nil }
            return try run(check, compile: compile ?? self.compile, only: [function], beforeStoring: beforeStoring)[function]
        }

        /// Checks `only` (and stamps the target when all are safe), as `swiftformal check --gate` does after `check` said the
        /// target changed; the status of each.
        func run(
            _ check: VerifyStampCheck, compile: CompileOptions? = nil, only: Set<String>, beforeStoring: () throws -> Void = {}
        ) throws -> [String: ScanStatus] {
            var options = VerifyOptions(only: Array(only))
            options.configurations = [.debug]
            let report = try SFVerify.run(check.recording(compile ?? self.compile), options, linking: check.recording(resolve))
            var statuses: [String: ScanStatus] = [:]
            for name in only { statuses[name] = try #require(report.functions.first { $0.name.hasPrefix(name + "(") }).status }
            try beforeStoring()
            stored = false
            if statuses.values.allSatisfy({ $0 == .safe }) {
                stored = check.store(
                    output: ["App.swift:3:6: note: proved"], notes: [], summary: "1 of 1", unlinked: report.unlinkedModules,
                    resolve: resolve)
            }
            return statuses
        }
    }

    @Test func anUnchangedTargetIsSkippedAndItsOutputKept() throws {
        let workspace = try Workspace()
        #expect(try workspace.verify() == .safe)
        #expect(try workspace.verify() == nil)
        let stamp = try #require(try workspace.stampCheck()?.unchanged(resolve: workspace.resolve))
        #expect(stamp.output == ["App.swift:3:6: note: proved"] && stamp.summary == "1 of 1")
    }

    /// Two builds of swiftformal (a release and a debug one, or two checkouts) keep a stamp each: neither makes the
    /// other check again.
    @Test func eachToolKeepsItsOwnStamp() throws {
        let workspace = try Workspace()
        #expect(try workspace.verify(tool: "tool A") == .safe)
        #expect(try workspace.verify(tool: "tool B") == .safe)
        #expect(try workspace.verify(tool: "tool A") == nil)
        #expect(try workspace.verify(tool: "tool B") == nil)
    }

    /// The caller's file did not change and neither did `Core`'s module: only the linked source did.
    @Test func aTargetIsCheckedAgainWhenALinkedDependencyStartsToTrap() throws {
        let workspace = try Workspace()
        #expect(try workspace.verify() == .safe)
        try workspace.writeCore("strokes - par")
        #expect(try workspace.verify() == .mayTrap)
    }

    @Test func aTargetIsCheckedAgainWhenAModuleItsArgumentsNameChanges() throws {
        let workspace = try Workspace()
        #expect(try workspace.verify() == .safe)
        try workspace.writeCore("strokes &- par }\npublic func birdie() -> Int8 { -1")
        try workspace.emitCoreModule()
        try workspace.writeCore("strokes &- par")
        #expect(try workspace.verify() == .safe)
    }

    @Test func aTargetIsCheckedAgainWhenTheManifestTheCompilerOrAFlagChanges() throws {
        let workspace = try Workspace()
        #expect(try workspace.verify() == .safe)
        try "// swift-tools-version:6.0\n// changed\n".write(toFile: workspace.manifest, atomically: true, encoding: .utf8)
        #expect(try workspace.verify() == .safe)
        #expect(try workspace.verify(settings: "strict=true") == .safe)
        var other = try ScanToolchain.current()
        other.triple += "-other"
        #expect(try workspace.stampCheck(toolchain: other)?.unchanged(resolve: workspace.resolve) == nil)
        #expect(try workspace.verify(settings: "strict=true") == nil)
    }

    /// A file edited while the check ran may not be what was checked: nothing is stamped, so the file as it was
    /// before is checked again too.
    @Test func anEditDuringTheCheckIsNotStamped() throws {
        let workspace = try Workspace()
        let edit = { (text: String) in try text.write(toFile: workspace.app, atomically: true, encoding: .utf8) }
        #expect(try workspace.verify(beforeStoring: { try edit(Workspace.app + "// edited\n") }) == .safe)
        #expect(!workspace.stored)
        try edit(Workspace.app)
        #expect(try workspace.verify() == .safe)
        #expect(workspace.stored)
    }

    /// `swiftformal check --gate` hashes the target before it reads its promises, and reads them from the bytes it hashed.
    /// A promise saved after that is not among the names checked: the file the compiler read is not the one hashed,
    /// so nothing is stamped and the next run checks the new promise.
    @Test func aPromiseSavedAfterTheTargetWasHashedIsNotStamped() throws {
        let workspace = try Workspace()
        workspace.extra = try VerifyMacroScanTests.macroArguments()
        try Workspace.verifiedApp.write(toFile: workspace.app, atomically: true, encoding: .utf8)
        let check = try #require(try workspace.stampCheck())
        try (Workspace.verifiedApp + "@Verify\nfunc bump(_ x: Int8) -> Int8 { x + 1 }\n").write(
            toFile: workspace.app, atomically: true, encoding: .utf8)
        let promises = BuildCheck.promises(in: [workspace.app], read: check.source)
        #expect(promises.promises.map(\.name) == ["overPar"])
        #expect(try workspace.run(check, only: Set(promises.promises.map(\.name))) == ["overPar": .safe])
        #expect(!workspace.stored)
        let next = try #require(try workspace.stampCheck())
        #expect(next.unchanged(resolve: workspace.resolve) == nil)
        let names = Set(BuildCheck.promises(in: [workspace.app], read: next.source).promises.map(\.name))
        #expect(try workspace.run(next, only: names) == ["overPar": .safe, "bump": .mayTrap])
    }

    /// A file edited and put back while the check ran has the bytes it had, but the compiler may have read the
    /// edit: nothing is stamped (its size, times or inode changed).
    @Test func anEditUndoneDuringTheCheckIsNotStamped() throws {
        let workspace = try Workspace()
        let edit = { (text: String) in try text.write(toFile: workspace.app, atomically: true, encoding: .utf8) }
        #expect(
            try workspace.verify(beforeStoring: {
                try edit(Workspace.app + "// edited\n"); try edit(Workspace.app)
            }) == .safe)
        #expect(!workspace.stored)
        #expect(try workspace.verify() == .safe)
        #expect(workspace.stored)
        #expect(try workspace.verify() == nil)
    }

    /// A C module's header includes `../limits.h`: no argument names it, only the compiler knows it read it. Changing
    /// it is a change.
    @Test func aTargetIsCheckedAgainWhenAHeaderNoArgumentNamesChanges() throws {
        let workspace = try Workspace()
        let library = workspace.path + "/C Lib"
        try FileManager.default.createDirectory(atPath: library + "/include", withIntermediateDirectories: true)
        try "module CLib {\n  header \"clib.h\"\n  export *\n}\n".write(
            toFile: library + "/include/module.modulemap", atomically: true, encoding: .utf8)
        try "#include \"../limits.h\"\n".write(toFile: library + "/include/clib.h", atomically: true, encoding: .utf8)
        let limit = { (n: Int) in try "#define CLIB_N \(n)\n".write(toFile: library + "/limits.h", atomically: true, encoding: .utf8) }
        try limit(16)
        try
            "import CLib\n// checked by name\nfunc scaled(_ x: Int8) -> Int8 {\n  guard x >= 0 && x < 8 else { return 0 }\n  return x * Int8(CLIB_N)\n}\n"
            .write(toFile: workspace.app, atomically: true, encoding: .utf8)
        let compile = CompileOptions(files: [workspace.app], moduleName: "App", extraArguments: ["-I", library + "/include"])
        // Only the compiler names `limits.h`, after the check: it must have changed a second before the check started.
        #expect(try workspace.verify(compile: compile, function: "scaled") == .safe)
        #expect(!workspace.stored)
        Thread.sleep(forTimeInterval: 1.1)
        #expect(try workspace.verify(compile: compile, function: "scaled") == .safe)
        #expect(workspace.stored)
        #expect(try workspace.verify(compile: compile, function: "scaled") == nil)
        try limit(32)
        #expect(try workspace.verify(compile: compile, function: "scaled") == .mayTrap)
    }

    /// The prerequisites of the Make rule the frontend writes, with its escapes undone.
    @Test func theCompilersDependencyFileIsRead() {
        let text = "- : /a/App.swift /b/C\\ Lib\\#1/x.h /c/$$d.h /e/f\\\\\\ g.h\n"
        #expect(CompilerDependencies.parse(text) == ["/a/App.swift", "/b/C Lib#1/x.h", "/c/$d.h", "/e/f\\ g.h"])
        #expect(CompilerDependencies.parse("no rule here\n") == nil)
    }

    /// A module that could not be linked was not checked with the caller: the run is not stamped.
    @Test func aCheckThatCouldNotLinkAModuleIsNotStamped() throws {
        let workspace = try Workspace()
        let check = try #require(try workspace.stampCheck())
        let broken: (String) throws -> CompileOptions? = {
            $0 == "Core" ? CompileOptions(files: [workspace.path + "/Missing.swift"], moduleName: "Core") : nil
        }
        var options = VerifyOptions(only: ["overPar"])
        options.configurations = [.debug]
        let report = try SFVerify.run(workspace.compile, options, linking: check.recording(broken))
        #expect(report.unlinkedModules == ["Core"])
        #expect(!check.store(output: [], notes: [], summary: "", unlinked: report.unlinkedModules, resolve: broken))
    }

    @Test(arguments: ["shared directory", "shared stamp", "symlink"])
    func aStampSomeoneElseCouldHaveWrittenIsNotUsed(_ forgery: String) throws {
        let workspace = try Workspace()
        #expect(try workspace.verify() == .safe)
        let stamp = try #require(try FileManager.default.contentsOfDirectory(atPath: workspace.stamps).first)
        let path = workspace.stamps + "/" + stamp
        switch forgery {
        case "shared directory": try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: workspace.stamps)
        case "shared stamp": try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: path)
        default:
            try FileManager.default.moveItem(atPath: path, toPath: workspace.path + "/elsewhere.json")
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: workspace.path + "/elsewhere.json")
        }
        #expect(try workspace.verify() == .safe)
    }

    /// Each `swift build` writes the SDK's stat cache again, with other bytes: that is not a change.
    @Test func aRewrittenSDKStatCacheIsNotAChange() throws {
        let workspace = try Workspace()
        let statCache = workspace.path + "/macosx-1.sdkstatcache"
        var compile = workspace.compile
        compile.extraArguments += ["-Xcc", "-ivfsstatcache", "-Xcc", statCache]
        let digest = {
            try "\(UUID())".write(toFile: statCache, atomically: true, encoding: .utf8)
            return VerifyInputs(toolchain: try ScanToolchain.current()).module(compile)
        }
        let (first, second) = (try digest(), try digest())
        #expect(first != nil && first == second)
    }

    @Test func argumentsThatNameARelativePathOrAnOverlayGiveNoStamp() throws {
        let workspace = try Workspace()
        for extra in [["-I", "relative/modules"], ["-vfsoverlay", workspace.path + "/overlay.yaml"]] {
            var compile = workspace.compile
            compile.extraArguments += extra
            #expect(try workspace.stampCheck(compile: compile) == nil)
        }
        #expect(
            VerifyStampCheck(
                directory: workspace.stamps, package: workspace.path, target: "App", settings: "", compile: workspace.compile,
                tool: nil, toolchain: try ScanToolchain.current()) == nil)
    }
}
