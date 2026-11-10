import Foundation
import SFVerifyKit

// The images this process runs from, read before any build it starts can replace them (the proof cache's key).
_ = ScanToolIdentity.current

let usage = """
    swiftformal — prove with logic first, for every input; walks check the promises the tests state.

    USAGE
      swiftformal check --scan <package-dir>:<target> [--scan …] [--tests <package-dir>:<test-target>] [options]
      swiftformal check --build-log <file> --target <name> [--tests …] [options]
                                                  an app target, from the log of a build that ran
      swiftformal check --gate [--package <dir>] [--target <name> …] [--strict]
                                                  the build-time check: every @Verify promise,
                                                  as Xcode errors and warnings (`swiftformal check --gate --help`)
      swiftformal doctor [--package <dir>]        check the setup: compiler pin, release build, package wiring
      swiftformal strings <path> [--sources <dir>]
                                                  check localization catalogues: missing languages, format
                                                  arguments, untranslated keys (`swiftformal strings --help`)
      swiftformal lsp                             language server: proves on save, verdicts as code lenses
                                                  (`swiftformal lsp --help`, docs/guides/editor.md)

    CHECK
      1. Logic. Every --scan target is built once with SwiftPM and proved from the compiler's SIL, for all inputs:
         cannot trap, and `@Verify` contracts (`#requires` ⇒ `#ensures`). No code runs.
      2. Walks. Each `Prove(it: …, over: …)` in the test target is linked to the function it calls, read from the
         `it:` closure or from a subject written first (`Type.==` names the operator). Every linked walk runs, also
         where a contract holds: a walk may state another promise (a table, injectivity). Walks that cover only
         functions where logic already found a failing input are not run, and are listed with the reason.
      3. One verdict per function: proved by logic for every input, proved over the walked inputs only, bounded,
         broken, or unchecked. A walk proves only the function it names: one whose subject names only a type
         proves none of its members, and its failure is blamed on no member. A known issue next to another walk's
         proof is shown as a disagreement.

    OPTIONS
      --scan <dir>:<target>    A SwiftPM package and the target to prove; repeatable.
      --build-log <file>       With --target: prove a target that a build already compiled (an Xcode or Tuist app
                               target), with the compile command from that build's log or the folder of Xcode's
                               activity logs; nothing is built. --scratch-path names that build's folder (default:
                               the log's folder), --cache-dir where the command is saved for a build that compiled
                               nothing. Its proof cache is --proof-cache only.
      --tests <dir>:<target>   The package to run `swift test` in, and the test target with the walks.
      --test-sources <dir>     Where the walks are (default: <dir>/Tests/<target>).
      --no-walks               Logic only.
      --budget <n>             Solver conflict budget per function (default 300000).
      --proof-cache <dir>      Where checked answers are kept between runs (default: <package-dir>/.build/swiftformal/proofs
                               of each --scan). Only checked proofs and replayed counterexamples are kept; a function
                               whose code, contracts, callees, compiler or flags changed is proved again. Not used
                               unless the directory and every one above it are writable only by you (or root).
      --no-proof-cache         Prove everything again; read and write no proof cache.
      --no-opaque-calls        Refuse every call with no body (binary modules, Objective-C methods, `==` of
                               Objective-C objects) instead of assuming it returns any value without trapping.
      --jobs <n>               Scan up to n packages at a time (default: half the cores, at most one per 2 GiB of
                               memory). The --scan targets of one package are scanned one after another; the report
                               and exit code are those of --jobs 1, which scans one target at a time.
      --at <file>:<line>       Check only the function whose body holds that line (the innermost one; its declaration,
                               attribute and doc-comment lines count), with the walks linked to it. Fails unless
                               exactly one function of the scanned targets is there.
      --symbol <name>          Check only the function with this name as reports print it (`Score.clamp(_:)`), or with
                               this Type.member and argument labels; fails unless exactly one has it. Every target is
                               still built and read, so walks link as without it; only the others' proofs are skipped.
      --mutate                 Check each contract that holds again on small edits of its function, and list it as
                               weak when an edit that changes the result still satisfies it (as `sfverify --mutate`).
      --json                   Machine-readable report on stdout.
      --xcode                  Compiler-format lines (file:line:col: error|warning|note: [swiftformal] …) for Xcode,
                               VS Code's $swiftc matcher and CI logs. error = what fails the run (a broken promise,
                               a walk that did not report; a trap only with --strict or a walk that fails on it);
                               notes give the input, the replay, the walk and the call chain. A counterexample is
                               concrete; "undecided" means no proof and no counterexample.
      --format <f>             text (default), json (as --json), xcode (as --xcode), sarif (SARIF 2.1.0, for GitHub
                               code scanning) or github (GitHub Actions annotations). xcode, sarif and github list the
                               same findings; the exit code is the same in every format.
      --emit-tests <dir>       Write <dir>/<Module>ScanPlaybackTests.swift for each --scan target: one Swift Testing
                               test per counterexample logic found, which replays the input on the real function.
      --show-unchecked         List the functions neither engine checked.
      --show-proved            List every function logic proved cannot trap (by default only their number).
      --strict                 Exit 1 also when a function may trap.
      -h, --help               This text.

    EXIT CODES  0 no promise broken · 1 a promise is broken (or a linked walk did not report) · 2 usage or build error
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func note(_ message: String) { FileHandle.standardError.write(Data(("swiftformal: " + message + "\n").utf8)) }

/// Commands of pre-release builds that `check` replaced: each says what to run instead.
let removedCommands = [
    "verify": "swiftformal verify was removed: run `swiftformal check --gate` (the same options and exit codes)",
    "scan":
        "swiftformal scan was removed: run `swiftformal check --scan <package-dir>:<target>` (--format json|xcode|sarif|github, "
        + "--emit-tests <dir>, --at, --symbol, --mutate)",
    "gen": "swiftformal gen was removed: walk a function in a test with `Prove(it: …, over: …) { … }` (SwiftFormalTesting)",
]

let doctorUsage = """
    swiftformal doctor — check the setup, and say how to fix what is wrong.

    USAGE
      swiftformal doctor [--package <dir>]

    CHECKS
      compiler      swiftc against the compilers Scan was validated against (the pin)
      swiftformal   this swiftformal is a release build (debug proofs are far slower)
      exit tests    Swift 6.3 or newer, not iOS: the trap walk and `check --emit-tests` tests need them
      package …     with a package (--package, or Package.swift in the working directory): products and plugins
                    of SwiftFormal it still names that were removed (SwiftFormalContracts, SFProve, SFVerifyKit,
                    SFGenKit, sfverify, sfgen, SwiftFormalGate, SwiftFormalScan) and what to use instead,
                    `// sf:verify` comments and hand-written contracts under the removed gate plugin (no longer
                    read), and gate stamps copied into a resource bundle

    EXIT CODES  0 every check passed · 1 a check needs attention · 2 usage error
    """

/// `swiftformal doctor` (plan item U9).
func doctor(_ arguments: [String]) -> Never {
    var arguments = arguments
    var package: String?
    while !arguments.isEmpty {
        let a = arguments.removeFirst()
        switch a {
        case "-h", "--help": print(doctorUsage); exit(0)
        case "--package":
            guard !arguments.isEmpty else { fail("--package needs a value") }
            package = arguments.removeFirst()
        default: fail("unknown option \(a)\n\n\(doctorUsage)")
        }
    }
    let root = package ?? FileManager.default.currentDirectoryPath
    if package != nil, !FileManager.default.fileExists(atPath: root + "/Package.swift") {
        fail("swiftformal: no Package.swift in \(root)")
    }
    let directory = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent()
    #if DEBUG
        let isDebug = true
    #else
        let isDebug = false
    #endif
    let facts = Doctor.gather(toolDirectory: directory.path, packageRoot: root, swiftformalIsDebug: isDebug)
    let checks = Doctor.checks(facts)
    print(Doctor.render(checks))
    exit(Doctor.exitCode(checks))
}

func pair(_ text: String, _ flag: String) -> (String, String) {
    guard let colon = text.lastIndex(of: ":") else { fail("\(flag) needs <package-dir>:<target>") }
    return (String(text[..<colon]), String(text[text.index(after: colon)...]))
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()
switch command {
case "-h", "--help", "help": print(usage); exit(0)
case let removed where removedCommands[removed] != nil: fail(removedCommands[removed] ?? "")
case "check": if args.contains("--gate") { runGate(args) }
case "doctor": doctor(args)
case "strings": runStrings(args)
case "lsp":
    #if canImport(SFLanguageServer)
        runLanguageServer(args)
    #else
        fail("swiftformal lsp is built on macOS only")
    #endif
default: fail("unknown command \(command)\n\n\(usage)")
}

var scans: [(package: String, target: String)] = []
var tests: (package: String, target: String)?
var testSources: String?
var walks = true
var budget = 300_000
var json = false
var xcode = false
var showUnchecked = false
var showProved = false
var strict = false
var selector: FunctionSelector?
var proofCacheDirectory: String?
var noProofCache = false
var noOpaqueCalls = false
var mutate = false
var jobs: Int?
var format: String?
var emitTests: String?
var buildLog: String?
var logTarget: String?
var logScratch: String?
var logCache: String?

@MainActor func value(_ flag: String) -> String {
    guard !args.isEmpty else { fail("\(flag) needs a value") }
    return args.removeFirst()
}

while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "--scan": scans.append(pair(value(a), a))
    case "--tests": tests = pair(value(a), a)
    case "--test-sources": testSources = value(a)
    case "--no-walks": walks = false
    case "--budget":
        guard let n = Int(value(a)), n > 0 else { fail("--budget needs a number") }
        budget = n
    case "--at", "--symbol":
        guard selector == nil else { fail("give one --at or --symbol") }
        do {
            selector = a == "--at" ? try FunctionSelector(at: value(a)) : .symbol(value(a))
        } catch {
            fail("swiftformal: \(error)")
        }
    case "--proof-cache": proofCacheDirectory = value(a)
    case "--no-proof-cache": noProofCache = true
    case "--no-opaque-calls": noOpaqueCalls = true
    case "--jobs":
        guard let n = Int(value(a)), n > 0 else { fail("--jobs needs a number of at least 1") }
        jobs = n
    case "--json": json = true
    case "--xcode": xcode = true
    case "--format":
        switch value(a) {
        case "text": (json, xcode, format) = (false, false, nil)
        case "json": json = true
        case "xcode": xcode = true
        case let other where other == "sarif" || other == "github": format = other
        case let other: fail("--format needs text, json, xcode, sarif or github, not \(other)")
        }
    case "--emit-tests": emitTests = value(a)
    case "--build-log": buildLog = value(a)
    case "--target": logTarget = value(a)
    case "--scratch-path": logScratch = value(a)
    case "--cache-dir": logCache = value(a)
    case "--show-unchecked": showUnchecked = true
    case "--show-proved": showProved = true
    case "--strict": strict = true
    case "--mutate": mutate = true
    default: fail("unknown option \(a)\n\n\(usage)")
    }
}
if (buildLog == nil) != (logTarget == nil) { fail("--build-log and --target go together: the log of a build, and the target it compiled") }
if buildLog == nil && (logScratch != nil || logCache != nil) { fail("--scratch-path and --cache-dir need --build-log") }
guard !scans.isEmpty || buildLog != nil else {
    fail("check needs at least one --scan <package-dir>:<target>, or --build-log <file> --target <name>\n\n\(usage)")
}
if json && xcode { note("warning: --xcode is ignored with --json") }
if let format, json || xcode { note("warning: --format \(format) is ignored with --json or --xcode") }
if noProofCache && proofCacheDirectory != nil { fail("--proof-cache and --no-proof-cache exclude each other") }

// When the walks are in a scanned package, one `swift build --build-tests` builds that package first: its scans read
// their compile commands from that build's log and the walks run without building, so SwiftPM runs twice in all, not
// three times. Tests of another package build in the background while the scans run.
var testBuild: Check.TestBuild?
var builtPackage: (root: String, log: String)?
func samePackage(_ a: String, _ b: String) -> Bool {
    URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
}
do {
    if walks, let tests {
        if scans.contains(where: { samePackage($0.package, tests.package) }) {
            note("logic: building \(tests.package) with its tests …")
            builtPackage = try SwiftPMBuild.buildIncludingTests(root: tests.package).map { (tests.package, $0) }
        } else {
            let scratch = tests.package + "/.build/swiftformal"
            try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
            testBuild = try Check.startTestBuild(package: tests.package, log: scratch + "/test-build.out")
        }
    }
    var settings = Check.ScanSettings(budget: budget, selector: selector)
    settings.mutate = mutate
    settings.proofCacheDirectory = proofCacheDirectory
    settings.noProofCache = noProofCache
    settings.opaqueCalls = !noOpaqueCalls
    if walks, let tests {
        // The walks' `Injective`, `RoundTrip` and `Agrees` that logic may prove for every input (RelationalWalks.swift).
        settings.relational = Check.relationalRequests(
            testSources: testSources ?? tests.package + "/Tests/" + tests.target, packages: [tests.package] + scans.map(\.package),
            scanned: scans.map(\.target))
    }
    let scanned = try Check.scan(scans, settings: settings, jobs: jobs, builtPackage: builtPackage, note: note)
    var reports = scanned.reports
    var packages = scans.map(\.package)
    if let buildLog, let logTarget {
        let scan = Check.BuildLogScan(log: buildLog, target: logTarget, scratchPath: logScratch, cacheDirectory: logCache)
        reports.append(try Check.scan(scan, settings: settings, note: note))
        packages.append(scan.scratch)
    }
    builtPackage = scanned.builtPackage

    // Thrown, not `fail`ed: the catch below stops the background test build, which holds SwiftPM's lock.
    if let selector { try Check.requireOneSelected(reports, by: selector) }
    if let emitTests {
        for written in try Check.emitPlaybackTests(reports, to: emitTests) { note("wrote \(written.tests) tests to \(written.path)") }
    }

    var found: [WalkCheck] = []
    var records: [WalkRecord] = []
    var known: Set<String> = []
    if walks, let tests {
        let sources = testSources ?? tests.package + "/Tests/" + tests.target
        let files =
            FileManager.default.enumerator(atPath: sources)?.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }.map { sources + "/" + $0 } ?? []
        // A walk over `X(…).execute()` whose `execute()` only returns `body` checks `X.body` (mapper plan T2).
        found = Check.resolvingForwarders(
            Check.findWalks(in: files), packages: [tests.package] + scans.map(\.package), scanned: scans.map(\.target), testFiles: files)
    }
    let plan = Check.plan(scans: reports, walks: found)
    let notSelected = plan.notSelected.isEmpty ? "" : "; \(plan.notSelected.count) not selected"
    if let tests, !plan.run.isEmpty {
        let started = Date()
        let toRun = plan.run.map { found[$0] }
        note(
            "walks: running \(toRun.count) of \(found.count) (\(plan.skippedByLogic.count) not run: logic found a failing input; "
                + "\(plan.unlinked.count) not linked\(notSelected)) …"
        )
        let scratch = tests.package + "/.build/swiftformal"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let log = scratch + "/walks.jsonl"
        let result = try Check.runWalks(
            toRun, package: tests.package, log: log, built: testBuild,
            skipBuild: builtPackage.map { samePackage($0.root, tests.package) } ?? false)
        let results = Check.walkResults(log: log, testOutput: result.output)
        records = results.records
        known = results.knownIssues
        let source = results.source == .eventStream ? "test event stream" : "walk log"
        note("walks: \(records.count) results in \(Int(Date().timeIntervalSince(started))) s, from the \(source) (test output: \(log).out)")
        if records.isEmpty, result.exitCode != 0 {
            fail("swiftformal: `swift test` failed before any walk reported; see \(log).out")
        }
    } else {
        testBuild?.cancel()
        if !found.isEmpty {
            note(
                "walks: none needed (\(plan.skippedByLogic.count) not run: logic found a failing input; \(plan.unlinked.count) not linked"
                    + "\(notSelected))")
        }
    }

    records = Check.applyingRelational(reports.flatMap { $0.relational ?? [] }, to: records)
    var report = Check.merge(scans: reports, plan: plan, records: records, knownIssues: known, packages: packages)
    if !report.unlinkedWalks.isEmpty {
        // Which `--scan` would link them, from the sources of the packages given (no build).
        let hintPackages = (tests.map { [$0.package] } ?? []) + scans.map(\.package)
        let members = Check.memberHints(for: report.unlinkedWalks, scans: reports)
        report.scanHints = members.hints + Check.scanHints(for: members.rest, packages: hintPackages, scanned: scans)
    }
    if json {
        print(try report.json())
    } else if xcode {
        print(report.diagnostics(strict: strict, showUnchecked: showUnchecked, showProved: showProved))
    } else if format == "sarif" {
        let base = FileManager.default.currentDirectoryPath
        print(try report.sarif(baseDirectory: base, strict: strict, showUnchecked: showUnchecked, showProved: showProved))
    } else if format == "github" {
        let base = FileManager.default.currentDirectoryPath
        print(report.githubAnnotations(baseDirectory: base, strict: strict, showUnchecked: showUnchecked, showProved: showProved))
    } else {
        print(report.text(showUnchecked: showUnchecked, showProved: showProved))
    }
    exit(report.hasFailures(strict: strict) ? 1 : 0)
} catch {
    testBuild?.cancel()
    fail("swiftformal: \(error)")
}
