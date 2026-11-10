import Foundation
import SFVerifyKit
import Testing

/// Only `@Verify`, on what the real macro writes: a file that uses `@Verify` is compiled with the `SwiftFormal` module and
/// the `SwiftFormalMacros` plugin this package built (SwiftPM builds every product before it runs tests), so the peers
/// are the macro's own, placed where the compiler places them. They are read; a hand-written contract next to them is
/// not.
@Suite struct VerifyMacroScanTests {
    /// The built macro executable: `SwiftFormalMacros` (Swift Build), or `SwiftFormalMacros-tool` (SwiftPM's native build
    /// system), in the test bundle's folder, else in this package's newest build folder.
    static var macro: String? {
        let fm = FileManager.default
        let bundles = (Bundle.allBundles.map(\.bundlePath) + CommandLine.arguments).filter { $0.contains(".xctest") }
        var folders = bundles.map { (($0.components(separatedBy: ".xctest")[0] + ".xctest") as NSString).deletingLastPathComponent }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        folders += ["out/Products/Debug", "out/Products/Release", "debug", "release"].map { root + "/.build/" + $0 }
        let found = folders.flatMap { folder in ["SwiftFormalMacros", "SwiftFormalMacros-tool"].map { folder + "/" + $0 } }
            .filter { fm.isExecutableFile(atPath: $0) }
        let fromBundle = found.first { path in bundles.contains { $0.hasPrefix((path as NSString).deletingLastPathComponent + "/") } }
        return fromBundle ?? found.max { modified($0) < modified($1) }
    }

    /// The compiler arguments that load the built macro and the `SwiftFormal` module, for a file that uses `@Verify`.
    static func macroArguments() throws -> [String] {
        let macro = try #require(macro, "no built SwiftFormalMacros next to the tests or under .build")
        let products = (macro as NSString).deletingLastPathComponent
        return ["-I", products, "-I", products + "/Modules", "-load-plugin-executable", macro + "#SwiftFormalMacros"]
    }

    private static func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    static let source = """
        import SwiftFormal

        @Verify
        func clamp(_ x: Int8) -> Int8 {
            #requires(x >= 0)
            #ensures { $0 <= 100 }
            return min(x, 100)
        }

        @Verify
        func bump(_ x: UInt8) -> UInt8 {
            #ensures { $0 > x }
            return x &+ 1
        }

        struct Card {
            var points: Int8

            @Verify
            var bonus: Int8 {
                #requires(points >= 0)
                #ensures { $0 >= 0 && $0 <= points }
                return points > 10 ? points - 10 : 0
            }
        }

        func handy(_ x: Int8) -> Int8 { x &+ 1 }
        func handy_ensures(_ x: Int8, _ r: Int8) -> Bool { r > x }
        """

    @Test func theContractVerifyWritesIsProvedOrRefutedAndAHandWrittenOneIsNot() throws {
        let directory = NSTemporaryDirectory() + "sfv-macro-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/Shop.swift"
        try Self.source.write(toFile: file, atomically: true, encoding: .utf8)
        let arguments = try Self.macroArguments()
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Shop", extraArguments: arguments), options)
        func function(_ name: String) throws -> FunctionReport {
            try #require(report.functions.first { $0.name == name }, "\(report.functions.map(\.name))")
        }

        #expect(try function("clamp(_:)").status == .contractHolds)
        #expect(try function("bump(_:)").status == .contractFails)
        #expect(try function("Card.bonus.getter").status == .contractHolds)
        let handy = try function("handy(_:)")
        #expect(handy.status == .safe && !handy.hasContract && handy.ignoredContracts == ["handy_ensures(_:_:)"])
        #expect(!report.functions.contains { $0.name.hasPrefix("clamp_") || $0.name.hasPrefix("bump_") }, "peers pair, never stand alone")
    }
}
