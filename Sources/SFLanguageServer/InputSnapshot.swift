import CryptoKit
import Darwin
package import Foundation

/// The inputs a check reads, captured before it starts and again after it ends. Equal snapshots mean no file changed
/// while it ran, so its answers are about the files as they were at the start.
package struct InputSnapshot: Equatable, Sendable {
    /// Size, modification time and inode: any write changes one of them.
    package struct Signature: Equatable, Sendable {
        package var size: Int64
        package var modified: Int64
        package var inode: UInt64
    }

    /// Every file under the packages, by path.
    package var files: [String: Signature] = [:]
    /// SHA-256 of each Swift source at the start, by path: what an editor buffer must equal to show a proof.
    package var hashes: [String: String] = [:]
    /// Everything else a verdict depends on that is not a file of the packages: the selected Xcode, the server's
    /// configuration, the `swiftformal` binary.
    package var context: [String: String] = [:]

    package init() {}

    /// The files under `roots` (skipping `.build`, `.git`, …, hidden folders and hidden files), hashing Swift sources when `hash`.
    package static func capture(roots: [String], context: [String: String], hash: Bool) -> InputSnapshot {
        var snapshot = InputSnapshot()
        snapshot.context = context
        let fm = FileManager.default
        for root in Set(roots) {
            guard let walker = fm.enumerator(atPath: root) else { continue }
            while let relative = walker.nextObject() as? String {
                let name = (relative as NSString).lastPathComponent
                let path = root + "/" + relative
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                    if name.hasPrefix(".") || Paths.isIgnored(path, roots: [root]) { walker.skipDescendants() }
                    continue
                }
                guard !name.hasPrefix("."), let signature = signature(path) else { continue }
                snapshot.files[path] = signature
                if hash, path.hasSuffix(".swift"), let data = fm.contents(atPath: path) { snapshot.hashes[path] = digest(data) }
            }
        }
        return snapshot
    }

    /// The paths whose signature differs between the two snapshots (added, removed or changed), and whether the
    /// context changed.
    package func changes(to later: InputSnapshot) -> (paths: Set<String>, context: Bool) {
        var paths: Set<String> = []
        for (path, signature) in files where later.files[path] != signature { paths.insert(path) }
        for path in later.files.keys where files[path] == nil { paths.insert(path) }
        return (paths, context != later.context)
    }

    package static func signature(_ path: String) -> Signature? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return Signature(size: Int64(info.st_size), modified: modified, inode: UInt64(info.st_ino))
    }

    /// SHA-256 of `data`, as hex.
    package static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The toolchain choice a check inherits: `DEVELOPER_DIR`, `TOOLCHAINS` and `xcode-select`'s link.
    package static func toolchainContext(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var context: [String: String] = [:]
        for key in ["DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT"] { context[key] = environment[key] ?? "" }
        context["xcode-select"] = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? ""
        return context
    }
}
