import Foundation
import SFSIL

public enum SFVerify {
    /// Compiles `compile.files` as one module, then verifies every supported function.
    ///
    /// At `-Onone` with both configurations in `options.configurations` (the default), the module is compiled again
    /// with `-assert-config Release`, and every function whose code (with its callees) differs there is verified again.
    /// A function is `safe` or `contractHolds` only when it is in each configuration (plan item R5).
    ///
    /// With `options.selector`, only the function it picks is verified (in each configuration) and reported; the
    /// others are listed in `ScanReport.unselected`. A module where it picks no function (another file than `--at`'s)
    /// is compiled once, for that list only, and its `configurations` name only the first.
    ///
    /// - Parameter dependency: see `ModuleCompiler.compile(_:linking:)`; imported modules it returns options for are
    ///   linked in, so that their types and functions are known (only this module's functions are reported). It is
    ///   asked about each module once, one call at a time, possibly from another thread (both configurations share it).
    public static func run(
        _ compile: CompileOptions, _ options: VerifyOptions = VerifyOptions(),
        linking dependency: (String) throws -> CompileOptions? = { _ in nil }
    ) throws -> ScanReport {
        let toolchain = try ScanToolchain.select(swiftc: compile.compiler)
        var options = options
        options.proofCache = startProofCache(options.proofCache)
        let configurations = compile.optimization == .none ? Self.configurations(options) : [.release]
        var first = compile
        first.configuration = configurations[0]
        return try withoutActuallyEscaping(dependency) { dependency in
            // Both configurations link the same imports: each is asked about once, one at a time (it may run
            // `swift build`, which writes one shared log).
            let dependencies = Dependencies(dependency)
            // The second configuration compiles on its own thread while the first compiles and is verified.
            let compileSecond = { inBackground(compile, configuration: configurations[1], dependencies: dependencies) }
            var other = configurations.count > 1 && (options.selector?.mayMatch(files: compile.files) ?? true) ? compileSecond() : nil
            let compiled: CompiledModule
            let selected: SelectedFunctions?
            do {
                compiled = try ModuleCompiler.compile(first, linking: dependencies.options)
                selected = try options.selector.map {
                    try SelectedFunctions($0, in: compiled, module: compile.moduleName, files: compile.files, options: options)
                }
            } catch {
                _ = try? other?.value()
                throw error
            }
            // `mayMatch` only starts the second build early: a function that is verified at all is verified in both.
            if other == nil, configurations.count > 1, selected.map({ !$0.symbols.isEmpty }) ?? true { other = compileSecond() }
            let started = Date()
            var functions = Verifier.run(compiled, options: options, symbols: selected?.symbols)
            var compileSeconds = compiled.compileSeconds, parseSeconds = compiled.parseSeconds,
                unlinked = Set(compiled.unlinkedModules.keys)
            if let other {
                let second = try other.value()
                unlinked.formUnion(second.unlinkedModules.keys)
                (compileSeconds, parseSeconds) = (compileSeconds + second.compileSeconds, parseSeconds + second.parseSeconds)
                functions = recheck(functions, first: compiled, second: second, configuration: configurations[1], options: options)
            }
            if options.crossCheck != .off {
                var first = compile
                first.configuration = configurations[0]
                functions = crossChecked(functions, compiled: compiled, compile: first, options: options)
            }
            functions = UnlinkedModules.explained(functions, compiled: compiled)
            if options.mutate { functions = ContractStrength.check(functions, compiled: compiled.reading(options)) }
            var report = Self.report(
                functions, compile: compile, compiled: compiled, options: options,
                timing: .init(
                    compileSeconds: compileSeconds, parseSeconds: parseSeconds,
                    verifySeconds: Date().timeIntervalSince(started), silBytes: compiled.silBytes))
            report.relational = try Verifier.proveRelational(options, first: compiled, second: other?.value(), compile: compile)
            report.configurations = (other == nil ? [configurations[0]] : configurations).map(\.rawValue)
            report.describe(toolchain: toolchain, options: options, selected: selected)
            (report.proofCache, report.unlinkedModules) = (options.proofCache?.use, unlinked.sorted())
            return report
        }
    }

