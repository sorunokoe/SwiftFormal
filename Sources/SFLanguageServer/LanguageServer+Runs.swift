import Foundation
import SFVerifyKit

// Starting checks, following them with `$/progress`, and publishing what they found.
extension LanguageServer {
    /// Checks what a save of `path` may change: the configured targets (all of them when walks are configured, as a
    /// walk may cover any of them), else the target that holds the file.
    func schedule(for path: String, config: ServerConfig) {
        guard !shuttingDown else { return }
        guard config.scans.isEmpty else {
            var scans = config.scans
            if config.tests == nil || !config.walks, let root = Paths.packageRoot(of: path) {
                let reached = config.scans.filter { manifests.cachedClosure($0.package)?.contains(root) ?? true }
                guard !reached.isEmpty else { return log("\((path as NSString).lastPathComponent): no configured target reads it") }
                scans = reached
            }
            let job = CheckJob(scans: scans, tests: config.tests, walks: config.walks, budget: config.budget)
            return request(job, changed: path)
        }
        guard let root = Paths.packageRoot(of: path) else { return log("\(path) is in no Swift package: nothing to check") }
        let manifests = manifests
        DispatchQueue.global().async {
            let target = manifests.manifest(root)?.target(containing: path)
            self.queue.async {
                guard let target else {
                    return self.log("\((path as NSString).lastPathComponent) is in no library or executable target of \(root)")
                }
                let job = CheckJob(scans: [TargetRef(package: root, target: target.name)], walks: false, budget: config.budget)
                self.request(job, changed: path)
            }
        }
    }

    /// Queues `job`; the running check is cancelled when `changed` may change its answers (they would be stale).
    func request(_ job: CheckJob, changed path: String?) {
        guard !shuttingDown else { return }
        var supersede = false
        if let active = scheduler.active {
            let scope = path.flatMap(scope(of:)) ?? .everything
            supersede = active.job.packages.contains { scope.affects(manifests.cachedClosure($0)) }
        }
        scheduler.request(job, supersede: supersede)
    }

    /// Checks every configured target, or the targets of the open files.
    func checkEverything() {
        let rootsToCheck = roots.isEmpty ? Array(Set(documents.keys.map(workspaceRoot(of:)))) : roots
        for root in rootsToCheck {
            guard let config = config(forRoot: root) else { continue }
            if !config.scans.isEmpty {
                request(CheckJob(scans: config.scans, tests: config.tests, walks: config.walks, budget: config.budget), changed: nil)
                continue
            }
            for path in documents.keys where Paths.isInside(path, root) && path.hasSuffix(".swift") {
                schedule(for: path, config: config)
            }
        }
    }

    func execute(_ params: JSONValue) -> JSONValue {
        switch params["command"].string {
        case Command.check: checkEverything()
        case Command.cancel: scheduler.cancelAll()
        default: break
        }
        return .null
    }

    // MARK: run events

    func runStarted(_ active: RunScheduler.Active) {
        let names = active.job.scans.map(\.target).joined(separator: ", ")
        log("checking \(names) (generation \(active.generation)): swiftformal \(active.job.arguments.joined(separator: " "))")
        notify("swiftformal/status", ["state": "running", "targets": .array(active.job.scans.map { .string($0.target) })])
        guard support.workDoneProgress else { return }
        let token = "swiftformal-run-\(active.id)"
        progressTokens[active.id] = token
        sendRequest("window/workDoneProgress/create", ["token": .string(token)])
        notify(
            "$/progress",
            [
                "token": .string(token),
                "value": ["kind": "begin", "title": "SwiftFormal", "message": .string("checking \(names)"), "cancellable": true],
            ]
        )
    }

    func runProgress(id: Int, _ text: String) {
        guard let token = progressTokens[id] else { return }
        notify("$/progress", ["token": .string(token), "value": ["kind": "report", "message": .string(text)]])
    }

    func runEnded(_ active: RunScheduler.Active, _ outcome: RunOutcome) {
        if let token = progressTokens.removeValue(forKey: active.id) {
            notify("$/progress", ["token": .string(token), "value": ["kind": "end"]])
        }
        switch outcome {
        case .finished(let run):
            if let changed = run.changedWhileRunning { store.change(changed) }
            let current = store.publish(run)
            log(
                "checked \(active.job.scans.map(\.target).joined(separator: ", ")): \(run.results.entries.count) functions, \(current) current"
            )
            refreshViews()
        case .failed(let message):
            show(message, type: 1)
        case .cancelled:
            log("check cancelled")
        }
        notify("swiftformal/status", ["state": scheduler.queued == nil ? "idle" : "queued"])
        store.pruneEvents(upTo: store.generation)
        finishShutdownIfIdle()
    }

