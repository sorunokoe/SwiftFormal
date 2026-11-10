import Foundation
import SFVerifyKit
import Testing

/// Plan item K5: `sfverify --build-log` takes the compile command from a build that already ran (what
/// `swift package scan` hands over, since its sandbox allows no nested build) and never builds.
@Suite struct BuildLogTests {
    private func scratch() throws -> String {
        let scratch = NSTemporaryDirectory() + "sfv-k5-\(UUID().uuidString)"
        let data = scratch + "/out/Intermediates.noindex/XCBuildData"
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        try "swiftbuild".write(toFile: scratch + "/.buildSystem_debug", atomically: true, encoding: .utf8)
        try "0af7bfbf2be300397f5d16ed07f9b2c7\n".write(toFile: data + "/prior-build-descriptions.txt", atomically: true, encoding: .utf8)
        return scratch
    }

    @Test func aLogThatCompiledTheTargetGivesItsCommandAndSavesIt() throws {
        let scratch = try scratch()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let source = scratch + "/Kern.swift"
        try "func f() {}".write(toFile: source, atomically: true, encoding: .utf8)
        let log = "builtin-Swift-Compilation -- /usr/bin/swiftc -module-name Kern -Onone -DKERN_FLAG \(source) -c\n"
        let plan = try SwiftPMBuild.plan(log: log, target: "Kern", scratch: scratch, cacheDirectory: scratch + "/cache")
        #expect(plan.files == [source])
        #expect(plan.arguments == ["-DKERN_FLAG"])
        #expect(!plan.usedCachedArguments)

        // The next build compiles nothing: the command saved for this description is used.
        let again = try SwiftPMBuild.plan(log: "Build complete!\n", target: "Kern", scratch: scratch, cacheDirectory: scratch + "/cache")
        #expect(again.usedCachedArguments)
        #expect(again.arguments == ["-DKERN_FLAG"])
    }