    /// The report of one scan: the verdicts, the timing and the run's warnings.
    private static func report(
        _ functions: [FunctionReport], compile: CompileOptions, compiled: CompiledModule, options: VerifyOptions,
        timing: ScanReport.Timing
    ) -> ScanReport {
        var report = ScanReport(
            module: compile.moduleName, optimization: compile.optimization == .none ? "-Onone" : "-O", functions: functions,
            compilerGenerated: compiled.functions.filter(\.isGenerated).count, timing: timing)
        let warnings = compiled.warnings + UnlinkedModules.warnings(compiled.unlinkedModules)
        report.warnings = warnings.isEmpty ? nil : warnings
        if options.mutate { report.summary.weakContracts = functions.count { $0.origin == nil && $0.weakContract != nil } }
        return report
    }

    /// A cache whose counts are this module's (both configurations count into one `ProofCacheUse`). Keys need the
    /// encoder's digest (`ScanToolIdentity.versions`, made once per process): it is made while the module compiles.
    private static func startProofCache(_ cache: ScanProofCache?) -> ScanProofCache? {
        if let cache, cache.versions == nil { DispatchQueue.global().async { _ = ScanToolIdentity.versions } }
        return cache?.forRun()
    }

    private static func inBackground(
        _ compile: CompileOptions, configuration: BuildConfiguration, dependencies: Dependencies
    ) -> Background<CompiledModule> {
        Background {
            var options = compile
            options.configuration = configuration
            return try ModuleCompiler.compile(options, linking: dependencies.options)
        }
    }

    private static func configurations(_ options: VerifyOptions) -> [BuildConfiguration] {
        let wanted = BuildConfiguration.allCases.filter { options.configurations.contains($0) }
        return wanted.isEmpty ? [.debug] : wanted
    }

    /// Verifies again, in `second`, every function that `first` did not refute or refuse and whose code differs there,
    /// and keeps the worse verdict.
    static func recheck(
        _ reports: [FunctionReport], first: CompiledModule, second: CompiledModule, configuration: BuildConfiguration,
        options: VerifyOptions
    ) -> [FunctionReport] {
        let open: Set<ScanStatus> = [.safe, .contractHolds, .undecided]
        var comparison = ClosureComparison(first: first.module, second: second.module)
        comparison.prepare(reports.filter { open.contains($0.status) }.map(\.symbol))
        var changed: Set<String> = []
        for report in reports where open.contains(report.status) && !comparison.isUnchanged(report.symbol) {
            changed.insert(report.symbol)
        }
        guard !changed.isEmpty else { return reports }
        let again = Dictionary(
            Verifier.run(second, options: options, symbols: changed).map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        return reports.map { report in
            guard changed.contains(report.symbol) else { return report }
            guard let other = again[report.symbol] else {
                var missing = report
                missing.status = .unsupported
                missing.category = "build configurations"
                missing.detail = "not found in the \(configuration.rawValue) build (-assert-config \(configuration.rawValue.capitalized))"
                return missing
            }
            return worse(report, other, configuration: configuration)
        }
    }

    /// The verdict that holds in both builds: a refutation in either wins, then a refusal, then `undecided`.
    static func worse(_ a: FunctionReport, _ b: FunctionReport, configuration: BuildConfiguration) -> FunctionReport {
        func rank(_ s: ScanStatus) -> Int {
            switch s {
            case .mayTrap, .contractFails: 4
            case .internalError: 3
            case .unsupported: 2
            case .undecided: 1
            case .safe, .contractHolds: 0
            }
        }
        var merged = Set(a.assumptions ?? []).union(b.assumptions ?? [])
        guard rank(b.status) > rank(a.status) else {
            var result = a
            if [.unsupported, .internalError].contains(a.status) { merged = [] }
            result.assumptions = merged.isEmpty ? nil : merged.sorted()
            return result
        }
        var result = b
        if [.unsupported, .internalError].contains(b.status) { merged = [] }
        result.assumptions = merged.isEmpty ? nil : merged.sorted()
        result.name = a.name
        result.location = a.location
        result.seconds = a.seconds + b.seconds
        let build = "in a \(configuration.rawValue) build (-assert-config \(configuration.rawValue.capitalized))"
        if var counterexample = result.counterexample {
            counterexample.failure = build + ": " + counterexample.failure
            result.counterexample = counterexample
        }
        result.detail = result.detail.map { build + ": " + $0 }
        return result
    }

    /// `-I` arguments for the module products of an earlier `swift build` in `root`, so that imports of the
    /// package's other targets and its dependencies resolve. Empty when the package has not been built.
    public static func packageIncludes(root: String) -> [String] {
        let fm = FileManager.default
        let candidates = [
            "/.build/debug", "/.build/out/Products/Debug", "/.build/arm64-apple-macosx/debug/Modules",
            "/.build/arm64-apple-macosx/debug", "/.build/x86_64-apple-macosx/debug/Modules", "/.build/x86_64-apple-macosx/debug",
        ]
        var found: [String] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let path = URL(fileURLWithPath: root + candidate).resolvingSymlinksInPath().path
            guard seen.insert(path).inserted, let entries = try? fm.contentsOfDirectory(atPath: path) else { continue }
            if entries.contains(where: { $0.hasSuffix(".swiftmodule") }) { found += ["-I", path] }
        }
        return found
    }

