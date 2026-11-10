import Foundation

/// Answers of Scan's claim (`Verifier`) that were checked once, kept on disk so that a later run with the same
/// identity does not solve them again (plan items D4, S5, X6). Only a `proved` that the LRAT checker accepted and a
/// counterexample that survived `honest` replay are stored; every other answer is solved each time.
///
/// An entry is used only when the directory, every directory above it and the entry itself pass `TrustedFiles`, and
/// its key (`ScanKeyContext`) matches. A stored counterexample is replayed on every use. A run never fails because of
/// the cache: when it cannot read or write, the function is verified as without it, and `ProofCacheUse` counts it.
public final class ScanProofCache: @unchecked Sendable {
    /// The directory given, made absolute (a relative one is under the current directory); entries are in its
    /// `scan-v1` subdirectory.
    public let directory: String
    private let lock = NSLock()
    /// Whether the directory passed `TrustedFiles`; nil until first used.
    private var checked: Trust?
    private var counts: ProofCacheUse
    private static let entryLimit = 1 << 20

    /// The tool's versions its keys include; nil means `ScanToolIdentity.versions`. Tests set a fixed text, so
    /// that they do not wait for `SemanticsDigest.current` (seconds in a debug build).
    package let versions: String?

    /// A cache in `directory`, created (readable by the user only) when first used.
    public convenience init(directory: String) { self.init(directory: directory, versions: nil) }

    package init(directory: String, versions: String?) {
        self.directory = URL(fileURLWithPath: directory).standardizedFileURL.path
        self.versions = versions
        counts = ProofCacheUse(directory: self.directory)
    }

    /// The default directory for a package: `<root>/.build/swiftformal/proofs`.
    public static func directory(package root: String) -> String {
        URL(fileURLWithPath: root).standardizedFileURL.path + "/.build/swiftformal/proofs"
    }

    /// A cache on the same directory with counts that start at zero (one per scanned module).
    package func forRun() -> ScanProofCache { ScanProofCache(directory: directory, versions: versions) }

    /// What this cache did so far.
    public var use: ProofCacheUse {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    private var entries: String { directory + "/scan-v1" }

    /// The entry stored under `key`, when there is one the user wrote in a trusted directory.
    package func lookup(_ key: String) -> ScanProofEntry? {
        guard let name = Self.fileName(key), isTrusted() else {
            count { $0.misses += 1 }
            return nil
        }
        switch TrustedFiles.read(entries + "/" + name, limit: Self.entryLimit) {
        case .missing:
            count { $0.misses += 1 }
        case .untrusted:
            count { $0.rejected += 1 }
        case .failed:
            count { $0.ioErrors += 1 }
        case .data(let data):
            guard let entry = try? JSONDecoder().decode(ScanProofEntry.self, from: data), entry.isValid(key: key) else {
                count { $0.rejected += 1 }
                return nil
            }
            return entry
        }
        return nil
    }

    /// Stores `entry` under its key, replacing an older one; does nothing when the directory is not trusted.
    package func store(_ entry: ScanProofEntry) {
        guard entry.isValid(key: entry.key), let name = Self.fileName(entry.key), isTrusted() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry), TrustedFiles.write(data, to: entries + "/" + name) else {
            count { $0.ioErrors += 1 }
            return
        }
        count { $0.stored += 1 }
    }

    /// Records a function whose answer came from an entry.
    package func recordHit() { count { $0.hits += 1 } }
    /// Records an entry that was read but did not hold for the claim (a counterexample that did not replay).
    package func recordReplayFailed() { count { $0.rejected += 1 } }
    /// Records a function verified without the cache because part of its identity was not known.
    package func recordUnkeyed() { count { $0.unkeyed += 1 } }
    /// Adds time spent computing keys.
    package func recordKeySeconds(_ seconds: Double) { count { $0.keySeconds += seconds } }

    private func count(_ change: (inout ProofCacheUse) -> Void) {
        lock.lock()
        change(&counts)
        lock.unlock()
    }

