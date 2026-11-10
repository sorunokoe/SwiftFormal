import Foundation

// `swiftformal check` reads the walks' results from Swift Testing's event stream (plan item U12): every
// `Prove` attaches its JSON line, and a known issue is an issue event with `isKnown`. Measured on Swift 6.4:
// stream versions 0 and 1 drop warning issues but carry an attachment's bytes inline; 6.3 and 6.4 keep warnings and
// name the file an attachment was saved to, only with `--attachments-path`; an unknown version makes `swift test`
// fail before any test runs.

extension Check {
    // MARK: the test event stream (plan item U12)

    /// Environment variable that makes `Prove` attach every report's JSON line, proofs too, so that the event
    /// stream holds every walk's result.
    public static let walkEventsVariable = "SWIFTFORMAL_WALK_EVENTS"

    /// What the walks reported, and where it was read from.
    public struct WalkResults: Sendable {
        /// One per `Prove` that ran.
        public var records: [WalkRecord]
        /// `File.swift:line` of each walk whose failure a test marks as known (`withKnownIssue`).
        public var knownIssues: Set<String>
        /// The event stream or the side file.
        public var source: WalkResultSource
    }

    /// Where the walk results were read from.
    public enum WalkResultSource: Sendable, Equatable {
        /// Swift Testing's event stream: attachments for the results, issue events for the known issues.
        case eventStream
        /// The `SWIFTFORMAL_WALK_LOG` side file, and the console text for the known issues.
        case sideFile
    }

    /// The `--event-stream-version` to ask `swift test` for: the toolchain's own from Swift 6.3 (6.4 for anything
    /// newer, the newest this reads), nil before 6.3, whose streams drop warning issues. An unsupported version makes
    /// `swift test` fail without running a test, so nothing older or newer is guessed.
    public static func eventStreamVersion(compilerVersion: String) -> String? {
        guard let range = compilerVersion.range(of: "Swift version ") else { return nil }
        let numbers = compilerVersion[range.upperBound...].prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        let version = (numbers[0], numbers[1])
        if version < (6, 3) { return nil }
        return version < (6, 4) ? "6.3" : "6.4"
    }

    /// The event stream written next to `log`.
    public static func eventStreamPath(log: String) -> String { log + ".events.jsonl" }

    /// The directory the attachments are saved to, next to `log`.
    static func attachmentsPath(log: String) -> String { log + ".attachments" }

    /// `swift test` arguments for an event stream of `version` next to `log`; none without a version.
    static func eventStreamArguments(log: String, version: String?) -> [String] {
        guard let version else { return [] }
        return [
            "--event-stream-output-path", eventStreamPath(log: log), "--event-stream-version", version, "--attachments-path",
            attachmentsPath(log: log),
        ]
    }

    /// The walk results of an event stream (one JSON object per line): `*.walk.json` attachments, read from the file
    /// the event names or from its inline bytes (stream versions 0 and 1), and the `file:line` of each known issue.
    /// Unreadable lines are skipped.
    public static func readEventStream(_ text: String) -> (records: [WalkRecord], knownIssues: Set<String>) {
        var records: [WalkRecord] = []
        var known: Set<String> = []
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            guard let event = try? decoder.decode(StreamLine.self, from: Data(line.utf8)), event.kind == "event",
                let payload = event.payload
            else { continue }
            if payload.kind == "valueAttached", let attachment = payload.attachment {
                let name = attachment.path ?? attachment.preferredName ?? ""
                guard name.hasSuffix(".walk.json") else { continue }
                let saved = attachment.path.flatMap { FileManager.default.contents(atPath: $0) }
                let data = saved ?? attachment.bytes.flatMap { Data(base64Encoded: $0) }
                if let data, let record = try? decoder.decode(WalkRecord.self, from: data) { records.append(record) }
            } else if payload.kind == "issueRecorded", let issue = payload.issue, issue.isKnown,
                let location = issue.sourceLocation, let path = location.filePath ?? location.fileID
            {
                known.insert("\(URL(fileURLWithPath: path).lastPathComponent):\(location.line)")
            }
        }
        return (records, known)
    }

    /// The results of the walks `runWalks` ran with `log`: from the event stream when it holds at least one walk
    /// result, else from the side file and the console output `testOutput`.
    public static func walkResults(log: String, testOutput: String) -> WalkResults {
        if let text = try? String(contentsOfFile: eventStreamPath(log: log), encoding: .utf8) {
            let streamed = readEventStream(text)
            if !streamed.records.isEmpty {
                return WalkResults(records: streamed.records, knownIssues: streamed.knownIssues, source: .eventStream)
            }
        }
        return WalkResults(records: readWalkLog(log), knownIssues: knownIssues(inTestOutput: testOutput), source: .sideFile)
    }
}

/// The parts of one line of Swift Testing's event stream that `Check.readEventStream` reads.
private struct StreamLine: Decodable {
    var kind: String
    var payload: StreamPayload?
}

/// An event: `valueAttached` with an attachment, `issueRecorded` with an issue, and others this does not read.
private struct StreamPayload: Decodable {
    var kind: String
    var attachment: StreamAttachment?
    var issue: StreamIssue?
}

/// Where an attachment was saved (`--attachments-path`), or its bytes (stream versions 0 and 1).
private struct StreamAttachment: Decodable {
    enum CodingKeys: String, CodingKey {
        case path
        case bytes = "_bytes"
        case preferredName = "_preferredName"
    }

    var path: String?
    var bytes: String?
    var preferredName: String?
}

/// An issue: whether a test marked it as known, and where it was recorded.
private struct StreamIssue: Decodable {
    struct Location: Decodable {
        var filePath: String?
        var fileID: String?
        var line: Int
    }

    var isKnown: Bool
    var sourceLocation: Location?
}
