import Foundation
import SFSIL
import SFTestSupport
import Testing

/// Plan item K8: the compiler's own dependency scanner (`swiftc -scan-dependencies`) as the oracle for Scan's import
/// discovery (`SILModule.imports`, read from the `import` lines of the SIL). Scan links package modules and checks
/// that type names are unique across exactly these modules, so a missed import spelling (the C1 class: an import with
/// an access level or an attribute was ignored) makes both unsound. Every spelling below must be found.
@Suite(.tags(.oracle), .requiresPinnedCompiler) struct ImportDiscoveryOracleTests {
    private static let source = """
        public import Foundation
        internal import Darwin
        @preconcurrency import Dispatch
        @_implementationOnly import os
        import class Combine.AnyCancellable
        package import CoreFoundation

        public func identity(_ x: Int8) -> Int8 { x }
        """

    @Test func scanFindsTheModulesTheDependencyScannerFinds() throws {
        let arguments = ["-package-name", "Oracle"]
        let module = try SILCompiler.module(source: Self.source, name: "Imports", optimization: .none, extraArguments: arguments)
        // SIL also prints the modules every file imports implicitly; the scanner lists those without a location.
        let found = Set(module.imports).subtracting(["Builtin", "Swift", "SwiftShims"])
        let scanned = try Self.scannerImports(source: Self.source, module: "Imports", arguments: arguments)
        #expect(scanned == ["Foundation", "Darwin", "Dispatch", "os", "Combine", "CoreFoundation"])
        #expect(found == scanned)
    }

    /// The imports the scanner places in the source (`modules[main].imports[].importLocations`).
    private static func scannerImports(source: String, module: String, arguments: [String]) throws -> Set<String> {
        let directory = NSTemporaryDirectory() + "sf-k8-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/\(module).swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-scan-dependencies", file, "-module-name", module, "-parse-as-library"] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "swiftc -scan-dependencies failed")

        // `modules` alternates `{"swift": name}` and that module's details.
        let graph = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let modules = try #require(graph["modules"] as? [Any])
        for (index, entry) in modules.enumerated().dropLast() where (entry as? [String: String])?["swift"] == module {
            let imports = ((modules[index + 1] as? [String: Any])?["imports"] as? [[String: Any]]) ?? []
            return Set(imports.filter { $0["importLocations"] != nil }.compactMap { $0["identifier"] as? String })
        }
        Issue.record("the scanner's output has no entry for \(module)")
        return []
    }
}
