import Foundation
import SFSIL

/// Gets the exact compiler flags SwiftPM uses for one target, by building it once with `swift build -v`.
/// That makes `-package-name`, `-D` conditions, upcoming-feature flags and the swiftmodules of the target's
/// dependencies come out right without sfverify having to guess any of them.
///
/// The build goes into the package's normal `.build`, the one `swift build` and `swift test` use, so a scan adds no
/// second copy of the package and its dependencies. A target build and a test build share their products there (the
/// debug build enables testing in both), so neither rebuilds what the other built. The compile commands are kept in
/// `.build/swiftformal/args`, because an up-to-date target prints none.
public enum SwiftPMBuild {
    public struct Plan: Sendable {
        public let module: String
        /// The Swift files of the target, as SwiftPM compiles them (including generated ones).
        public let files: [String]
        /// Arguments for the Swift frontend, with everything that produces objects, modules or indexes removed.
        public let arguments: [String]
        public let buildSeconds: Double
        public let usedCachedArguments: Bool
        /// The `swiftc` SwiftPM compiled the target with, when the log or the saved command names it (plan item K2).
        public var compiler: String?
    }

    public static func plan(root: String, target: String, scratch: String? = nil) throws -> Plan {
        // `swift build` runs inside `root`, so a relative root would nest the scratch path inside itself.
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        let scratchPath = scratch.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? root + "/.build"
        let cache = argumentsFile(of: target, in: scratchPath)
        let started = Date()
        let log = try build(root: root, target: target, scratch: scratchPath)
        var found = command(in: log, target: target, scratch: scratchPath, cache: cache, ownBuild: true)
        if found == nil {
            // Nothing was recompiled, no saved command belongs to this build, or another task printed into the command
            // line: drop the target's products and build it again, one task at a time so that nothing can print into it.
            removeProducts(of: target, in: scratchPath)
            let again = try build(root: root, target: target, scratch: scratchPath, serial: true)
            found = compileInvocation(in: again, module: target).map { FoundCommand(tool: $0.tool, arguments: $0.arguments, cached: false) }
        }
        guard let found, isWhole(found.arguments) else {
            throw SILError.invalid("could not find a whole compile command of \(target) in the SwiftPM log (\(scratchPath))")
        }
        recordTarget(target, tool: found.tool, arguments: found.arguments, in: scratchPath)
        save(found, to: cache, description: ownDescription(in: scratchPath))
        return finish(target: target, found, started: started)
    }

    /// The plan of `target` from a build log someone else produced (`swift package scan`, plan item K5): no build is
    /// started. On a null build the log has no command; then the command saved for the folder's last build description
    /// (or the native build system's `debug.yaml`) is used, and without one this throws `ScanUsageError.upToDate`.
    public static func plan(log: String, target: String, scratch: String, cacheDirectory: String? = nil) throws -> Plan {
        try plan(log: log, target: target, scratch: scratch, cacheDirectory: cacheDirectory, ownBuild: false).plan
    }

    /// Compile options for `module` when it is a target of this build whose sources live outside the scratch
    /// directory (a target of this package or of a local path dependency), so that `ModuleCompiler` can link it.
    /// Nil for SDK modules and for remote packages (checked out under the scratch directory), which stay unread.
    public static func localDependency(_ module: String, root: String, scratch: String? = nil) throws -> CompileOptions? {
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        let scratchPath = scratch.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? root + "/.build"
        guard isLocalTarget(module, scratch: scratchPath) else { return nil }
        // The scanned target's build built this module too and saved its command for this build description; only
        // without one does the module take a build of its own.
        if let saved = try? plan(log: "", target: module, scratch: scratchPath, ownBuild: true) { return options(saved.plan) }
        return options(try plan(root: root, target: module, scratch: scratchPath))
    }

    /// The same for a scan from a build log (`--build-log`): the dependency's command comes from that log or from the
    /// command saved for its build description, never from a build. Nil when there is none: the module stays unlinked.
    public static func localDependency(_ module: String, log: String, scratch: String, cacheDirectory: String? = nil) -> CompileOptions? {
        let scratchPath = URL(fileURLWithPath: scratch).standardizedFileURL.path
        guard isLocalTarget(module, scratch: scratchPath),
            let plan = try? plan(log: log, target: module, scratch: scratchPath, cacheDirectory: cacheDirectory)
        else { return nil }
        return options(plan)
    }

    static func isLocalTarget(_ module: String, scratch: String) -> Bool {
        let resolvedScratch = URL(fileURLWithPath: scratch).resolvingSymlinksInPath().path + "/"
        guard let sources = sourceList(of: module, in: scratch) else { return false }
        return sources.contains { !URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(resolvedScratch) }
    }

    static func options(_ plan: Plan) -> CompileOptions {
        var options = CompileOptions(files: plan.files, moduleName: plan.module, extraArguments: plan.arguments)
        options.compiler = plan.compiler
        return options
    }

