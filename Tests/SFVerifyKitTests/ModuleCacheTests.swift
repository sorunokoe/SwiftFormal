import Foundation
import SFSIL
import Testing

@testable import SFVerifyKit

/// Plan item K9: every Scan compile uses one implicit module cache per compiler, so a new scratch path, CI checkout or
/// plugin work directory does not build Foundation's module again (about 20 s).
@Suite struct ModuleCacheTests {
    @Test func theDirectoryIsNamedAfterTheCompilerVersionLineAndIsStable() {
        let a = ModuleCacheLocation.directoryName(versionLine: "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)")
        #expect(a == ModuleCacheLocation.directoryName(versionLine: "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)"))
        #expect(a != ModuleCacheLocation.directoryName(versionLine: "Apple Swift version 6.5 (swiftlang-6.5.0.1.1 clang-2200.0.1.1)"))
        // A fixed FNV-1a hash, not `hashValue`: the same name in every process.
        #expect(a == "ModuleCache-65f67e9a1ee84605", "\(a)")
    }

    @Test func theFirstWritableRootWins() throws {
        let base = NSTemporaryDirectory() + "sfv-cache-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        // A file where a directory should be: nothing can be created under it.
        let blocked = base + "/file"
        FileManager.default.createFile(atPath: blocked, contents: Data())
        let chosen = ModuleCacheLocation.directory(versionLine: "v", roots: [blocked, base + "/second", base + "/third"])
        #expect(chosen == base + "/second/" + ModuleCacheLocation.directoryName(versionLine: "v"))
        #expect(FileManager.default.fileExists(atPath: chosen ?? ""))
        #expect(ModuleCacheLocation.directory(versionLine: "v", roots: [blocked]) == nil)
    }

    @Test func theOptionAndTheEnvironmentComeBeforeTheUserCache() {
        let roots = ModuleCacheLocation.roots(option: "/opt/cache", environment: ["SFVERIFY_MODULE_CACHE": "/env/cache"])
        #expect(Array(roots.prefix(2)) == ["/opt/cache", "/env/cache"])
        #expect(roots.count == 4, "then the user's cache directory and the temporary directory: \(roots)")
        #expect(ModuleCacheLocation.roots(option: nil, environment: [:]).count == 2)
    }

    @Test func swiftPMsModuleCachePathIsReplaced() {
        let swiftPM = ["-module-cache-path", "/s/ModuleCache.noindex", "-I", "/i", "-module-cache-path", "/s/Explicit", "-DX"]
        #expect(ModuleCompiler.withModuleCache(swiftPM, cache: "/c") == ["-I", "/i", "-DX", "-module-cache-path", "/c"])
        #expect(ModuleCompiler.withModuleCache(swiftPM, cache: nil) == swiftPM, "no usable cache: the arguments stay as they are")
    }

    @Test func aScanCompileFillsTheSharedCache() throws {
        let toolchain = try ScanToolchain.current()
        let cache = try #require(toolchain.moduleCache, "no writable module cache directory on this machine")
        let directory = NSTemporaryDirectory() + "sfv-cache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/a.swift"
        try "public func f(_ x: Int8) -> Int8 { x / 2 }\n".write(toFile: file, atomically: true, encoding: .utf8)
        _ = try ModuleCompiler.compile(CompileOptions(files: [file], moduleName: "CacheProbe"))
        let entries = try FileManager.default.contentsOfDirectory(atPath: cache)
        #expect(!entries.isEmpty, "the compile wrote nothing to \(cache)")
    }
}
