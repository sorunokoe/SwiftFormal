import Foundation
import SFSIL
import Testing

@testable import SFVerifyKit

/// Plan item K10: one `swiftc -print-target-info` gives the version (for the pin), the triple and the resource
/// directory; the compiler is found without `xcrun` where there is none; `TOOLCHAINS` that names nothing is reported;
/// `--package` without `--build` compiles for the package's deployment target, not the host's.
@Suite struct ToolchainLocatorTests {
    /// The output of `swiftc -print-target-info` of Apple Swift 6.4, shortened.
    private static let targetInfo = """
        {
          "compilerVersion": "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)",
          "swiftCompilerTag": "swiftlang-6.4.0.34.1",
          "target": {
            "triple": "arm64-apple-macosx27.0.0",
            "unversionedTriple": "arm64-apple-macosx",
            "moduleTriple": "arm64-apple-macos",
            "platform": "macosx",
            "arch": "arm64"
          },
          "paths": {
            "runtimeResourcePath": "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
          }
        }
        """

    @Test func targetInfoGivesTheVersionLineTheTripleAndTheResourceDirectory() throws {
        let info = try ScanToolchain.TargetInfo(json: Data(Self.targetInfo.utf8))
        #expect(info.compilerVersion == SILFrontendVersion.verifiedCompilers[0])
        #expect(info.triple == "arm64-apple-macosx27.0.0")
        #expect(info.unversionedTriple == "arm64-apple-macosx")
        #expect(info.platform == "macosx")
        #expect(info.resourceDirectory?.hasSuffix("/usr/lib/swift") == true)
        // The same first line as `swiftc -version`, so the pin compares what it compared before.
        #expect(CompilerToolchain(swiftcVersion: info.versionOutput, sdkVersion: "").versionLine == SILFrontendVersion.verifiedCompilers[0])
        #expect(throws: (any Error).self) { try ScanToolchain.TargetInfo(json: Data("{}".utf8)) }
    }

    @Test func swiftExecWinsThenXcrunThenThePath() throws {
        let found = ScanToolchain.Locator(
            environment: ["SWIFT_EXEC": "/opt/swift/usr/bin/swiftc", "PATH": "/usr/bin"], hasXcrun: true,
            isExecutable: { $0 == "/opt/swift/usr/bin/swiftc" || $0 == "/usr/bin/swiftc" }, xcrunFind: { "/xcode/usr/bin/swiftc" })
        #expect(try found.swiftc() == .init(path: "/opt/swift/usr/bin/swiftc", origin: "SWIFT_EXEC"))

        let xcrun = ScanToolchain.Locator(
            environment: ["DEVELOPER_DIR": "/Library/Developer/CommandLineTools", "PATH": "/usr/bin"], hasXcrun: true,
            isExecutable: { _ in true }, xcrunFind: { "/Library/Developer/CommandLineTools/usr/bin/swiftc" })
        let clt = "/Library/Developer/CommandLineTools"
        #expect(try xcrun.swiftc() == .init(path: clt + "/usr/bin/swiftc", origin: "xcrun (DEVELOPER_DIR=\(clt))"))

        // Linux: no xcrun, so the first `swiftc` on PATH.
        let linux = ScanToolchain.Locator(
            environment: ["PATH": "/usr/local/bin:/opt/swift/usr/bin:/usr/bin"], hasXcrun: false,
            isExecutable: { $0 == "/opt/swift/usr/bin/swiftc" || $0 == "/usr/bin/swiftc" },
            xcrunFind: {
                Issue.record("no xcrun")
                return ""
            })
        #expect(try linux.swiftc() == .init(path: "/opt/swift/usr/bin/swiftc", origin: "PATH"))

        let nothing = ScanToolchain.Locator(
            environment: ["PATH": "/usr/bin"], hasXcrun: false, isExecutable: { _ in false }, xcrunFind: { "" })
        #expect(throws: (any Error).self) { try nothing.swiftc() }
    }

