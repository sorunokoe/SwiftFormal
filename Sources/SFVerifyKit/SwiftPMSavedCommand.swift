import Foundation

/// The compile command of a target when the build printed none (plan item K3).
///
/// A build that compiles nothing prints no command. With Swift Build the command saved from an earlier build is used,
/// but only when it was saved for the same build description; after a build this process ran itself, the command in
/// Swift Build's own plan of that description too (`SwiftPMDescribedCommand.swift`, `SwiftPMOwnBuild.swift`). The
/// native build system writes every command into `debug.yaml`. All are internal formats, so whatever cannot be read
/// means "no command" and the caller rebuilds.
extension SwiftPMBuild {
    /// A compile command, and whether it came from a saved file or `debug.yaml` instead of the log.
    struct FoundCommand {
        var tool: String
        var arguments: [String]
        var cached: Bool
    }

    /// The command of `target`: from the log when the build compiled it, otherwise saved or described (K3). `ownBuild`:
    /// the log is of the build this process ran last in `scratch` (`recordOwnBuild`).
    static func command(in log: String, target: String, scratch: String, cache: String, ownBuild: Bool) -> FoundCommand? {
        if let fresh = compileInvocation(in: log, module: target), isWhole(fresh.arguments) {
            return FoundCommand(tool: fresh.tool, arguments: fresh.arguments, cached: false)
        }
        guard let saved = savedCommand(target: target, scratch: scratch, cache: cache, ownBuild: ownBuild), isWhole(saved.arguments)
        else { return nil }
        return FoundCommand(tool: saved.tool, arguments: saved.arguments, cached: true)
    }

    /// The id of the build description Swift Build used last in `scratch`: the last line of
    /// `out/Intermediates.noindex/XCBuildData/prior-build-descriptions.txt`. It stays the same over null builds and
    /// `touch`, and changes with a new setting, an added or removed file, or another requested target. Nil when the
    /// file is missing or does not look as expected (an internal format: never trusted beyond that).
    package static func buildDescription(in scratch: String) -> String? {
        guard let text = try? String(contentsOfFile: descriptionsFile(in: scratch), encoding: .utf8),
            let last = text.split(whereSeparator: \.isNewline).last.map(String.init),
            last.count == 32, last.allSatisfy(\.isHexDigit)
        else { return nil }
        return last
    }

