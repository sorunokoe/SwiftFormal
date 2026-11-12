import Foundation

/// Compile commands from Swift Build's plan of a build description.
///
/// Swift Build keeps the plan of each recent build description in
/// `out/Intermediates.noindex/XCBuildData/<id>.xcbuilddata/task-store.msgpack`, with every task's command line: for a
/// Swift module, `["builtin-SwiftDriver", "--", "<swiftc>", …, "-module-name", "<module>", …]`. A target's build
/// therefore holds the command of each module it compiled, its dependencies' too, even when the build was a null build
/// and printed none. The file is MessagePack in a layout private to Swift Build, so no field positions are assumed:
/// every array of strings that names a module with `-module-name` is a candidate, a module with two different command
/// lines (two architectures, say) has none, and a file that does not read as MessagePack gives no command at all; the
/// caller then plans the module with a build of its own.
extension SwiftPMBuild {
    /// The command of `target` in the plan of build description `description`, as `(swiftc, arguments)`.
    static func describedCommand(target: String, scratch: String, description: String) -> (tool: String, arguments: [String])? {
        let path = scratch + "/out/Intermediates.noindex/XCBuildData/\(description).xcbuilddata/task-store.msgpack"
        guard let commands = TaskStore.commands(at: path), let found = commands[target], found.count == 1, let command = found.first
        else { return nil }
        return (command[0], Array(command.dropFirst()))
    }
}

