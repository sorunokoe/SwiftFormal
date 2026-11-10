import Foundation

/// The imported modules of a `--build-log` scan (app study round 6, L1). An incremental Xcode build recompiles only what
/// changed, so the newest activity log that compiled the target often has no command for a dependency. Such a module
/// was left out silently: its types were unknown and every function using them `unsupported`, with exit 0 and no
/// warning. Now the dependency's command comes from the newest other activity log of the same DerivedData folder that
/// compiled it, when that command targets the same platform (`-target`, `-sdk`); otherwise the module is reported as
/// not linked, with the reason.
extension SwiftPMBuild {
    /// The activity logs of a DerivedData folder (or its `Logs/Build`), newest first, decoded once each.
    public final class ActivityLogs: @unchecked Sendable {
        private let paths: [String]
        private let lock = NSLock()
        private var texts: [String: String] = [:]

        /// The logs of `folder` when it is a folder; none for a single log file.
        public init(folder: String) {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory)
            paths = exists && isDirectory.boolValue ? SwiftPMBuild.activityLogs(in: folder) : []
        }

        /// The newest log that compiled `module` with a whole command, with that command.
        func command(of module: String) -> ActivityLogCommand? {
            for path in paths {
                guard let text = text(of: path), let found = compileInvocation(in: text, module: module), isWhole(found.arguments)
                else { continue }
                return ActivityLogCommand(log: URL(fileURLWithPath: path).lastPathComponent, tool: found.tool, arguments: found.arguments)
            }
            return nil
        }

        private func text(of path: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let text = texts[path] { return text }
            let text = try? SwiftPMBuild.activityLogText(path)
            texts[path] = text
            return text
        }
    }

    /// The same as `localDependency(_:log:scratch:cacheDirectory:)`, but a local module the log did not compile is never
    /// left out silently: its command comes from the newest of `otherLogs` that compiled it with the same `-target` and
    /// `-sdk` as `main` (the scanned target's arguments), or this throws, and the module is reported as not linked.
    public static func localDependency(
        _ module: String, log: String, scratch: String, cacheDirectory: String? = nil, otherLogs: ActivityLogs,
        compatibleWith main: [String]
    ) throws -> CompileOptions? {
        let scratchPath = URL(fileURLWithPath: scratch).standardizedFileURL.path
        guard isLocalTarget(module, scratch: scratchPath) else { return nil }
        if let plan = try? plan(log: log, target: module, scratch: scratchPath, cacheDirectory: cacheDirectory) {
            return options(plan)
        }
        guard let found = otherLogs.command(of: module) else {
            throw ScanUsageError(
                "no compile command for \(module) in this build log, and no other activity log in the folder compiled it "
                    + "(an incremental build compiles only what changed; scan the log of a clean build, or build again after "
                    + "touching a file of \(module))")
        }
        for flag in ["-target", "-sdk"] where value(of: flag, in: found.arguments) != value(of: flag, in: main) {
            throw ScanUsageError(
                "no compile command for \(module) in this build log; the newest log that compiled it (\(found.log)) has "
                    + "another \(flag) (\(value(of: flag, in: found.arguments) ?? "none")), so it is not used")
        }
        let command = FoundCommand(tool: found.tool, arguments: found.arguments, cached: true)
        return options(finish(target: module, command, started: Date()))
    }

    /// The value after `flag` in `arguments`.
    private static func value(of flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
}

/// A compile command and the name of the activity log it was read from.
struct ActivityLogCommand {
    var log: String
    var tool: String
    var arguments: [String]
}
