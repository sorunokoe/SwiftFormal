import Foundation
import SFSIL
import SFVerifyKit

// The images this process runs from, read before any build it starts can replace them (the proof cache's key).
_ = ScanToolIdentity.current

var args = Array(CommandLine.arguments.dropFirst())
var files: [String] = []
var module = "Sample"
var package: String?
var target: String?
var extra: [String] = []
var optimization = Optimization.none
var only: [String] = []
var budget = 300_000
var json = false
var stats = false
var xcode = false
var format: String?
var showUnsupported = false
var strict = false
var build = false
var gate = false
var stamp: String?
var timeLimit: Int?
var budgetGiven = false
var configurations: [BuildConfiguration] = [.debug, .release]
var crossCheck = CrossCheck.off
var compiler: String?
var buildLog: String?
var scratchPath: String?
var cacheDirectory: String?
var emitTests: String?
var confirm = false
var paranoid = false
var modular = false
var selector: FunctionSelector?
var proofCacheDirectory: String?
var noProofCache = false
var noOpaqueCalls = false
var unwind = 8
var mutate = false
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

@MainActor func value(_ flag: String) -> String {
    guard !args.isEmpty else { fail("\(flag) needs a value") }
    return args.removeFirst()
}

/// The compile options of this run: the files, module and flags gathered above, with the compiler `--build` found.
@MainActor func compileOptions() -> CompileOptions {
    var options = CompileOptions(files: files, moduleName: module, optimization: optimization, extraArguments: extra)
    options.compiler = compiler
    options.verifiesCompilerSIL = paranoid
    return options
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data(("sfverify: warning: " + message + "\n").utf8))
}

let valueFlags: Set = [
    "--emit-tests", "--format", "--module", "--package", "--target", "--swiftc-arg", "--only", "--budget", "--time-limit", "--stamp",
    "--config", "--build-log", "--scratch-path", "--cache-dir", "--cross-check", "--module-cache", "--at", "--symbol",
    "--proof-cache", "--unwind",
]

while !args.isEmpty {
    var a = args.removeFirst()
    // `--flag=value` is the same as `--flag value`.
    if let equals = a.firstIndex(of: "="), valueFlags.contains(String(a[..<equals])) {
        args.insert(String(a[a.index(after: equals)...]), at: 0)
        a = String(a[..<equals])
    }
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "--module": module = value(a)
    case "--package": package = value(a)
    case "--target": target = value(a)
    case "--swiftc-arg": extra.append(value(a))
    case "-O": optimization = .speed
    case "--config":
        switch value(a) {
        case "debug": configurations = [.debug]
        case "release": configurations = [.release]
        case "both": configurations = [.debug, .release]
        case let other: fail("--config needs debug, release or both, not \(other)")
        }
    case "--cross-check":
        let text = value(a)
        guard let mode = CrossCheck(rawValue: text), mode != .off else { fail("--cross-check needs llvm or llvm-strict, not \(text)") }
        crossCheck = mode
    case "--only": only.append(value(a))
    case "--at", "--symbol":
        guard selector == nil else { fail("give one --at or --symbol") }
        do { selector = a == "--at" ? try FunctionSelector(at: value(a)) : .symbol(value(a)) } catch { fail("sfverify: \(error)") }
    case "--budget":
        guard let n = Int(value(a)), n > 0 else { fail("--budget needs a positive number of conflicts") }
        budget = n
        budgetGiven = true
    case "--time-limit":
        guard let n = Int(value(a)), n > 0 else { fail("--time-limit needs a number of seconds") }
        timeLimit = n
    case "--json": json = true
    case "--stats": stats = true
    case "--xcode": xcode = true
    case "--format":
        switch value(a) {
        case "text": format = nil
        case "json": json = true
        case "xcode": xcode = true
        case let other where other == "sarif" || other == "github": format = other
        case let other: fail("--format needs text, json, xcode, sarif or github, not \(other)")
        }
    case "--show-unsupported": showUnsupported = true
    case "--strict": strict = true
    case "--paranoid": paranoid = true
    case "--modular": modular = true
    case "--mutate": mutate = true
    case "--unwind":
        guard let n = Int(value(a)), n >= 0 else { fail("--unwind needs a number of iterations, 0 or more") }
        unwind = n
    case "--module-cache": ModuleCacheLocation.useRoot(value(a))
    case "--build": build = true
    case "--build-log": buildLog = value(a)
    case "--scratch-path": scratchPath = value(a)
    case "--cache-dir": cacheDirectory = value(a)
    case "--proof-cache": proofCacheDirectory = value(a)
    case "--no-proof-cache": noProofCache = true
    case "--no-opaque-calls": noOpaqueCalls = true
    case "--gate": gate = true
    case "--stamp": stamp = value(a)
    case "--emit-tests": emitTests = value(a)
    case "--confirm": confirm = true
    default:
        if a.hasPrefix("-") { fail("unknown option \(a)\n\n\(usage)") }
        files.append(a)
    }
}

