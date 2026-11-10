import Foundation
import SFVerifyKit
import Testing

/// `swiftformal check --jobs`: packages scanned at the same time give what one after another gives.
@Suite struct ScanScheduleTests {
    private struct Failure: Error, Equatable { var message: String }

    /// A fake module: its package's build folder, its compiler, how long it works, and where it fails.
    private struct Module {
        var folder: String
        var compiler: String? = "swiftc"
        var seconds = 0.0
        var failsIn: String?
    }

    /// What ran when, shared by the workers.
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        private var activeFolders: [String: Int] = [:]
        private var proving: [String?] = []
        private(set) var samePackageOverlapped = false
        private(set) var compilersMixed = false
        private(set) var mostAtOnce = 0
        private var running = 0

        func start(_ event: String, folder: String) {
            lock.withLock {
                events.append(event)
                activeFolders[folder, default: 0] += 1
                if activeFolders[folder, default: 0] > 1 { samePackageOverlapped = true }
                running += 1
                mostAtOnce = max(mostAtOnce, running)
            }
        }

        func end(folder: String) {
            lock.withLock {
                activeFolders[folder, default: 0] -= 1
                running -= 1
            }
        }

        func startProving(_ compiler: String?) {
            lock.withLock {
                if proving.contains(where: { $0 != compiler }) { compilersMixed = true }
                proving.append(compiler)
            }
        }

        func endProving(_ compiler: String?) {
            lock.withLock { if let index = proving.firstIndex(of: compiler) { proving.remove(at: index) } }
        }

        var isIdle: Bool { lock.withLock { running == 0 } }
    }

    private final class Notes: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
    }

    private func run(_ modules: [Module], jobs: Int, trace: Trace = Trace()) -> (notes: [String], result: Result<[String], Failure>) {
        let notes = Notes()
        let result = Result<[String], any Error> {
            try ScanSchedule.run(
                count: modules.count, jobs: jobs, folder: { modules[$0].folder },
                stages: ScanSchedule.Stages(
                    plan: { index, note in
                        let module = modules[index]
                        trace.start("plan \(index)", folder: module.folder)
                        defer { trace.end(folder: module.folder) }
                        note("building \(index)")
                        Thread.sleep(forTimeInterval: module.seconds / 2)
                        if module.failsIn == "plan" { throw Failure(message: "plan \(index) failed") }
                        return module.compiler
                    },
                    compiler: { $0 },
                    prove: { index, compiler, note in
                        let module = modules[index]
                        trace.start("prove \(index)", folder: module.folder)
                        trace.startProving(compiler)
                        defer {
                            trace.endProving(compiler)
                            trace.end(folder: module.folder)
                        }
                        Thread.sleep(forTimeInterval: module.seconds / 2)
                        if module.failsIn == "prove" { throw Failure(message: "prove \(index) failed") }
                        note("proved \(index)")
                        return "report \(index)"
                    }),
                note: notes.add)
        }
        return (notes.lines, result.mapError { $0 as? Failure ?? Failure(message: "\($0)") })
    }

    @Test func packagesScannedAtOnceGiveTheNotesAndReportsOfOneAfterAnother() throws {
        // The first module is the slowest: the others finish first, and are still reported after it.
        let modules = [
            Module(folder: "a", seconds: 0.4), Module(folder: "b", seconds: 0.05), Module(folder: "a", seconds: 0.05),
            Module(folder: "c", seconds: 0.1),
        ]
        let sequential = run(modules, jobs: 1)
        let trace = Trace()
        let concurrent = run(modules, jobs: 4, trace: trace)
        #expect(try sequential.result.get() == ["report 0", "report 1", "report 2", "report 3"])
        #expect(try concurrent.result.get() == sequential.result.get())
        #expect(concurrent.notes.filter { !$0.hasPrefix("logic: scanning") } == sequential.notes)
        #expect(trace.mostAtOnce > 1)
        #expect(!trace.samePackageOverlapped)
        // The modules of one package keep their order: 0 is planned and proved before 2 starts.
        let events = trace.events
        #expect(events.firstIndex(of: "prove 0")! < events.firstIndex(of: "plan 2")!)
    }

    @Test func oneJobRunsEachModuleToTheEndInScanOrder() {
        let trace = Trace()
        let modules = [Module(folder: "a"), Module(folder: "b"), Module(folder: "a")]
        let result = run(modules, jobs: 1, trace: trace)
        #expect(trace.events == ["plan 0", "prove 0", "plan 1", "prove 1", "plan 2", "prove 2"])
        #expect(result.notes == ["building 0", "proved 0", "building 1", "proved 1", "building 2", "proved 2"])
    }

    @Test func theFirstFailureInScanOrderIsReportedAsInSequence() {
        for failsIn in ["plan", "prove"] {
            // Module 1 fails; module 3 (another package) fails sooner, but comes later in order.
            let modules = [
                Module(folder: "a", seconds: 0.3), Module(folder: "b", seconds: 0.1, failsIn: failsIn), Module(folder: "b"),
                Module(folder: "c", failsIn: "prove"), Module(folder: "a"),
            ]
            let sequential = run(modules, jobs: 1)
            let trace = Trace()
            let concurrent = run(modules, jobs: 4, trace: trace)
            #expect(sequential.result == .failure(Failure(message: "\(failsIn) 1 failed")))
            #expect(concurrent.result == sequential.result)
            #expect(concurrent.notes.filter { !$0.hasPrefix("logic: scanning") } == sequential.notes)
            // Nothing runs on after the error is returned, and the package of the failure stops at it.
            #expect(trace.isIdle)
            #expect(!trace.events.contains("plan 2"))
        }
    }

    @Test func modulesBuiltWithAnotherCompilerAreNotProvedAtTheSameTime() throws {
        let modules = [
            Module(folder: "a", compiler: "x", seconds: 0.2), Module(folder: "b", compiler: "y", seconds: 0.2),
            Module(folder: "c", compiler: nil, seconds: 0.2), Module(folder: "d", compiler: "x", seconds: 0.2),
        ]
        let trace = Trace()
        let concurrent = run(modules, jobs: 4, trace: trace)
        #expect(try concurrent.result.get() == run(modules, jobs: 1).result.get())
        #expect(!trace.compilersMixed)
    }

    @Test func modulesGroupByTheFolderSwiftPMBuildsTheirPackageIn() throws {
        let root = NSTemporaryDirectory() + "sf-scan-folders-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/Real/Nested", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/Link", withDestinationPath: root + "/Real")
        #expect(ScanSchedule.buildFolder(of: root + "/Link") == ScanSchedule.buildFolder(of: root + "/Real/"))
        #expect(ScanSchedule.buildFolder(of: root + "/Real/Nested/..") == ScanSchedule.buildFolder(of: root + "/Real"))
        #expect(ScanSchedule.buildFolder(of: root + "/Real/Nested") != ScanSchedule.buildFolder(of: root + "/Real"))
    }
}
