import Foundation

/// Starts a child process and collects its output. `Process.waitUntilExit()` waits by spinning the run loop in slices,
/// which added about 65 ms to every spawn (measured); this waits on the termination handler instead, and reads stdout
/// and stderr at the same time, so a child that fills one pipe while sfverify reads the other cannot block.
/// Only this module's spawns use it: one shared process module for every tool is an open decision (ADR 0009, D10).
enum Spawn {
    struct Result {
        let status: Int32
        let output: Data
        let errors: Data

        /// Stderr as text, for an error message.
        var errorText: String { String(bytes: errors, encoding: .utf8) ?? "(\(errors.count) bytes of stderr, not UTF-8)" }
    }

    /// Runs `executable` with `arguments`, writing `input` to its stdin. `output: false` discards stdout; `log` receives
    /// stdout and stderr instead of the pipes (both `output` and `errors` are then empty).
    static func run(
        _ executable: String, _ arguments: [String], input: Data? = nil, directory: String? = nil,
        environment: [String: String]? = nil, output: Bool = true, log: FileHandle? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if let environment { process.environment = environment }
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        if let log {
            process.standardOutput = log
            process.standardError = log
        } else {
            process.standardOutput = output ? outputPipe : FileHandle.nullDevice
            process.standardError = errorPipe
        }
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Queues of their own, not the global ones: those share their threads with Swift concurrency's pool, so a caller
        // on that pool, with every one of its threads blocked in a spawn, would wait for them forever.
        if let inputPipe, let input {
            DispatchQueue(label: "SFVerifyKit.Spawn.input").async {
                inputPipe.fileHandleForWriting.write(input)
                try? inputPipe.fileHandleForWriting.close()
            }
        }
        var collected = (output: Data(), errors: Data())
        if log == nil {
            let errors = Collected()
            let readErrors = DispatchWorkItem { errors.data = errorPipe.fileHandleForReading.readDataToEndOfFile() }
            DispatchQueue(label: "SFVerifyKit.Spawn.errors").async(execute: readErrors)
            if output { collected.output = outputPipe.fileHandleForReading.readDataToEndOfFile() }
            readErrors.wait()
            collected.errors = errors.data
        }
        exited.wait()
        return Result(status: process.terminationStatus, output: collected.output, errors: collected.errors)
    }

    /// A process started by `start`, running while the caller does something else.
    final class Background {
        private let process: Process
        private let exited: DispatchSemaphore

        fileprivate init(_ process: Process, exited: DispatchSemaphore) {
            self.process = process
            self.exited = exited
        }

        /// Waits for the process to exit and returns its status; later calls return at once.
        func wait() -> Int32 {
            exited.wait()
            exited.signal()
            return process.terminationStatus
        }

        /// Stops the process (SIGTERM) if it still runs, and waits for it.
        func stop() {
            if process.isRunning { process.terminate() }
            _ = wait()
        }
    }

    /// Starts `executable` with stdout and stderr going to `log`, and returns without waiting for it.
    static func start(_ executable: String, _ arguments: [String], directory: String? = nil, log: FileHandle) throws -> Background {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardOutput = log
        process.standardError = log
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        return Background(process, exited: exited)
    }

    /// `xcrun <arguments>` printed one line (a path), trimmed.
    static func xcrunLine(_ arguments: [String]) throws -> String {
        let result = try run("/usr/bin/xcrun", arguments)
        return (String(bytes: result.output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Written by one reader thread, read after `wait()` on its work item, which orders the accesses.
    private final class Collected: @unchecked Sendable {
        var data = Data()
    }
}
