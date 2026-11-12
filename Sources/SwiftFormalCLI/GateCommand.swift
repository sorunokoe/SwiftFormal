import Foundation
import SFVerifyKit

let gateUsage = """
    swiftformal check --gate — the build-time check: prove every promise with logic, before the tests run.

    USAGE
      swiftformal check --gate [--package <dir>] [--target <name> …] [--strict] [--tests <dir> …] [--budget <n>] [--force]
                               [--no-proof-cache] [--no-opaque-calls]
      swiftformal check --gate --build-log <file> --target <name> [--package <dir>] [--scratch-path <dir>] [--strict]
                               [--no-opaque-calls]

    WHAT IT CHECKS
      Functions and computed properties marked `@Verify` (a contract is `#requires` / `#ensures` in the body), in every
      target under --package (found as Sources/<Target>/), or only the --target ones. Each target is built with
      SwiftPM in the package's own .build (the one `swift build` and `swift test` use) and proved for all inputs.
      A hand-written `f_requires` / `f_ensures` and a `// sf:verify` comment are not read: each is an error that says
      to write the contract in place with @Verify, #requires and #ensures.
      With --build-log, the target's compile command is read from the log of a build that already ran (an Xcode app
      target: `xcodebuild … | tee build.log`, or the folder of Xcode's activity logs); nothing is built, and every run
      checks again (no stamps).

    OUTPUT  file:line:col diagnostics, which Xcode shows in the editor:
      error    a promise is broken, or the function may trap, for a concrete input (shown).
      warning  logic could not prove a `@Verify` function (unsupported, undecided). Only a test can check it now: the
               warning names the walk to call. With --strict, an error. With --tests, an error unless a `Prove`
               walk in those test sources is linked to the function (then a note names the walk).

    Every target is built on each run. One that passed before is not checked again while nothing the check read has
    changed: its files and build arguments with every module, header and macro they name, every file the compiler
    read, the local modules it links (theirs too), Package.swift and Package.resolved, the compiler and SDK,
    swiftformal itself, and the flags; its diagnostics are printed again. A target that is checked takes the answers
    checked before for the same code, contracts, callees, compiler and flags from the proof cache instead of proving
    them again. Both live in <package>/.build/swiftformal/proofs.

    OPTIONS
      --package <dir>       The SwiftPM package to check (default: the current directory).
      --target <name>       Check only this target; repeatable. With --build-log, exactly one.
      --build-log <file>    Read the target's compile command from this build log (or folder of activity logs).
      --scratch-path <dir>  With --build-log: the build folder of that build (default <package>/.build, or the log's
                            folder).
      --cache-dir <dir>     With --build-log: where the saved command is kept (default: the scratch path).
      --strict              Every promise must be proved by logic: warnings become errors. (Without --gate, --strict
                            makes a function that may trap fail the run; with it, the gate's warnings.)
      --tests <dir>         Test sources (a folder, searched for `Prove` walks); repeatable. A `@Verify` function that logic
                            cannot prove must have a walk linked to it, as `swiftformal check` links them, or the gate
                            fails. The gate does not run the walks: that the linked test runs and passes is for the tests.
      --budget <n>          Solver conflict budget per function (default 300000).
      --proof-cache <dir>   Keep checked answers in <dir> instead (trusted only when it and every directory above
                            it are writable by you or root alone).
      --no-proof-cache      Check every target and prove everything again; read and write no proof cache.
      --force               Check even the targets unchanged since they last passed.
      --no-opaque-calls     Refuse every call with no body (binary modules, Objective-C methods, `==` of Objective-C
                            objects) instead of assuming it returns any value without trapping.
      The other options of `swiftformal check` (--scan, --at, --json, …) do not apply with --gate.

    XCODE  Add a Run Script build phase (with "User Script Sandboxing" off for it):
      /path/to/swiftformal check --gate --package "$SRCROOT/Packages"
    CI     Run the same command (for an app target: --build-log of the CI build), then `swiftformal check` for the walks.

    EXIT CODES  0 no errors · 1 an error above, or a target that could not be built · 2 usage error
    """

