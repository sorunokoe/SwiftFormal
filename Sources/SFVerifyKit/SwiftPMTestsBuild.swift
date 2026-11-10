import Foundation
import SFSIL

/// One build of a whole package for a run that scans several of its targets (`swiftformal check --gate`), or scans and then
/// runs its tests (`swiftformal check`), instead of one `swift build --target` per target.
extension SwiftPMBuild {
    /// `swift build --build-tests -v` in `root`, run the way `plan(root:target:)` runs its build, saving the command of
    /// every module it compiled: one build for a run that scans and then runs tests (`swiftformal check`). Each scanned
    /// target of `root` is then planned from the returned log (`plan(log:target:scratch:)`), and the tests run without
    /// building. Nil when the build failed: then each scan builds its own target, and `swift test` shows the error.
    public static func buildIncludingTests(root: String) throws -> String? {
        try buildPackage(root: URL(fileURLWithPath: root).standardizedFileURL.path, tests: true, serial: false)
    }

    /// `swift build -v` in `root` (every target, no tests), for a run that scans several targets: each is then planned
    /// from the returned log with `plan(fromPackageBuild:root:target:)`. Nil when the build failed.
    public static func buildPackage(root: String) throws -> String? {
        try buildPackage(root: URL(fileURLWithPath: root).standardizedFileURL.path, tests: false, serial: false)
    }

    /// Whether SwiftPM built in `root`'s `.build` before (either build system). A run that checks several targets builds
    /// the whole package only then: on a fresh checkout that would build targets the run does not need.
    public static func hasBuiltBefore(root: String) -> Bool {
        let scratch = URL(fileURLWithPath: root).standardizedFileURL.path + "/.build"
        return buildDescription(in: scratch) != nil || FileManager.default.fileExists(atPath: scratch + "/debug.yaml")
    }

    /// `plan(fromTestsBuild:root:target:)` for a `buildPackage` log.
    public static func plan(fromPackageBuild log: String, root: String, target: String) throws -> (plan: Plan, log: String)? {
        try plan(fromBuild: log, root: root, target: target, tests: false)
    }

    /// The plan of `target` of `root` from a `buildIncludingTests` log. When the log has no command for it and none
    /// was saved for this build description (the target was built by another kind of build last), its products are
    /// dropped and the package is built that way again, one task at a time, as `plan(root:target:)` does: later runs
    /// then find the command saved for this build description. Returns the plan and the log to use from then on; nil
    /// when that build fails.
    public static func plan(fromTestsBuild log: String, root: String, target: String) throws -> (plan: Plan, log: String)? {
        try plan(fromBuild: log, root: root, target: target, tests: true)
    }

    private static func plan(fromBuild log: String, root: String, target: String, tests: Bool) throws -> (plan: Plan, log: String)? {
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        let scratch = root + "/.build"
        if let found = try? plan(log: log, target: target, scratch: scratch, ownBuild: true) {
            recordTarget(target, tool: found.command.tool, arguments: found.command.arguments, in: scratch)
            return (found.plan, log)
        }
        removeProducts(of: target, in: scratch)
        guard let again = try buildPackage(root: root, tests: tests, serial: true) else { return nil }
        let found = try plan(log: again, target: target, scratch: scratch, ownBuild: true)
        recordTarget(target, tool: found.command.tool, arguments: found.command.arguments, in: scratch)
        return (found.plan, again)
    }

    private static func buildPackage(root: String, tests: Bool, serial: Bool) throws -> String? {
        let scratch = root + "/.build"
        try? FileManager.default.createDirectory(atPath: scratch + "/swiftformal", withIntermediateDirectories: true)
        let logPath = scratch + (tests ? "/swiftformal/build-tests.log" : "/swiftformal/build-package.log")
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        let swift = try ScanToolchain.swiftCommand(["build"] + (tests ? ["--build-tests"] : []) + ["-v"] + (serial ? ["-j", "1"] : []))
        let result = try Spawn.run(swift.executable, swift.arguments, directory: root, log: handle)
        recordOwnBuild(in: scratch)
        try? handle.close()
        guard result.status == 0 else { return nil }
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        saveCompileCommands(in: log, scratch: scratch)
        return log
    }
}
