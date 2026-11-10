import Foundation
import Testing

@testable import SFSIL
@testable import SFVerifyKit

/// Plan item H7: the sites `-strict-memory-safety` reported were rewritten without pointers or C variadic calls, and
/// give the same text as before.
@Suite struct StrictMemorySafetyTests {
    @Test func hexMatchesTheFormatItReplaces() {
        for byte in [0, 1, 9, 10, 15, 16, 127, 128, 255] as [UInt8] {
            #expect(ProofDigest.hex(byte, digits: 2) == String(format: "%02x", byte))
        }
        for value in [0, 1, 0xdead_beef, UInt64.max, 0x0123_4567_89ab_cdef] as [UInt64] {
            #expect(ProofDigest.hex(value, digits: 16) == String(format: "%016llx", value))
        }
        // The FNV-1a 128 test vector for the empty input (the offset basis).
        #expect(ProofDigest.fnv1a128([]) == "6c62272e07bb014262b821756295c58d")
    }

    @Test func secondsMatchTheFormatItReplacesInAnyLocale() {
        for value in [0, 0.004, 0.5, 1.234, 12.345678, 99.999, 1234.5] {
            #expect(ScanReport.seconds(value) == String(format: "%.2f", value), "\(value)")
        }
    }

    @Test func isDirectoryFollowsSymbolicLinksAsFileExistsDid() throws {
        let base = NSTemporaryDirectory() + "sfv-dir-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base + "/real", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: base + "/file", contents: Data())
        try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/real")
        #expect(FileManager.default.isDirectory(atPath: base + "/real"))
        #expect(FileManager.default.isDirectory(atPath: base + "/link"))
        #expect(!FileManager.default.isDirectory(atPath: base + "/file"))
        #expect(!FileManager.default.isDirectory(atPath: base + "/missing"))
    }
}
