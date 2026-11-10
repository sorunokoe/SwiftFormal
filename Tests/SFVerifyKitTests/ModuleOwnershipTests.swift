import Foundation
import SFSIL
import Testing

@testable import SFVerifyKit

/// Which functions of the compiler's output belong to the scanned module. The Swift mangler shortens a module name
/// whose words already appeared in the symbol (`AppStepByStep` -> `09AppStepByB0`, `AppSettings`
/// after `AppCore` -> `0A8Settings`), so a plain `$s<length><module>` prefix test drops real functions.
/// Found on a real app (app study round 5).
@Suite struct ModuleOwnershipTests {
    private static func temporaryDirectory() throws -> String {
        let dir = NSTemporaryDirectory() + "sfv-own-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ text: String, _ path: String) throws -> String {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func names(_ report: ScanReport) -> [String] { report.functions.map(\.name) }

    @Test func aModuleWhoseNameRepeatsAWordKeepsItsFunctions() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = try Self.write("public func half(_ x: Int) -> Int { x / 2 }\n", dir + "/k.swift")
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "AppStepByStep"))
        let half = try #require(report.functions.first { $0.name == "half(_:)" }, "functions: \(Self.names(report))")
        #expect(half.status == .safe)
        #expect(report.warnings == nil)
    }

    @Test func extensionsOfAnotherModulesTypesAreReported() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let core = try Self.write(
            """
            public enum TemperatureUnitType { case celsius, fahrenheit }
            public enum LoadingState<Value> { case loading, loaded(Value) }
            """, dir + "/core.swift")
        let built = try Spawn.run(
            "/usr/bin/xcrun",
            [
                "swiftc", "-parse-as-library", "-emit-module", "-module-name", "AppCore", core,
                "-emit-module-path", dir + "/AppCore.swiftmodule",
            ])
        try #require(built.status == 0, "\(built.errorText)")
        let settings = try Self.write(
            """
            import AppCore
            public struct Details { public var id: Int }
            extension TemperatureUnitType {
                public var code: Int {
                    switch self {
                    case .celsius: 1
                    case .fahrenheit: 2
                    }
                }
            }
            extension LoadingState<Details> {
                public var isLoading: Bool {
                    if case .loading = self { return true }
                    return false
                }
            }
            extension LoadingState {
                public static func placeholderCount() -> Int { 3 }
            }
            public func plain(_ x: Int) -> Int { x }
            """, dir + "/settings.swift")
        let report = try SFVerify.run(
            CompileOptions(files: [settings], moduleName: "AppSettings", extraArguments: ["-I", dir]))
        let names = Self.names(report)
        for expected in ["code.getter", "isLoading.getter", "placeholderCount()", "plain(_:)"] {
            #expect(names.contains { $0.contains(expected) }, "\(expected) missing from \(names)")
        }
        #expect(report.warnings == nil)
    }

    /// A function of another module that the demangler names is never reported, even when it has a name comment.
    @Test func foreignFunctionsStayOut() {
        let text = """
            // foo()
            sil @$s7Foreign3fooyyF : $@convention(thin) () -> () {
            bb0:
              %0 = tuple ()
              return %0 : $()
            }

            // bar()
            sil @$s4Mine3baryyF : $@convention(thin) () -> () {
            bb0:
              %0 = tuple ()
              return %0 : $()
            }

            // Shared.baz()
            sil @$s6Shared3BazV0A4MineE3bazyyF : $@convention(method) (Baz) -> () {
            bb0(%0 : $Baz):
              %1 = tuple ()
              return %1 : $()
            }
            """
        let demangled = [
            "$s7Foreign3fooyyF": "Foreign.foo() -> ()",
            "$s6Shared3BazV0A4MineE3bazyyF": "(extension in Mine):Shared.Baz.baz() -> ()",
        ]
        let prepared = SILText.prepare(
            text, module: "Mine",
            demangle: { symbols in
                Dictionary(uniqueKeysWithValues: symbols.compactMap { s in demangled[s].map { (s, $0) } })
            })
        #expect(prepared.functions.map(\.symbol).sorted() == ["$s4Mine3baryyF", "$s6Shared3BazV0A4MineE3bazyyF"])
        #expect(prepared.warnings.isEmpty)
    }

    /// Without a demangler, the functions the prefix finds are kept and the report says some may be missing.
    @Test func withoutTheDemanglerItWarnsInsteadOfStayingSilent() {
        let text = """
            // half(_:)
            sil @$s09AppStepByB04halfyS2iF : $@convention(thin) (Int) -> Int {
            bb0(%0 : $Int):
              return %0 : $Int
            }
            """
        let prepared = SILText.prepare(text, module: "AppStepByStep", demangle: { _ in nil })
        #expect(prepared.functions.isEmpty)
        #expect(prepared.warnings.contains { $0.contains("swift-demangle") })
        #expect(prepared.warnings.contains { $0.contains("no function of module AppStepByStep") })
    }

    @Test func demangledNamesDecideTheModule() {
        #expect(SILText.belongs("AppStepByStep.half(Swift.Int) -> Swift.Int", to: "AppStepByStep"))
        #expect(SILText.belongs("static (extension in AppSettings):AppCore.Foo.bar() -> Swift.Int", to: "AppSettings"))
        #expect(SILText.belongs("(extension in M):Swift.Int.f() -> ()", to: "M"))
        #expect(!SILText.belongs("AppCore.Foo.bar() -> ()", to: "AppCoreTesting"))
        #expect(!SILText.belongs("AppCoreTesting.f() -> ()", to: "AppCore"))
        #expect(!SILText.belongs("closure #1 in M.f() -> ()", to: "M"))
    }
}

/// Code a macro wrote is not counted as hand-written, except accessors, which stand for a property the user wrote.
@Suite struct MacroGeneratedFunctionTests {
    @Test func previewAndObservableHelpersAreCompilerGenerated() throws {
        let dir = NSTemporaryDirectory() + "sfv-macro-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/p.swift"
        try """
        import Observation
        import SwiftUI
        public func one() -> Int { 1 }
        @Observable final class Model { var count = 0 }
        #Preview { Text("x") }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Demo"))
        let names = report.functions.map(\.name)
        #expect(names.contains("one()"))
        #expect(names.contains("Model.count.getter"), "\(names)")
        #expect(!names.contains { $0.contains("$s") || $0.contains("PreviewRegistry") }, "\(names)")
        #expect(!names.contains { $0.contains("shouldNotifyObservers") || $0.contains("_count.") }, "\(names)")
        #expect(report.summary.compilerGenerated > 0)
        #expect(!report.summary.unsupportedByCategory.keys.contains { $0.contains("fM") }, "\(report.summary.unsupportedByCategory)")
    }

    @Test func loopsAndRangesAreNamedForWhatTheyAre() {
        let note = SILError.supportedTypesNote
        #expect(Verifier.category(of: .unsupported("type IndexingIterator<Range<Int>>\(note)")) == "for-in loops")
        #expect(Verifier.category(of: .unsupported("type Range<String.Index>\(note)")) == "ranges of non-integer bounds")
    }

    @Test func macroTypeNamesGetOneReadableCategory() {
        for name in ["$s4Demo5Model10ObservablefMm_6MemberfMu3_", "s4Demo5Model10ObservablefMm_6MemberfMu1_"] {
            let error = SILError.unsupported("type \(name)\(SILError.supportedTypesNote)")
            #expect(Verifier.category(of: error) == "macro-generated types")
        }
    }
}
