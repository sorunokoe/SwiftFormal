import Foundation
package import SFVerifyKit

/// What changed: the files of some packages, or anything (a manifest, the configuration, the toolchain).
package enum ChangeScope: Equatable, Sendable {
    case packages(Set<String>)
    case everything

    /// True when a result that read the files of `dependsOn` (nil: unknown) may be out of date after this change.
    package func affects(_ dependsOn: Set<String>?) -> Bool {
        switch self {
        case .everything: true
        case .packages(let changed): dependsOn.map { !changed.isDisjoint(with: $0) } ?? true
        }
    }

    package func union(_ other: ChangeScope) -> ChangeScope {
        switch (self, other) {
        case (.packages(let a), .packages(let b)): .packages(a.union(b))
        default: .everything
        }
    }
}

/// One function's verdict from a finished run, with what it was proved about.
package struct StoredResult: Sendable {
    package var entry: CheckResults.Entry
    package var target: TargetRef
    package var module: CheckReport.Module?
    /// The function's file, standardized; nil when the report gives no place.
    package var file: String?
    /// SHA-256 of that file when the run started; a buffer must hash the same for the result to be shown as current.
    package var fileHash: String?
    /// The packages whose files the verdict depends on; nil when not known (any change makes it stale).
    package var dependsOn: Set<String>?
    /// True once something it depends on changed after its run started. Never cleared: only a newer run replaces it.
    package var stale: Bool
    /// The generation its run started at.
    package var generation: Int
}

/// A finished check: its answers, and what they were proved about.
package struct FinishedRun: Sendable {
    package var job: CheckJob
    /// The generation when it started (before its snapshot was taken).
    package var generation: Int
    package var results: CheckResults
    /// `closure(package)` for each scanned package and the tests package; nil values are unknown.
    package var closures: [String: Set<String>?]
    package var snapshot: InputSnapshot
    /// What changed between the snapshot at the start and the one at the end; nil when nothing did.
    package var changedWhileRunning: ChangeScope?
    /// The source folder of each scanned target, where known: attributes the verdicts of a report that does not name
    /// packages when two scanned targets have the same name.
    package var sourceDirectories: [TargetRef: String]

    package init(
        job: CheckJob, generation: Int, results: CheckResults, closures: [String: Set<String>?], snapshot: InputSnapshot,
        changedWhileRunning: ChangeScope? = nil, sourceDirectories: [TargetRef: String] = [:]
    ) {
        self.job = job
        self.generation = generation
        self.results = results
        self.closures = closures
        self.snapshot = snapshot
        self.changedWhileRunning = changedWhileRunning
        self.sourceDirectories = sourceDirectories
    }

    /// The verdicts of `target`. A report names each one's package; one that does not (an older `swiftformal`)
    /// attributes a verdict by module name when no other scanned target has that name, else only when its file is
    /// in the target's source folder. A verdict that cannot be attributed is left out: never shown under another
    /// package.
    func entries(of target: TargetRef) -> [CheckResults.Entry] {
        let sameName = job.scans.filter { $0.target == target.target }
        let folder = sourceDirectories[target]
        return results.entries.filter { entry in
            guard entry.module == target.target else { return false }
            if let package = entry.package { return Paths.standard(package) == target.package }
            if sameName.count == 1 { return true }
            guard let folder, let file = entry.location?.file else { return false }
            return Paths.isInside(Paths.standard(file), folder)
        }
    }

    /// What `target`'s verdicts hold under: the module the report names with its package, else the one at the
    /// target's place in the scan order (one module per `--scan`), else the only module of that name.
    func module(of target: TargetRef) -> CheckReport.Module? {
        let modules = results.modules ?? []
        if let named = modules.first(where: { $0.module == target.target && $0.package.map(Paths.standard) == target.package }) {
            return named
        }
        if modules.contains(where: { $0.package != nil }) { return nil }
        if modules.count == job.scans.count, let index = job.scans.firstIndex(of: target), modules[index].module == target.target {
            return modules[index]
        }
        let sameName = modules.filter { $0.module == target.target }
        return sameName.count == 1 ? sameName.first : nil
    }
}

