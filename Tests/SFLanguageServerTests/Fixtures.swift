import Foundation
import SFLanguageServer

/// A package on disk to check: `Package.swift` and `Sources/Lib/Lib.swift`.
struct FixturePackage {
    let root: String
    var source: String { root + "/Sources/Lib/Lib.swift" }

    static let libText = """
        public func add(_ a: Int, _ b: Int) -> Int {
            a + b
        }

        public func half(_ n: Int) -> Int {
            n / 2
        }

        public func pick(_ n: Int) -> Int {
            n
        }

        """

    init(text: String = Self.libText) throws {
        let base = NSTemporaryDirectory() + "sf-lsp-tests-" + UUID().uuidString
        root = Paths.standard(base)
        try FileManager.default.createDirectory(atPath: root + "/Sources/Lib", withIntermediateDirectories: true)
        try
            "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n"
            .write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
        try text.write(toFile: source, atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    var target: TargetRef { TargetRef(package: root, target: "Lib") }
}

/// A `swiftformal check --json` report about `file`: `add` may trap (only in a release build), `half` cannot trap,
/// `pick` is unchecked.
func checkJSON(file: String, configurations: [String] = ["debug", "release"], pinned: Bool = true, optimization: String = "-Onone")
    -> Data
{
    let configurations = configurations.map { "\"\($0)\"" }.joined(separator: ", ")
    let json = """
        {"schemaVersion": 1,
         "modules": [{"module": "Lib", "optimization": "\(optimization)", "configurations": [\(configurations)],
                      "compiler": "Apple Swift version 6.3", "pinned": \(pinned)}],
         "entries": [
          {"module": "Lib", "function": "add(_:_:)", "location": {"file": "\(file)", "line": 1, "column": 13},
           "logic": "mayTrap", "outcome": "counterexample", "walks": [],
           "counterexample": {"inputs": ["a = 9223372036854775807", "b = 1"],
                              "failure": "in a release build (-assert-config Release): traps: arithmetic overflow",
                              "at": {"file": "\(file)", "line": 2, "column": 7}, "replay": "add(9223372036854775807, 1)"}},
          {"module": "Lib", "function": "half(_:)", "location": {"file": "\(file)", "line": 5, "column": 13},
           "logic": "safe", "outcome": "cannotTrap", "walks": []},
          {"module": "Lib", "function": "pick(_:)", "location": {"file": "\(file)", "line": 9, "column": 13},
           "logic": "undecided", "outcome": "unchecked", "walks": [], "category": "budget",
           "detail": "the solver ran out of budget", "hint": "raise --budget"}
         ]}
        """
    return Data(json.utf8)
}

/// One report of two packages that both have a target `Lib` (A checked in debug only), as `checkJSON` writes each;
/// with `namePackages`, each module and entry says its package, as `swiftformal check` does.
func twoPackagesJSON(_ a: FixturePackage, _ b: FixturePackage, namePackages: Bool) throws -> Data {
    func part(_ package: FixturePackage, _ configurations: [String]) throws -> [String: Any] {
        guard
            var json = try JSONSerialization.jsonObject(with: checkJSON(file: package.source, configurations: configurations))
                as? [String: Any]
        else { throw CocoaError(.coderReadCorrupt) }
        guard namePackages else { return json }
        for key in ["modules", "entries"] {
            json[key] = (json[key] as? [[String: Any]])?.map { item in item.merging(["package": package.root]) { $1 } }
        }
        return json
    }
    var json = try part(a, ["debug"])
    let other = try part(b, ["debug", "release"])
    for key in ["modules", "entries"] {
        json[key] = (json[key] as? [Any] ?? []) + (other[key] as? [Any] ?? [])
    }
    return try JSONSerialization.data(withJSONObject: json)
}

/// A finished run of `package`'s `Lib` with the report of `checkJSON`.
func finishedRun(
    _ package: FixturePackage, generation: Int, job: CheckJob? = nil, json: Data? = nil, changedWhileRunning: ChangeScope? = nil
) throws -> FinishedRun {
    FinishedRun(
        job: job ?? CheckJob(scans: [package.target], walks: false), generation: generation,
        results: try CheckResults.read(json ?? checkJSON(file: package.source)), closures: [package.root: [package.root]],
        snapshot: InputSnapshot.capture(roots: [package.root], context: [:], hash: true), changedWhileRunning: changedWhileRunning)
}

/// A runner that starts nothing: the test finishes each run.
final class FakeRunner: CheckRunner, @unchecked Sendable {
    final class Run: RunningCheck, @unchecked Sendable {
        let job: CheckJob
        let generation: Int
        let completion: @Sendable (RunOutcome) -> Void
        private let lock = NSLock()
        private var cancelledFlag = false
        /// When true, `cancel` reports `.cancelled` at once (a run whose processes are gone).
        let cancelsAtOnce: Bool

        init(job: CheckJob, generation: Int, cancelsAtOnce: Bool, completion: @escaping @Sendable (RunOutcome) -> Void) {
            self.job = job
            self.generation = generation
            self.cancelsAtOnce = cancelsAtOnce
            self.completion = completion
        }

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelledFlag
        }

        func cancel() {
            lock.lock()
            cancelledFlag = true
            lock.unlock()
            if cancelsAtOnce { completion(.cancelled) }
        }
    }

    private let lock = NSLock()
    private var started: [Run] = []
    let cancelsAtOnce: Bool

    init(cancelsAtOnce: Bool = true) { self.cancelsAtOnce = cancelsAtOnce }

    var runs: [Run] {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func start(
        _ job: CheckJob, generation: Int, progress: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (RunOutcome) -> Void
    ) -> any RunningCheck {
        let run = Run(job: job, generation: generation, cancelsAtOnce: cancelsAtOnce, completion: completion)
        lock.lock()
        started.append(run)
        lock.unlock()
        return run
    }
}

/// Every message a server sent, in order.
final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [RPCMessage] = []

    func append(_ message: RPCMessage) {
        lock.lock()
        sent.append(message)
        lock.unlock()
    }

    var messages: [RPCMessage] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func notifications(_ method: String) -> [JSONValue] {
        messages.compactMap {
            if case .notification(method, let params) = $0 { return params }
            return nil
        }
    }

    func response(_ id: Int) -> JSONValue? {
        messages.lazy.compactMap {
            if case .response(.number(id), let result) = $0 { return result }
            return nil
        }.first
    }

    func error(_ id: Int) -> Int? {
        messages.lazy.compactMap {
            if case .errorResponse(.number(id), let code, _) = $0 { return code }
            return nil
        }.first
    }
}
