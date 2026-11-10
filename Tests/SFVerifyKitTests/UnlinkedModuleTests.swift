import Foundation
import Testing

@testable import SFVerifyKit

/// App study round 6, bug B: an imported module of the same build that could not be linked was silent. Its types were then
/// "unsupported: type ValuesData" with the hint "Scan reads integers, Bool, and structs…", wrong advice for a
/// plain struct. The report now says which module and why, and the hint of a type declared there says so.
@Suite struct UnlinkedModuleTests {
    /// The start of a real reason (a production iOS app, iOS Simulator SDK, before the plugin fix), paths shortened.
    static let reason = """
        COMPILER FAILED: /work/MainApp/Sources/Banners/View/ConnectivityBannerView.swift:6:10: warning: Localization required!
         4 | import DesignTokens
         5 |
         6 | #warning("Localization required!")
           |          `- warning: Localization required!

        /work/Packages/Sources/AppCore/BannerModifier.swift:8:17: error: external macro implementation type \
        'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found
         6 |
         7 |     @State
           |                 `- error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
        """

    @Test func theWarningNamesTheModuleAndItsFirstError() {
        let warnings = UnlinkedModules.warnings(["AppCore": Self.reason, "Alpha": "no such module 'Alpha'"])
        #expect(warnings.count == 2)
        #expect(warnings[0].hasPrefix("module Alpha could not be linked"), "\(warnings)")
        #expect(warnings[0].hasSuffix(": no such module 'Alpha'"))
        #expect(warnings[1].hasPrefix("module AppCore could not be linked"))
        #expect(
            warnings[1].hasSuffix(
                ": /work/Packages/Sources/AppCore/BannerModifier.swift:8:17: error: external macro implementation type "
                    + "'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found"),
            "\(warnings[1])")
    }

    /// The reason keeps the first 8,000 characters of the compiler's output: many warnings can push the error out.
    /// A warning is then never given as the reason.
    @Test func aReasonWithoutItsErrorDoesNotBlameAWarning() {
        let warnings = (1...3).map { "/work/A.swift:\($0):10: warning: Localization required!\n 6 | #warning(\"x\")" }
        let groups = "[#ImplicitStrongCapture]: <https://docs.swift.org/compiler/documentation/diagnostics/implicit-strong-capture>"
        let line = UnlinkedModules.firstError(in: "COMPILER FAILED: " + warnings.joined(separator: "\n") + "\n\n" + groups)
        #expect(!line.contains("warning"), "\(line)")
        #expect(line.contains("past the part of the compiler output Scan keeps"), "\(line)")
    }

    @Test func aLongErrorLineIsShortened() {
        let line = UnlinkedModules.firstError(in: "COMPILER FAILED: a.swift:1:1: error: " + String(repeating: "x", count: 1000))
        #expect(line.count <= 301)
        #expect(line.hasPrefix("a.swift:1:1: error: x"))
    }

    @Test func declaredTypeNamesAreFoundInTheSources() {
        let names = UnlinkedModules.declaredTypes(
            in: """
                public struct ValuesData { var x: Int }
                @MainActor final class Store {}
                indirect enum Tree { case leaf }
                public typealias Wind = Int
                // struct Commented is harmless
                """)
        #expect(names.isSuperset(of: ["ValuesData", "Store", "Tree", "Wind"]))
        #expect(!names.contains("Int"))
    }

    @Test func aTypeOfAnUnlinkedModuleSaysSoInItsHint() throws {
        let directory = NSTemporaryDirectory() + "sfv-unlinked-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let dependency = directory + "/Dep.swift"
        try """
        public struct ValuesData {
            public var wind: Int8
            public init(wind: Int8) { self.wind = wind }
        }
        #if SF_BROKEN
        let broken: Int = "not a number"
        #endif
        """.write(toFile: dependency, atomically: true, encoding: .utf8)
        let built = try ModuleCompiler.run([
            "swiftc", "-emit-module", "-parse-as-library", "-module-name", "Dep", "-emit-module-path", directory + "/Dep.swiftmodule",
            dependency,
        ])
        try #require(built.status == 0, "\(built.errors)")
        let main = directory + "/Main.swift"
        try """
        import Dep
        public func gust(_ c: ValuesData) -> Int8 { c.wind }
        public func half(_ x: Int8) -> Int8 { x / 2 }
        """.write(toFile: main, atomically: true, encoding: .utf8)

        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(
            CompileOptions(files: [main], moduleName: "Main", extraArguments: ["-I", directory]), options,
            linking: { name in
                name == "Dep" ? CompileOptions(files: [dependency], moduleName: "Dep", extraArguments: ["-D", "SF_BROKEN"]) : nil
            })
        let warning = try #require(report.warnings?.first { $0.hasPrefix("module Dep could not be linked") }, "\(report.warnings ?? [])")
        #expect(warning.contains("Dep.swift:6:"), "\(warning)")
        #expect(warning.contains("error:"))
        let gust = try #require(report.functions.first { $0.name.hasPrefix("gust(") })
        #expect(gust.status == .unsupported)
        #expect(gust.category == "type ValuesData")
        #expect(gust.hint?.contains("Dep, which could not be linked") == true, "\(String(describing: gust.hint))")
        #expect(report.functions.first { $0.name.hasPrefix("half(") }?.status == .safe)
    }
}
