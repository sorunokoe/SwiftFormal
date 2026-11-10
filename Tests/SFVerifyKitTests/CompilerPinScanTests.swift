import Foundation
import SFSIL
import SFVerifyKit
import Testing

/// Plan item K2: Scan names the compiler it ran, checks it against the pin, and the build gate fails closed on an
/// unpinned compiler while `sfverify` and `swiftformal check` warn and stamp the report.
@Suite struct CompilerPinScanTests {
    private static let pinned = CompilerToolchain(
        swiftcVersion: SILFrontendVersion.verifiedCompilers[0] + "\nTarget: arm64-apple-macosx26.0", sdkVersion: "26.0")
    private static let other = CompilerToolchain(
        swiftcVersion: "Apple Swift version 6.5 (swiftlang-6.5.0.1.1 clang-2200.0.1.1)\nTarget: arm64-apple-macosx26.0", sdkVersion: "26.0")
    /// A pin that no installed compiler matches.
    private static let impossiblePin = CompilerPin(acceptedVersions: ["Apple Swift version 0.0 (swiftlang-0.0.0.0.0 clang-0.0.0.0.0)"])

    @Test func aPinnedCompilerPassesAndAnyOtherIsRefusedByTheGateAndWarnedAboutElsewhere() {
        let good = ScanToolchain(swiftc: "/usr/bin/swiftc", toolchain: Self.pinned)
        #expect(good.isPinned())
        #expect(good.gateRefusal() == nil)
        #expect(good.warning() == nil)
        let bad = ScanToolchain(swiftc: "/opt/swift/bin/swiftc", toolchain: Self.other)
        #expect(!bad.isPinned())
        let refusal = bad.gateRefusal()
        #expect(refusal?.contains("Apple Swift version 6.5") == true)
        #expect(refusal?.contains("fails closed") == true)
        #expect(bad.warning()?.contains("not covered by docs/TRUST.md") == true)
    }

    @Test func theCompilerNextToABuildToolIsFoundAndARelativeToolIsIgnored() throws {
        let swiftc = try ScanToolchain.resolve().swiftc
        let directory = (swiftc as NSString).deletingLastPathComponent
        #expect(ScanToolchain.swiftc(fromBuildTool: directory + "/swift-frontend") == swiftc)
        #expect(ScanToolchain.swiftc(fromBuildTool: "swiftc") == nil)
    }

    @Test func theGateFailsClosedOnAnUnpinnedCompiler() throws {
        let directory = NSTemporaryDirectory() + "sfv-pin-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/gated.swift"
        try "import SwiftFormal\n@Verify\npublic func id(_ x: Int8) -> Int8 { x }\n".write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.pin = Self.impossiblePin
        let compile = CompileOptions(files: [file], moduleName: "Gated", extraArguments: try VerifyMacroScanTests.macroArguments())
        let result = SFVerify.gate(compile, options)
        #expect(!result.passed)
        #expect(result.proved == 0)
        #expect(result.diagnostics.contains { $0.contains("fails closed") })
    }

    @Test func aScanNamesItsCompilerAndStampsAnUnpinnedOne() throws {
        // On a machine without the pinned compiler the first half cannot hold; the second half is the point.
        let installedIsPinned = try ScanToolchain.resolve().isPinned()
        let directory = NSTemporaryDirectory() + "sfv-pin-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/plain.swift"
        try "public func id(_ x: Int8) -> Int8 { x }\n".write(toFile: file, atomically: true, encoding: .utf8)
        let compile = CompileOptions(files: [file], moduleName: "Plain")
        let pinned = try SFVerify.run(compile)
        #expect(pinned.pinned == installedIsPinned)
        #expect(pinned.compiler == (try ScanToolchain.resolve().versionLine))
        var options = VerifyOptions()
        options.pin = Self.impossiblePin
        let unpinned = try SFVerify.run(compile, options)
        #expect(unpinned.pinned == false)
        #expect(unpinned.text().contains("warning: unpinned compiler"))
        #expect(unpinned.functions.first?.status == .safe, "an unpinned compiler is reported, not refused, outside the gate")
    }
}