    /// The source files a previous build compiled for `module`: Swift Build's `<module>.SwiftFileList`, or the
    /// native build system's `<module>.build/sources`.
    private static func sourceList(of module: String, in scratch: String) -> [String]? {
        let fm = FileManager.default
        func list(_ path: String) -> [String] {
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        // Swift Build under SwiftPM (`out/`), and Xcode's DerivedData (`Build/`).
        for intermediates in [scratch + "/out/Intermediates.noindex", scratch + "/Build/Intermediates.noindex"] {
            for package in (try? fm.contentsOfDirectory(atPath: intermediates)) ?? [] {
                for configuration in (try? fm.contentsOfDirectory(atPath: intermediates + "/" + package)) ?? [] {
                    let objects = "\(intermediates)/\(package)/\(configuration)/\(module)-t.build/Objects-normal"
                    for arch in (try? fm.contentsOfDirectory(atPath: objects)) ?? [] {
                        let files = list("\(objects)/\(arch)/\(module).SwiftFileList")
                        if !files.isEmpty { return files }
                    }
                }
            }
        }
        for triple in (try? fm.contentsOfDirectory(atPath: scratch)) ?? [] {
            let files = list("\(scratch)/\(triple)/debug/\(module).build/sources")
            if !files.isEmpty { return files }
        }
        return nil
    }

    /// Where the compile command of `module` is kept between runs.
    package static func argumentsFile(of module: String, in scratch: String) -> String {
        scratch + "/swiftformal/args/\(module).args"
    }

    /// `<target>.build` (native SwiftPM) and `<target>-t.build` (Swift Build) folders a few levels under the build
    /// output folders. Checked-out dependencies, artifacts and SwiftFormal's own files are never touched: this is the
    /// developer's `.build`.
    package static func removeProducts(of target: String, in scratch: String) {
        let kept: Set<String> = ["checkouts", "repositories", "artifacts", "prebuilts", "index-build", "plugins", "swiftformal"]
        var level = ((try? FileManager.default.contentsOfDirectory(atPath: scratch)) ?? [])
            .filter { !kept.contains($0) }.map { scratch + "/" + $0 }
        for _ in 0..<5 {
            var next: [String] = []
            for dir in level {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                    let path = dir + "/" + name
                    guard FileManager.default.isDirectory(atPath: path) else { continue }
                    // Swift Build: `<target>-t.build` (`-p.build` for a test target); native: `<triple>/<config>/<target>.build`.
                    // Never `Intermediates.noindex/<Package>.build`: with a target named like its package it holds every target.
                    let native = name == target + ".build" && !dir.hasSuffix("/Intermediates.noindex")
                    if native || name == target + "-t.build" || name == target + "-p.build" {
                        try? FileManager.default.removeItem(atPath: path)
                    } else {
                        next.append(path)
                    }
                }
            }
            level = next
        }
    }

