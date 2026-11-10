import Foundation

extension Check {
    /// A target compiled by a build that already ran (an Xcode or Tuist app target): `swiftformal check --build-log
    /// <file> --target <name>`. Its compile command comes from the log (or the folder of Xcode's activity logs), the
    /// modules it imports from that build or the other logs of the folder; nothing is built.
    public struct BuildLogScan: Sendable {
        public var log: String
        public var target: String
        /// The build folder of that build (default: the log's folder, or the folder given as the log).
        public var scratchPath: String?
        /// Where the command is saved for a later build that compiled nothing (default: the scratch path).
        public var cacheDirectory: String?

        public init(log: String, target: String, scratchPath: String? = nil, cacheDirectory: String? = nil) {
            self.log = log
            self.target = target
            self.scratchPath = scratchPath
            self.cacheDirectory = cacheDirectory
        }

        /// The scratch path: given, or a folder given as the log, or the log's own folder.
        public var scratch: String {
            if let scratchPath { return scratchPath }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: log, isDirectory: &isDirectory) && isDirectory.boolValue
                ? log : (log as NSString).deletingLastPathComponent
        }
    }

    /// Verifies the target of `scan` from its build log, as `scan(_:settings:jobs:builtPackage:note:)` verifies a
    /// SwiftPM target. The proof cache is `settings.proofCacheDirectory` only: a log has no package of its own.
    public static func scan(_ scan: BuildLogScan, settings: ScanSettings, note: @escaping @Sendable (String) -> Void) throws
        -> ScanReport
    {
        let started = Date()
        note("logic: reading \(scan.target) from \(scan.log) …")
        let logText = try SwiftPMBuild.readBuildLog(scan.log, module: scan.target)
        let scratch = scan.scratch
        let plan = try SwiftPMBuild.plan(log: logText, target: scan.target, scratch: scratch, cacheDirectory: scan.cacheDirectory)
        var compile = CompileOptions(files: plan.files, moduleName: scan.target, extraArguments: plan.arguments)
        compile.compiler = plan.compiler
        var options = VerifyOptions(conflictBudget: settings.budget, only: [])
        options.selector = settings.selector
        options.mutate = settings.mutate
        options.opaqueCalls = settings.opaqueCalls
        options.relational = settings.relational
        if !settings.noProofCache, let directory = settings.proofCacheDirectory {
            options.proofCache = ScanProofCache(directory: directory)
        }
        let otherLogs = SwiftPMBuild.ActivityLogs(folder: scan.log)
        let arguments = plan.arguments
        let cacheDirectory = scan.cacheDirectory
        let report = try SFVerify.run(
            compile, options,
            linking: { @Sendable name in
                try SwiftPMBuild.localDependency(
                    name, log: logText, scratch: scratch, cacheDirectory: cacheDirectory, otherLogs: otherLogs,
                    compatibleWith: arguments)
            })
        for line in (try? ScanToolchain.current().explanation) ?? [] { note(line) }
        if report.pinned == false, let compiler = report.compiler {
            note("warning: unpinned compiler '\(compiler)': these verdicts are not covered by docs/TRUST.md")
        }
        for warning in report.warnings ?? [] { note("warning: \(scan.target): \(warning)") }
        let s = report.summary
        note(
            "logic: \(scan.target): \(s.safe + s.contractHolds) proved, \(s.mayTrap + s.contractFails) broken, "
                + "\(s.unsupported + s.undecided) outside what logic reads, of \(s.total) "
                + "(\(Int(Date().timeIntervalSince(started))) s)")
        return report
    }
}
