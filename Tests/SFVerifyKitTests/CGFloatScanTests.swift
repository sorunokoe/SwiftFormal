import Foundation
import SFVerifyKit
import Testing

/// `CGFloat` through the whole pipeline: the package-type probe confirms that the bare name is CoreFoundation's
/// `CGFloat` and that it wraps a `Double` on this target, then it is read as that `Double` (`SILCGFloat.swift`).
@Suite struct CGFloatScanTests {
    static func run(_ source: String, module: String) throws -> ScanReport {
        let directory = NSTemporaryDirectory() + "sfv-cgfloat-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/sizes.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        return try SFVerify.run(CompileOptions(files: [file], moduleName: module), options)
    }

    @Test func aLayoutInCGFloatIsReadAndATrapShowsACGFloatLiteral() throws {
        let report = try Self.run(
            """
            import CoreGraphics
            public struct Size { public var width: CGFloat; public var height: CGFloat }
            public func isWide(_ s: Size) -> Bool { s.width > s.height }
            public func points(_ s: Size) -> Int { s.width > -1000 && s.width < 1000 ? Int(s.width) : 0 }
            public func columns(_ s: Size) -> Int { Int(s.width) }
            """, module: "Sizes")
        func function(_ name: String) -> FunctionReport? { report.functions.first { $0.name.hasPrefix(name) } }
        for name in ["isWide(", "points(", "Size.width.getter", "Size.height.setter"] {
            #expect(function(name)?.status == .safe, "\(name): \(function(name)?.detail ?? "missing")")
        }
        let columns = try #require(function("columns("))
        #expect(columns.status == .mayTrap, "\(columns.detail ?? "")")
        #expect(columns.counterexample?.inputs.first?.contains("width: CGFloat(") == true, "\(columns.counterexample?.inputs ?? [])")
    }

    @Test func aModulesOwnCGFloatIsNeverTakenForCoreFoundations() throws {
        // A module that declares `CGFloat` beside Foundation's: the bare name is ambiguous, so neither layout is used.
        let report = try Self.run(
            """
            import Foundation
            public struct CGFloat { public var native: Int8 }
            public func bump(_ x: CGFloat) -> Int8 { x.native + 1 }
            """, module: "OwnFloat")
        let bump = try #require(report.functions.first { $0.name.hasPrefix("bump(") })
        #expect(bump.status == .unsupported, "\(bump.detail ?? "")")
    }
}
