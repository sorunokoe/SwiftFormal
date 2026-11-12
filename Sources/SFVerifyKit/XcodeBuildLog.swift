import Foundation

/// Build logs from Xcode and `xcodebuild` (plan item K6). They carry the same `builtin-Swift-Compilation -- swiftc …`
/// lines as SwiftPM's Swift Build, so `compileInvocation` reads all of them once the text is out.
extension SwiftPMBuild {
    /// The text of a build log for `--build-log`:
    /// - a plain log (`swift build -v` or `xcodebuild` output) as it is;
    /// - an `.xcactivitylog` (Xcode's own log: gzip-compressed SLF), decoded to its strings;
    /// - the plan of an Xcode build (`…/Build/Intermediates.noindex/XCBuildData`, or one `<id>.xcbuilddata` in it): the
    ///   newest plan that holds a command for `module`; it also works inside that build, from a Run Script phase;
    /// - a folder (DerivedData, or its `Logs/Build`): the newest activity log that compiled `module`, or the newest
    ///   one when none did (its build compiled nothing; then the saved command decides).
    public static func readBuildLog(_ path: String, module: String) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ScanUsageError("no build log at \(path)")
        }
        if isDirectory.boolValue {
            let plans = xcodeBuildData(in: path)
            if !plans.isEmpty {
                for plan in plans {
                    if let text = xcodeBuildDataLog(plan), compileInvocation(in: text, module: module) != nil { return text }
                }
                throw ScanUsageError("no plan of an Xcode build in \(path) holds a compile command for \(module)")
            }
            let logs = activityLogs(in: path)
            guard !logs.isEmpty else { throw ScanUsageError("no .xcactivitylog in \(path) or its Logs/Build") }
            var newest: String?
            for log in logs {
                let text = try activityLogText(log)
                if compileInvocation(in: text, module: module) != nil { return text }
                newest = newest ?? text
            }
            return newest ?? ""
        }
        if path.hasSuffix(".xcactivitylog") { return try activityLogText(path) }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// The activity logs of `folder` (or of its `Logs/Build`), newest first.
    static func activityLogs(in folder: String) -> [String] {
        let fm = FileManager.default
        for directory in [folder + "/Logs/Build", folder] {
            let names = ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".xcactivitylog") }
            guard !names.isEmpty else { continue }
            let paths = names.map { directory + "/" + $0 }
            func modified(_ path: String) -> Date {
                ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
            }
            return paths.sorted { modified($0) > modified($1) }
        }
        return []
    }

    /// The strings of an activity log, one per line (Xcode separates a command's lines with `\r`).
    package static func activityLogText(_ path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ScanUsageError("could not decompress \(path) (not a gzip file)") }
        return slfStrings(data).joined(separator: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// The strings of SLF, the format of `.xcactivitylog`: after `SLF0`, tokens of a value (hex digits for a double,
    /// decimal otherwise) and one type character. `"` (string), `%` (class name) and `*` (JSON) are followed by as
    /// many bytes as the value says; `#`, `^`, `@`, `(` and `-` stand alone. An unknown type ends the reading (an
    /// internal format: what was read so far is kept).
    private static func slfStrings(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        guard bytes.starts(with: Array("SLF0".utf8)) else { return [] }
        var strings: [String] = []
        var index = 4
        while index < bytes.count {
            var end = index
            while end < bytes.count, isHexDigit(bytes[end]) { end += 1 }
            guard end < bytes.count else { break }
            let type = bytes[end]
            switch type {
            case UInt8(ascii: "\""), UInt8(ascii: "%"), UInt8(ascii: "*"):
                guard let digits = String(bytes: bytes[index..<end], encoding: .ascii), let length = Int(digits),
                    end + 1 + length <= bytes.count
                else { return strings }
                if type == UInt8(ascii: "\""), let text = String(bytes: bytes[(end + 1)..<(end + 1 + length)], encoding: .utf8) {
                    strings.append(text)
                }
                index = end + 1 + length
            case UInt8(ascii: "#"), UInt8(ascii: "^"), UInt8(ascii: "@"), UInt8(ascii: "("), UInt8(ascii: "-"):
                index = end + 1
            default:
                return strings
            }
        }
        return strings
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }
}