// Flags that are accepted but have no effect in this combination: say so instead of silently ignoring them.
if stats && !json { warn("--stats has no effect without --json") }
if !gate && (stamp != nil || timeLimit != nil) { warn("--stamp and --time-limit only apply with --gate") }
if gate && mutate { warn("--mutate is ignored with --gate") }
if gate && !only.isEmpty { warn("--only is ignored with --gate: the gate proves every gated function") }
if let selector, gate { fail("\(selector) and --gate exclude each other: the gate proves every gated function") }
if let selector, !only.isEmpty { fail("\(selector) and --only exclude each other: --at and --symbol pick exactly one function") }
if json && xcode { warn("--xcode is ignored with --json") }
if gate && (emitTests != nil || confirm) { warn("--emit-tests and --confirm are ignored with --gate") }
if let format, json || xcode { warn("--format \(format) is ignored with --json or --xcode") }
if buildLog == nil && cacheDirectory != nil { warn("--cache-dir only applies with --build-log") }
if noProofCache && proofCacheDirectory != nil { fail("--proof-cache and --no-proof-cache exclude each other") }
if gate && proofCacheDirectory != nil { warn("--proof-cache is ignored with --gate") }
if buildLog != nil && build { fail("--build and --build-log exclude each other: --build-log reads a build that already ran") }
if buildLog != nil && target == nil { fail("--build-log needs --target") }
// The scratch path of --build-log: given, or `<package>/.build`, or a DerivedData folder given as the log, or the
// log's own folder.
let logScratch =
    scratchPath ?? package.map { $0 + "/.build" }
    ?? buildLog.map { log in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: log, isDirectory: &isDirectory) && isDirectory.boolValue
            ? log : (log as NSString).deletingLastPathComponent
    } ?? "."

