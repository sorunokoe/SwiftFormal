import Foundation

/// Where Scan's compiles keep their implicit module cache (plan item K9).
///
/// Building the module of `Foundation` into an empty cache takes 20 to 30 s; with a warm one, a compile takes 0.1 s.
/// SwiftPM gives each scratch path a cache of its own (`<scratch>/out/ModuleCache.noindex`), so every new scratch path,
/// CI checkout or plugin work directory paid that again. Every Scan compile now uses one directory per compiler,
/// named after its version line. The compiler keys the modules inside by their options, and checks them against their
/// sources, so sharing is what the cache is designed for.
///
/// The directory is the first of these that can be created: `sfverify --module-cache <dir>`, `SFVERIFY_MODULE_CACHE`,
/// the user's cache directory (`~/Library/Caches/sfverify`, `~/.cache/sfverify`), the temporary directory. A build
/// plugin's sandbox may allow only some of them. When none works, the compile keeps the arguments it had.
package enum ModuleCacheLocation {
    /// The environment variable that names the root (the directory that holds the per-compiler directories).
    package static let variable = "SFVERIFY_MODULE_CACHE"

    /// `sfverify --module-cache <dir>`: set once, before the first compile.
    package static func useRoot(_ root: String?) { option.withLock { $0 = root } }

    /// `ModuleCache-<FNV-1a of the version line, 16 hex digits>`.
    package static func directoryName(versionLine: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in versionLine.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return "ModuleCache-" + String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// The candidate roots in order: the option, the environment variable, the user's cache directory, the temporary
    /// directory.
    package static func roots(option: String?, environment: [String: String]) -> [String] {
        var roots = [option, environment[variable]].compactMap { $0 }.filter { !$0.isEmpty }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(caches.appendingPathComponent("sfverify").path)
        }
        roots.append((NSTemporaryDirectory() as NSString).appendingPathComponent("sfverify"))
        return roots
    }

    /// The per-compiler directory under the first root where it exists or can be created and is writable; nil when
    /// there is none.
    package static func directory(versionLine: String, roots: [String]) -> String? {
        let name = directoryName(versionLine: versionLine)
        for root in roots {
            let path = (root as NSString).appendingPathComponent(name)
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            if FileManager.default.isDirectory(atPath: path), FileManager.default.isWritableFile(atPath: path) { return path }
        }
        return nil
    }

    /// The directory for `versionLine` in this process (the option and the environment of this process).
    static func directory(versionLine: String) -> String? {
        directory(versionLine: versionLine, roots: roots(option: option.withLock { $0 }, environment: ProcessInfo.processInfo.environment))
    }

    private static let option = Guarded<String?>(nil)
}

/// A value that every access reads or writes under one lock.
final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

extension ModuleCompiler {
    /// `arguments` without their `-module-cache-path <dir>` pairs, then `-module-cache-path cache`; unchanged when
    /// `cache` is nil.
    static func withModuleCache(_ arguments: [String], cache: String?) -> [String] {
        guard let cache else { return arguments }
        var kept: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "-module-cache-path" {
                index += 2
                continue
            }
            kept.append(arguments[index])
            index += 1
        }
        return kept + ["-module-cache-path", cache]
    }

    /// `arguments` with the scan's shared module cache (`ScanToolchain.moduleCache`).
    static func withModuleCache(_ arguments: [String]) throws -> [String] {
        withModuleCache(arguments, cache: try ScanToolchain.current().moduleCache)
    }
}