/// Xcode gives a Run Script phase the build settings of an iOS build (`SDKROOT`, `ARCHS`, deployment targets …).
/// `swift build` would pick some of them up and build something else than the developer's `swift build`, so the
/// check runs with a plain environment: the same as in a terminal or on CI.
func dropXcodeBuildSettings() {
    let environment = ProcessInfo.processInfo.environment
    guard environment["XCODE_VERSION_ACTUAL"] != nil || environment["BUILT_PRODUCTS_DIR"] != nil else { return }
    let kept: Set = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "DEVELOPER_DIR", "TOOLCHAINS",
        "SWIFTFORMAL_WALK_LOG",
    ]
    for name in environment.keys where !kept.contains(name) { unsetenv(name) }
}

private struct GateRequest {
    var package = FileManager.default.currentDirectoryPath
    var packageGiven = false
    var targets: [String] = []
    var strict = false
    var budget = 300_000
    var proofCache: String?
    var noProofCache = false
    var tests: [String] = []
    var force = false
    var opaqueCalls = true
    var buildLog: String?
    var scratchPath: String?
    var cacheDirectory: String?

    init(_ arguments: [String]) {
        var args = arguments
        func value(_ flag: String) -> String {
            guard !args.isEmpty else { fail("\(flag) needs a value") }
            return args.removeFirst()
        }
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "-h", "--help": print(gateUsage); exit(0)
            case "--gate": continue
            case "--strict": strict = true
            case "--force": force = true
            case "--no-proof-cache": noProofCache = true
            case "--no-opaque-calls": opaqueCalls = false
            case _ where a.hasPrefix("-"): set(a, value(a))
            default: fail("unexpected argument \(a)\n\n\(gateUsage)")
            }
        }
        validate()
        package = URL(fileURLWithPath: package).standardizedFileURL.path
    }

    /// Options that exclude or need each other.
    private func validate() {
        if noProofCache && proofCache != nil { fail("--proof-cache and --no-proof-cache exclude each other") }
        if buildLog != nil && targets.count != 1 { fail("--build-log needs exactly one --target") }
        if buildLog == nil && (scratchPath != nil || cacheDirectory != nil) { fail("--scratch-path and --cache-dir need --build-log") }
    }

    /// An option with a value; any other option of `check` is a usage error here, not silently ignored.
    private mutating func set(_ flag: String, _ value: @autoclosure () -> String) {
        let known = ["--package", "--target", "--budget", "--build-log", "--scratch-path", "--cache-dir", "--proof-cache", "--tests"]
        guard known.contains(flag) else {
            fail("\(flag) does not apply with --gate (the gate proves @Verify promises and runs no walks)\n\n\(gateUsage)")
        }
        let text = value()
        switch flag {
        case "--package": (package, packageGiven) = (text, true)
        case "--target": targets.append(text)
        case "--budget":
            guard let n = Int(text), n > 0 else { fail("--budget needs a number") }
            budget = n
        case "--tests": tests.append(URL(fileURLWithPath: text).standardizedFileURL.path)
        case "--build-log": buildLog = text
        case "--scratch-path": scratchPath = text
        case "--cache-dir": cacheDirectory = text
        default: proofCache = text
        }
    }

    /// The proof cache of this run: given, the package's own, or none with --no-proof-cache.
    var cache: ScanProofCache? {
        noProofCache ? nil : ScanProofCache(directory: proofCache ?? ScanProofCache.directory(package: package))
    }

    /// Where the stamps of passing targets are kept (`VerifyStampCheck`): next to the proof cache; none with
    /// --no-proof-cache, and none with --build-log (a log is not a build whose inputs the stamp can hash).
    var stamps: String? {
        noProofCache || buildLog != nil
            ? nil : URL(fileURLWithPath: proofCache ?? ScanProofCache.directory(package: package)).standardizedFileURL.path + "/verify-v1"
    }

    /// The flags that change what a check prints.
    var settings: String {
        "strict=\(strict) budget=\(budget)\(opaqueCalls ? "" : " no-opaque-calls")"
            + (tests.isEmpty ? "" : " tests=\(BuildCheck.fingerprint(of: testFiles, salt: tests.joined(separator: ",")))")
    }

    /// The Swift files under the --tests folders.
    var testFiles: [String] {
        tests.flatMap { folder -> [String] in
            let names = FileManager.default.enumerator(atPath: folder)?.compactMap { $0 as? String } ?? []
            return names.filter { $0.hasSuffix(".swift") && !$0.contains(".build/") }.map { folder + "/" + $0 }
        }.sorted()
    }

    /// The walks of the --tests sources, or `nil` without --tests.
    var walks: [WalkCheck]? { tests.isEmpty ? nil : Check.findWalks(in: testFiles) }

    /// The targets to check: the named ones, or every target under the package with a promise.
    var found: [BuildCheck.Target] {
        guard !targets.isEmpty else { return BuildCheck.targets(under: package) }
        return targets.map { name in
            BuildCheck.target(named: name, under: package) ?? BuildCheck.Target(name: name, directory: "", files: [])
        }
    }

    /// The scratch path of --build-log: given, or `<package>/.build` when --package was given, or a folder given as
    /// the log, or the log's own folder.
    var logScratch: String {
        if let scratchPath { return scratchPath }
        if packageGiven { return package + "/.build" }
        guard let buildLog else { return "." }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: buildLog, isDirectory: &isDirectory) && isDirectory.boolValue
            ? buildLog : (buildLog as NSString).deletingLastPathComponent
    }
}