do {
    var logText = ""
    var logArguments: [String] = []
    if let buildLog, let target {
        logText = try SwiftPMBuild.readBuildLog(buildLog, module: target)
        let plan = try SwiftPMBuild.plan(log: logText, target: target, scratch: logScratch, cacheDirectory: cacheDirectory)
        files += plan.files
        extra += plan.arguments
        logArguments = plan.arguments
        module = target
        compiler = plan.compiler
    } else if let package {
        if build {
            guard let target else { fail("--build needs --target") }
            let plan = try SwiftPMBuild.plan(root: package, target: target, scratch: scratchPath)
            files += plan.files
            extra += plan.arguments
            module = target
            compiler = plan.compiler
        } else {
            let found = try SFVerify.packageFiles(root: package, target: target)
            files += found.files
            extra += SFVerify.packageIncludes(root: package)
            extra += SFVerify.packageTargetArguments(root: package, extra: extra)
            if module == "Sample" { module = found.module }
        }
    }
    guard !files.isEmpty else { fail(usage) }
    if gate {
        let started = Date()
        let limit = timeLimit ?? 60
        let watched = files
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(limit)) {
            let lines = Gate.timeoutDiagnostics(files: watched, seconds: limit)
            FileHandle.standardError.write(
                Data((lines.joined(separator: "\n") + "\nsfverify: gate FAILED: timed out after \(limit) s\n").utf8))
            exit(1)
        }
        let result = SFVerify.gate(
            compileOptions(),
            {
                var gateOptions = VerifyOptions(conflictBudget: budgetGiven ? budget : 50_000, only: [])
                gateOptions.configurations = configurations
                gateOptions.opaqueCalls = !noOpaqueCalls
                return gateOptions
            }()
        )
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        for line in result.diagnostics { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        guard result.passed else {
            FileHandle.standardError.write(
                Data("sfverify: gate FAILED: \(result.proved) of \(result.gated) gated functions proved (\(milliseconds) ms)\n".utf8))
            exit(1)
        }
        if let stamp {
            // A comment only: the plugin names it `<Module>.sfgate.swift` so that SwiftPM compiles it (to nothing) instead
            // of copying it into a resource bundle of the gated target.
            try "// sfverify gate: \(result.proved) of \(result.gated) gated functions proved\n".write(
                toFile: stamp, atomically: true, encoding: .utf8)
        }
        print("sfverify: gate passed: \(result.proved) of \(result.gated) gated functions proved (\(milliseconds) ms)")
        exit(0)
    }
    var options = VerifyOptions(conflictBudget: budget, only: only)
    options.collectStats = stats
    options.configurations = configurations
    options.crossCheck = crossCheck
    options.modular = modular
    options.selector = selector
    options.opaqueCalls = !noOpaqueCalls
    if !noProofCache, let directory = proofCacheDirectory ?? package.map({ ScanProofCache.directory(package: $0) }) {
        options.proofCache = ScanProofCache(directory: directory)
    }
    options.unwind = unwind
    options.mutate = mutate
    let linkRoot = build ? package : nil
    // A dependency the chosen log did not compile comes from another activity log of the same folder (app study round 6, L1).
    let otherLogs = SwiftPMBuild.ActivityLogs(folder: buildLog ?? "")
    var report = try SFVerify.run(
        compileOptions(), options,
        // Called from the linker's threads: `@Sendable` keeps it off the main actor, with the values it reads copied.
        linking: { @Sendable [buildLog, logText, logArguments, logScratch, cacheDirectory, linkRoot, scratchPath] name in
            if buildLog != nil {
                return try SwiftPMBuild.localDependency(
                    name, log: logText, scratch: logScratch, cacheDirectory: cacheDirectory, otherLogs: otherLogs,
                    compatibleWith: logArguments)
            }
            return try linkRoot.flatMap { try SwiftPMBuild.localDependency(name, root: $0, scratch: scratchPath) }
        }
    )
    if let selector, report.selection?.function == nil {
        fail("sfverify: \(selector): no function of \(report.module) that Scan verifies is there; nothing was verified")
    }
    for warning in report.warnings ?? [] { warn(warning) }
    for line in (try? ScanToolchain.current().explanation) ?? [] {
        FileHandle.standardError.write(Data(("sfverify: note: " + line + "\n").utf8))
    }
    if report.pinned == false, let found = report.compiler {
        warn("unpinned compiler '\(found)': these verdicts are not covered by docs/TRUST.md (docs/guides/pin-upgrade.md)")
    }
    if let emitTests {
        try FileManager.default.createDirectory(atPath: emitTests, withIntermediateDirectories: true)
        let path = (emitTests as NSString).appendingPathComponent(Playback.fileName(module: report.module))
        try Playback.file(for: report).write(toFile: path, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("sfverify: wrote \(Playback.tests(for: report).tests.count) tests to \(path)\n".utf8))
    }
    if confirm {
        do {
            let confirmation = try Playback.confirm(report, files: files, arguments: extra, swift: try Playback.swiftDriver())
            let settled = Playback.settle(report, confirmation)
            report = settled.report
            if !settled.inconclusive.isEmpty {
                warn(
                    "not reproduced in the scratch build, whose settings may differ from the scan's (-D conditions, flags): "
                        + settled.inconclusive.joined(separator: ", ") + "; left unconfirmed")
            }
        } catch {
            warn("--confirm could not run the tests, so no counterexample is marked confirmed: \(error)")
        }
    }
    if json {
        print(try report.json())
    } else if xcode {
        print(report.diagnostics(showUnsupported: showUnsupported))
    } else if format == "sarif" {
        print(try report.sarif(baseDirectory: FileManager.default.currentDirectoryPath, showUnsupported: showUnsupported))
    } else if format == "github" {
        print(report.githubAnnotations(baseDirectory: FileManager.default.currentDirectoryPath, showUnsupported: showUnsupported))
    } else {
        print(report.text(showUnsupported: showUnsupported))
    }
    exit(report.hasFailures || (strict && report.summary.mayTrap > 0) ? 1 : 0)
} catch let error as ScanUsageError {
    fail("sfverify: \(error)")
} catch {
    // A target that imports another module of its package needs that module built: say how (plan item U10).
    let hint =
        !build && "\(error)".contains("no such module")
        ? "\nsfverify: hint: the code imports a module that was not built; with --package, add --build" : ""
    fail("sfverify: \(error)\(hint)")
}
