import Foundation
import SFTestSupport
import SFVerifyKit
import Testing

/// App study round 6 (L19): playback tests of methods and getters compile and reproduce on the real binary. `--confirm`
/// builds the scanned file with the generated tests in a scratch package and runs each one alone.
@Suite(.tags(.oracle), .requiresPinnedCompiler) struct MethodPlaybackOracleTests {
    static let source = """
        enum Tab: CaseIterable { case recent, saved }

        enum Kind {
            case plain
            case sized(width: Int8, height: Int8)
            var share: Int8 {
                switch self {
                case .plain: return 1
                case .sized(let w, let h): return w / h
                }
            }
        }

        struct State {
            var _selectedTabIndex: Int
            var selectedTabIndex: Int = 0 {
                @storageRestrictions(initializes: _selectedTabIndex)
                init(initialValue) { _selectedTabIndex = initialValue }
                get { _selectedTabIndex }
                set { _selectedTabIndex = newValue }
            }
            var items: [Int] = []
            var title: String = ""
            var small: UInt8 = 7
            var kind: Kind? = nil
            var selectedTab: Tab { Tab.allCases[selectedTabIndex] }
            mutating func bump(by amount: UInt8) { small += amount }
            func label(_ k: Int8) -> Int8 { title == "Fairway" ? k + 100 : 0 }
        }

        struct Maker {
            static func make(_ x: Int8) -> Int8 { x + 100 }
        }
        """

    @Test func methodPlaybackTestsReproduceNatively() throws {
        let directory = NSTemporaryDirectory() + "sfv-l19-oracle-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/Tabs.swift"
        try Self.source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Tabs"), options)
        let (tests, skipped) = Playback.tests(for: report)
        let replayed = Set(tests.map(\.function))
        for name in ["Kind.share.getter", "State.selectedTab.getter", "State.bump(by:)", "State.label(_:)", "static Maker.make(_:)"] {
            #expect(replayed.contains(name), "\(name): \(skipped)")
        }
        let confirmation = try Playback.confirm(report, files: [file], arguments: [], swift: try Playback.swiftDriver())
        #expect(confirmation.exact)
        #expect(confirmation.outcomes.count == tests.count)
        #expect(confirmation.outcomes.values.allSatisfy { $0 }, "\(confirmation.outcomes)\n\(Playback.file(for: report))")
    }
}
