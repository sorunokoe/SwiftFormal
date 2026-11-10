import Foundation
import SFSIL
import Testing

@testable import SFVerifyKit

/// Where the proof cache's directory is, and which tool is running.
@Suite struct ScanToolIdentityTests {
    #if canImport(Darwin)
        /// The tool's identity is the image the encoder runs from, read from memory, not the process's main executable
        /// (which, for a library user or a test, is the host and does not change with the encoder) and not a file that
        /// can be rebuilt while the process runs.
        @Test func theToolIsTheLoadedImageThatHoldsTheEncoderNotTheMainExecutable() throws {
            let identity = try #require(ScanToolIdentity.current)
            var info = Dl_info()
            let encoder = unsafeBitCast(SILModule.self as Any.Type, to: UnsafeRawPointer.self)
            #expect(dladdr(encoder, &info) != 0)
            let image = String(cString: try #require(info.dli_fname))
            #expect(image != Bundle.main.executablePath)
            let dump = Process()
            dump.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            dump.arguments = ["dwarfdump", "--uuid", image]
            let pipe = Pipe()
            dump.standardOutput = pipe
            try dump.run()
            let text = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            dump.waitUntilExit()
            let onDisk = try #require(text.split(separator: " ").dropFirst().first.map(String.init))
            #expect(identity.split(separator: ",").map(String.init) == [onDisk])
        }

        @Test func anAddressOutsideEveryImageHasNoIdentity() {
            let heap = NSObject()
            #expect(ScanToolImages.image(containing: UInt(bitPattern: ObjectIdentifier(heap))) == nil)
            #expect(ScanToolImages.identity(of: [SILModule.self, Int.self])?.split(separator: ",").count == 2)
        }

    #endif

    /// A relative `--proof-cache` is the directory under the current one, trusted like any other.
    @Test func aRelativeCacheDirectoryIsTheOneUnderTheCurrentDirectory() throws {
        let relative = ".build/sfv-relative-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: relative) }
        let cache = ScanProofCache(directory: relative, versions: "test")
        #expect(cache.directory == FileManager.default.currentDirectoryPath + "/" + relative)
        cache.store(ScanProofEntry(key: "sha256:" + String(repeating: "a", count: 64), values: nil, approximations: [], symbol: "f"))
        #expect(cache.lookup("sha256:" + String(repeating: "a", count: 64)) != nil)
        #expect(cache.use.trusted)
    }
}
