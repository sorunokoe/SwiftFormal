import Foundation
import Testing

@testable import SFVerifyKit

/// Holds every arriving thread until `count` have arrived (or two seconds have passed), so the spawns that follow all
/// start while every thread of Swift concurrency's pool is busy.
private final class Barrier: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = 0
    private let count: Int
    private let open = DispatchSemaphore(value: 0)

    init(_ count: Int) { self.count = count }

    func arrive() {
        lock.lock()
        arrived += 1
        let last = arrived == count
        lock.unlock()
        if last { for _ in 0..<count { open.signal() } }
        _ = open.wait(timeout: .now() + 2)
    }
}

@Suite struct SpawnTests {
    /// Tests (and parallel callers) spawn from Swift concurrency's threads. When all of them were blocked in `Spawn.run`,
    /// its stderr reader, queued on a global queue, never got a thread, and every spawn waited forever. One task fewer
    /// than the pool's threads: this test's own thread, blocked waiting, is the last one, and is free again after the
    /// timeout, so a regression fails the test instead of stopping the whole run.
    @Test func spawnsFromEveryConcurrencyThreadAtOnceFinish() {
        let width = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        let barrier = Barrier(width)
        let finished = DispatchGroup()
        let failures = Failures()
        for _ in 0..<width {
            finished.enter()
            Task.detached {
                barrier.arrive()
                do {
                    let small = try Spawn.run("/bin/sh", ["-c", "echo out; echo err >&2"])
                    // Fills stderr (1 MiB) before it reads stdin, then copies stdin to stdout.
                    let input = Data(repeating: 65, count: 1 << 20)
                    let large = try Spawn.run("/bin/sh", ["-c", "head -c 1048576 /dev/zero >&2; cat"], input: input)
                    if small.output != Data("out\n".utf8) || small.errorText != "err\n" { failures.add("small: \(small)") }
                    if large.output != input || large.errors.count != 1 << 20 || large.status != 0 {
                        failures.add("large: status \(large.status), \(large.output.count) and \(large.errors.count) bytes")
                    }
                } catch {
                    failures.add("\(error)")
                }
                finished.leave()
            }
        }
        #expect(finished.wait(timeout: .now() + 60) == .success, "spawns still running after 60 s")
        #expect(failures.all.isEmpty, "\(failures.all)")
    }

    /// `swiftformal check` starts the test build before the scan and stops it when no walk needs it.
    @Test func backgroundProcessesFinishOrStop() throws {
        let path = NSTemporaryDirectory() + "spawn-\(UUID().uuidString).log"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        let finished = try Spawn.start("/bin/sh", ["-c", "echo built"], log: log)
        #expect(finished.wait() == 0)
        #expect(finished.wait() == 0, "a second wait returns at once")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "built\n")

        let started = Date()
        let stopped = try Spawn.start("/bin/sleep", ["30"], log: log)
        stopped.stop()
        #expect(stopped.wait() != 0)
        #expect(Date().timeIntervalSince(started) < 10)
        try log.close()
    }

    /// `SFVerify.run` compiles the second build configuration on a thread of its own, while it lends that thread the
    /// caller's `linking` closure (`withoutActuallyEscaping`). A run that fails must throw, every time, not trap
    /// because the thread still held the closure.
    @Test func aFailingCompileThrowsInsteadOfTrapping() {
        for _ in 0..<20 {
            #expect(throws: (any Error).self) {
                try SFVerify.run(
                    CompileOptions(files: ["/nonexistent/sfverify-\(UUID().uuidString).swift"], moduleName: "Missing"),
                    linking: { _ in nil })
            }
        }
    }
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func add(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
