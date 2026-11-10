import Foundation
import SFLanguageServer
import Testing

/// One check at a time; requests meanwhile are merged; a newer request can supersede the running one.
@Suite struct RunSchedulerTests {
    final class Events: @unchecked Sendable {
        var started: [CheckJob] = []
        var ended: [String] = []
    }

    /// A scheduler on `queue`, recording starts and ends.
    func scheduler(_ runner: FakeRunner, queue: DispatchQueue, events: Events) -> RunScheduler {
        let scheduler = RunScheduler(runner: runner, generation: { 0 }, post: { work in queue.async(execute: work) })
        scheduler.onStart = { events.started.append($0.job) }
        scheduler.onEnd = { _, outcome in
            switch outcome {
            case .finished: events.ended.append("finished")
            case .failed: events.ended.append("failed")
            case .cancelled: events.ended.append("cancelled")
            }
        }
        return scheduler
    }

    let a = TargetRef(package: "/w/A", target: "A")
    let b = TargetRef(package: "/w/B", target: "B")
    let c = TargetRef(package: "/w/C", target: "C")

    @Test func requestsWhileRunningAreCoalescedIntoOneRun() {
        let queue = DispatchQueue(label: "test")
        let runner = FakeRunner()
        let events = Events()
        let scheduler = scheduler(runner, queue: queue, events: events)
        queue.sync {
            scheduler.request(CheckJob(scans: [a], walks: false), supersede: false)
            scheduler.request(CheckJob(scans: [b], walks: false), supersede: false)
            scheduler.request(CheckJob(scans: [c, b], walks: false), supersede: false)
        }
        #expect(runner.runs.count == 1)
        #expect(queue.sync { scheduler.queued?.scans } == [b, c])
        runner.runs[0].completion(.failed(message: "x"))
        queue.sync {}
        #expect(runner.runs.count == 2)
        #expect(runner.runs[1].job.scans == [b, c])
        #expect(events.ended == ["failed"])
        runner.runs[1].completion(.failed(message: "x"))
        queue.sync {}
        #expect(queue.sync { scheduler.isBusy } == false)
    }

    @Test func aSupersedingRequestCancelsTheRunAndRerunsItsTargets() {
        let queue = DispatchQueue(label: "test")
        let runner = FakeRunner(cancelsAtOnce: false)
        let events = Events()
        let scheduler = scheduler(runner, queue: queue, events: events)
        queue.sync { scheduler.request(CheckJob(scans: [a], walks: false), supersede: false) }
        queue.sync { scheduler.request(CheckJob(scans: [b], walks: false), supersede: true) }
        #expect(runner.runs[0].cancelled)
        // Nothing new starts until the cancelled run's processes are gone.
        #expect(runner.runs.count == 1)
        runner.runs[0].completion(.cancelled)
        queue.sync {}
        #expect(events.ended == ["cancelled"])
        #expect(runner.runs.count == 2)
        #expect(Set(runner.runs[1].job.scans) == [a, b])
    }

    @Test func aLateCompletionOfAnEndedRunIsIgnored() {
        let queue = DispatchQueue(label: "test")
        let runner = FakeRunner(cancelsAtOnce: false)
        let events = Events()
        let scheduler = scheduler(runner, queue: queue, events: events)
        queue.sync { scheduler.request(CheckJob(scans: [a], walks: false), supersede: false) }
        runner.runs[0].completion(.cancelled)
        runner.runs[0].completion(.failed(message: "twice"))
        queue.sync {}
        #expect(events.ended == ["cancelled"])
    }

    @Test func cancelAllDropsTheQueue() {
        let queue = DispatchQueue(label: "test")
        let runner = FakeRunner()
        let events = Events()
        let scheduler = scheduler(runner, queue: queue, events: events)
        queue.sync {
            scheduler.request(CheckJob(scans: [a], walks: false), supersede: false)
            scheduler.request(CheckJob(scans: [b], walks: false), supersede: false)
            scheduler.cancelAll()
        }
        queue.sync {}
        #expect(events.ended == ["cancelled"])
        #expect(runner.runs.count == 1)
        #expect(queue.sync { scheduler.isBusy } == false)
    }

    @Test func mergedJobsKeepEveryTargetAndWalks() {
        let merged = CheckJob(scans: [a], walks: false, budget: 10).merged(with: CheckJob(scans: [b], tests: c, walks: true, budget: 20))
        #expect(merged.scans == [a, b] && merged.tests == c && merged.walks && merged.budget == 20)
        #expect(
            merged.arguments == ["check", "--scan", a.argument, "--scan", b.argument, "--tests", c.argument, "--budget", "20", "--json"])
        #expect(CheckJob(scans: [a], walks: false).arguments == ["check", "--scan", a.argument, "--no-walks", "--json"])
    }
}

/// Stopping a check stops every process it started, even those in their own process groups.
@Suite struct ProcessTreeTests {
    @Test func killStopsTheWholeTreeAndConfirmsIt() throws {
        let child = try ChildProcess.spawn("/bin/sh", ["-c", "sleep 30 & (sleep 30 & wait) & wait"])
        var tree: [pid_t] = []
        for _ in 0..<100 where tree.count < 4 {
            tree = ProcessTree.tree(child.pid)
            usleep(20_000)
        }
        #expect(tree.count >= 4)
        let left = ProcessTree.kill(root: child.pid, rootExited: { child.hasExited })
        #expect(left.isEmpty)
        _ = child.reap()
        #expect(tree.dropFirst().allSatisfy { !ProcessTree.exists($0) })
    }
}