/// Xcode keeps the same files for each build it plans: `<DerivedData>/Build/Intermediates.noindex/XCBuildData/<id>.xcbuilddata/`.
/// The plan of a build holds the command of every Swift module in it, also of a module an incremental build does not
/// compile, and it is written before the first task runs: a Run Script phase of the build can read its own build's
/// plan, which no activity log offers (Xcode writes that log when the build ends).
extension SwiftPMBuild {
    /// The `.xcbuilddata` folders `path` names, newest first: the folder itself, the `XCBuildData` folder, or the
    /// `Intermediates.noindex` folder that holds it. Empty for any other folder, so a DerivedData folder is still read
    /// as a folder of activity logs.
    package static func xcodeBuildData(in path: String) -> [String] {
        let fm = FileManager.default
        if fm.fileExists(atPath: path + "/task-store.msgpack") { return [path] }
        let folder = fm.fileExists(atPath: path + "/XCBuildData") ? path + "/XCBuildData" : path
        let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".xcbuilddata") }
        func modified(_ path: String) -> Date {
            ((try? fm.attributesOfItem(atPath: path + "/task-store.msgpack"))?[.modificationDate] as? Date) ?? .distantPast
        }
        return names.map { folder + "/" + $0 }.filter { fm.fileExists(atPath: $0 + "/task-store.msgpack") }
            .sorted { modified($0) > modified($1) }
    }

    /// The plan in the `.xcbuilddata` folder `path` as the log lines `compileInvocation` reads
    /// (`builtin-SwiftDriver -- <swiftc> …`), one per module. A module the plan holds with two different commands
    /// (two architectures) gets none: no command is better than a guessed one. Nil when the file cannot be read.
    package static func xcodeBuildDataLog(_ path: String) -> String? {
        guard let commands = TaskStore.commands(at: path + "/task-store.msgpack") else { return nil }
        return commands.keys.sorted().compactMap { module -> String? in
            guard let found = commands[module], found.count == 1, let command = found.first,
                !command.contains(where: { $0.contains("\n") })
            else { return nil }
            return "builtin-SwiftDriver -- " + command.map(quoted).joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// One argument as `tokenize` reads it back.
    private static func quoted(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { " \"'\\\n".contains($0) }) else { return argument }
        let escaped = argument.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}

/// Reads the Swift compile commands out of a `task-store.msgpack`, once per version of the file in a process.
private enum TaskStore {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: (version: FileStatus, commands: [String: [[String]]]?)] = [:]
    }

    private static let cache = Cache()

    /// Every module's distinct commands (the compiler first), or nil when the file is missing or unreadable.
    static func commands(at path: String) -> [String: [[String]]]? {
        guard let version = FileStatus(path) else { return nil }
        cache.lock.lock()
        if let entry = cache.entries[path], entry.version == version {
            cache.lock.unlock()
            return entry.commands
        }
        cache.lock.unlock()
        let commands = FileManager.default.contents(atPath: path).flatMap { read([UInt8]($0)) }
        // Changed while it was read: not remembered (and not trusted to be the version stat'ed).
        guard FileStatus(path) == version else { return nil }
        cache.lock.lock()
        cache.entries[path] = (version, commands)
        cache.lock.unlock()
        return commands
    }

    private static func read(_ bytes: [UInt8]) -> [String: [[String]]]? {
        var reader = Reader(bytes: bytes)
        do {
            while reader.offset < bytes.count { _ = try reader.value(depth: 0) }
        } catch { return nil }
        return reader.commands
    }

    private struct Malformed: Error {}

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var commands: [String: [[String]]] = [:]

        init(bytes: [UInt8]) { self.bytes = bytes }

        /// Bytes after the type byte of the values that hold neither text nor other values (nil, booleans, numbers,
        /// fixed-size extensions).
        private static let fixed: [UInt8: Int] = [
            0xC0: 0, 0xC2: 0, 0xC3: 0, 0xCA: 4, 0xCB: 8, 0xCC: 1, 0xCD: 2, 0xCE: 4, 0xCF: 8, 0xD0: 1, 0xD1: 2, 0xD2: 4,
            0xD3: 8, 0xD4: 2, 0xD5: 3, 0xD6: 5, 0xD7: 9, 0xD8: 17,
        ]

        /// The values whose length follows the type byte: the length's size, and what they are.
        private static let prefixed: [UInt8: (size: Int, kind: MessagePackKind)] = [
            0xC4: (1, .string), 0xC5: (2, .string), 0xC6: (4, .string), 0xD9: (1, .string), 0xDA: (2, .string),
            0xDB: (4, .string), 0xC7: (1, .ext), 0xC8: (2, .ext), 0xC9: (4, .ext), 0xDC: (2, .array), 0xDD: (4, .array),
            0xDE: (2, .map), 0xDF: (4, .map),
        ]

        /// One MessagePack value: its text when it is a string, else nil (arrays of strings are looked at here).
        mutating func value(depth: Int) throws -> String? {
            guard depth < 256, let byte = try take(1).first else { throw Malformed() }
            if byte <= 0x7F || byte >= 0xE0 { return nil }
            if let size = Self.fixed[byte] {
                _ = try take(size)
                return nil
            }
            let (count, kind): (Int, MessagePackKind)
            if let prefix = Self.prefixed[byte] {
                (count, kind) = (try length(prefix.size), prefix.kind)
            } else if let inline = MessagePackKind.inline(byte) {
                (count, kind) = inline
            } else {
                throw Malformed()
            }
            switch kind {
            case .string: return try string(count)
            case .ext: _ = try take(count + 1)
            case .array: try array(count, depth: depth)
            case .map: try map(count, depth: depth)
            }
            return nil
        }

        private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= bytes.count - offset else { throw Malformed() }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }

        private mutating func length(_ size: Int) throws -> Int {
            try take(size).reduce(0) { $0 << 8 | Int($1) }
        }

        private mutating func string(_ count: Int) throws -> String? {
            String(bytes: try take(count), encoding: .utf8)
        }

        private mutating func map(_ count: Int, depth: Int) throws {
            guard count <= (bytes.count - offset) / 2 else { throw Malformed() }
            for _ in 0..<count * 2 { _ = try value(depth: depth + 1) }
        }

        private mutating func array(_ count: Int, depth: Int) throws {
            guard count <= bytes.count - offset else { throw Malformed() }
            var strings: [String]? = []
            strings?.reserveCapacity(count)
            for _ in 0..<count {
                let item = try value(depth: depth + 1)
                if let item { strings?.append(item) } else { strings = nil }
            }
            if let strings { note(strings) }
        }

        /// Keeps `strings` when it is a Swift compile command naming its module.
        private mutating func note(_ strings: [String]) {
            var command = strings[...]
            if let first = command.first, first.hasPrefix("builtin-"), command.dropFirst().first == "--" {
                command = command.dropFirst(2)
            }
            guard let tool = command.first, ["swiftc", "swift-frontend"].contains((tool as NSString).lastPathComponent),
                let flag = command.firstIndex(of: "-module-name"), flag + 1 < command.endIndex
            else { return }
            let module = command[flag + 1]
            let whole = Array(command)
            if commands[module]?.contains(whole) != true { commands[module, default: []].append(whole) }
        }
    }
}

private enum MessagePackKind {
    case string, ext, array, map

    /// A fixed-size string, array or map: its length is in the type byte.
    static func inline(_ byte: UInt8) -> (count: Int, kind: Self)? {
        switch byte {
        case 0x80...0x8F: (Int(byte & 0x0F), .map)
        case 0x90...0x9F: (Int(byte & 0x0F), .array)
        case 0xA0...0xBF: (Int(byte & 0x1F), .string)
        default: nil
        }
    }
}
