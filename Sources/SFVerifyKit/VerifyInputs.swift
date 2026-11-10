import Foundation
import SFSIL

/// Digests of what a compile reads, each path hashed once per instance, with what `stat` said of each file and
/// directory read.
final class VerifyInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [String: String?] = [:]
    private var statuses: [String: FileStatus] = [:]
    /// The files whose bytes are kept (`kept`).
    private let keeping: Set<String>
    private var contents: [String: Data] = [:]
    /// Directories of the compiler and the SDK platform: their contents come with the compiler's and the SDK's versions.
    private let covered: [String]
    private static let entryLimit = 50_000
    private static let moduleExtensions: Set = [
        "swiftmodule", "swiftinterface", "modulemap", "h", "hh", "hpp", "hxx", "inc", "def", "apinotes", "tbd", "pcm",
    ]

    /// Keeps the bytes it hashes of the files in `keeping`.
    init(toolchain: ScanToolchain, keeping: [String] = []) {
        self.keeping = Set(keeping.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var roots = [toolchain.resourceDirectory, toolchain.sdk].compactMap { $0 }
        let toolchainRoot = (toolchain.toolchainUsr as NSString).deletingLastPathComponent
        if toolchainRoot.hasSuffix(".xctoolchain") { roots.append(toolchainRoot) }
        // A toolchain of its own (`/Library/Developer/CommandLineTools/usr`, `/opt/swift/usr`), not the system's `/usr`.
        if toolchain.toolchainUsr.split(separator: "/").count >= 3 { roots.append(toolchain.toolchainUsr) }
        if let sdk = toolchain.sdk {
            // <platform>.platform/Developer/SDKs/<name>.sdk
            let platform = (((sdk as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString)
                .deletingLastPathComponent
            if platform.hasSuffix(".platform") { roots.append(platform) }
        }
        covered = roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path + "/" }
    }

    /// The digest of the module `options` compiles: its frontend arguments, the contents of every path they name, and
    /// the manifests of the package of its first file; nil when an argument names something that cannot be hashed.
    func module(_ options: CompileOptions) -> String? {
        guard let arguments = try? ModuleCompiler.silArguments(options), let first = options.files.first,
            let manifests = manifests(near: first)
        else { return nil }
        var lines = ["module=\(options.moduleName)", "manifests=\(manifests)"]
        var previous = ""
        for argument in arguments {
            defer { previous = argument }
            lines.append(argument)
            if previous == "-module-cache-path" { continue }
            guard !argument.hasPrefix("@"), !argument.hasSuffix("vfsoverlay"), let paths = Self.paths(in: argument, after: previous)
            else { return nil }
            let everyFile = previous == "-plugin-path" || previous == "-external-plugin-path"
            for path in paths {
                guard let digest = digest(of: path, everyFile: everyFile) else { return nil }
                lines.append("  " + digest)
            }
        }
        return ProofDigest.hash(lines.joined(separator: "\n"))
    }

    /// The absolute paths `argument` (following `previous`) names: itself, and the path a joined option ends with
    /// (`-I/x`, `-fmodule-map-file=/x`) in each `#`-separated part (`<directory>#<server>`, `<plugin>#<module>`); nil
    /// when it names a relative path, or may (a source file, the value of an option that takes a path).
    static func paths(in argument: String, after previous: String) -> [String]? {
        let value = !argument.hasPrefix("-")
        if !argument.hasPrefix("/") && (pathOptions.contains(previous) || value && (previous == "-Xcc" || argument.hasSuffix(".swift"))) {
            return nil
        }
        guard argument.contains("/") else { return [] }
        var paths = argument.hasPrefix("/") ? [argument] : []
        guard argument.contains("#") || !argument.hasPrefix("/") else { return paths }
        for part in argument.split(separator: "#", omittingEmptySubsequences: false).map(String.init) where part.contains("/") {
            if part.hasPrefix("/") {
                paths.append(part)
            } else if part.hasPrefix("-"), let slash = part.firstIndex(of: "/"), isJoinedOption(part[..<slash]) {
                paths.append(String(part[slash...]))
            } else {
                return nil
            }
        }
        return paths
    }

    /// Options whose value is a path.
    private static let pathOptions: Set = [
        "-I", "-F", "-Isystem", "-Fsystem", "-L", "-sdk", "-plugin-path", "-external-plugin-path", "-load-plugin-executable",
        "-load-plugin-library", "-import-objc-header",
    ]

    private static func isJoinedOption(_ option: Substring) -> Bool {
        option.hasSuffix("=") || ["-I", "-F", "-L", "-isystem", "-iquote", "-iframework", "-idirafter", "-include"].contains(option)
    }

    /// The bytes hashed of `path`, one of the files in `keeping`.
    func kept(_ path: String) -> Data? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return lock.withLock { contents[path] }
    }

    /// Whether `path` is in the compiler's or the SDK's directories, whose contents come with their versions.
    func isCovered(_ path: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return covered.contains { path.hasPrefix($0) }
    }

    /// The digest of a file the compiler said it read; nil when it is not there (it was, when the compiler read it)
    /// or cannot be read.
    func readFile(_ path: String) -> String? {
        guard let digest = digest(of: path, everyFile: false), !digest.hasSuffix(" absent") else { return nil }
        return digest
    }

    /// Whether every file and directory read by both `self` and `earlier` has the same `stat` in both, and every one
    /// only `self` read last changed before `started`, with a margin for the file system's coarser clock.
    func unchanged(since earlier: VerifyInputs, started: FileStatus.Time) -> Bool {
        let before = earlier.lock.withLock { earlier.statuses }
        let after = lock.withLock { statuses }
        let deadline = started.adding(seconds: -1)
        for (path, status) in after {
            if let known = before[path] {
                guard known == status else { return false }
            } else if !(status.changed < deadline) {
                return false
            }
        }
        return true
    }

    /// `toolchain` for a path of the compiler, `absent`, the file's contents' digest, or the digest of a directory's
    /// module files (`everyFile`: of all its files); nil when it cannot be read.
    private func digest(of path: String, everyFile: Bool) -> String? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if covered.contains(where: { path.hasPrefix($0) }) { return "toolchain" }
        // A stat cache of the SDK (`-ivfsstatcache`), written again by each build: the SDK's version covers it, and
        // its name has the SDK's build.
        if path.hasSuffix(".sdkstatcache") { return path + " sdk" }
        let key = (everyFile ? "*" : "") + path
        if let known = lock.withLock({ digests[key] }) { return known }
        let digest: String?
        switch Kind(path) {
        case .absent: digest = path + " absent"
        case .directory: digest = directoryDigest(path, everyFile: everyFile).map { path + " " + $0 }
        case .file: digest = fileDigest(path).map { path + " " + $0 }
        }
        lock.withLock { digests[key] = digest }
        return digest
    }

    /// The digest of the module files under `root` (all files with `everyFile`), following symbolic links.
    private func directoryDigest(_ root: String, everyFile: Bool) -> String? {
        var lines: [String] = []
        var visited: Set<String> = []
        var pending = [""]
        var count = 0
        while let relative = pending.popLast() {
            let directory = relative.isEmpty ? root : root + "/" + relative
            guard visited.insert(URL(fileURLWithPath: directory).resolvingSymlinksInPath().path).inserted else { continue }
            // An entry added or removed changes the directory's times.
            guard let status = FileStatus(directory), let names = try? FileManager.default.contentsOfDirectory(atPath: directory),
                FileStatus(directory) == status
            else { return nil }
            lock.withLock { statuses[directory] = status }
            count += names.count
            guard count <= Self.entryLimit else { return nil }
            for name in names.sorted().reversed() {
                let child = relative.isEmpty ? name : relative + "/" + name
                let kind = Kind(root + "/" + child)
                if kind == .directory {
                    pending.append(child)
                } else if everyFile || Self.isModuleFile(name) {
                    guard let digest = kind == .absent ? "absent" : fileDigest(root + "/" + child) else { return nil }
                    lines.append(child + " " + digest)
                }
            }
        }
        return ProofDigest.hash(lines.joined(separator: "\n"))
    }

    /// What is at a path, following symbolic links.
    private enum Kind {
        case absent, file, directory

        init(_ path: String) {
            let values = try? URL(fileURLWithPath: path).resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey])
            self = values.map { $0.isDirectory == true ? .directory : .file } ?? .absent
        }
    }

    private static func isModuleFile(_ name: String) -> Bool {
        name == "module.map" || moduleExtensions.contains((name as NSString).pathExtension)
    }

    /// The digest of the manifests (`Package.swift`, `Package@swift-*.swift`, `Package.resolved`) of the nearest
    /// directory above `file` that has a `Package.swift`; `none` when there is none.
    private func manifests(near file: String) -> String? {
        var directory = (URL(fileURLWithPath: file).standardizedFileURL.path as NSString).deletingLastPathComponent
        while directory != "/" && !directory.isEmpty {
            if FileManager.default.fileExists(atPath: directory + "/Package.swift") {
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter {
                    $0 == "Package.resolved" || $0.hasPrefix("Package") && $0.hasSuffix(".swift")
                }
                var lines: [String] = []
                for name in names.sorted() {
                    guard let digest = digest(of: directory + "/" + name, everyFile: false) else { return nil }
                    lines.append(digest)
                }
                return ProofDigest.hash(lines.joined(separator: "\n"))
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return "none"
    }

    /// The digest of a file's contents, read while its `stat` stayed the same (kept with the bytes of a file in
    /// `keeping`); nil when it cannot be read or changed while it was.
    private func fileDigest(_ path: String) -> String? {
        // Copied, not mapped, and hashed before the second `stat`: every byte hashed was read between the two, so a
        // write in place after the second one cannot reach the digest (a mapped file's pages are read when touched).
        guard let status = FileStatus(path), let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [])
        else { return nil }
        let digest = ProofDigest.hash(bytes: Array(data))
        guard FileStatus(path) == status else { return nil }
        lock.withLock {
            statuses[path] = status
            if keeping.contains(path) { contents[path] = data }
        }
        return digest
    }
}

/// What `stat` says of a file or directory (following symbolic links): writing it, replacing it, or putting its
/// bytes back changes it.
struct FileStatus: Equatable {
    /// A time in nanoseconds since 1970.
    struct Time: Comparable {
        var nanoseconds: Int64

        static var now: Time {
            var time = timespec()
            clock_gettime(CLOCK_REALTIME, &time)
            return Time(time)
        }

        init(_ time: timespec) { nanoseconds = Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec) }

        func adding(seconds: Int64) -> Time {
            var time = self
            time.nanoseconds += seconds * 1_000_000_000
            return time
        }

        static func < (a: Time, b: Time) -> Bool { a.nanoseconds < b.nanoseconds }
    }

    var device: UInt64
    var inode: UInt64
    var size: Int64
    var modified: Time
    /// When the file's contents or attributes last changed; nobody can set it back.
    var changed: Time

    init?(_ path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        (device, inode, size) = (UInt64(info.st_dev), UInt64(info.st_ino), Int64(info.st_size))
        #if canImport(Darwin)
            (modified, changed) = (Time(info.st_mtimespec), Time(info.st_ctimespec))
        #else
            (modified, changed) = (Time(info.st_mtim), Time(info.st_ctim))
        #endif
    }
}
