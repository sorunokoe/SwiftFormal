package import Darwin
package import Foundation

/// A child process started with `posix_spawn`, reaped only when the caller says so: until then its pid cannot be
/// reused, so stopping its tree never signals a stranger.
package struct ChildProcess: Sendable {
    package let pid: pid_t
    /// The read ends of its standard output and error. Standard input is `/dev/null`.
    package let stdout: FileHandle
    package let stderr: FileHandle

    package struct SpawnError: Error, CustomStringConvertible {
        package var description: String
    }

    /// Starts `executable` with `arguments` in `directory`. Only the three standard descriptors are inherited.
    package static func spawn(_ executable: String, _ arguments: [String], directory: String? = nil) throws -> ChildProcess {
        let output = Pipe()
        let errors = Pipe()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, 2)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        guard result == 0 else { throw SpawnError(description: "could not start \(executable): \(String(cString: strerror(result)))") }
        return ChildProcess(pid: pid, stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading)
    }

    /// Blocks until the process has exited, without reaping it.
    package func waitForExit() {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
    }

    /// True once the process has exited (it is not reaped).
    package var hasExited: Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG) == 0 && info.si_pid == pid
    }

    /// Reaps the exited process: its exit status, or minus the signal that ended it.
    package func reap() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : -signal
    }
}
