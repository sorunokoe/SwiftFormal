import Foundation

/// One `swiftformal check` to run: the targets to prove, and the walks.
package struct CheckJob: Equatable, Sendable {
    package var scans: [TargetRef]
    package var tests: TargetRef?
    package var walks: Bool
    package var budget: Int?

    package init(scans: [TargetRef], tests: TargetRef? = nil, walks: Bool = true, budget: Int? = nil) {
        self.scans = scans
        self.tests = tests
        self.walks = walks
        self.budget = budget
    }

    /// Both jobs in one: every target of either, in order, without repeats. The newer job's settings win.
    package func merged(with newer: CheckJob) -> CheckJob {
        var scans = self.scans
        for scan in newer.scans where !scans.contains(scan) { scans.append(scan) }
        return CheckJob(scans: scans, tests: newer.tests ?? tests, walks: newer.walks || walks, budget: newer.budget ?? budget)
    }

    /// The command-line arguments after `swiftformal`.
    package var arguments: [String] {
        var arguments = ["check"]
        for scan in scans { arguments += ["--scan", scan.argument] }
        if walks, let tests { arguments += ["--tests", tests.argument] } else { arguments.append("--no-walks") }
        if let budget { arguments += ["--budget", "\(budget)"] }
        arguments.append("--json")
        return arguments
    }

    /// Every package directory the job names.
    package var packages: [String] {
        var packages: [String] = []
        for root in scans.map(\.package) + (tests.map { [$0.package] } ?? []) where !packages.contains(root) { packages.append(root) }
        return packages
    }
}

/// How a run ended.
package enum RunOutcome: Sendable {
    /// The check finished; `stdout` holds its JSON report (exit status 0 or 1).
    case finished(FinishedRun)
    /// It stopped before giving a report (exit status 2: a usage or build error, or it could not start).
    case failed(message: String)
    /// It was cancelled, and every process it started is gone.
    case cancelled
}

/// A run in progress.
package protocol RunningCheck: AnyObject, Sendable {
    /// Stops the run. Its completion reports `.cancelled` only once every process it started has exited.
    func cancel()
}

/// Starts checks. The completion is called once, on any thread.
package protocol CheckRunner: Sendable {
    func start(
        _ job: CheckJob, generation: Int, progress: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (RunOutcome) -> Void
    ) -> any RunningCheck
}

/// One check at a time; requests that arrive meanwhile are merged into a single queued job, and a newer request can
/// supersede the running one. Confined to the server's one queue (the runner's completions are posted back to it).
package final class RunScheduler: @unchecked Sendable {
    package struct Active {
        package var id: Int
        package var job: CheckJob
        package var generation: Int
        package var handle: any RunningCheck
        package var cancelling: Bool
    }

    private let runner: any CheckRunner
    private var nextID = 1
    package private(set) var active: Active?
    package private(set) var queued: CheckJob?
    /// Called (on the scheduler's queue) when a run starts and when it ends.
    package var onStart: (Active) -> Void = { _ in }
    package var onEnd: (Active, RunOutcome) -> Void = { _, _ in }
    /// Posts work back to the scheduler's queue.
    private let post: @Sendable (@escaping @Sendable () -> Void) -> Void
    /// The generation a new run starts at.
    private let generation: () -> Int
    private let progress: @Sendable (Int, String) -> Void

    package init(
        runner: any CheckRunner, generation: @escaping () -> Int, post: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        progress: @escaping @Sendable (Int, String) -> Void = { _, _ in }
    ) {
        self.runner = runner
        self.generation = generation
        self.post = post
        self.progress = progress
    }

    /// Asks for `job`. It starts now if nothing runs; otherwise it is merged into the queued job. With `supersede`, a
    /// running check is cancelled first (its answers would be stale anyway).
    package func request(_ job: CheckJob, supersede: Bool) {
        queued = queued.map { $0.merged(with: job) } ?? job
        if let active, supersede, !active.cancelling {
            // The cancelled run's targets still need an answer: they run again with the new request.
            queued = active.job.merged(with: queued ?? job)
            cancelActive()
        }
        startNextIfIdle()
    }

    /// Cancels the running check (it reports `.cancelled` when its processes are gone) and drops the queued one.
    package func cancelAll() {
        queued = nil
        cancelActive()
    }

    package func cancelActive() {
        guard var active, !active.cancelling else { return }
        active.cancelling = true
        self.active = active
        active.handle.cancel()
    }

    /// True while a check runs or waits.
    package var isBusy: Bool { active != nil || queued != nil }

    private func startNextIfIdle() {
        guard active == nil, let job = queued else { return }
        queued = nil
        let id = nextID
        nextID += 1
        let generation = generation()
        let post = post
        let progress = progress
        // The handle is set before any completion can be handled: completions are posted to this queue.
        let handle = runner.start(
            job, generation: generation, progress: { progress(id, $0) },
            completion: { [self] outcome in post { self.finished(id: id, outcome) } })
        let started = Active(id: id, job: job, generation: generation, handle: handle, cancelling: false)
        active = started
        onStart(started)
    }

    private func finished(id: Int, _ outcome: RunOutcome) {
        guard let ended = active, ended.id == id else { return }
        active = nil
        onEnd(ended, outcome)
        startNextIfIdle()
    }
}