    @Test func aLogThatCompiledNothingAndNoSavedCommandSaysWhatToDo() throws {
        let scratch = try scratch()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let error = #expect(throws: ScanUsageError.self) {
            try SwiftPMBuild.plan(log: "Build complete!\n", target: "Kern", scratch: scratch)
        }
        #expect(error?.description.contains("touch Sources/Kern/*.swift") == true)
    }

    // MARK: Xcode (K6)

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// `xcodebuild` prints the same `builtin-Swift-Compilation -- swiftc …` lines as SwiftPM's Swift Build.
    @Test func anXcodebuildLogGivesTheTargetsCommand() throws {
        let log = try SwiftPMBuild.readBuildLog(Self.fixtures.appendingPathComponent("xcodebuild-Pkg.log").path, module: "Kern")
        let kern = try #require(SwiftPMBuild.compileCommand(in: log, module: "Kern"))
        #expect(kern.contains("-DKERN_FLAG"))
        #expect(kern.contains { $0.hasPrefix("@/fixture/") && $0.hasSuffix("/Kern.SwiftFileList") })
        let base = try #require(SwiftPMBuild.compileCommand(in: log, module: "Base"))
        #expect(!base.contains("-DKERN_FLAG"))
    }

    /// Xcode's own log (`DerivedData/…/Logs/Build/*.xcactivitylog`, gzip-compressed SLF) holds the same command.
    @Test func anActivityLogGivesTheSameCommandAsXcodebuildsOutput() throws {
        let activity = try SwiftPMBuild.readBuildLog(
            Self.fixtures.appendingPathComponent("xcode-Pkg.xcactivitylog").path, module: "Kern")
        let printed = try SwiftPMBuild.readBuildLog(Self.fixtures.appendingPathComponent("xcodebuild-Pkg.log").path, module: "Kern")
        let fromActivity = try #require(SwiftPMBuild.compileCommand(in: activity, module: "Kern"))
        #expect(fromActivity == SwiftPMBuild.compileCommand(in: printed, module: "Kern"))
    }

    // MARK: dependencies an incremental build did not compile (app study round 6, L1)

    /// An activity log holding `lines` (gzip-compressed SLF: `SLF0`, then `<length>"<bytes>` per string), modified at
    /// `date`.
    private func writeActivityLog(_ lines: [String], to path: String, modified date: Date) throws {
        var slf = Data("SLF0".utf8)
        for line in lines { slf += Data("\(line.utf8.count)\"\(line)".utf8) }
        let raw = path + ".slf"
        try slf.write(to: URL(fileURLWithPath: raw))
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-c", raw]
        FileManager.default.createFile(atPath: path, contents: nil)
        gzip.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try gzip.run()
        gzip.waitUntilExit()
        try FileManager.default.removeItem(atPath: raw)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// A DerivedData folder whose `Base` module has sources outside it (a local target), and two activity logs: the
    /// newest, of an incremental build, compiled only `Kern`; the older, of a clean build, compiled both.
    private func incrementalDerivedData(olderTarget: String = "arm64-apple-ios17.0-simulator") throws -> (derived: String, source: String) {
        let derived = NSTemporaryDirectory() + "sfv-l1-\(UUID().uuidString)"
        let logs = derived + "/Logs/Build"
        let objects = derived + "/Build/Intermediates.noindex/App.build/Debug-iphonesimulator/Base-t.build/Objects-normal/arm64"
        try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: objects, withIntermediateDirectories: true)
        let source = NSTemporaryDirectory() + "sfv-l1-src-\(UUID().uuidString).swift"
        try "public struct Box { public var n: Int }".write(toFile: source, atomically: true, encoding: .utf8)
        try source.write(toFile: objects + "/Base.SwiftFileList", atomically: true, encoding: .utf8)
        func compile(_ module: String, target: String) -> String {
            "builtin-Swift-Compilation -- /usr/bin/swiftc -module-name \(module) -target \(target) -sdk /SDKs/Sim.sdk "
                + "-D\(module.uppercased())_FLAG \(source) -c"
        }
        let now = Date()
        try writeActivityLog(
            [compile("Base", target: olderTarget), compile("Kern", target: "arm64-apple-ios17.0-simulator")],
            to: logs + "/Clean.xcactivitylog", modified: now.addingTimeInterval(-600))
        try writeActivityLog(
            [compile("Kern", target: "arm64-apple-ios17.0-simulator")], to: logs + "/Incremental.xcactivitylog", modified: now)
        return (derived, source)
    }

    @Test func aDependencyTheIncrementalBuildDidNotCompileComesFromAnOlderLog() throws {
        let (derived, source) = try incrementalDerivedData()
        defer {
            try? FileManager.default.removeItem(atPath: derived)
            try? FileManager.default.removeItem(atPath: source)
        }
        let log = try SwiftPMBuild.readBuildLog(derived, module: "Kern")
        #expect(SwiftPMBuild.compileCommand(in: log, module: "Base") == nil, "the newest log compiled only Kern")
        let main = try #require(SwiftPMBuild.compileCommand(in: log, module: "Kern"))
        let options = try SwiftPMBuild.localDependency(
            "Base", log: log, scratch: derived, cacheDirectory: derived + "/cache", otherLogs: SwiftPMBuild.ActivityLogs(folder: derived),
            compatibleWith: main)
        #expect(options?.extraArguments.contains("-DBASE_FLAG") == true, "\(String(describing: options?.extraArguments))")
        #expect(options?.files == [source])
        // A module that is not a local target (an SDK module) is still left to the SDK, without a warning.
        let sdk = try SwiftPMBuild.localDependency(
            "Foundation", log: log, scratch: derived, otherLogs: SwiftPMBuild.ActivityLogs(folder: derived), compatibleWith: main)
        #expect(sdk == nil)
    }

    /// Without a usable older command the module is not linked with a reason (the scan's warnings name it), never
    /// left out silently.
    @Test func aDependencyNoLogCompiledForThisPlatformIsReportedNotSkipped() throws {
        let (derived, source) = try incrementalDerivedData(olderTarget: "arm64-apple-macos14.0")
        defer {
            try? FileManager.default.removeItem(atPath: derived)
            try? FileManager.default.removeItem(atPath: source)
        }
        let log = try SwiftPMBuild.readBuildLog(derived, module: "Kern")
        let main = try #require(SwiftPMBuild.compileCommand(in: log, module: "Kern"))
        let other = #expect(throws: ScanUsageError.self) {
            try SwiftPMBuild.localDependency(
                "Base", log: log, scratch: derived, otherLogs: SwiftPMBuild.ActivityLogs(folder: derived), compatibleWith: main)
        }
        #expect(other?.description.contains("Clean.xcactivitylog") == true && other?.description.contains("-target") == true)
        // A single log file has no other logs to look in.
        let single = derived + "/Logs/Build/Incremental.xcactivitylog"
        let none = #expect(throws: ScanUsageError.self) {
            try SwiftPMBuild.localDependency(
                "Base", log: log, scratch: derived, otherLogs: SwiftPMBuild.ActivityLogs(folder: single), compatibleWith: main)
        }
        #expect(none?.description.contains("no compile command for Base in this build log") == true, "\(none?.description ?? "")")
    }

    /// A DerivedData folder: its newest activity log that compiled the module.
    @Test func aDerivedDataFolderIsSearchedForTheModule() throws {
        let derived = NSTemporaryDirectory() + "sfv-k6-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: derived) }
        try FileManager.default.createDirectory(atPath: derived + "/Logs/Build", withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: Self.fixtures.appendingPathComponent("xcode-Pkg.xcactivitylog").path, toPath: derived + "/Logs/Build/A.xcactivitylog")
        let log = try SwiftPMBuild.readBuildLog(derived, module: "Kern")
        #expect(SwiftPMBuild.compileCommand(in: log, module: "Kern")?.contains("-DKERN_FLAG") == true)
    }
}