/// `swiftformal check --gate` (was `swiftformal verify`).
func runGate(_ arguments: [String]) -> Never {
    let request = GateRequest(arguments)
    dropXcodeBuildSettings()
    if let buildLog = request.buildLog, let name = request.targets.first {
        exit(gateFromLog(name, log: buildLog, request: request) ? 0 : 1)
    }
    guard FileManager.default.fileExists(atPath: request.package + "/Package.swift") else {
        fail("swiftformal: error: no Package.swift in \(request.package); pass --package <dir>, or --build-log for an app target")
    }
    let found = request.found
    if found.isEmpty {
        note("gate: nothing to check (no @Verify, sf:verify or _ensures under \(request.package))")
        exit(0)
    }
    // Two or more targets in a package built before: one `swift build` of the package, each target planned from its
    // log (one null build instead of one per target, and a build description that a plain `swift build` keeps).
    var packageLog: String?
    if found.count > 1, SwiftPMBuild.hasBuiltBefore(root: request.package) {
        packageLog = try? SwiftPMBuild.buildPackage(root: request.package)
    }
    var failed = false
    for target in found {
        failed = !gate(target.name, request: request, packageLog: &packageLog) || failed
    }
    exit(failed ? 1 : 0)
}

/// Builds and checks one target of the package, prints its diagnostics, and returns whether it passed. A target
/// unchanged since it last passed (`VerifyStampCheck`) is not checked again: its diagnostics are printed again.
/// With `packageLog` (one build of the package), the target is planned from it instead of from a build of its own.
private func gate(_ name: String, request: GateRequest, packageLog: inout String?) -> Bool {
    let started = Date()
    do {
        var fromPackage: SwiftPMBuild.Plan?
        if let log = packageLog, let found = try SwiftPMBuild.plan(fromPackageBuild: log, root: request.package, target: name) {
            (fromPackage, packageLog) = (found.plan, found.log)
        }
        let plan = try fromPackage ?? SwiftPMBuild.plan(root: request.package, target: name)
        let compile = CompileOptions(files: plan.files, moduleName: name, extraArguments: plan.arguments)
        let resolve: (String) throws -> CompileOptions? = { try SwiftPMBuild.localDependency($0, root: request.package) }
        // Hashed before anything reads the sources: the promises come from the bytes hashed, and an edit saved after
        // that is seen when the stamp would be written.
        let stamp = request.stamps.flatMap {
            VerifyStampCheck(
                directory: $0, package: request.package, target: name, settings: request.settings, compile: compile,
                toolchain: try? ScanToolchain.select(swiftc: nil))
        }
        if !request.force, let saved = stamp?.unchanged(resolve: resolve) {
            replay(saved, name: name)
            return true
        }
        let read: (String) -> String? = { path in stamp.map { $0.source(path) } ?? (try? String(contentsOfFile: path, encoding: .utf8)) }
        let target = GateTarget(name: name, files: plan.files, read: read, started: started)
        return check(
            target, request: request,
            run: { options in try SFVerify.run(stamp?.recording(compile) ?? compile, options, linking: stamp?.recording(resolve) ?? resolve)
            },
            passed: { result, report, notes, summary in
                stamp?.store(output: result.diagnostics, notes: notes, summary: summary, unlinked: report.unlinkedModules, resolve: resolve)
            })
    } catch {
        return couldNotBuild(name, error)
    }
}

