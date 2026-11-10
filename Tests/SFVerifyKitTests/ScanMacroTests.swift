import Foundation
import SFVerifyKit
import Testing

/// Plan item K4: macros that ship with the toolchain or the SDK compile without `--build`, including Swift Testing's.
@Suite struct ScanMacroTests {
    @Test func aLooseFileWithSwiftTestingCompilesAndIsScanned() throws {
        let directory = NSTemporaryDirectory() + "sfv-k4-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/halving.swift"
        try """
        import Testing
        public func half(_ x: Int8) -> Int8 { x / 2 }
        @Test func halving() { #expect(half(4) == 2) }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Halving"), options)
        #expect(report.functions.first { $0.name.hasPrefix("half(") }?.status == .safe)
    }

    /// Plan item U6: code from a macro expansion is never counted as written by hand. Accessors a macro writes for a
    /// declared property (`count` under `@Observable`) are listed with their origin; the members, peers and extensions
    /// it adds are compiler-generated (`summary.compilerGenerated`).
    @Test func macroExpansionsAreNotCountedAsHandWritten() throws {
        let directory = NSTemporaryDirectory() + "sfv-u6-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/model.swift"
        try """
        import Observation
        @Observable public final class Model { public var count: Int = 0 }
        public func twice(_ x: Int8) -> Int8 { x &* 2 }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Models"), options)
        let generated = report.functions.filter { $0.origin == "macro" }
        #expect(generated.count >= 3, "the @Observable expansion: \(report.functions.map(\.name))")
        #expect(report.summary.compilerGenerated > 0)
        #expect(report.summary.generatedCode == generated.count)
        #expect(report.summary.total == report.functions.count - generated.count)
        #expect(report.functions.first { $0.name.hasPrefix("twice(") }?.origin == nil)
    }

    /// Hand-written code in a package that sits inside some `.build` folder (a dependency checkout, a clean clone under
    /// `.build/`) is not build-generated: its broken contract must still fail the run.
    @Test func sourcesUnderABuildFolderAreStillHandWritten() throws {
        let root = NSTemporaryDirectory() + "sfv-origin-\(UUID().uuidString)"
        let directory = root + "/.build/checkouts/Dependency/Sources/Dependency"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = directory + "/bump.swift"
        try """
        public func bump(_ x: UInt8) -> UInt8 { x &+ 1 }
        #sourceLocation(file: "@__swiftmacro_10Dependency4bump6VerifyfMp_.swift", line: 1)
        public func bump_ensures(_ x: UInt8, _ r: UInt8) -> Bool { r > x }
        #sourceLocation()
        """.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Dependency"), options)
        let bump = try #require(report.functions.first { $0.name.hasPrefix("bump(") })
        #expect(bump.origin == nil)
        #expect(bump.status == .contractFails)
        #expect(report.summary.contractFails == 1)
        #expect(report.hasFailures)
    }

    @Test func aBuildToolPluginsOutputIsBuildGenerated() throws {
        let root = NSTemporaryDirectory() + "sfv-origin-\(UUID().uuidString)"
        let directory = root + "/.build/plugins/outputs/app/App/destination/Generator"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = directory + "/generated.swift"
        try "public func generated(_ x: Int8) -> Int8 { x &* 2 }".write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "App"), options)
        #expect(report.functions.first { $0.name.hasPrefix("generated(") }?.origin == "build")
    }
}