    @Test func toolchainsThatNamesNoInstalledToolchainIsReported() {
        let xcode = ScanToolchain.ToolchainIdentity(
            directory: "/X/XcodeDefault.xctoolchain", names: ["com.apple.dt.toolchain.XcodeDefault"])
        #expect(ScanToolchain.toolchainsNote(requested: nil, picked: xcode) == nil)
        #expect(ScanToolchain.toolchainsNote(requested: "com.apple.dt.toolchain.XcodeDefault", picked: xcode) == nil)
        let note = ScanToolchain.toolchainsNote(requested: "nonexistent", picked: xcode)
        #expect(note?.contains("TOOLCHAINS=nonexistent") == true)
        #expect(note?.contains("/X/XcodeDefault.xctoolchain") == true)
        let swiftOrg = ScanToolchain.ToolchainIdentity(directory: "/T/swift-6.4.xctoolchain", names: ["org.swift.64", "swift"])
        #expect(ScanToolchain.toolchainsNote(requested: "Swift", picked: swiftOrg) == nil, "aliases match, ignoring case")
    }

    @Test func theInstalledCompilerIsDescribedByOneProbe() throws {
        let found = try ScanToolchain.resolve()
        #expect(!found.triple.isEmpty)
        #expect(found.resourceDirectory.map { FileManager.default.fileExists(atPath: $0) } == true)
        #expect(found.versionLine.contains("Swift version"))
        #expect(!found.origin.isEmpty)
    }

    @Test func thePackagesDeploymentTargetReplacesTheHosts() {
        let dump = #"{"platforms": [{"platformName": "ios", "version": "16.0"}, {"platformName": "macos", "version": "13.0"}]}"#
        #expect(
            SFVerify.deploymentTarget(dumpPackage: Data(dump.utf8), unversionedTriple: "arm64-apple-macosx", platform: "macosx")
                == "arm64-apple-macosx13.0")
        // No macOS entry, or not a platform the manifest can name: the host's default stays.
        let iOSOnly = #"{"platforms": [{"platformName": "ios", "version": "16.0"}]}"#
        let mac = "arm64-apple-macosx"
        #expect(SFVerify.deploymentTarget(dumpPackage: Data(iOSOnly.utf8), unversionedTriple: mac, platform: "macosx") == nil)
        let linux = "x86_64-unknown-linux-gnu"
        #expect(SFVerify.deploymentTarget(dumpPackage: Data(dump.utf8), unversionedTriple: linux, platform: "linux") == nil)
    }

    @Test func aLooseScanOfAPackageCompilesForItsDeploymentTarget() throws {
        let root = NSTemporaryDirectory() + "sfv-target-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/Sources/T", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "T", platforms: [.macOS(.v13)], targets: [.target(name: "T")])
        """.write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
        let arguments = SFVerify.packageTargetArguments(root: root, extra: [])
        #expect(arguments.first == "-target" && arguments.last?.hasSuffix("-apple-macosx13.0") == true, "\(arguments)")
        #expect(arguments.count == 2)
        let given = SFVerify.packageTargetArguments(root: root, extra: ["-target", "arm64-apple-macosx14.0"])
        #expect(given.isEmpty, "the user's -target wins")
    }
}

@Suite struct DoctorCompilerChoiceTests {
    @Test func doctorSaysWhichCompilerItFoundAndHow() {
        var facts = DoctorFacts()
        facts.compiler = SILFrontendVersion.verifiedCompilers[0]
        facts.pinned = true
        facts.acceptedVersions = SILFrontendVersion.verifiedCompilers
        facts.compilerChoice = [
            "at /X/usr/bin/swiftc (xcrun (TOOLCHAINS=nope))", "TOOLCHAINS=nope names no installed toolchain; xcrun used /X",
        ]
        let message = Doctor.checks(facts).first { $0.name == "compiler" }?.message ?? ""
        #expect(message.contains("at /X/usr/bin/swiftc (xcrun (TOOLCHAINS=nope))"))
        #expect(message.contains("names no installed toolchain"))
    }
}