/// Checks the target `name` compiled by the build that wrote `log` (an Xcode app target), without building it and
/// without stamps.
private func gateFromLog(_ name: String, log: String, request: GateRequest) -> Bool {
    let started = Date()
    do {
        let scratch = request.logScratch
        let logText = try SwiftPMBuild.readBuildLog(log, module: name)
        let plan = try SwiftPMBuild.plan(log: logText, target: name, scratch: scratch, cacheDirectory: request.cacheDirectory)
        var compile = CompileOptions(files: plan.files, moduleName: name, extraArguments: plan.arguments)
        compile.compiler = plan.compiler
        let otherLogs = SwiftPMBuild.ActivityLogs(folder: log)
        let arguments = plan.arguments
        let cacheDirectory = request.cacheDirectory
        let resolve: @Sendable (String) throws -> CompileOptions? = { dependency in
            try SwiftPMBuild.localDependency(
                dependency, log: logText, scratch: scratch, cacheDirectory: cacheDirectory, otherLogs: otherLogs,
                compatibleWith: arguments)
        }
        let target = GateTarget(name: name, files: plan.files, read: { try? String(contentsOfFile: $0, encoding: .utf8) }, started: started)
        return check(
            target, request: request, run: { options in try SFVerify.run(compile, options, linking: resolve) }, passed: { _, _, _, _ in })
    } catch {
        return couldNotBuild(name, error)
    }
}

/// One target to check: its name, its files, how to read them, and when its check started.
private struct GateTarget {
    var name: String
    var files: [String]
    var read: (String) -> String?
    var started: Date
}

/// The promises of the target's files, proved with `run`; prints the diagnostics and returns whether it passed.
private func check(
    _ target: GateTarget, request: GateRequest, run: (VerifyOptions) throws -> ScanReport,
    passed: (BuildCheckResult, ScanReport, [String], String) -> Void
) -> Bool {
    let (name, files, read, started) = (target.name, target.files, target.read, target.started)
    let promises = BuildCheck.promises(in: files, read: read)
    guard let names = BuildCheck.names(of: promises.promises, contractNames: Gate.contractNames(in: files, read: read)) else {
        promises.problems.forEach { print($0) }  // only `// sf:verify` comments: errors, no compiler run
        note("gate: \(name): no promises")
        return promises.problems.isEmpty
    }
    var options = VerifyOptions(conflictBudget: request.budget, only: names)
    options.proofCache = request.cache
    options.opaqueCalls = request.opaqueCalls
    let report: ScanReport
    do { report = try run(options) } catch { return couldNotBuild(name, error) }
    let notes = (report.warnings ?? []).map { "gate: \(name): warning: \($0)" }
    for line in notes { note(line) }
    var result = BuildCheck.evaluate(report, promises: promises.promises, strict: request.strict, walks: request.walks)
    result.diagnostics = promises.problems + result.diagnostics
    for line in result.diagnostics { print(line) }
    fflush(stdout)
    let assuming = result.provedAssuming > 0 ? " (\(result.provedAssuming) assuming calls with no body)" : ""
    let summary =
        "\(result.proved) of \(result.checked) promises proved by logic\(assuming), \(result.broken) broken, "
        + "\(result.unproved) left to the tests"
    note(
        "gate: \(name): \(summary) (\(Int(Date().timeIntervalSince(started))) s"
            + "\(report.proofCache.map { "; " + $0.shortSummary } ?? ""))")
    if result.passed { passed(result, report, notes, summary) }
    return result.passed
}

/// Prints why target `name` could not be built or read, as an error line; the gate then fails.
private func couldNotBuild(_ name: String, _ error: any Error) -> Bool {
    let reason = "\(error)"
    for line in reason.split(separator: "\n") where line.contains(": error:") { print(line) }
    print("swiftformal: error: [SwiftFormal] could not build \(name) to check it: \(reason.prefix(400))")
    return false
}

/// Prints again what the last passing check of target `name` printed.
private func replay(_ stamp: VerifyStamp, name: String) {
    for line in stamp.notes { note(line) }
    for line in stamp.output { print(line) }
    fflush(stdout)
    note("gate: \(name): \(stamp.summary) (unchanged since it last passed)")
}
