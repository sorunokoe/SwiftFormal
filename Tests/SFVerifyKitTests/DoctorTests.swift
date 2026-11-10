import Foundation
import SFVerifyKit
import Testing

/// Plan item U9: `swiftformal doctor` turns facts about the machine and the package into checks, each with a fix.
@Suite struct DoctorTests {
    static func healthy() -> DoctorFacts {
        var facts = DoctorFacts()
        facts.compiler = "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.0.123.102)"
        facts.pinned = true
        facts.acceptedVersions = ["swiftlang-6.4.0.34.1"]
        facts.swiftformalIsDebug = false
        facts.platform = "macOS"
        return facts
    }

    @Test func aHealthySetupPassesEveryCheck() {
        let checks = Doctor.checks(Self.healthy())
        #expect(!checks.isEmpty)
        #expect(checks.allSatisfy { $0.outcome == .ok }, "\(checks)")
        #expect(Doctor.exitCode(checks) == 0)
    }

    @Test func anUnpinnedCompilerAndADebugScanFailWithFixes() {
        var facts = Self.healthy()
        facts.pinned = false
        facts.compiler = "Apple Swift version 6.5 (swiftlang-6.5.0.1.1)"
        facts.swiftformalIsDebug = true
        let checks = Doctor.checks(facts)
        let compiler = checks.first { $0.name == "compiler" }
        #expect(compiler?.outcome == .failure)
        #expect(compiler?.fix?.contains("pin-upgrade") == true)
        let scan = checks.first { $0.name == "swiftformal" }
        #expect(scan?.outcome == .warning)
        #expect(scan?.fix?.contains("-c release") == true)
        #expect(Doctor.exitCode(checks) == 1)
        #expect(Doctor.render(checks).contains("fix: "))
    }

    @Test func exitTestsNeedSwift63AndAreNotOnIOS() {
        var facts = Self.healthy()
        facts.compiler = "Apple Swift version 6.2.1 (swiftlang-6.2.1.4.8)"
        #expect(Doctor.checks(facts).first { $0.name == "exit tests" }?.outcome == .warning)
        facts = Self.healthy()
        facts.platform = "iOS"
        #expect(Doctor.checks(facts).first { $0.name == "exit tests" }?.outcome == .warning)
        #expect(Doctor.swiftVersion("Apple Swift version 6.4 (swiftlang-6.4.0.34.1)") == [6, 4])
        #expect(Doctor.swiftVersion("Swift version 6.3-dev (LLVM abc)") == [6, 3])
    }

