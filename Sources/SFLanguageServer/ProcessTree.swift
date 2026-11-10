package import Darwin
package import Foundation

/// Stopping a process and everything it started. SwiftPM starts its compilers in process groups of their own, so a
/// group signal misses them; the tree is found by parent pid instead.
package enum ProcessTree {
    /// The pids whose parent is `pid`.
    package static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 256
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = Int(proc_listchildpids(pid, &pids, Int32(capacity * MemoryLayout<pid_t>.size)))
            if count < 0 { return [] }
            if count < capacity { return Array(pids.prefix(count)).filter { $0 > 0 } }
            capacity *= 4
        }
    }

    /// `pid` and every process below it, parents before children.
    package static func tree(_ pid: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var queue = [pid]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard !out.contains(next) else { continue }
            out.append(next)
            queue += children(of: next)
        }
        return out
    }

    /// True while `pid` exists (a zombie counts until it is reaped).
    package static func exists(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    /// Freezes the tree under `root` from the top down (a stopped process neither starts nor leaves children, so
    /// none escapes to `launchd`), kills every process in it, and waits until all are gone or `timeout` passes.
    /// Returns the pids still there at the end (empty on success). `rootExited` tells when `root`, the caller's own
    /// child that it reaps itself, has exited (it stays a zombie until reaped).
    @discardableResult
    package static func kill(root: pid_t, timeout: TimeInterval = 10, rootExited: () -> Bool) -> [pid_t] {
        var frozen: [pid_t] = []
        while true {
            let found = tree(root).filter { !frozen.contains($0) }
            if found.isEmpty { break }
            for pid in found { _ = Darwin.kill(pid, SIGSTOP) }
            frozen += found
        }
        for pid in frozen { _ = Darwin.kill(pid, SIGKILL) }
        let deadline = Date().addingTimeInterval(timeout)
        var left = frozen
        while true {
            left = left.filter { $0 == root ? !rootExited() : exists($0) }
            if left.isEmpty || Date() > deadline { return left }
            usleep(20_000)
        }
    }
}
