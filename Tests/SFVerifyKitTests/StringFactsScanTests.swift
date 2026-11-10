import Foundation
import SFVerifyKit
import Testing

/// String facts end to end (`SILStringFacts.swift`), on the shapes of a production iOS app's rules (app study
/// round 6): a `switch` over a lowercased optional string, an integer printed as text, and
/// a `String` raw-value enum.
@Suite struct StringFactsScanTests {
    static let source = """
        public enum DeepLinkHost: Equatable { case app, api, portal }
        public struct DeepLinkTypeRule {
            public var input: String?
            public var body: DeepLinkHost? {
                switch input?.lowercased() {
                case "home":
                    .app
                case "api.example.org", "api.example.net", "api-staging.example.net":
                    .api
                case "portal.example.net":
                    .portal
                default:
                    nil
                }
            }
        }
        extension DeepLinkTypeRule {
            #sourceLocation(file: "@__swiftmacro_3App4body6VerifyfMp_.swift", line: 1)
            public func body_ensures(_ result: DeepLinkHost?) -> Bool {
                (input != nil || result == nil) && (input != "home" || result == .app)
            }
            #sourceLocation()
        }

        public struct ProgressInput {
            public let finishedAllSteps: Bool
            public let numberOfStepsDone: Int
        }
        public struct HeaderProgressRule {
            public let input: ProgressInput
            public var body: String { input.finishedAllSteps ? "F" : "\\(input.numberOfStepsDone)" }
        }
        extension HeaderProgressRule {
            #sourceLocation(file: "@__swiftmacro_3App4body6VerifyfMp_.swift", line: 1)
            public func body_ensures(_ result: String) -> Bool { !input.finishedAllSteps || result == "F" }
            #sourceLocation()
        }
        public struct PlantedProgressRule {
            public let input: ProgressInput
            public var body: String { input.numberOfStepsDone >= 18 ? "F" : "\\(input.numberOfStepsDone)" }
        }
        extension PlantedProgressRule {
            #sourceLocation(file: "@__swiftmacro_3App4body6VerifyfMp_.swift", line: 1)
            public func body_ensures(_ result: String) -> Bool { !input.finishedAllSteps || result == "F" }
            #sourceLocation()
        }

        public enum Tool: String { case hammer, saw, wrench = "Wrench" }
        public func tool(_ text: String) -> Tool? { Tool(rawValue: text) }
        public func grip(_ text: String, _ x: Int8) -> Int8 { if case .wrench? = Tool(rawValue: text) { return x + 1 }; return x }
        public func number(_ n: Int) -> String { String(n) }
        #sourceLocation(file: "@__swiftmacro_3App6number6VerifyfMp_.swift", line: 1)
        public func number_ensures(_ n: Int, _ r: String) -> Bool { r != "007" && r != "-0" && (n != 18 || r == "18") }
        #sourceLocation()
        """

    static func run(_ source: String = source) throws -> ScanReport {
        let dir = NSTemporaryDirectory() + "sfv-strings-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/rules.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Rules"), VerifyOptions())
    }

    @Test func appRuleShapesGetVerdicts() throws {
        let report = try Self.run()
        func fn(_ prefix: String) throws -> FunctionReport { try #require(report.functions.first { $0.name.hasPrefix(prefix) }) }

        let deepLink = try fn("DeepLinkTypeRule.body")
        #expect(deepLink.status == .contractHolds, "\(deepLink.detail ?? "")")
        let progress = try fn("HeaderProgressRule.body")
        #expect(progress.status == .contractHolds, "\(progress.detail ?? "")")

        // The planted bug: a user who finished all steps but fewer than 18 gets a number, not "F".
        let planted = try fn("PlantedProgressRule.body")
        #expect(planted.status == .contractFails, "\(planted.detail ?? "")")
        let inputs = planted.counterexample?.inputs.joined(separator: ", ") ?? ""
        #expect(inputs.contains("finishedAllSteps: true"), "\(inputs)")
        let steps = inputs.range(of: "numberOfStepsDone: ").flatMap { Int(inputs[$0.upperBound...].prefix { $0 == "-" || $0.isNumber }) }
        #expect(steps.map { $0 < 18 } == true, "\(inputs)")

        #expect(try fn("tool(").status == .safe)
        let grip = try fn("grip(")
        #expect(grip.status == .mayTrap)
        #expect(grip.counterexample?.inputs == [#"text = "Wrench""#, "x = 127"])
        #expect(try fn("number(").status == .contractHolds)
    }
}
