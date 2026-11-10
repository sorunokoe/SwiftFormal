package import Foundation
package import SwiftFormal
package import Testing

/// What a behaviour lock found.
package enum LockOutcome: Sendable, CustomStringConvertible {
    /// No lock existed (or an update was requested): the current behaviour was written to `path`.
    case recorded(path: String, count: Int)
    /// Every output over the domain is the same as in the committed lock.
    case matches(count: Int)
    /// Behaviour differs from the lock.
    case changed([LockChange], oldCount: Int, newCount: Int)
    /// No lock exists and strict mode (`SF_LOCK_STRICT=1`) forbids recording one.
    case missing(path: String)

    /// Whether a test should pass: the lock was recorded or still matches.
    package var isAcceptable: Bool {
        switch self {
        case .recorded, .matches: true
        case .changed, .missing: false
        }
    }

    /// A message describing the outcome. For a change it lists the first ten differences.
    package var description: String {
        switch self {
        case let .recorded(path, count): "recorded \(count) behaviours in \(path)"
        case let .matches(count): "behaviour unchanged over \(count) inputs"
        case let .missing(path): "no behaviour lock at \(path); run once without SF_LOCK_STRICT to record it"
        case let .changed(changes, oldCount, newCount):
            "behaviour changed for \(changes.count) of \(max(oldCount, newCount)) inputs"
                + (oldCount == newCount ? "" : " (domain size \(oldCount) → \(newCount))") + ":\n"
                + changes.prefix(10).map { "  #\($0.index) \($0.input)\n    was: \($0.was)\n    now: \($0.now)" }
                .joined(separator: "\n")
                + (changes.count > 10 ? "\n  … and \(changes.count - 10) more" : "")
        }
    }
}

/// One input whose output differs from the lock.
package struct LockChange: Sendable {
    /// The position of the input in the domain.
    package let index: Int
    /// The input, as text.
    package let input: String
    /// The output recorded in the lock.
    package let was: String
    /// The output the function returns now.
    package let now: String
}

/// Records what a function returns for every input of a domain, and later fails when that changes.
///
/// This is a semantic diff: after an AI (or a person) refactors a function, `checkBehaviorLock` says exactly which
/// inputs now give a different answer, with no hand-written spec. It does not say which behaviour is *right*;
/// it says what *moved*. Review the diff, then re-record with `SF_LOCK_UPDATE=1`.
///
/// The lock is a text file in a `__SFLocks__` folder next to the test file; commit it. Inputs are identified
/// by their position in the domain, so a domain must be deterministic, which every `Domain` is.
/// Outputs are compared by their `String(describing:)` text, with memory addresses (`0x…`) masked.
/// An output type without a stable description (a class holding an address or a date) will report false changes.
@discardableResult
package func checkBehaviorLock<Input, Output>(
    _ name: String,
    _ function: (Input) throws -> Output,
    over domain: Domain<Input>,
    maxInputs: Int = 100_000,
    file: StaticString = #filePath,
    directory: URL? = nil
) -> LockOutcome {
    let environment = ProcessInfo.processInfo.environment
    let update = environment["SF_LOCK_UPDATE"] == "1"
    let strict = environment["SF_LOCK_STRICT"] == "1"

    let count = min(domain.count, maxInputs)
    var current: [(hash: UInt64, text: String)] = []
    current.reserveCapacity(count)
    for index in 0..<count {
        let text: String
        do { text = BehaviorLock.mask(String(describing: try function(domain[index]))) } catch {
            text = "threw " + BehaviorLock.mask(String(describing: error))
        }
        current.append((BehaviorLock.hash(text), text))
    }

    let folder =
        directory
        ?? URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        .appendingPathComponent("__SFLocks__", isDirectory: true)
    let url = folder.appendingPathComponent(BehaviorLock.fileName(for: name))

    func record() -> LockOutcome {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? BehaviorLock.render(name: name, entries: current).write(to: url, atomically: true, encoding: .utf8)
        return .recorded(path: url.path, count: count)
    }

    if update { return record() }
    guard let old = try? String(contentsOf: url, encoding: .utf8) else {
        return strict ? .missing(path: url.path) : record()
    }
    let locked = BehaviorLock.parse(old)
    var changes: [LockChange] = []
    for index in 0..<max(locked.count, count) {
        let was = index < locked.count ? locked[index] : nil
        let now = index < count ? current[index] : nil
        guard was?.hash != now?.hash else { continue }
        let input = index < count ? BehaviorLock.mask(String(describing: domain[index])) : "(not in the domain any more)"
        changes.append(LockChange(index: index, input: input, was: was?.text ?? "(no entry)", now: now?.text ?? "(no entry)"))
    }
    return changes.isEmpty ? .matches(count: count) : .changed(changes, oldCount: locked.count, newCount: count)
}