    /// Writes `#tool`, `#description` (when known) and then one argument per line.
    package static func saveCommand(tool: String, arguments: [String], description: String?, to cache: String) {
        let header = ["#tool \(tool)"] + (description.map { ["#description \($0)"] } ?? [])
        try? FileManager.default.createDirectory(
            atPath: (cache as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? (header + arguments).joined(separator: "\n").write(toFile: cache, atomically: true, encoding: .utf8)
    }

    /// The command of `target` without a log line: the native build system's `debug.yaml`, or, with Swift Build, the
    /// command saved in `cache` for the build description. Without `ownBuild` (a log someone else produced) that is the
    /// folder's last description, and nothing else is used: the log may come from another build. With it, it is the
    /// description of this process's last build in `scratch`, else that description's plan gives the command (a
    /// dependency of the target built last, whose own build saved its command for another description); either is
    /// used only while no other build has run in the folder since. Nil when none applies; a command saved without a
    /// description, or for another one, is never used, because nothing then says it is still the build's.
    package static func savedCommand(
        target: String, scratch: String, cache: String, ownBuild: Bool
    ) -> (tool: String, arguments: [String])? {
        let system = (try? String(contentsOfFile: scratch + "/.buildSystem_debug", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if system == "native" { return nativeCommand(target: target, scratch: scratch) }
        guard ownBuild else { return buildDescription(in: scratch).flatMap { savedCommand(in: cache, description: $0) } }
        guard let own = self.ownBuild(in: scratch) else { return nil }
        let found =
            savedCommand(in: cache, description: own.description) ?? describedCommand(target: target, scratch: scratch, own: own)
        return own.isCurrent(in: scratch) ? found : nil
    }

    /// The command saved in `cache` for `description`.
    private static func savedCommand(in cache: String, description: String) -> (tool: String, arguments: [String])? {
        guard let saved = try? String(contentsOfFile: cache, encoding: .utf8) else { return nil }
        var lines = saved.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > 2, lines[0].hasPrefix("#tool "), lines[1] == "#description \(description)" else { return nil }
        let tool = String(lines.removeFirst().dropFirst("#tool ".count))
        lines.removeFirst()
        return (tool, lines)
    }

    /// `target`'s command in the plan of `own`'s description; for another target than the one planned from that build
    /// last, only when the plan holds that one's command as its plan used it.
    private static func describedCommand(target: String, scratch: String, own: OwnBuild) -> (tool: String, arguments: [String])? {
        if let planned = own.target, planned.name != target {
            guard let theirs = describedCommand(target: planned.name, scratch: scratch, description: own.description),
                theirs.tool == planned.tool, theirs.arguments == planned.arguments
            else { return nil }
        }
        return describedCommand(target: target, scratch: scratch, description: own.description)
    }

    /// The native build system writes every target's full command into `<scratch>/debug.yaml` on each build:
    /// `"C.<target>-<triple>-debug.module":` followed by `args: [<JSON strings>]`.
    private static func nativeCommand(target: String, scratch: String) -> (tool: String, arguments: [String])? {
        guard let yaml = try? String(contentsOfFile: scratch + "/debug.yaml", encoding: .utf8) else { return nil }
        var inTarget = false
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("  \"") {
                inTarget = line.hasPrefix("  \"C.\(target)-") && line.hasSuffix("-debug.module\":")
            } else if inTarget, let range = line.range(of: "    args: ") {
                guard let data = String(line[range.upperBound...]).data(using: .utf8),
                    let args = try? JSONDecoder().decode([String].self, from: data), args.count > 1,
                    args.firstIndex(of: "-module-name").map({ $0 + 1 < args.count && args[$0 + 1] == target }) == true
                else { continue }
                return (args[0], Array(args.dropFirst()))
            }
        }
        return nil
    }

    /// `plan(log:target:scratch:cacheDirectory:)`, for a log of this process's last build in `scratch` when `ownBuild`.
    static func plan(
        log: String, target: String, scratch: String, cacheDirectory: String? = nil, ownBuild: Bool
    ) throws -> (plan: Plan, command: FoundCommand) {
        let scratchPath = URL(fileURLWithPath: scratch).standardizedFileURL.path
        let cache = cacheDirectory.map { $0 + "/\(target).args" } ?? argumentsFile(of: target, in: scratchPath)
        guard let found = command(in: log, target: target, scratch: scratchPath, cache: cache, ownBuild: ownBuild) else {
            throw ScanUsageError.upToDate(target)
        }
        save(found, to: cache, description: ownBuild ? ownDescription(in: scratchPath) : buildDescription(in: scratchPath))
        return (finish(target: target, found, started: Date()), found)
    }

    /// Saves a command the log gave, for `description` (never reused without one).
    static func save(_ found: FoundCommand, to cache: String, description: String?) {
        if !found.cached { saveCommand(tool: found.tool, arguments: found.arguments, description: description, to: cache) }
    }

    /// The plan made of a command: its Swift files, and the frontend arguments without the outputs.
    static func finish(target: String, _ found: FoundCommand, started: Date) -> Plan {
        let (tool, raw, cached) = (found.tool, found.arguments, found.cached)
        var files: [String] = []
        var rest: [String] = []
        for token in raw {
            if token.hasPrefix("@"), let list = try? String(contentsOfFile: String(token.dropFirst()), encoding: .utf8) {
                files += tokenize(list.replacingOccurrences(of: "\n", with: " "))
            } else if token.hasSuffix(".swift"), FileManager.default.fileExists(atPath: token) {
                files.append(token)
            } else {
                rest.append(token)
            }
        }
        return Plan(
            module: target, files: files, arguments: filter(rest),
            buildSeconds: Date().timeIntervalSince(started), usedCachedArguments: cached,
            compiler: ScanToolchain.swiftc(fromBuildTool: tool)
        )
    }
}
