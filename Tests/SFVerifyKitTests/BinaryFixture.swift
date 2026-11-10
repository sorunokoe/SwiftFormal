import Foundation
import Testing

@testable import SFVerifyKit

/// The binary modules of `Fixtures/BinaryTypes`, built once per compiler and source text and kept under the package's
/// `.build/sf-fixtures`: `Kit` (an Objective-C clang module with a Swift layer shaped like a SKIE export, without library
/// evolution) and `Seasons` (built with library evolution). Each is a `.swiftmodule` with a static library and no
/// `.swiftinterface`, so a client's SIL has no bodies of theirs.
enum BinaryFixture {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/BinaryTypes")
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The directory holding `Kit.swiftmodule`, `Seasons.swiftmodule` and their libraries.
    static let built = Result { try build() }

    /// Compile options for a client of the fixture modules made of `files` (names in `Fixtures/BinaryTypes`).
    static func client(_ files: [String], moduleName: String) throws -> CompileOptions {
        let directory = try built.get()
        return CompileOptions(
            files: files.map { sources.appendingPathComponent($0).path }, moduleName: moduleName,
            extraArguments: ["-I", directory, "-I", sources.appendingPathComponent("Kit").path])
    }

    private static func build() throws -> String {
        let toolchain = try ScanToolchain.current()
        let sdk = try #require(toolchain.sdk, "the binary fixtures need an SDK (macOS)")
        let names = ["Kit.swift", "Seasons.swift", "Kit/Kit.h", "Kit/Kit.m", "Kit/Kit.apinotes", "Kit/module.modulemap"]
        var identity = toolchain.swiftc + "\n" + toolchain.versionLine + "\n" + sdk
        for name in names { identity += "\n" + (try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)) }
        let root = packageRoot.appendingPathComponent(".build/sf-fixtures").path
        let directory = root + "/binary-types-" + fnv(identity)
        if FileManager.default.fileExists(atPath: directory + "/done") { return directory }

        let staging = directory + ".staging-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let kit = sources.appendingPathComponent("Kit").path
        let cache = try ModuleCompiler.withModuleCache([])
        func swiftc(_ module: String, _ extra: [String]) throws {
            let arguments =
                ["-emit-module", "-emit-library", "-static", "-parse-as-library", "-module-name", module, "-sdk", sdk]
                + cache + extra
                + [
                    sources.appendingPathComponent("\(module).swift").path, "-emit-module-path", "\(staging)/\(module).swiftmodule",
                    "-o", "\(staging)/lib\(module).a",
                ]
            try run(toolchain.swiftc, arguments)
        }
        try swiftc("Kit", ["-import-underlying-module", "-I", kit])
        try swiftc("Seasons", ["-enable-library-evolution"])
        try run("/usr/bin/xcrun", ["clang", "-c", "-fobjc-arc", "-isysroot", sdk, "\(kit)/Kit.m", "-o", "\(staging)/Kit.o"])
        try run("/usr/bin/xcrun", ["libtool", "-static", "-o", "\(staging)/libKitObjC.a", "\(staging)/Kit.o"])
        try Data().write(to: URL(fileURLWithPath: staging + "/done"))
        // Another process may have built the same directory meanwhile: either copy is the same.
        if (try? FileManager.default.moveItem(atPath: staging, toPath: directory)) == nil,
            !FileManager.default.fileExists(atPath: directory + "/done")
        {
            throw FixtureError("could not move the built binary fixtures to \(directory)")
        }
        return directory
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let result = try Spawn.run(executable, arguments, output: false)
        guard result.status == 0 else {
            throw FixtureError("\(executable) \(arguments.joined(separator: " ")) failed:\n\(result.errorText.prefix(4000))")
        }
    }

    private static func fnv(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
