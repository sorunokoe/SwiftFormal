import Foundation
import SFVerifyKit
import Testing

/// Plan item K1: rebuilding one target must not delete the build folder of its whole package. With Swift Build a
/// target named like its package (`Foo` in package `Foo`) shares the name of `Intermediates.noindex/Foo.build`, which
/// holds every target; deleting it made the first `sfverify --build` fail.
@Suite struct SwiftPMProductsTests {
    @Test func onlyTheTargetsOwnFoldersAreRemoved() throws {
        let scratch = NSTemporaryDirectory() + "sfv-k1-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let fm = FileManager.default
        let package = scratch + "/out/Intermediates.noindex/Foo.build"
        let paths = [
            package + "/Debug/Foo-t.build/x", package + "/Debug/Foo-p.build/x", package + "/Debug/Bar-t.build/x",
            scratch + "/arm64-apple-macosx/debug/Foo.build/x", scratch + "/arm64-apple-macosx/debug/Bar.build/x",
        ]
        for path in paths {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        SwiftPMBuild.removeProducts(of: "Foo", in: scratch)
        #expect(fm.fileExists(atPath: package), "the package's folder holds every target and must stay")
        #expect(fm.fileExists(atPath: package + "/Debug/Bar-t.build"))
        #expect(!fm.fileExists(atPath: package + "/Debug/Foo-t.build"))
        #expect(!fm.fileExists(atPath: package + "/Debug/Foo-p.build"))
        #expect(!fm.fileExists(atPath: scratch + "/arm64-apple-macosx/debug/Foo.build"))
        #expect(fm.fileExists(atPath: scratch + "/arm64-apple-macosx/debug/Bar.build"))
    }

    @Test func aFlagNamingABuildOnlyFileIsDropped() {
        let kept = SwiftPMBuild.filter(["-const-gather-protocols-list", "/tmp/x.json", "-D", "DEBUG"])
        #expect(kept == ["-D", "DEBUG"])
    }
}
