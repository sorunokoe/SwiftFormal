import Foundation

/// What `ScanToolchain.resolve` asks a compiler and `xcrun` (about 0.1 s of every run, before the first compile), kept
/// on disk between runs. The answer feeds the compiler pin, so a stale one must be impossible: the key is the
/// compiler's real path with its file identity (inode, size, modification time in nanoseconds), the environment that
/// selects a toolchain or an SDK, and the Xcode `xcode-select` points at. A file is used only when its stored key is
/// that key exactly; anything else (missing, unreadable, another key) means asking again and writing it anew.
enum ToolchainInfoCache {
    struct Answers: Codable, Equatable {
        /// The raw `-print-target-info` output.
        var targetInfo: Data
        var sdkVersion: String
        var sdkPath: String?
    }

    private struct Entry: Codable {
        var key: String
        var answers: Answers
    }

    /// The key of `swiftc` in `environment`; nil when the compiler's file cannot be described (nothing is cached then).
    static func key(swiftc: String, environment: [String: String]) -> String? {
        let real = URL(fileURLWithPath: swiftc).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: real),
            let size = attributes[.size] as? Int, let inode = attributes[.systemFileNumber] as? Int,
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let selected = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? ""
        let nanoseconds = Int64((modified.timeIntervalSince1970 * 1_000_000_000).rounded())
        return [
            "format 1", "swiftc \(real)", "file \(inode):\(size):\(nanoseconds)", "xcode-select \(selected)",
            "DEVELOPER_DIR \(environment["DEVELOPER_DIR"] ?? "")", "SDKROOT \(environment["SDKROOT"] ?? "")",
            "TOOLCHAINS \(environment["TOOLCHAINS"] ?? "")",
        ].joined(separator: "\n")
    }

    static func read(key: String, roots: [String]) -> Answers? {
        for root in roots {
            guard let data = FileManager.default.contents(atPath: file(key: key, root: root)),
                let entry = try? JSONDecoder().decode(Entry.self, from: data)
            else { continue }
            return entry.key == key ? entry.answers : nil
        }
        return nil
    }

    /// Writes into the first root where it can; a cache that cannot be written only means asking again next time.
    static func write(_ answers: Answers, key: String, roots: [String]) {
        guard let data = try? JSONEncoder().encode(Entry(key: key, answers: answers)) else { return }
        for root in roots {
            let path = file(key: key, root: root)
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil { return }
        }
    }

    /// `<root>/toolchains/<FNV-1a of the key>.json`.
    private static func file(key: String, root: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return (root as NSString).appendingPathComponent("toolchains/\(String(hash, radix: 16)).json")
    }
}
