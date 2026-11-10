import Foundation
@testable import SFGenKit
import SFTestSupport
import Testing

// The generator reads sources with swift-syntax, which only the `Generator` trait (on by default) builds.
#if Generator && (os(macOS) || os(Linux))

    /// The file `sfgen` writes is test code in the app's package, which sees only SwiftFormal's public API. It must
    /// compile there: generated, put in a package that depends on SwiftFormal as an app does, and built.
    @Suite struct GeneratedTestsSlowTests {
        private static let app = """
            protocol Rule {
                associatedtype Output
                func execute() -> Output
            }

            enum Mode { case fast, slow(level: Int) }

            struct Input {
                let mode: Mode
                let name: String?
            }

            struct ThresholdRule: Rule {
                let input: Input
                func execute() -> String { input.name == "gold" ? "vip" : "x" }
            }

            final class Badge {
                let level: Int
                init(level: Int) { self.level = level }
            }

            struct BadgeRule: Rule {
                let input: Bool
                func execute() -> Badge { Badge(level: input ? 42 : 0) }
            }

            """

        @Test func theGeneratedFileCompilesInTheAppsPackage() throws {
            let index = TypeIndex()
            let indexer = SourceIndexer(index: index)
            indexer.indexSource(Self.app, path: "Rules.swift")
            let result = RuleGenerator.generate(
                rules: indexer.rules, index: index, options: GenerationOptions(imports: [], testableImports: ["App"]))
            #expect(result.generated == ["ThresholdRule", "BadgeRule"], "\(result.skipped)")
            #expect(result.source.contains("Prove(") && !result.source.contains("expectProved"))

            let swiftFormal = ".product(name: \"SwiftFormal\", package: \"SwiftFormal\")"
            let testing = ".product(name: \"SwiftFormalTesting\", package: \"SwiftFormal\")"
            let package = try FixturePackage(
                name: "sfgen-output",
                targets: """
                        .target(name: "App"),
                        .target(name: "Generated", dependencies: ["App", \(swiftFormal), \(testing)]),
                    """,
                files: ["Sources/App/Rules.swift": Self.app, "Sources/Generated/Generated.swift": result.source])
            let build = try package.build(target: "Generated")
            #expect(build.status == 0, "\(build.output.suffix(4000))")
        }
    }
#endif