    /// Creates the directory when it is missing and checks it once (`TrustedFiles.isTrustedDirectory`).
    private func isTrusted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let checked { return checked == .trusted }
        let made = TrustedFiles.createDirectory(entries)
        let trusted = made && TrustedFiles.isTrustedDirectory(directory) && TrustedFiles.isTrustedDirectory(entries)
        if !made { counts.ioErrors += 1 }
        counts.trusted = trusted
        checked = trusted ? .trusted : .untrusted
        return trusted
    }

    private enum Trust {
        case trusted
        case untrusted
    }

    /// `<hex>.json` for a SHA-256 key; nil for anything else.
    private static func fileName(_ key: String) -> String? {
        guard key.hasPrefix("sha256:") else { return nil }
        let hex = key.dropFirst("sha256:".count)
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return hex + ".json"
    }
}

/// What the proof cache did in a run; in `ScanReport.proofCache`.
public struct ProofCacheUse: Codable, Sendable, Equatable {
    /// The cache directory.
    public var directory: String
    /// False when the directory (or one above it) is not trusted: then no entry was read or written.
    public var trusted = true
    /// Functions whose answer came from the cache (a counterexample replayed).
    public var hits = 0
    /// Lookups that found no entry.
    public var misses = 0
    /// Answers written.
    public var stored = 0
    /// Entries found but not used: not trusted, unreadable, for another key, or a counterexample that did not replay.
    public var rejected = 0
    /// Functions verified without the cache because part of their identity was not known.
    public var unkeyed = 0
    /// Reads or writes that failed (the function was verified as without the cache).
    public var ioErrors = 0
    /// Time spent computing keys, summed over threads.
    public var keySeconds = 0.0

    public init(directory: String) { self.directory = directory }

    /// A few words for a progress line: `412 from the proof cache`, or why it was not used.
    public var shortSummary: String {
        guard trusted else { return "proof cache not trusted: \(directory)" }
        return "\(hits) from the proof cache" + (ioErrors > 0 ? ", \(ioErrors) cache errors" : "")
    }

    /// One line for the text report: what came from the cache, or why it was not used.
    public var summary: String {
        guard trusted else {
            return "Proof cache: not used, \(directory) is not trusted (it or a directory above it can be changed by others)"
        }
        var line = "Proof cache: \(hits) answers reused, \(stored) stored"
        if unkeyed > 0 { line += ", \(unkeyed) without a key" }
        if rejected > 0 { line += ", \(rejected) entries rejected" }
        if ioErrors > 0 { line += ", \(ioErrors) read or write errors" }
        return line + " · keys \(ScanReport.seconds(keySeconds))s"
    }
}

/// One stored answer. `key` repeats the file name's key; a mismatch is rejected.
package struct ScanProofEntry: Codable, Equatable {
    /// The answer an entry holds.
    package enum Verdict: String, Codable {
        case proved
        case counterexample
    }

    /// The file format; another one is rejected.
    package var format = 1
    /// Whose claim the entry answers; only Scan's is read.
    package var namespace = "scan"
    /// The claim's key (`ScanKeyContext.key`).
    package var key: String
    /// The answer.
    package var verdict: Verdict
    /// The counterexample's parameter values, in hexadecimal; nil for `proved`.
    package var values: [String]?
    /// The summarized calls the counterexample's encoding relied on (decides whether other trap sites are searched).
    package var approximations: [String]?
    /// What the solve that found the answer spent (reported again with `--stats`).
    package var conflicts = 0
    /// See `conflicts`.
    package var variables = 0
    /// See `conflicts`.
    package var clauses = 0
    /// For a reader of the file only.
    package var symbol: String
    /// What the encoding that found the answer took on trust (`FunctionReport.assumptions`); nil when nothing.
    package var assumptions: [String]?

    /// A `proved` entry, or a counterexample when `values` is given.
    package init(key: String, values: [UInt64]? = nil, approximations: Set<String> = [], symbol: String) {
        self.key = key
        verdict = values == nil ? .proved : .counterexample
        self.values = values?.map { String($0, radix: 16) }
        self.approximations = values == nil ? nil : approximations.sorted()
        self.symbol = symbol
    }

    /// The counterexample's values; nil when one is not hexadecimal.
    package var counterexample: [UInt64]? {
        guard let values else { return nil }
        let parsed = values.compactMap { UInt64($0, radix: 16) }
        return parsed.count == values.count ? parsed : nil
    }

    func isValid(key: String) -> Bool {
        guard format == 1, namespace == "scan", self.key == key else { return false }
        switch verdict {
        case .proved: return values == nil
        case .counterexample: return counterexample != nil
        }
    }
}
