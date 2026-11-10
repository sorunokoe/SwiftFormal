import Foundation
import Testing

@testable import SFVerifyKit

/// Plan item U12: `swiftformal check` reads the walks' results and the known issues from Swift Testing's event stream
/// (`--event-stream-output-path`), and falls back to the `SWIFTFORMAL_WALK_LOG` side file and the console text.
@Suite struct CheckEventStreamTests {
    private static let walk =
        #"{"subject":"Speed -> label","verdict":"proved","evaluated":3,"domainSize":3,"domainComplete":true,"properties":[],"file":"/p/Tests/ShippingTests/ShippingTests.swift","line":7,"test":"labels()"}"#

    /// Lines as Swift Testing 6.4 writes them (`--event-stream-version 6.4 --attachments-path <dir>`), shortened: an
    /// attachment names the file it was saved to, an issue carries `isKnown` and `severity`.
    private static func stream(attachment: String) -> String {
        """
        {"kind":"test","payload":{"id":"PTests.S/a()/T.swift:4:4","kind":"function","name":"a"},"version":"6.4.0"}
        {"kind":"event","payload":{"attachment":{"path":"\(attachment)"},"kind":"valueAttached","messages":[{"symbol":"_attachment","text":"Attached 'x.walk.json' to a()."}],"testID":"PTests.S/a()/T.swift:4:4"},"version":"6.4.0"}
        {"kind":"event","payload":{"attachment":{"path":"/elsewhere/x.report.txt"},"kind":"valueAttached","testID":"PTests.S/a()/T.swift:4:4"},"version":"6.4.0"}
        {"kind":"event","payload":{"issue":{"isFailure":false,"isKnown":true,"severity":"error","sourceLocation":{"column":34,"fileID":"PTests/ShippingTests.swift","filePath":"/p/Tests/ShippingTests/ShippingTests.swift","line":12}},"kind":"issueRecorded","testID":"PTests.S/a()/T.swift:4:4"},"version":"6.4.0"}
        {"kind":"event","payload":{"issue":{"isFailure":false,"isKnown":false,"severity":"warning","sourceLocation":{"column":17,"fileID":"PTests/T.swift","filePath":"/p/Tests/PTests/T.swift","line":7}},"kind":"issueRecorded","testID":"PTests.S/a()/T.swift:4:4"},"version":"6.4.0"}
        {"kind":"event","payload":{"kind":"runEnded"},"version":"6.4.0"}
        """
    }

    @Test func recordsComeFromAttachmentsAndKnownIssuesFromIssueEvents() throws {
        let directory = NSTemporaryDirectory() + "sfv-events-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // Swift Testing may add a suffix to the name; the path in the event is the one to read.
        let saved = directory + "/Speed_-_label-1ox0j64177tw4.walk.json"
        try Self.walk.write(toFile: saved, atomically: true, encoding: .utf8)
        let read = Check.readEventStream(Self.stream(attachment: saved))
        #expect(read.records.map(\.subject) == ["Speed -> label"])
        #expect(read.records.first?.verdict == "proved")
        #expect(read.knownIssues == ["ShippingTests.swift:12"], "a warning that is not known is not a known issue")
    }

    @Test func versionOneStreamsCarryTheBytesInline() {
        let bytes = Data(Self.walk.utf8).base64EncodedString()
        let line =
            #"{"kind":"event","payload":{"attachment":{"_bytes":"\#(bytes)","_preferredName":"x.walk.json"},"kind":"valueAttached"},"version":1}"#
        #expect(Check.readEventStream(line).records.map(\.line) == [7])
        #expect(Check.readEventStream("not json\n{\"kind\":\"event\"}\n").records.isEmpty, "unreadable lines are skipped")
    }

    @Test func theStreamIsUsedWhenItHasRecordsElseTheSideFileAndTheConsole() throws {
        let directory = NSTemporaryDirectory() + "sfv-results-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let log = directory + "/walks.jsonl"
        let sideRecord = Self.walk.replacingOccurrences(of: "\"line\":7", with: "\"line\":9")
        try (sideRecord + "\n").write(toFile: log, atomically: true, encoding: .utf8)
        let console = "✘ Test labels() recorded a known issue at ShippingTests.swift:9:5: Expectation failed"

        // No stream (an older toolchain, or `swift test` did not write one): the side file and the console.
        let fallback = Check.walkResults(log: log, testOutput: console)
        #expect(fallback.source == .sideFile)
        #expect(fallback.records.map(\.line) == [9])
        #expect(fallback.knownIssues == ["ShippingTests.swift:9"])

        let saved = directory + "/w.walk.json"
        try Self.walk.write(toFile: saved, atomically: true, encoding: .utf8)
        try Self.stream(attachment: saved).write(toFile: Check.eventStreamPath(log: log), atomically: true, encoding: .utf8)
        let streamed = Check.walkResults(log: log, testOutput: console)
        #expect(streamed.source == .eventStream)
        #expect(streamed.records.map(\.line) == [7])
        #expect(streamed.knownIssues == ["ShippingTests.swift:12"])
    }

    @Test func theStreamVersionFollowsTheToolchainFromSwift63() {
        #expect(Check.eventStreamVersion(compilerVersion: "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)") == "6.4")
        #expect(Check.eventStreamVersion(compilerVersion: "Apple Swift version 6.3.1 (swiftlang-6.3.1.1.2 clang-2000.0.1)") == "6.3")
        #expect(Check.eventStreamVersion(compilerVersion: "Swift version 7.1 (swift-7.1-RELEASE)") == "6.4", "newer: the newest one read")
        #expect(Check.eventStreamVersion(compilerVersion: "Apple Swift version 6.2 (swiftlang-6.2.0.1.1)") == nil, "drops warnings")
        #expect(Check.eventStreamVersion(compilerVersion: "something else") == nil)
    }

    @Test func swiftTestGetsTheStreamFlagsAndTheSideFileStaysSwitchedOn() {
        let arguments = Check.eventStreamArguments(log: "/s/walks.jsonl", version: "6.4")
        #expect(
            arguments == [
                "--event-stream-output-path", "/s/walks.jsonl.events.jsonl", "--event-stream-version", "6.4", "--attachments-path",
                "/s/walks.jsonl.attachments",
            ])
        #expect(Check.eventStreamArguments(log: "/s/walks.jsonl", version: nil).isEmpty)
    }
}