    private static func build(root: String, target: String, scratch: String, serial: Bool = false) throws -> String {
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: scratch + "/swiftformal", withIntermediateDirectories: true)
        let logPath = scratch + "/swiftformal/build.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        // The package's own `.build` is left to SwiftPM to name: an explicit path that differs only by a symlink
        // (`/tmp` and `/private/tmp`) would make this build and the developer's rebuild each other's products.
        let scratchArguments = scratch == root + "/.build" ? [] : ["--scratch-path", scratch]
        let swift = try ScanToolchain.swiftCommand(
            ["build", "--target", target, "-v"] + (serial ? ["-j", "1"] : []) + scratchArguments)
        let result = try Spawn.run(swift.executable, swift.arguments, directory: root, log: handle)
        recordOwnBuild(in: scratch)
        try? handle.close()
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        guard result.status == 0 else {
            if log.contains("Could not find target named '\(target)'") {
                let known = (try? FileManager.default.contentsOfDirectory(atPath: root + "/Sources")) ?? []
                throw ScanUsageError.unknownTarget(target, root: root, known: known.filter { !$0.hasPrefix(".") })
            }
            throw SILError.compilerFailed(
                "swift build --target \(target) failed:\n" + log.split(separator: "\n").suffix(30).joined(separator: "\n"))
        }
        saveCompileCommands(in: log, scratch: scratch)
        return log
    }

    /// Saves the compile command of every module this process's build compiled (`swiftformal/args/<module>.args`, keyed
    /// on its build description like any saved command), so that linking a dependency reads its command instead of starting
    /// another `swift build`.
    static func saveCompileCommands(in log: String, scratch: String) {
        var modules: Set<String> = []
        for match in withoutGateMessages(log).matches(of: #/-module-name ([A-Za-z_][A-Za-z0-9_]*) /#) { modules.insert(String(match.1)) }
        let description = ownDescription(in: scratch)
        for module in modules {
            guard let command = compileInvocation(in: log, module: module), isWhole(command.arguments) else { continue }
            saveCommand(
                tool: command.tool, arguments: command.arguments, description: description, to: argumentsFile(of: module, in: scratch))
        }
    }

    /// The `swiftc ...` invocation that compiles `module`, as separate arguments (without the executable).
    ///
    /// Swift Build prints the module's driver arguments three times (`builtin-SwiftDriver`, the requirements task and
    /// `builtin-Swift-Compilation`); the native build system prints a plain `swiftc` line. The compilation task's own line
    /// is preferred (the last plain line otherwise), as before. Another task can print into a line in the middle (see
    /// `isWhole`); then the first of the module's other lines that is whole is used, never a repaired guess.
    package static func compileCommand(in log: String, module: String) -> [String]? {
        compileInvocation(in: log, module: module)?.arguments
    }

    /// The executable and the arguments of the invocation that compiles `module`.
    package static func compileInvocation(in log: String, module: String) -> (tool: String, arguments: [String])? {
        let tasks = ["builtin-Swift-Compilation -- ", "builtin-Swift-Compilation-Requirements -- ", "builtin-SwiftDriver -- "]
        var candidates: [(order: (rank: Int, position: Int), tokens: [String])] = []
        for line in withoutGateMessages(log).split(separator: "\n") where line.contains("-module-name \(module) ") {
            var text = String(line)
            var rank = tasks.count
            if let index = tasks.firstIndex(where: { text.contains($0) }), let r = text.range(of: tasks[index]) {
                (rank, text) = (index, String(text[r.upperBound...]))
            } else if !(text.contains("/swiftc ") || text.hasPrefix("swiftc ")) {
                continue
            }
            let tokens = tokenize(text)
            guard tokens.count > 1, tokens[0].hasSuffix("swiftc") || tokens[0].hasSuffix("swift-frontend") else { continue }
            // Within a rank: the first task line, the last plain line.
            candidates.append(((rank, rank < tasks.count ? candidates.count : -candidates.count), tokens))
        }
        let ordered = candidates.sorted { $0.order < $1.order }.map(\.tokens)
        guard let best = ordered.first(where: { isWhole(Array($0.dropFirst())) }) ?? ordered.first else { return nil }
        return (best[0], Array(best.dropFirst()))
    }

    /// The build gate prints into the same log, sometimes in the middle of the compile command line. Its messages are
    /// removed (with their newline) so that the command is whole again.
    package static func withoutGateMessages(_ log: String) -> String {
        log.replacing(/sfverify: gate[^\n]*\n/, with: "")
    }

    /// Splits like a shell: backslash escapes and single or double quotes.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var started = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\", quote != "'" { escaped = true; started = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; started = true; continue }
            if ch == " " {
                if started || !current.isEmpty { tokens.append(current) }
                current = ""
                started = false
                continue
            }
            current.append(ch)
            started = true
        }
        if started || !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static let dropAlone: Set<String> = [
        "-incremental", "-c", "-v", "-save-temps", "-parseable-output", "-use-frontend-parseable-output", "-whole-module-optimization",
        "-wmo", "-enable-batch-mode", "-index-ignore-system-modules", "-driver-time-compilation", "-Onone", "-O", "-Osize",
        "-Ounchecked", "-g", "-gline-tables-only", "-gdwarf-types", "-no-color-diagnostics", "-disable-batch-mode",
    ]
    private static let dropWithValue: Set<String> = [
        "-o", "-output-file-map", "-index-store-path", "-j", "-num-threads", "-debug-info-format", "-serialize-diagnostics-path",
        "-module-name", "-Xlinker", "-L", "-module-link-name", "-emit-module-path", "-working-directory",
        "-const-gather-protocols-list",
        // The build's module caches: a scan that wrote its own modules there would make the next build recompile.
        "-module-cache-path", "-clang-scanner-module-cache-path", "-sdk-module-cache-path", "-clang-build-session-file",
    ]
    private static let dropAlone2: Set<String> = [
        "-parse-as-library", "-Xfrontend", "-driver-use-frontend-path", "-validate-clang-modules-once",
    ]

    /// Keeps what defines the *meaning* of the code (conditions, features, language mode, search paths) and drops what
    /// only produces build outputs.
    public static func filter(_ arguments: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if dropAlone.contains(a) || dropAlone2.contains(a) { i += 1; continue }
            if a == "-explicit-module-build" || a.hasPrefix("-driver-") || (a.hasPrefix("-j") && a.dropFirst(2).allSatisfy(\.isNumber)) {
                i += 1
                continue
            }
            if a.hasPrefix("-dependency-scan") { i += 2; continue }
            if dropWithValue.contains(a) { i += 2; continue }
            if a.hasPrefix("-emit-") {
                i += a.hasSuffix("-path") ? 2 : 1
                continue
            }
            if a.hasPrefix("-profile-") || a.hasPrefix("-sanitize") || a.hasPrefix("-experimental-emit")
                || a.hasPrefix("-no-emit") || a.hasPrefix("-serialize-diagnostics")
            {
                i += 1
                continue
            }
            out.append(a)
            i += 1
        }
        return out
    }
}