    /// `-target <triple>` for the package's macOS deployment target (`swift package dump-package`), so that a scan
    /// without `--build` checks the code for the platform version it ships for, not the host's (plan item K10). Empty
    /// when `extra` already has a `-target`, when the manifest names no version for the host's platform, or when the
    /// manifest cannot be read: the compiler's default (the host) stays.
    public static func packageTargetArguments(root: String, extra: [String]) -> [String] {
        guard !extra.contains("-target"), let toolchain = try? ScanToolchain.current(),
            let swift = try? ScanToolchain.swiftCommand(["package", "dump-package", "--package-path", root]),
            let dump = try? Spawn.run(swift.executable, swift.arguments), dump.status == 0,
            let triple = deploymentTarget(
                dumpPackage: dump.output, unversionedTriple: toolchain.unversionedTriple, platform: toolchain.platform)
        else { return [] }
        return ["-target", triple]
    }

    /// `arm64-apple-macosx13.0` for a manifest (`dump-package` JSON) that declares `.macOS(.v13)`, on a compiler whose
    /// platform is `macosx`; nil otherwise.
    static func deploymentTarget(dumpPackage: Data, unversionedTriple: String, platform: String) -> String? {
        let names = ["macosx": "macos"]
        guard let name = names[platform], let manifest = try? JSONDecoder().decode(ManifestPlatforms.self, from: dumpPackage),
            let version = manifest.platforms?.first(where: { $0.platformName == name })?.version,
            version.allSatisfy({ $0.isNumber || $0 == "." })
        else { return nil }
        return unversionedTriple + version
    }

    /// All `.swift` files of a SwiftPM target (`Sources/<target>/**`), sorted for stable output.
    public static func packageFiles(root: String, target: String?) throws -> (files: [String], module: String) {
        let sources = root + "/Sources"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sources) else {
            throw ScanUsageError("\(root) has no Sources directory")
        }
        let targets = entries.filter { fm.isDirectory(atPath: sources + "/" + $0) }
        let name: String
        if let target {
            name = target
        } else if targets.count == 1 {
            name = targets[0]
        } else {
            throw ScanUsageError("pick a target with --target: \(targets.sorted().joined(separator: ", "))")
        }
        guard targets.contains(name) else { throw ScanUsageError.unknownTarget(name, root: root, known: targets) }
        var files: [String] = []
        if let walker = fm.enumerator(atPath: sources + "/" + name) {
            for case let path as String in walker where path.hasSuffix(".swift") { files.append(sources + "/" + name + "/" + path) }
        }
        guard !files.isEmpty else { throw SILError.invalid("target \(name) has no Swift files") }
        return (files.sorted(), name)
    }
}

/// The `platforms` of `swift package dump-package`'s JSON.
private struct ManifestPlatforms: Decodable {
    struct Platform: Decodable {
        var platformName: String
        var version: String
    }

    var platforms: [Platform]?
}

extension ScanReport {
    /// The facts about the run as a whole: compiler, pin, warnings, and what a selector picked.
    fileprivate mutating func describe(toolchain: ScanToolchain, options: VerifyOptions, selected: SelectedFunctions?) {
        compiler = toolchain.versionLine
        pinned = toolchain.isPinned(options.pin)
        selection = selected?.selection
        unselected = selected?.unselected ?? []
    }
}