    // MARK: publishing

    /// Shows the stored verdicts again: diagnostics, code lenses, and the results for the test explorer.
    func refreshViews() {
        publishDiagnostics(store.files.union(publishedDiagnostics).union(documents.keys))
        if support.codeLensRefresh { sendRequest("workspace/codeLens/refresh", .null) }
        publishResults()
    }

    /// `textDocument/publishDiagnostics` for each of `paths`: the current verdicts that say something is wrong.
    func publishDiagnostics(_ paths: Set<String>) {
        for path in paths.sorted() where !Paths.isIgnored(path, roots: roots) {
            let results = store.results(inFile: path)
            let hash = results.isEmpty ? nil : currentHash(path)
            // An open document is read for its `// sf:verify` comments too, which are no longer read by any check.
            let text = results.isEmpty && documents[path] == nil ? nil : currentText(path)
            let lines = (text ?? "").components(separatedBy: "\n")
            let found =
                results.compactMap { Render.diagnostic($0, current: $0.isCurrent(currentHash: hash)) }
                + (documents[path] == nil ? [] : Render.markerDiagnostics(text ?? ""))
            let diagnostics: [JSONValue] = found.map { diagnostic in
                [
                    "range": lineRange(diagnostic.line - 1, lines: lines), "severity": .number(Double(diagnostic.severity.rawValue)),
                    "source": "swiftformal", "message": .string(diagnostic.message),
                ]
            }
            if diagnostics.isEmpty && !publishedDiagnostics.contains(path) { continue }
            if diagnostics.isEmpty { publishedDiagnostics.remove(path) } else { publishedDiagnostics.insert(path) }
            var params: JSONValue = ["uri": .string(documents[path]?.uri ?? Paths.uri(path: path)), "diagnostics": .array(diagnostics)]
            if case .object(var members) = params, let version = documents[path]?.version {
                members["version"] = .number(Double(version))
                params = .object(members)
            }
            notify("textDocument/publishDiagnostics", params)
        }
    }

    /// The code on `line` (0-based), without its indentation.
    func lineRange(_ line: Int, lines: [String]) -> JSONValue {
        let text = line >= 0 && line < lines.count ? lines[line] : ""
        let start = text.utf16.count - text.drop { $0 == " " || $0 == "\t" }.utf16.count
        return [
            "start": Position(line: max(line, 0), character: start).json,
            "end": Position(line: max(line, 0), character: text.utf16.count).json,
        ]
    }

    /// `swiftformal/results`: every verdict with its state, for the editor's test explorer.
    func publishResults() {
        var hashes: [String: String?] = [:]
        let items: [JSONValue] = store.all.compactMap { result in
            guard let file = result.file, !Paths.isIgnored(file, roots: roots), let location = result.entry.location else { return nil }
            if hashes[file] == nil { hashes[file] = .some(currentHash(file)) }
            let current = result.isCurrent(currentHash: hashes[file].flatMap { $0 })
            return [
                "id": .string(result.id), "package": .string(result.target.package),
                "module": .string(result.entry.module), "function": .string(result.entry.function),
                "uri": .string(Paths.uri(path: file)), "line": .number(Double(location.line - 1)),
                "state": .string(state(result, current: current)), "title": .string(Render.lensTitle(result, current: current)),
                "message": .string(Render.diagnostic(result, current: current)?.message ?? ""),
                "walk": .bool(!result.entry.walks.isEmpty),
            ]
        }
        notify("swiftformal/results", ["generation": .number(Double(store.generation)), "items": .array(items)])
    }

    /// `passed`, `failed`, `skipped` (not checked, or not a proof) or `stale`, for a test explorer.
    func state(_ result: StoredResult, current: Bool) -> String {
        guard current else { return "stale" }
        switch result.entry.checkedOutcome {
        case .provedByLogic, .provedByLogicAndWalk, .provedByWalk, .cannotTrap: return "passed"
        case .counterexample, .walkMissing: return "failed"
        case .typeWalkFailed: return result.entry.typeWalkFailedUnmarked ? "failed" : "skipped"
        case .bounded, .knownIssue, .conflict, .unchecked: return "skipped"
        }
    }
}
