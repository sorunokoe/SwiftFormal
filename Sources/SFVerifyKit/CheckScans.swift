import Foundation

extension Check {
    /// What `swiftformal check` verifies each `--scan` module with.
    public struct ScanSettings: Sendable {
        public var budget: Int
        public var selector: FunctionSelector?
        public var mutate = false
        /// `--proof-cache`; nil: each package's own (`ScanProofCache.directory(package:)`).
        public var proofCacheDirectory: String?
        public var noProofCache = false
        /// `VerifyOptions.opaqueCalls`; false with --no-opaque-calls.
        public var opaqueCalls = true
        /// `VerifyOptions.relational`: the walks' claims logic decides for every input (`Check.relationalRequests`).
        public var relational: [RelationalRequest] = []

        public init(budget: Int, selector: FunctionSelector? = nil) {
            self.budget = budget
            self.selector = selector
        }
    }

    /// A package built with its tests by `SwiftPMBuild.buildIncludingTests`: its scans plan from that build's log.
    public typealias BuiltPackage = (root: String, log: String)

    /// Builds and verifies each `--scan` module, packages at the same time (`jobs`, nil: `ScanSchedule.defaultJobs`),
    /// with the notes for stderr (`note`, called on this thread) and reports of one after another, in `scans` order.
    /// Returns them with `builtPackage` as its scans left it (they move its log on).
    public static func scan(
        _ scans: [(package: String, target: String)], settings: ScanSettings, jobs: Int?, builtPackage: BuiltPackage?,
        note: @escaping @Sendable (String) -> Void
    ) throws -> (reports: [ScanReport], builtPackage: BuiltPackage?) {
        var jobs = jobs ?? ScanSchedule.defaultJobs
        if !ScanSchedule.canScanPackagesAtOnce {
            if jobs > 1, scans.count > 1 { note("logic: without xcrun, packages are scanned one at a time") }
            jobs = 1
        }
        let built = Guarded(builtPackage)
        let compilers = Guarded([String?](repeating: nil, count: scans.count))
        let reports = try ScanSchedule.run(
            count: scans.count, jobs: jobs, folder: { ScanSchedule.buildFolder(of: scans[$0].package) },
            stages: ScanSchedule.Stages(
                plan: { index, note in
                    let scan = scans[index]
                    let started = Date()
                    note("logic: building \(scan.target) …")
                    return Planned(plan: try plan(scan, built: built), started: started)
                },
                compiler: { $0.plan.compiler },
                prove: { index, planned, note in
                    compilers.withLock { $0[index] = planned.plan.compiler }
                    return try prove(scans[index], planned, first: index == 0, settings: settings, note: note)
                }),
            note: note)
        // As after one after another: the last module's compiler is the process's (the walks read it).
        if let last = compilers.withLock({ $0.last }) { _ = try? ScanToolchain.select(swiftc: last) }
        return (reports, built.withLock { $0 })
    }

    private struct Planned: Sendable {
        var plan: SwiftPMBuild.Plan
        var started: Date
    }

    private static func samePackage(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    /// From the package build's log (or the command it saved), else a build of the target alone.
    private static func plan(_ scan: (package: String, target: String), built: Guarded<BuiltPackage?>) throws -> SwiftPMBuild.Plan {
        // Only scans of the built package read or move its log, and they are one package: one after another.
        if let package = built.withLock({ $0 }), samePackage(package.root, scan.package),
            let found = try SwiftPMBuild.plan(fromTestsBuild: package.log, root: package.root, target: scan.target)
        {
            built.withLock { $0 = (package.root, found.log) }
            return found.plan
        }
        return try SwiftPMBuild.plan(root: scan.package, target: scan.target)
    }

    private static func prove(
        _ scan: (package: String, target: String), _ planned: Planned, first: Bool, settings: ScanSettings,
        note: (String) -> Void
    ) throws -> ScanReport {
        let plan = planned.plan
        var compile = CompileOptions(files: plan.files, moduleName: scan.target, extraArguments: plan.arguments)
        compile.compiler = plan.compiler
        var options = VerifyOptions(conflictBudget: settings.budget, only: [])
        options.selector = settings.selector
        options.mutate = settings.mutate
        options.opaqueCalls = settings.opaqueCalls
        options.relational = settings.relational
        if !settings.noProofCache {
            options.proofCache = ScanProofCache(directory: settings.proofCacheDirectory ?? ScanProofCache.directory(package: scan.package))
        }
        let report = try SFVerify.run(
            compile, options, linking: { @Sendable [scan] in try SwiftPMBuild.localDependency($0, root: scan.package) })
        // Read while this module's compiler is the selected one: modules proved at the same time share it.
        if first { for line in (try? ScanToolchain.current().explanation) ?? [] { note(line) } }
        if report.pinned == false, let compiler = report.compiler {
            note("warning: unpinned compiler '\(compiler)': these verdicts are not covered by docs/TRUST.md")
        }
        for warning in report.warnings ?? [] { note("warning: \(scan.target): \(warning)") }
        let s = report.summary
        let seconds = Int(Date().timeIntervalSince(planned.started))
        if let selection = report.selection {
            let status = report.functions.first.map { " (\($0.status.rawValue))" } ?? ""
            note(
                "logic: \(scan.target): \(selection.function.map { $0 + status } ?? "no function selected"), "
                    + "\(report.unselected.count) others not verified (\(seconds) s)")
            return report
        }
        note(
            "logic: \(scan.target): \(s.safe + s.contractHolds) proved (\(s.contractHolds) contracts hold, \(s.safe) cannot crash), "
                + "\(s.mayTrap + s.contractFails) broken, "
                + "\(s.unsupported + s.undecided) outside what logic reads, of \(s.total) (\(seconds) s"
                + "\(report.proofCache.map { "; " + $0.shortSummary } ?? ""))")
        return report
    }
}
