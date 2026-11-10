import Darwin
import Foundation

/// `swift package dump-package` for each local package, read once per version of its manifest. Thread-safe.
package final class ManifestCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: (signature: InputSnapshot.Signature?, manifest: PackageManifest)] = [:]
    private let swift: String

    package init(swift: String = ManifestCache.findSwift()) {
        self.swift = swift
    }

    /// `swift` on `PATH`, else `/usr/bin/swift`.
    package static func findSwift(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String {
        for directory in path.split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(directory)/swift") {
            return "\(directory)/swift"
        }
        return "/usr/bin/swift"
    }

    /// The package's manifest, read again when `Package.swift` changed; nil when it cannot be read.
    package func manifest(_ root: String) -> PackageManifest? {
        let signature = InputSnapshot.signature(root + "/Package.swift")
        lock.lock()
        let cached = cache[root]
        lock.unlock()
        if let cached, cached.signature == signature { return cached.manifest }
        guard let child = try? ChildProcess.spawn(swift, ["package", "dump-package"], directory: root) else { return nil }
        let data = (try? child.stdout.readToEnd()) ?? Data()
        _ = try? child.stderr.readToEnd()
        child.waitForExit()
        guard child.reap() == 0, let manifest = try? PackageManifest.parse(data, root: root) else { return nil }
        lock.lock()
        cache[root] = (signature, manifest)
        lock.unlock()
        return manifest
    }

    /// `root` and every local package it depends on, or nil when one of them cannot be read.
    package func closure(_ root: String) -> Set<String>? {
        var graph = PackageGraph()
        while true {
            let missing = graph.missing(from: [root])
            if missing.isEmpty { return graph.closure(of: root) }
            for package in missing {
                guard let manifest = manifest(package) else { return nil }
                graph.add(manifest)
            }
        }
    }

    /// `closure(_:)` from the manifests already read, without running anything; nil when one is not read yet.
    package func cachedClosure(_ root: String) -> Set<String>? {
        lock.lock()
        let graph = PackageGraph(cache.values.map(\.manifest))
        lock.unlock()
        return graph.missing(from: [root]).isEmpty ? graph.closure(of: root) : nil
    }

    /// The manifest already read for `root`, without running anything.
    package func cachedManifest(_ root: String) -> PackageManifest? {
        lock.lock()
        defer { lock.unlock() }
        return cache[root]?.manifest
    }
}

/// Runs each check as a child `swiftformal check --json` and reads its report. A child process can be stopped at any
/// moment (with every compiler it started), and each run starts with fresh process-wide state: the toolchain choice
/// and `TypeNameCheck`'s answers, which are keyed by compiler arguments but not by the modules those arguments read.
package struct ProcessCheckRunner: CheckRunner {
    /// The `swiftformal` to run.
    package var executable: String
    package var manifests: ManifestCache
    /// Facts that are not files but that verdicts depend on (see `InputSnapshot.context`).
    package var context: @Sendable () -> [String: String]

    package init(executable: String, manifests: ManifestCache, context: @escaping @Sendable () -> [String: String]) {
        self.executable = executable
        self.manifests = manifests
        self.context = context
    }

    /// The toolchain selection and the `swiftformal` binary's signature: when either changes, every verdict may.
    package static func context(executable: String) -> [String: String] {
        var context = InputSnapshot.toolchainContext()
        if let signature = InputSnapshot.signature(executable) {
            context["swiftformal"] = "\(signature.size):\(signature.modified):\(signature.inode)"
        }
        return context
    }

    package func start(
        _ job: CheckJob, generation: Int, progress: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (RunOutcome) -> Void
    ) -> any RunningCheck {
        let run = ProcessRun(runner: self, job: job, generation: generation, progress: progress, completion: completion)
        Thread.detachNewThread { run.main() }
        return run
    }
}

/// One child check.
final class ProcessRun: RunningCheck, @unchecked Sendable {
    private let runner: ProcessCheckRunner
    private let job: CheckJob
    private let generation: Int
    private let progress: @Sendable (String) -> Void
    private let completion: @Sendable (RunOutcome) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var child: ChildProcess?
    /// Signalled when a cancellation's kill has confirmed that every process of the tree is gone.
    private let killed = DispatchSemaphore(value: 0)

