import Foundation

/// Work running on a thread of its own, started at once; `value()` waits for it. Not a global queue: callers may be on
/// Swift concurrency's threads, and global-queue work cannot start while all of them wait (see `Spawn`).
final class Background<Value>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Value, any Error>?
    private var work: (@Sendable () throws -> Value)?

    /// `work` is released before `value()` returns, so it may capture a closure lent by `withoutActuallyEscaping`
    /// (the thread itself may live a little longer, and it holds only this object).
    init(_ work: @escaping @Sendable () throws -> Value) {
        self.work = work
        let thread = Thread { [self] in
            run()
            done.signal()
        }
        // Parsing and verifying recurse deeply; a secondary thread's default stack (512 KiB) is too small.
        thread.stackSize = 64 << 20
        thread.start()
    }

    private func run() {
        guard let work else { return }
        self.work = nil
        result = Result { try work() }
    }

    /// The work's result, after waiting for it; later calls return at once.
    func value() throws -> Value {
        done.wait()
        done.signal()
        guard let result else { preconditionFailure("background work finished without a result") }
        return try result.get()
    }
}

/// A `dependency` closure of `ModuleCompiler.compile(_:linking:)` asked at most once per module and one call at a
/// time, so that two compiles of one module can share it: it may run `swift build`, which writes one shared log.
final class Dependencies: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<CompileOptions?, any Error>] = [:]
    private let ask: (String) throws -> CompileOptions?

    init(_ ask: @escaping (String) throws -> CompileOptions?) { self.ask = ask }

    func options(for module: String) throws -> CompileOptions? {
        lock.lock()
        defer { lock.unlock() }
        if let answer = answers[module] { return try answer.get() }
        let answer = Result { try ask(module) }
        answers[module] = answer
        return try answer.get()
    }
}
