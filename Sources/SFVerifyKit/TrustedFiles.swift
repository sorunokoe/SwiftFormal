import Foundation

/// File access for the Scan proof cache that trusts only what the current user wrote: a directory is trusted when it
/// and every directory above it can be changed only by the user or root, an entry when it is a regular file of the
/// user that nobody else may write. Entries are opened without following a symbolic link and checked on the open
/// file, so nothing can be swapped in between the check and the read; writes go to a new file that is renamed into
/// place.
enum TrustedFiles {
    /// What reading an entry found.
    enum Read {
        case missing
        /// A symbolic link, not a regular file, not the user's, writable by others, or too large.
        case untrusted
        case failed
        case data(Data)
    }

    /// Whether `directory` exists and is trusted: it and each directory above it (as written and with symbolic links
    /// resolved) belongs to the user or root, and none can be written by others unless it is sticky (`/tmp`); the
    /// directory itself belongs to the user and only the user may write it.
    static func isTrustedDirectory(_ directory: String) -> Bool {
        guard directory.hasPrefix("/") else { return false }
        let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        for path in [directory, resolved] {
            for prefix in prefixes(of: path) {
                guard let info = status(prefix, following: false), isSafeAncestor(info) else { return false }
            }
        }
        guard let leaf = status(resolved, following: true) else { return false }
        return leaf.st_mode & S_IFMT == S_IFDIR && leaf.st_uid == geteuid() && leaf.st_mode & 0o022 == 0
    }

    /// Creates `directory` (only the user may read or write what is created) unless it exists.
    static func createDirectory(_ directory: String) -> Bool {
        if FileManager.default.fileExists(atPath: directory) { return true }
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            return false
        }
    }

    /// The contents of the entry at `path`, read from the opened file after checking that file.
    static func read(_ path: String, limit: Int) -> Read {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return .missing
            case ELOOP: return .untrusted
            default: return .failed
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .failed }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o022 == 0, info.st_size <= limit else {
            return .untrusted
        }
        guard let data = try? handle.read(upToCount: limit + 1) ?? Data(), data.count <= limit else { return .failed }
        return .data(data)
    }

    /// Writes `data` to a new file of the user in `path`'s directory, then renames it to `path`.
    static func write(_ data: Data, to path: String) -> Bool {
        let temporary = (path as NSString).deletingLastPathComponent + "/.\(UUID().uuidString).tmp"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(atPath: temporary)
            return false
        }
        guard rename(temporary, path) == 0 else {
            try? FileManager.default.removeItem(atPath: temporary)
            return false
        }
        return true
    }

    /// `/a`, `/a/b`, … up to `path` itself.
    private static func prefixes(of path: String) -> [String] {
        var result: [String] = ["/"]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            result.append(current)
        }
        return result
    }

    /// A directory or symbolic link on the way to the cache: the user's or root's, and if it is a directory, writable
    /// by nobody else unless it is sticky (others then cannot rename or delete what is not theirs).
    private static func isSafeAncestor(_ info: stat) -> Bool {
        guard info.st_uid == geteuid() || info.st_uid == 0 else { return false }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return true
        case S_IFDIR: return info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0
        default: return false
        }
    }

    private static func status(_ path: String, following: Bool) -> stat? {
        var info = stat()
        return (following ? stat(path, &info) : lstat(path, &info)) == 0 ? info : nil
    }
}
