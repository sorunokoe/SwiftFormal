import Foundation
import Testing

@testable import SFVerifyKit

/// App study round 6: 12 of 18 walks were not run because their subjects name types of a target that was not given to
/// `--scan`, and the report did not say which `--scan` would link them. It now says so when a target of the packages
/// involved declares the type (found by reading the sources, no build), and gives a general hint otherwise.
@Suite struct CheckScanHintTests {
    private static func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// An umbrella package (its own target `App`) with a nested package whose target sets `path:`, and two targets
    /// that both declare `Shared`.
    private static func packages() throws -> String {
        let root = NSTemporaryDirectory() + "sfv-hints-\(UUID().uuidString)"
        try write(
            """
            // swift-tools-version: 6.1
            import PackageDescription
            let package = Package(name: "Umbrella", targets: [
                .target(name: "App"), .target(name: "Left"), .target(name: "Right"),
                .testTarget(name: "AppTests", dependencies: ["App"]),
            ])
            """, to: root + "/Package.swift")
        try write("public struct Screen { public func title() -> Int { 1 } }\n", to: root + "/Sources/App/Screen.swift")
        try write("public enum Shared { case a }\n", to: root + "/Sources/Left/Shared.swift")
        try write("public enum Shared { case b }\n", to: root + "/Sources/Right/Shared.swift")
        try write("struct CustomStore {}\n", to: root + "/Tests/AppTests/Fake.swift")
        try write(
            """
            // swift-tools-version: 6.1
            import PackageDescription
            let package = Package(name: "Core", targets: [
                .target(
                    name: "AppCore",
                    path: "Sources/Core"
                ),
                .testTarget(name: "AppCoreTests", dependencies: ["AppCore"], path: "Tests"),
            ])
            """, to: root + "/Foundation/Core/Package.swift")
        try write(
            "public struct CustomStore {\n    public func reduce() -> Int { 0 }\n}\n",
            to: root + "/Foundation/Core/Sources/Core/Conditions/Store.swift")
        try write(
            "public func clampHeight(_ x: Int) -> Int { x }\npublic let title = 1\n", to: root + "/Foundation/Core/Sources/Core/Clamp.swift"
        )
        try write(
            "extension Double {\n    public var withFormat: String { \"\" }\n}\n", to: root + "/Foundation/Core/Sources/Core/Format.swift")
        return root
    }

    private static func walk(_ subject: String) -> WalkCheck {
        WalkCheck(subject: subject, file: "/t/Walks.swift", line: 1, suite: nil, test: nil)
    }

    @Test func aTypeDeclaredInAnotherTargetNamesThatScan() throws {
        let root = try Self.packages()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let walks = [
            Self.walk("CustomStore.reduce: never negative"), Self.walk("CustomStore without overlay"),
            Self.walk("clampHeight(_:)"), Self.walk("Shared.label"), Self.walk("Mystery.member"),
            Self.walk("Double.withFormat: percent text"), Self.walk("Double.rounded"), Self.walk("title text, rounded first"),
        ]
        let hints = Check.scanHints(for: walks, packages: [root], scanned: [(root, "App")])
        #expect(
            hints.contains(
                "add --scan \(root)/Foundation/Core:AppCore to link 4 walks (it declares CustomStore, clampHeight, Double.withFormat)"
            ),
            "\(hints)")
        #expect(hints.contains("add one of --scan \(root):Left, --scan \(root):Right to link 1 walk (each declares Shared)"), "\(hints)")
        #expect(
            hints.contains {
                $0.hasPrefix(
                    "3 walks name no scanned function, and no other target under the given packages declares their types (Mystery, Double, title)"
                )
            },
            "\(hints)")
    }

    @Test func anAlreadyScannedTargetIsNotSuggested() throws {
        let root = try Self.packages()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let hints = Check.scanHints(
            for: [Self.walk("Screen.subtitle")], packages: [root], scanned: [(root, "App")])
        #expect(hints.count == 1)
        #expect(hints.first?.contains("declares its type (Screen): start the subject") == true, "\(hints)")
    }

    @Test func theTextAndJSONCarryTheHints() throws {
        var report = CheckReport(entries: [], unlinkedWalks: [Self.walk("Mystery.member")], ranWalks: 0, totalWalks: 1)
        #expect(!report.text().contains("hint:"))
        #expect(try !report.json().contains("scanHints"))
        report.scanHints = ["add --scan Pkg:Core to link 1 walk (it declares Mystery)"]
        #expect(report.text().contains("  hint: add --scan Pkg:Core to link 1 walk (it declares Mystery)"), "\(report.text())")
        #expect(try report.json().contains("\"scanHints\""))
    }
}
