import Foundation
import SFLanguageServer
import Testing

/// `swiftformal check --jobs`: scanning packages at the same time prints what scanning one module at a time prints,
/// on stdout and with the same exit code, also when a module does not build.
@Suite struct CheckJobsSlowTests {
    private struct Run: Equatable {
        var status: Int32
        var output: String
        /// Standard error without the times and the line `--jobs` adds.
        var notes: [String]
        /// Whether packages were scanned at the same time (that line was there).
        var atOnce = false

        static func == (a: Run, b: Run) -> Bool { (a.status, a.output, a.notes) == (b.status, b.output, b.notes) }
    }

    private static func check(_ arguments: [String], in root: String) throws -> Run {
        let executable = try #require(LanguageServerSlowTests.executable, "build the swiftformal product first")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["check"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let errors = Thread.detachedRead(error.fileHandleForReading)
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = String(bytes: errors.wait(), encoding: .utf8) ?? ""
        let lines = stderr.split(separator: "\n").map(String.init)
        let notes = lines.filter { !$0.hasPrefix("swiftformal: logic: scanning ") }
            .map { $0.replacingOccurrences(of: #"\(\d+ s"#, with: "(… s", options: .regularExpression) }
        return Run(
            status: process.terminationStatus, output: String(bytes: stdout, encoding: .utf8) ?? "", notes: notes,
            atOnce: notes.count < lines.count)
    }

    private struct Source {
        var package, target, code: String
        init(_ package: String, _ target: String, _ code: String) { (self.package, self.target, self.code) = (package, target, code) }
    }

    /// Two packages; `p1` has two targets, one with a trap. `broken`: `p2` also has a target that does not compile.
    private static func packages(broken: Bool) throws -> String {
        let root = NSTemporaryDirectory() + "sf-check-jobs-\(UUID().uuidString)"
        let sources =
            [
                Source("p1", "A", "public func half(_ x: Int8) -> Int8 { x / 2 }\n"),
                Source("p1", "B", "public func next(_ x: Int8) -> Int8 { x + 1 }\n"),
                Source("p2", "C", "public func third(_ x: Int8) -> Int8 { x / 3 }\n"),
            ] + (broken ? [Source("p2", "D", "public func broken() -> Int8 { undefined }\n")] : [])
        for package in ["p1", "p2"] {
            let targets = sources.filter { $0.package == package }.map { ".target(name: \"\($0.target)\")" }
            try FileManager.default.createDirectory(atPath: root + "/" + package, withIntermediateDirectories: true)
            try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "\(package)", platforms: [.macOS(.v13)], targets: [\(targets.joined(separator: ", "))])
            """.write(toFile: root + "/\(package)/Package.swift", atomically: true, encoding: .utf8)
        }
        for source in sources {
            let folder = root + "/\(source.package)/Sources/\(source.target)"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try source.code.write(toFile: folder + "/\(source.target).swift", atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func packagesScannedAtOnceReportWhatOneAtATimeReports() throws {
        let root = try Self.packages(broken: false)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let scans = ["--scan", "p1:A", "--scan", "p2:C", "--scan", "p1:B", "--no-proof-cache"]
        for format in [["--json"], ["--xcode", "--strict"], ["--show-proved"]] {
            let sequential = try Self.check(scans + format + ["--jobs", "1"], in: root)
            let concurrent = try Self.check(scans + format + ["--jobs", "2"], in: root)
            #expect(concurrent == sequential, "\(format)")
            #expect(concurrent.atOnce && !sequential.atOnce)
            #expect(sequential.status == (format.contains("--strict") ? 1 : 0), "\(sequential.notes)")
            if format == ["--json"] {
                // The language server reads it, with the modules in --scan order.
                let results = try CheckResults.read(Data(concurrent.output.utf8))
                #expect(results.modules?.map(\.module) == ["A", "C", "B"])
            }
        }
    }

    @Test func aModuleThatDoesNotBuildFailsTheRunAsOneAtATime() throws {
        let root = try Self.packages(broken: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let scans = ["--scan", "p1:A", "--scan", "p2:C", "--scan", "p2:D", "--scan", "p1:B", "--json", "--no-proof-cache"]
        let sequential = try Self.check(scans + ["--jobs", "1"], in: root)
        let concurrent = try Self.check(scans + ["--jobs", "2"], in: root)
        #expect(sequential.status == 2 && sequential.output.isEmpty)
        #expect(sequential.notes.contains { $0.hasPrefix("swiftformal: logic: C: ") })
        #expect(!sequential.notes.contains { $0.contains("building B") })
        // The error quotes `swift build -v`, whose log differs between a first and a later build of the package.
        func headline(_ run: Run) -> Run {
            var run = run
            run.notes = Array(run.notes.prefix { !$0.contains("COMPILER FAILED") } + run.notes.filter { $0.contains("COMPILER FAILED") })
            return run
        }
        #expect(headline(concurrent) == headline(sequential))
        #expect(concurrent.atOnce)
        #expect(headline(sequential).notes.last == "swiftformal: COMPILER FAILED: swift build --target D failed:")
        for run in [sequential, concurrent] {
            #expect(run.notes.contains { $0.contains("cannot find 'undefined' in scope") })
        }
    }
}

extension Thread {
    /// Reads `handle` to its end on a thread of its own; `wait()` returns what it read.
    fileprivate static func detachedRead(_ handle: FileHandle) -> DetachedRead {
        let read = DetachedRead()
        Thread {
            read.data = handle.readDataToEndOfFile()
            read.done.signal()
        }.start()
        return read
    }

    fileprivate final class DetachedRead: @unchecked Sendable {
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        func wait() -> Data {
            done.wait()
            return data
        }
    }
}
