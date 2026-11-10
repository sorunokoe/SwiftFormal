import Foundation
import SFSIL
import Testing
@testable import SFVerifyKit

/// App study round 6 (L19): the one real trap was a getter on a struct, and `--emit-tests` wrote tests only for free
/// functions over scalars. A counterexample of a method, getter, static method or initializer is replayed when its
/// `self` and arguments can be written in Swift.
@Suite struct MethodPlaybackTests {
    static let source = """
        enum Tab: CaseIterable { case recent, saved }

        enum Kind {
            case plain
            case scaled(Int8)
            case sized(width: Int8, height: Int8)
            var share: Int8 {
                switch self {
                case .plain: return 1
                case .scaled(let k): return 100 / k
                case .sized(let w, let h): return w / h
                }
            }
        }

        // The shape TCA's `@ObservableState` gives a state: backing storage set through an init accessor.
        struct State {
            var _selectedTabIndex: Int
            var selectedTabIndex: Int = 0 {
                @storageRestrictions(initializes: _selectedTabIndex)
                init(initialValue) { _selectedTabIndex = initialValue }
                get { _selectedTabIndex }
                set { _selectedTabIndex = newValue }
            }
            var items: [Int] = []
            var small: UInt8 = 7
            var kind: Kind? = nil
            var selectedTab: Tab { Tab.allCases[selectedTabIndex] }
            func pick(_ k: Int8) -> Int8 { Int8(small) + k }
            mutating func bump(by amount: UInt8) { small += amount }
            // Traps only for some arrays: the replay cannot leave `items` to its default.
            var first: Int { items.count == 3 ? 100 / (selectedTabIndex - selectedTabIndex) : 0 }
        }

        struct Fixed {
            let base: Int8 = 3
            var x: Int8
            var ratio: Int8 { x / (base - base) }
        }

        private struct Hidden {
            var x: Int8
            var double: Int8 { x * 2 }
        }

        struct Custom {
            var a: Int8
            init(b: Int8) { a = b &* 2 }
            var inverse: Int8 { 100 / a }
        }

        struct Maker {
            static func make(_ x: Int8) -> Int8 { x + 100 }
        }

        func useHidden(_ h: Int8) -> Int8 { Hidden(x: h).double }
        """

    static func scan() throws -> ScanReport {
        let directory = NSTemporaryDirectory() + "sfv-l19-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/State.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Tabs"), options)
    }

    @Test func membersOfStructsAndEnumsAreReplayedWithSwiftLiterals() throws {
        let report = try Self.scan()
        func example(_ name: String) throws -> ScanCounterexample {
            let f = try #require(report.functions.first { $0.name == name || $0.name.hasPrefix(name + "(") }, "\(name)")
            #expect(f.status == .mayTrap, "\(f)")
            return try #require(f.counterexample, "\(name)")
        }
        // The app study case: the index is written, the array is left to its default, which the proof allows.
        let tab = try example("State.selectedTab.getter")
        let tabReplay = try #require(tab.replay, "\(tab)")
        #expect(tabReplay.hasPrefix("State(selectedTabIndex: "), "\(tabReplay)")
        #expect(tabReplay.hasSuffix(").selectedTab") && !tabReplay.contains("items:"), "\(tabReplay)")
        // A UInt8 field is written as unsigned, an optional enum with its case.
        #expect(try example("State.pick").replay?.contains("small: ") == true)
        let bump = try #require(try example("State.bump").replay)
        #expect(bump.hasPrefix("{ var value = State(") && bump.contains("; return value.bump(by: "), "\(bump)")
        #expect(try example("Kind.share.getter").replay?.hasPrefix("Kind.") == true)
        #expect(try example("static Maker.make").replay?.hasPrefix("Maker.make(") == true)
        // A `let` with an initial value is left to it: here the trap does not depend on it.
        #expect(try example("Fixed.ratio.getter").replay?.hasPrefix("Fixed(x: ") == true)

        #expect(try example("Hidden.double.getter").noReplay?.contains("private") == true)
        #expect(try example("Custom.inverse.getter").noReplay?.contains("memberwise") == true)
        // Here it does (only an array of three traps), so there is no replay; a `let` that matters is refused the same way.
        #expect(try example("State.first.getter").noReplay?.contains("State.items") == true)

        let (tests, skipped) = Playback.tests(for: report)
        #expect(tests.contains { $0.source.contains("_ = State(selectedTabIndex: ") })
        #expect(skipped.contains { $0.hasPrefix("Hidden.double.getter: no replay (Hidden is private") }, "\(skipped)")
    }

    /// TCA's `@ObservableState` adds `@ObservationStateIgnored var _$observationRegistrar = …()`, which a test cannot
    /// pass; the initializer still counts as memberwise, and the registrar keeps its initial value.
    @Test func aMacroDeclaredPropertyMayBeMissingFromTheInitializer() throws {
        let declaration = TypeDeclarationText(
            header: "struct State : Equatable {",
            members: [
                "@_hasStorage var _selectedTabIndex: Int { get set }",
                "@_hasInitialValue var selectedTabIndex: Int {", "@storageRestrictions(initializes: _selectedTabIndex) init(initialValue)",
                "get", "set", "}",
                "@_hasStorage @_hasInitialValue var _$observationRegistrar: ObservationStateRegistrar { get set }",
                "init(selectedTabIndex: Int = 0)",
            ])
        let initializer = try #require(MemberwiseInitializer(declaration, stored: ["_selectedTabIndex", "_$observationRegistrar"]))
        #expect(initializer.parameters.map(\.label) == ["selectedTabIndex"])
        #expect(initializer.parameters.map(\.field) == [0])
        // A plain property missing from an initializer still means a hand-written one.
        let custom = TypeDeclarationText(
            header: "struct Custom {",
            members: ["@_hasStorage var a: Int { get set }", "@_hasStorage var b: Int { get set }", "init(a: Int)"])
        #expect(MemberwiseInitializer(custom, stored: ["a", "b"]) == nil)
    }
}