    init(
        runner: ProcessCheckRunner, job: CheckJob, generation: Int, progress: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (RunOutcome) -> Void
    ) {
        self.runner = runner
        self.job = job
        self.generation = generation
        self.progress = progress
        self.completion = completion
    }

    func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        let child = self.child
        lock.unlock()
        guard first, let child else { return }
        let killed = killed
        let progress = progress
        DispatchQueue.global().async {
            let left = ProcessTree.kill(root: child.pid, rootExited: { child.hasExited })
            if !left.isEmpty { progress("could not stop processes \(left.map(String.init).joined(separator: ", "))") }
            killed.signal()
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func main() {
        var closures: [String: Set<String>?] = [:]
        for package in job.packages {
            if isCancelled { return completion(.cancelled) }
            progress("reading the manifests of \((package as NSString).lastPathComponent) …")
            closures[package] = runner.manifests.closure(package)
        }
        let roots = Array(Set(job.packages.flatMap { closures[$0].flatMap { $0 } ?? [$0] })).sorted()
        let start = InputSnapshot.capture(roots: roots, context: runner.context(), hash: true)
        lock.lock()
        if cancelled {
            lock.unlock()
            return completion(.cancelled)
        }
        let child: ChildProcess
        do { child = try ChildProcess.spawn(runner.executable, job.arguments) } catch {
            lock.unlock()
            return completion(.failed(message: "\(error)"))
        }
        self.child = child
        lock.unlock()

        let lines = StderrLines(progress: progress)
        let reader = Thread { lines.read(child.stderr) }
        reader.start()
        let output = (try? child.stdout.readToEnd()) ?? Data()
        child.waitForExit()
        if isCancelled {
            killed.wait()
            _ = child.reap()
            return completion(.cancelled)
        }
        let status = child.reap()
        lines.finished.wait()
        let end = InputSnapshot.capture(roots: roots, context: runner.context(), hash: false)
        guard status == 0 || status == 1 else {
            let why = lines.last.isEmpty ? "exit status \(status)" : lines.last.joined(separator: "\n")
            return completion(.failed(message: "swiftformal check failed: \(why)"))
        }
        do {
            let results = try CheckResults.read(output)
            let changed = Self.scope(start.changes(to: end))
            completion(
                .finished(
                    FinishedRun(
                        job: job, generation: generation, results: results, closures: closures, snapshot: start,
                        changedWhileRunning: changed, sourceDirectories: sourceDirectories())))
        } catch {
            completion(.failed(message: "could not read the report of swiftformal check: \(error)"))
        }
    }

    /// The source folder of each scanned target, from the manifests read for this run.
    private func sourceDirectories() -> [TargetRef: String] {
        var folders: [TargetRef: String] = [:]
        for scan in job.scans {
            folders[scan] = runner.manifests.cachedManifest(scan.package)?.targets.first { $0.name == scan.target }?.path
        }
        return folders
    }

    /// What a change between two snapshots touched: the packages of the files, or everything when a manifest, a
    /// file outside any package, or the context changed. Nil when nothing changed.
    static func scope(_ changes: (paths: Set<String>, context: Bool)) -> ChangeScope? {
        if changes.context { return .everything }
        if changes.paths.isEmpty { return nil }
        var packages: Set<String> = []
        for path in changes.paths {
            let name = (path as NSString).lastPathComponent
            guard !name.hasPrefix("Package."), let root = Paths.packageRoot(of: path) else { return .everything }
            packages.insert(root)
        }
        return .packages(packages)
    }
}

/// The child's standard error, line by line: progress for the editor, and the last lines for a failure message.
private final class StderrLines: @unchecked Sendable {
    private let progress: @Sendable (String) -> Void
    private(set) var last: [String] = []
    let finished = DispatchSemaphore(value: 0)

    init(progress: @escaping @Sendable (String) -> Void) { self.progress = progress }

    func read(_ handle: FileHandle) {
        var pending = Data()
        while let chunk = handle.readAvailable(upTo: 4096) {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = String(bytes: pending[pending.startIndex..<newline], encoding: .utf8) ?? ""
                pending = Data(pending[pending.index(after: newline)...])
                let text = line.hasPrefix("swiftformal: ") ? String(line.dropFirst("swiftformal: ".count)) : line
                guard !text.isEmpty else { continue }
                last = Array((last + [text]).suffix(12))
                progress(text)
            }
        }
        finished.signal()
    }
}