/// Every published verdict, and the generation counter that decides which of them are still about the current code.
///
/// Each change bumps the generation and is logged with its scope; results it affects become stale at once. A run
/// records the generation it started at; when it finishes, its results replace the old ones of the same targets, and
/// every change logged after it started is applied to them again, so a result that may predate an edit is stale,
/// never shown as proved.
package final class ResultStore {
    /// The project generation: one more for every change. A run's verdicts are current only for the generation it
    /// started at.
    package private(set) var generation = 0
    private var events: [(generation: Int, scope: ChangeScope)] = []
    /// The latest verdicts of each target, stale or not.
    package private(set) var results: [TargetRef: [StoredResult]] = [:]

    /// An empty store at generation 0.
    package init() {}

    /// Records a change and marks every result it may affect stale. Returns how many results turned stale.
    @discardableResult
    package func change(_ scope: ChangeScope) -> Int {
        generation += 1
        events.append((generation, scope))
        var staled = 0
        for (target, list) in results {
            results[target] = list.map { result in
                var result = result
                if !result.stale, scope.affects(result.dependsOn) {
                    result.stale = true
                    staled += 1
                }
                return result
            }
        }
        return staled
    }

    /// Stores a finished run's verdicts in place of the old ones of its targets. Results that a change logged after
    /// the run started may affect are stored stale. Returns how many are current.
    @discardableResult
    package func publish(_ run: FinishedRun) -> Int {
        let testsClosure: Set<String>?? = run.job.tests.map { run.closures[$0.package].flatMap { $0 } }
        let later = events.filter { $0.generation > run.generation }
        var current = 0
        for target in run.job.scans {
            let module = run.module(of: target)
            let ownClosure = run.closures[target.package].flatMap { $0 }
            results[target] = run.entries(of: target).map { entry in
                var dependsOn = ownClosure
                if entry.dependsOnWalks, run.job.walks, let testsClosure {
                    dependsOn = testsClosure.flatMap { tests in dependsOn.map { $0.union(tests) } }
                }
                let file = entry.location.map { Paths.standard($0.file) }
                let stale = later.contains { $0.scope.affects(dependsOn) }
                if !stale { current += 1 }
                return StoredResult(
                    entry: entry, target: target, module: module, file: file, fileHash: file.flatMap { run.snapshot.hashes[$0] },
                    dependsOn: dependsOn, stale: stale, generation: run.generation)
            }
        }
        return current
    }

    /// Forgets changes no running or queued check can still need (all started at or after `generation`).
    package func pruneEvents(upTo generation: Int) {
        events.removeAll { $0.generation <= generation }
    }

    /// Every stored result whose function is in `path`.
    package func results(inFile path: String) -> [StoredResult] {
        results.values.flatMap { $0 }.filter { $0.file == path }.sorted { ($0.entry.location?.line ?? 0) < ($1.entry.location?.line ?? 0) }
    }

    /// Every stored result.
    package var all: [StoredResult] {
        results.keys.sorted { $0.argument < $1.argument }.flatMap { results[$0] ?? [] }
    }

    /// Files that have at least one result.
    package var files: Set<String> { Set(results.values.flatMap { $0.compactMap(\.file) }) }
}

extension StoredResult {
    /// Unique among stored results: the package, module, function and place (two packages may have a target of the
    /// same name).
    package var id: String {
        "\(target.package):\(entry.module)/\(entry.function)@\(file ?? ""):\(entry.location?.line ?? 0)"
    }

    /// True when the verdict is about exactly this text: nothing it depends on changed since its run started, and the
    /// file (`currentHash`: the buffer's or the disk's SHA-256) is the one the run read.
    package func isCurrent(currentHash: String?) -> Bool {
        !stale && fileHash != nil && fileHash == currentHash
    }
}