    /// A package with three targets that apply the gate plugin: one with a `// sf:verify` comment and a hand-written
    /// contract, one with `@Verify`, one that imports another target; and stamps an older gate copied into bundles.
    static func gatedPackage() throws -> String {
        let root = NSTemporaryDirectory() + "sfv-u9-\(UUID().uuidString)"
        for (path, text) in [
            (
                "Package.swift",
                """
                // swift-tools-version: 6.0
                import PackageDescription
                let package = Package(
                    name: "P",
                    dependencies: [.package(url: "https://example.com/SwiftFormal.git", from: "0.1.0")],
                    targets: [
                        .target(name: "Core", dependencies: [.product(name: "SFProve", package: "SwiftFormal")]),
                        .target(name: "Marked", plugins: [.plugin(name: "SwiftFormalGate", package: "SwiftFormal")]),
                        .target(name: "Verified", plugins: [.plugin(name: "SwiftFormalGate", package: "SwiftFormal")]),
                        .target(
                            name: "Empty",
                            dependencies: ["Core"],
                            plugins: [.plugin(name: "SwiftFormalGate", package: "SwiftFormal")]
                        ),
                        .testTarget(
                            name: "MarkedTests",
                            dependencies: ["Marked", .product(name: "SwiftFormalContracts", package: "SwiftFormal")]),
                    ]
                )
                """
            ),
            ("Sources/Core/Core.swift", "public func one() -> Int { 1 }\n"),
            (
                "Sources/Marked/M.swift",
                "// sf:verify\nfunc inc(_ x: Int8) -> Int8 { x &+ 1 }\nfunc inc_ensures(_ x: Int8, _ r: Int8) -> Bool { r > x }\n"
            ),
            (
                "Sources/Verified/V.swift",
                "import SwiftFormal\n@Verify\nfunc inc(_ x: Int8) -> Int8 {\n    #ensures { $0 != x }\n    return x &+ 1\n}\n"
            ),
            ("Sources/Empty/E.swift", "import Core\nfunc two() -> Int { one() + 1 }\n"),
            (".build/arm64-apple-macosx/debug/P_Marked.bundle/Marked.sfgate", "// stamp\n"),
            (".build/out/Products/Debug/P_Marked.bundle/Contents/Resources/Marked.sfgate", "// stamp\n"),
        ] {
            let file = root + "/" + path
            try FileManager.default.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func gateWiringIsReadFromThePackage() throws {
        let root = try Self.gatedPackage()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let package = try #require(Doctor.packageFacts(root: root))
        #expect(package.gated.map(\.name) == ["Marked", "Verified", "Empty"])
        #expect(package.gated.first?.markers == 1 && package.gated.first?.contracts == 1)
        #expect(package.gated[1].verifyFunctions == 1 && package.gated[1].markers == 0)
        #expect(package.gated.last?.markers == 0 && package.gated.last?.verifyFunctions == 0)
        #expect(package.gated.last?.importedTargets == ["Core"])
        #expect(package.removed.contains("SwiftFormalGate"))
        #expect(package.stampsInBundles.count == 2)  // native and swiftbuild layouts

    }

    @Test func gateChecksSayWhatThePluginCannotRead() throws {
        let root = try Self.gatedPackage()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var facts = Self.healthy()
        facts.package = try #require(Doctor.packageFacts(root: root))
        let checks = Doctor.checks(facts)
        // Only `@Verify`: a `// sf:verify` comment and a hand-written contract are not read.
        let marked = checks.filter { $0.name == "gate Marked" }
        #expect(
            marked.contains { $0.outcome == .failure && $0.message.contains("1 `// sf:verify` comment and 1 hand-written contract") },
            "\(marked)")
        #expect(marked.contains { $0.fix?.contains("@Verify, #requires and #ensures") == true }, "\(marked)")
        // The plugin was removed: each target that applies it says so, and how to gate instead.
        let verified = checks.filter { $0.name == "gate Verified" }
        #expect(verified.contains { $0.outcome == .failure && $0.message.contains("1 `@Verify` function to gate") }, "\(verified)")
        #expect(verified.contains { $0.fix?.contains("swiftformal check --gate") == true }, "\(verified)")
        let empty = checks.filter { $0.name == "gate Empty" }
        #expect(empty.contains { $0.outcome == .failure && $0.message.contains("no longer has") }, "\(empty)")
        #expect(checks.first { $0.name == "gate stamp" }?.outcome == .failure)
    }

    /// A manifest that still names a removed product or plugin is read as text (SwiftPM would refuse to resolve it), and
    /// each name gets what to use instead.
    @Test func removedProductsAndPluginsSayWhatToUseInstead() throws {
        let root = try Self.gatedPackage()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let package = try #require(Doctor.packageFacts(root: root))
        #expect(package.removed == ["SFProve", "SwiftFormalContracts", "SwiftFormalGate"])
        var facts = Self.healthy()
        facts.package = package
        let removed = Doctor.checks(facts).filter { $0.name == "package" }
        #expect(removed.count == 3 && removed.allSatisfy { $0.outcome == .failure }, "\(removed)")
        #expect(removed.contains { $0.fix?.contains("SwiftFormalTesting") == true && $0.message.contains("SFProve") })
        #expect(removed.contains { $0.fix?.contains("import SwiftFormal") == true && $0.message.contains("SwiftFormalContracts") })
        #expect(Doctor.removedNames(in: ".plugin(name: \"SwiftFormalScan\", package: \"SwiftFormal\")") == ["SwiftFormalScan"])
    }

    @Test func aPackageWithoutTheGateIsNotAProblem() throws {
        let root = NSTemporaryDirectory() + "sfv-u9-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "let package = Package(name: \"P\", targets: [.target(name: \"A\")])\n".write(
            toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
        var facts = Self.healthy()
        facts.package = Doctor.packageFacts(root: root)
        let gate = Doctor.checks(facts).first { $0.name == "package" }
        #expect(gate?.outcome == .ok)
        #expect(gate?.message.contains("swiftformal check --gate") == true)
        #expect(Doctor.packageFacts(root: root + "/missing") == nil)
    }
}
