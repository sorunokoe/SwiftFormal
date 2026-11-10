import Foundation
import SFVerifyKit
import Testing

/// Plan item K3: a saved compile command is reused only for the build description it came from (Swift Build), and the
/// native build system's `debug.yaml` gives every target's command without a rebuild. A null build prints no command,
/// so these are what `--build` and `--build-log` fall back on.
@Suite struct SwiftPMCacheTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// A scratch folder laid out like Swift Build's, with `ids` in `prior-build-descriptions.txt` (oldest first).
    private func swiftBuildScratch(ids: [String]) throws -> String {
        let scratch = NSTemporaryDirectory() + "sfv-k3-\(UUID().uuidString)"
        let data = scratch + "/out/Intermediates.noindex/XCBuildData"
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        try "swiftbuild".write(toFile: scratch + "/.buildSystem_debug", atomically: true, encoding: .utf8)
        try (ids.joined(separator: "\n") + "\n").write(toFile: data + "/prior-build-descriptions.txt", atomically: true, encoding: .utf8)
        return scratch
    }

    private let idA = "0af7bfbf2be300397f5d16ed07f9b2c7"
    private let idB = "3be1db533378e323c7e6d18c50b41800"

    @Test func theDescriptionIsTheLastLineOfThePriorDescriptions() throws {
        let scratch = try swiftBuildScratch(ids: [idB, idA])
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        #expect(SwiftPMBuild.buildDescription(in: scratch) == idA)
    }

    @Test func noDescriptionWithoutSwiftBuildsFiles() {
        #expect(SwiftPMBuild.buildDescription(in: NSTemporaryDirectory() + "sfv-k3-missing-\(UUID().uuidString)") == nil)
    }

    @Test func aSavedCommandIsReusedOnlyForItsOwnBuildDescription() throws {
        let scratch = try swiftBuildScratch(ids: [idA])
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let cache = scratch + "/sfverify-Kern.args"
        SwiftPMBuild.saveCommand(tool: "/usr/bin/swiftc", arguments: ["-module-name", "Kern", "-DK2"], description: idA, to: cache)
        let same = SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: cache, ownBuild: false)
        #expect(same?.arguments == ["-module-name", "Kern", "-DK2"])
        #expect(same?.tool == "/usr/bin/swiftc")

        // A new define, an added file or another requested target gives Swift Build a new description.
        try (idA + "\n" + idB + "\n").write(
            toFile: scratch + "/out/Intermediates.noindex/XCBuildData/prior-build-descriptions.txt", atomically: true, encoding: .utf8)
        #expect(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: cache, ownBuild: false) == nil)
    }

    @Test func aCommandSavedWithoutADescriptionIsNeverReused() throws {
        let scratch = try swiftBuildScratch(ids: [idA])
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let cache = scratch + "/sfverify-Kern.args"
        // The format before K3: the compiler, then one argument per line.
        try "#tool /usr/bin/swiftc\n-module-name\nKern\n".write(toFile: cache, atomically: true, encoding: .utf8)
        #expect(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: cache, ownBuild: false) == nil)
    }

    /// MessagePack as Swift Build writes its task store: fixed and 8/16-bit strings, arrays and maps, nil, booleans
    /// and integers.
    private enum Pack {
        case string(String), array([Pack]), map([(Pack, Pack)]), none, bool(Bool), int(UInt16)

        var bytes: [UInt8] {
            switch self {
            case .string(let text):
                let utf8 = Array(text.utf8)
                if utf8.count < 32 { return [0xA0 | UInt8(utf8.count)] + utf8 }
                return [0xDA, UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)] + utf8
            case .array(let items):
                return [0xDC, UInt8(items.count >> 8), UInt8(items.count & 0xFF)] + items.flatMap(\.bytes)
            case .map(let pairs): return [0x80 | UInt8(pairs.count)] + pairs.flatMap { $0.0.bytes + $0.1.bytes }
            case .none: return [0xC0]
            case .bool(let value): return [value ? 0xC3 : 0xC2]
            case .int(let value): return [0xCD, UInt8(value >> 8), UInt8(value & 0xFF)]
            }
        }
    }

    /// A task of Swift Build's plan: its rule, and the command line it runs.
    private func task(_ command: [String]) -> Pack {
        .array([.none, .array([.string("SwiftDriver"), .string(command[4])]), .array(command.map(Pack.string)), .bool(true), .int(300)])
    }

    private func writeTaskStore(_ values: [Pack], id: String, in scratch: String) throws {
        let directory = scratch + "/out/Intermediates.noindex/XCBuildData/\(id).xcbuilddata"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data(values.flatMap(\.bytes)).write(to: URL(fileURLWithPath: directory + "/task-store.msgpack"))
    }

    private let kern = ["builtin-SwiftDriver", "--", "/usr/bin/swiftc", "-module-name", "Kern", "-DKERN_FLAG", "-parse-as-library"]
    private let base = ["builtin-SwiftDriver", "--", "/usr/bin/swiftc", "-module-name", "Base", "-Onone"]

    /// A null build prints no command, but Swift Build keeps the plan of the current build description, every task's
    /// command line with it: a dependency's command comes from there instead of from a `swift build` of its own.
    @Test func theCurrentBuildDescriptionsPlanGivesEveryModulesCommand() throws {
        let scratch = try swiftBuildScratch(ids: [idA])
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        try #require(SwiftPMBuild.recordOwnBuild(in: scratch) != nil)
        try writeTaskStore(
            [task(base), .map([(.string("tasks"), .array([task(kern), .string(String(repeating: "x", count: 40))]))]), .int(7)],
            id: idA, in: scratch)
        let found = try #require(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: scratch + "/none.args", ownBuild: true))
        #expect(found.tool == "/usr/bin/swiftc" && found.arguments == Array(kern.dropFirst(3)))
        #expect(
            SwiftPMBuild.savedCommand(target: "Base", scratch: scratch, cache: scratch + "/none.args", ownBuild: true)?.arguments == [
                "-module-name", "Base", "-Onone",
            ])
        #expect(SwiftPMBuild.savedCommand(target: "Missing", scratch: scratch, cache: scratch + "/none.args", ownBuild: true) == nil)
    }

    @Test func anotherDescriptionsPlanOrAnUnreadablePlanGivesNoCommand() throws {
        let scratch = try swiftBuildScratch(ids: [idA])
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        try #require(SwiftPMBuild.recordOwnBuild(in: scratch) != nil)
        try writeTaskStore([task(kern)], id: idB, in: scratch)
        #expect(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: scratch + "/none.args", ownBuild: true) == nil)
        // Cut short, or a type this reader does not know: nothing from it is used.
        let whole = task(kern).bytes
        for broken in [Array(whole.dropLast(3)), [0xC1] + whole] {
            let directory = scratch + "/out/Intermediates.noindex/XCBuildData/\(idA).xcbuilddata"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try Data(broken).write(to: URL(fileURLWithPath: directory + "/task-store.msgpack"))
            #expect(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: scratch + "/none.args", ownBuild: true) == nil)
        }
    }

    /// Two different command lines for one module (two architectures, say): which one a build uses is not known here.
    @Test func aModuleWithTwoDifferentCommandsGetsNone() throws {
        let scratch = try swiftBuildScratch(ids: [idA])
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        try #require(SwiftPMBuild.recordOwnBuild(in: scratch) != nil)
        try writeTaskStore([task(kern), task(kern), task(kern + ["-DOTHER"])], id: idA, in: scratch)
        #expect(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: scratch + "/none.args", ownBuild: true) == nil)
        try writeTaskStore([task(kern), task(kern)], id: idA, in: scratch)
        #expect(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: scratch + "/none.args", ownBuild: true) != nil)
    }

    /// A build log someone else produced (`--build-log`) may come from another build than the scratch folder's last
    /// one (Xcode's, a release build, another platform): its null build never reads Swift Build's plan.
    @Test func withoutAnOwnBuildThePlanIsNeverRead() throws {
        let scratch = try swiftBuildScratch(ids: [idA])
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        try writeTaskStore([task(kern)], id: idA, in: scratch)
        #expect(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: scratch + "/none.args", ownBuild: false) == nil)
        #expect(throws: ScanUsageError.self) { try SwiftPMBuild.plan(log: "", target: "Kern", scratch: scratch) }
        // Nor does a run that says it built, when no build of this process is known for the folder.
        #expect(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: scratch + "/none.args", ownBuild: true) == nil)
    }

    /// Another build in the same folder after this process's own (another description): neither the command saved for
    /// the own build's description nor its plan is used any more.
    @Test func anotherBuildAfterTheOwnOneGivesNoCommand() throws {
        let scratch = try swiftBuildScratch(ids: [idA])
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        try writeTaskStore([task(kern), task(base)], id: idA, in: scratch)
        let cache = scratch + "/Kern.args"
        SwiftPMBuild.saveCommand(tool: "/usr/bin/swiftc", arguments: ["-module-name", "Kern"], description: idA, to: cache)
        try #require(SwiftPMBuild.recordOwnBuild(in: scratch) != nil)
        #expect(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: cache, ownBuild: true) != nil)
        #expect(SwiftPMBuild.savedCommand(target: "Base", scratch: scratch, cache: scratch + "/none.args", ownBuild: true) != nil)
        try (idA + "\n" + idB + "\n" + idA + "\n").write(
            toFile: scratch + "/out/Intermediates.noindex/XCBuildData/prior-build-descriptions.txt", atomically: true, encoding: .utf8)
        #expect(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: cache, ownBuild: true) == nil)
        #expect(SwiftPMBuild.savedCommand(target: "Base", scratch: scratch, cache: scratch + "/none.args", ownBuild: true) == nil)
    }

    /// A dependency's command is read from the plan only when that plan has the scanned target's command exactly as
    /// the scan uses it: the plan is then the one of the build the target's command came from.
    @Test func aDependencyIsReadFromAPlanOnlyWhenItHasTheTargetsCommand() throws {
        let scratch = try swiftBuildScratch(ids: [idA])
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        try writeTaskStore([task(kern), task(base)], id: idA, in: scratch)
        try #require(SwiftPMBuild.recordOwnBuild(in: scratch) != nil)
        let none = scratch + "/none.args"
        SwiftPMBuild.recordTarget("Kern", tool: "/usr/bin/swiftc", arguments: Array(kern.dropFirst(3)), in: scratch)
        #expect(SwiftPMBuild.savedCommand(target: "Base", scratch: scratch, cache: none, ownBuild: true) != nil)
        SwiftPMBuild.recordTarget("Kern", tool: "/usr/bin/swiftc", arguments: Array(kern.dropFirst(3)) + ["-DOTHER"], in: scratch)
        #expect(SwiftPMBuild.savedCommand(target: "Base", scratch: scratch, cache: none, ownBuild: true) == nil)
        SwiftPMBuild.recordTarget("Gone", tool: "/usr/bin/swiftc", arguments: ["-module-name", "Gone"], in: scratch)
        #expect(SwiftPMBuild.savedCommand(target: "Base", scratch: scratch, cache: none, ownBuild: true) == nil)
    }

    @Test func theNativeBuildSystemsManifestGivesTheCommand() throws {
        let scratch = NSTemporaryDirectory() + "sfv-k3-native-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        try "native".write(toFile: scratch + "/.buildSystem_debug", atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(
            atPath: Self.fixtures.appendingPathComponent("native-debug.yaml").path, toPath: scratch + "/debug.yaml")
        let kern = try #require(SwiftPMBuild.savedCommand(target: "Kern", scratch: scratch, cache: scratch + "/none.args", ownBuild: true))
        #expect(kern.tool.hasSuffix("/swiftc"))
        #expect(kern.arguments.contains("-DKERN_FLAG"))
        #expect(kern.arguments.firstIndex(of: "-module-name").map { kern.arguments[$0 + 1] } == "Kern")
        let base = try #require(SwiftPMBuild.savedCommand(target: "Base", scratch: scratch, cache: scratch + "/none.args", ownBuild: true))
        #expect(!base.arguments.contains("-DKERN_FLAG"))
        #expect(SwiftPMBuild.savedCommand(target: "Missing", scratch: scratch, cache: scratch + "/none.args", ownBuild: true) == nil)
    }
}