/// Fails the test when behaviour differs from the committed lock. See `checkBehaviorLock`.
@discardableResult
package func expectBehaviorLocked<Input, Output>(
    _ name: String,
    _ function: (Input) throws -> Output,
    over domain: Domain<Input>,
    maxInputs: Int = 100_000,
    file: StaticString = #filePath,
    sourceLocation: SourceLocation = #_sourceLocation
) -> LockOutcome {
    let outcome = checkBehaviorLock(name, function, over: domain, maxInputs: maxInputs, file: file)
    if !outcome.isAcceptable { Issue.record(Comment(rawValue: "\(name): \(outcome)"), sourceLocation: sourceLocation) }
    return outcome
}

/// The text a behaviour lock stores for an output: `String(describing:)` with memory addresses masked.
/// Use it to compare outputs that are not `Equatable`.
package func describeMasked<Output>(_ value: Output) -> String { BehaviorLock.mask(String(describing: value)) }

enum BehaviorLock {
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return value
    }

    /// Replaces runs like `0x000000012ab3c4d0` and UUIDs so object addresses and fresh identifiers do not look
    /// like behaviour changes.
    static func mask(_ text: String) -> String {
        // Most outputs hold neither, and a lock masks every output, so look at the bytes before doing the slow work:
        // an address needs "0x", a UUID needs four "-". Masking never adds or removes a "-".
        var hasHexPrefix = false
        var dashes = 0
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if previous == UInt8(ascii: "0") && byte == UInt8(ascii: "x") { hasHexPrefix = true }
            if byte == UInt8(ascii: "-") { dashes += 1 }
            previous = byte
        }
        let withoutAddresses = hasHexPrefix ? maskAddresses(text) : text
        guard dashes >= 4 else { return withoutAddresses }
        return withoutAddresses.replacingOccurrences(of: uuidPattern, with: "<uuid>", options: .regularExpression)
    }

    private static let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    private static func maskAddresses(_ text: String) -> String {
        var result = ""
        var scalars = text.unicodeScalars[...]
        while let first = scalars.first {
            if first == "0", scalars.dropFirst().first == "x" {
                let digits = scalars.dropFirst(2).prefix(while: { $0.properties.isASCIIHexDigit })
                if digits.count >= 6 {
                    result += "0x*"
                    scalars = scalars.dropFirst(2 + digits.count)
                    continue
                }
            }
            result.unicodeScalars.append(first)
            scalars = scalars.dropFirst()
        }
        return result
    }

    static func fileName(for name: String) -> String { fileStem(for: name) + ".sflock" }

    /// `name` with every character other than letters, digits, `-` and `.` replaced by `_`.
    static func fileStem(for name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
    }

    static func render(name: String, entries: [(hash: UInt64, text: String)]) -> String {
        var lines = ["# swiftformal behavior lock v1", "# name: \(name)", "# count: \(entries.count)"]
        for (index, entry) in entries.enumerated() {
            let shown = entry.text.count > 160 ? String(entry.text.prefix(160)) + "…" : entry.text
            let escaped = shown.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
            lines.append("\(index)\t\(String(entry.hash, radix: 16))\t\(escaped)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String) -> [(hash: UInt64, text: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let hash = UInt64(parts[1], radix: 16) else { return nil }
            return (hash, String(parts[2]))
        }
    }
}
