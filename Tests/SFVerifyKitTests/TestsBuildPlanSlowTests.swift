import Foundation
import SFVerifyKit
import Testing

/// `swiftformal check` builds the package once with its tests, and `swiftformal check --gate` once without, then plan each
/// target from that build's log.
@Suite struct TestsBuildPlanSlowTests {
    @Test func aTargetIsPlannedFromTheTestsBuildEvenAfterAnotherKindOfBuild() throws {
        let root = NSTemporaryDirectory() + "sfv-tests-build-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        for directory in ["/Sources/Lib", "/Tests/LibTests"] {
            try FileManager.default.createDirectory(atPath: root + directory, withIntermediateDirectories: true)
        }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Lib", platforms: [.macOS(.v13)],
            targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])])
        """.write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
        try "public func half(_ x: Int8) -> Int8 { x / 2 }\n"
            .write(toFile: root + "/Sources/Lib/Lib.swift", atomically: true, encoding: .utf8)
        try "import Testing\nimport Lib\n@Test func halves() { #expect(half(4) == 2) }\n"
            .write(toFile: root + "/Tests/LibTests/LibTests.swift", atomically: true, encoding: .utf8)

        // Cold: the build compiles Lib, so its log has the command.
        let log = try #require(try SwiftPMBuild.buildIncludingTests(root: root))
        let cold = try #require(try SwiftPMBuild.plan(fromTestsBuild: log, root: root, target: "Lib"))
        #expect(cold.plan.files.map { ($0 as NSString).lastPathComponent } == ["Lib.swift"])
        // A scan's own build of the target changes the build description; the next tests build compiles nothing.
        _ = try SwiftPMBuild.plan(root: root, target: "Lib")
        let nullLog = try #require(try SwiftPMBuild.buildIncludingTests(root: root))
        let again = try #require(try SwiftPMBuild.plan(fromTestsBuild: nullLog, root: root, target: "Lib"))
        #expect(again.plan.files == cold.plan.files && again.plan.arguments == cold.plan.arguments)
        // Then it is saved for the tests build's description: a null build finds it without building again.
        let steady = try #require(try SwiftPMBuild.buildIncludingTests(root: root))
        let found = try #require(try SwiftPMBuild.plan(fromTestsBuild: steady, root: root, target: "Lib"))
        #expect(found.plan.usedCachedArguments && found.log == steady)
        #expect(found.plan.arguments == cold.plan.arguments)
    }

    @Test func severalTargetsArePlannedFromOnePackageBuild() throws {
        let root = NSTemporaryDirectory() + "sfv-package-build-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        for target in ["A", "B"] {
            try FileManager.default.createDirectory(atPath: root + "/Sources/\(target)", withIntermediateDirectories: true)
            try "public func f\(target)(_ x: Int8) -> Int8 { x / 2 }\n"
                .write(toFile: root + "/Sources/\(target)/\(target).swift", atomically: true, encoding: .utf8)
        }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "AB", platforms: [.macOS(.v13)], targets: [.target(name: "A"), .target(name: "B", dependencies: ["A"])])
        """.write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
        #expect(!SwiftPMBuild.hasBuiltBefore(root: root))
        let log = try #require(try SwiftPMBuild.buildPackage(root: root))
        #expect(SwiftPMBuild.hasBuiltBefore(root: root))
        let a = try #require(try SwiftPMBuild.plan(fromPackageBuild: log, root: root, target: "A"))
        let b = try #require(try SwiftPMBuild.plan(fromPackageBuild: a.log, root: root, target: "B"))
        #expect(a.plan.module == "A" && b.plan.module == "B")
        // A null build of the package finds both commands saved for its build description.
        let null = try #require(try SwiftPMBuild.buildPackage(root: root))
        for target in ["A", "B"] {
            let found = try #require(try SwiftPMBuild.plan(fromPackageBuild: null, root: root, target: target))
            #expect(found.plan.usedCachedArguments && found.log == null, "\(target)")
        }
    }

    /// A target's dependencies are linked with the commands of the target's own build: no `swift build` of each one,
    /// even after a build of the dependency alone saved its command for another build description.
    @Test func aLocalDependencyIsPlannedFromTheTargetsBuildWithoutABuildOfItsOwn() throws {
        let root = NSTemporaryDirectory() + "sfv-dependency-plan-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        for target in ["A", "B", "C"] {
            try FileManager.default.createDirectory(atPath: root + "/Sources/\(target)", withIntermediateDirectories: true)
            try "public func f\(target)(_ x: Int8) -> Int8 { x / 2 }\n"
                .write(toFile: root + "/Sources/\(target)/\(target).swift", atomically: true, encoding: .utf8)
        }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "ABC", platforms: [.macOS(.v13)],
            targets: [
                .target(name: "A", swiftSettings: [.define("A_FLAG")]), .target(name: "B", dependencies: ["A"]),
                .target(name: "C", dependencies: ["B"]),
            ])
        """.write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
        // What planning each dependency with a build of its own gives (and saves, for those builds' descriptions).
        let alone = try ["A", "B"].map { try SwiftPMBuild.plan(root: root, target: $0) }
        _ = try SwiftPMBuild.plan(root: root, target: "C")
        let scratch = root + "/.build"
        let description = try #require(SwiftPMBuild.buildDescription(in: scratch))
        for plan in alone {
            let linked = try #require(try SwiftPMBuild.localDependency(plan.module, root: root))
            #expect(linked.files == plan.files && linked.extraArguments == plan.arguments, "\(plan.module)")
            #expect(SwiftPMBuild.buildDescription(in: scratch) == description, "\(plan.module) was built again")
        }
    }
}
