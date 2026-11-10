import Foundation

/// The order in which `swiftformal check` builds and verifies its `--scan` modules (`--jobs`): packages at the same
/// time, the modules of one package one after another, with what one after another would give.
///
/// * The modules of one package (one `.build` folder) run in `--scan` order, each planned and proved before the next
///   starts: SwiftPM locks the folder, and planning a module changes the saved commands that linking the one before
///   still reads (`SwiftPMBuild.recordTarget`).
/// * Modules are proved at the same time only when they were built with the same compiler: proving selects the
///   process's toolchain (`ScanToolchain.select`), which every compile, cache key and probe of the proof reads.
/// * The caller gets the notes of each module in `--scan` order, a module's only after those of the modules before it,
///   and the reports in that order: the same as one after another. The first module in that order that fails ends
///   the run with its error, after the modules running then finish; no module after it starts.
public enum ScanSchedule {
    /// Packages scanned at the same time when `--jobs` is not given: half the cores (a proof is itself parallel) and
    /// at most one per 2 GiB of memory (a module of a production app took up to 0.7 GB), at least one.
    public static var defaultJobs: Int {
        let info = ProcessInfo.processInfo
        return max(1, min(info.activeProcessorCount / 2, Int(info.physicalMemory >> 31)))
    }

    /// The folder SwiftPM builds the package at `package` in: modules with the same one share SwiftPM's lock and its
    /// saved commands. A symbolic link and `..` resolve, so two spellings of one package are one package.
    public static func buildFolder(of package: String) -> String {
        URL(fileURLWithPath: package).standardizedFileURL.resolvingSymlinksInPath().path + "/.build"
    }

    /// Whether this process may scan packages at the same time: planning runs `swift` through `xcrun`, independent
    /// of the toolchain another module's proof selected (without `xcrun` it runs the selected toolchain's `swift`).
    package static var canScanPackagesAtOnce: Bool { ScanToolchain.Locator.current.hasXcrun }

    /// What is done with each module: `plan` builds it, `compiler` names the compiler a plan built with, and `prove`
    /// verifies it. Each gets a `note` for stderr.
    public struct Stages<Planned: Sendable, Report: Sendable>: Sendable {
        public var plan: @Sendable (Int, _ note: @escaping @Sendable (String) -> Void) throws -> Planned
        public var compiler: @Sendable (Planned) -> String?
        public var prove: @Sendable (Int, Planned, _ note: @escaping @Sendable (String) -> Void) throws -> Report

        public init(
            plan: @escaping @Sendable (Int, _ note: @escaping @Sendable (String) -> Void) throws -> Planned,
            compiler: @escaping @Sendable (Planned) -> String?,
            prove: @escaping @Sendable (Int, Planned, _ note: @escaping @Sendable (String) -> Void) throws -> Report
        ) {
            self.plan = plan
            self.compiler = compiler
            self.prove = prove
        }
    }

    /// Plans and proves modules `0..<count`, at most `jobs` packages at a time; `folder(i)` is module `i`'s package
    /// build folder. `note` is called on the calling thread only. With `jobs` 1, or one package, each module is
    /// planned and proved on the calling thread, in order.
    public static func run<Planned: Sendable, Report: Sendable>(
        count: Int, jobs: Int, folder: (Int) -> String, stages: Stages<Planned, Report>,
        note: @escaping @Sendable (String) -> Void
    ) throws -> [Report] {
        var groups: [[Int]] = []
        var groupOf: [String: Int] = [:]
        for index in 0..<count {
            let key = folder(index)
            if let group = groupOf[key] {
                groups[group].append(index)
            } else {
                groupOf[key] = groups.count
                groups.append([index])
            }
        }
        let workers = min(jobs, groups.count)
        guard workers > 1 else {
            return try (0..<count).map { index in try stages.prove(index, stages.plan(index, note), note) }
        }
        note("logic: scanning \(count) modules of \(groups.count) packages, up to \(workers) at a time")
        let run = Run<Report>(count: count, groups: groups)
        let threads = (0..<workers).map { _ in Background { work(run, stages) } }
        defer { for thread in threads { _ = try? thread.value() } }
        return try (0..<count).map { index in try run.wait(for: index, emitting: note).get() }
    }

    /// One worker: takes the next package not started, and runs its modules in order until one fails or one before
    /// it in `--scan` order has.
    private static func work<Planned, Report>(_ run: Run<Report>, _ stages: Stages<Planned, Report>) {
        while let group = run.nextGroup() {
            for index in group {
                guard run.mayStart(index) else { break }
                let notes: @Sendable (String) -> Void = { run.add($0, to: index) }
                do {
                    let planned = try stages.plan(index, notes)
                    let report = try run.proving(stages.compiler(planned)) { try stages.prove(index, planned, notes) }
                    run.finish(index, .success(report))
                } catch {
                    run.finish(index, .failure(error))
                    break
                }
            }
        }
    }

    /// State shared by the workers and the caller: the groups not started, each module's notes and result, the first
    /// failure, and which compiler the modules being proved now were built with.
    private final class Run<Report: Sendable>: @unchecked Sendable {
        private let condition = NSCondition()
        private var groups: [[Int]]
        private var notes: [[String]]
        private var results: [Result<Report, any Error>?]
        private var firstFailure = Int.max
        private var provingCompiler: String?
        private var proving = 0
        /// How many modules wait to be proved, by compiler: while one built with another compiler waits, no new module
        /// joins those being proved, so that it is not kept waiting for ever.
        private var waiting: [String?: Int] = [:]

        init(count: Int, groups: [[Int]]) {
            self.groups = groups.reversed()
            notes = Array(repeating: [], count: count)
            results = Array(repeating: nil, count: count)
        }

        func nextGroup() -> [Int]? {
            condition.withLock { groups.popLast() }
        }

        /// Whether module `index` may start: no module before it failed (one after it in order may have).
        func mayStart(_ index: Int) -> Bool {
            condition.withLock { index < firstFailure }
        }

        func add(_ line: String, to index: Int) {
            condition.withLock {
                notes[index].append(line)
                condition.broadcast()
            }
        }

        func finish(_ index: Int, _ result: Result<Report, any Error>) {
            condition.withLock {
                results[index] = result
                if case .failure = result { firstFailure = min(firstFailure, index) }
                condition.broadcast()
            }
        }

        /// Runs `work` once no module built with another compiler is being proved.
        func proving<Value>(_ compiler: String?, _ work: () throws -> Value) rethrows -> Value {
            condition.withLock {
                waiting[compiler, default: 0] += 1
                while proving > 0 && (provingCompiler != compiler || waiting.contains { $0.key != compiler && $0.value > 0 }) {
                    condition.wait()
                }
                waiting[compiler, default: 0] -= 1
                provingCompiler = compiler
                proving += 1
            }
            defer {
                condition.withLock {
                    proving -= 1
                    condition.broadcast()
                }
            }
            return try work()
        }

        /// Module `index`'s result, after passing each of its notes to `emit` as it comes (on the calling thread).
        func wait(for index: Int, emitting emit: (String) -> Void) -> Result<Report, any Error> {
            var emitted = 0
            while true {
                condition.lock()
                while emitted == notes[index].count && results[index] == nil { condition.wait() }
                let lines = Array(notes[index][emitted...])
                let result = emitted + lines.count == notes[index].count ? results[index] : nil
                condition.unlock()
                for line in lines { emit(line) }
                emitted += lines.count
                if let result { return result }
            }
        }
    }
}
