import Foundation
import SFVerifyKit
import Testing

/// App study round 6, L5: an `ensures` that reads an array element (which logic does not model) made the whole contract
/// `undecided`, and so hid an index trap that does not depend on the element. The trap must still be reported, as the
/// contract's failure with its input; an ensures whose trap does depend on the element stays undecided. The arrays are
/// stored properties, whose elements logic does not know; the elements of a literal array are known (`literalSource`).
@Suite struct UndecidedEnsuresTrapTests {
    static let source = """
        public enum Tab: String, Equatable, Sendable, CaseIterable { case recent, saved }

        public struct Store {
            public var tabs: [Tab]
            public var selectedTabIndex: Int
            public var selectedTab: Tab { tabs[selectedTabIndex] }
            #sourceLocation(file: "@__swiftmacro_3App11selectedTab6VerifyfMp_.swift", line: 1)
            func selectedTab_ensures(_ result: Tab) -> Bool {
                result.rawValue == (selectedTabIndex == 0 ? "recent" : "saved")
            }
            #sourceLocation()
        }

        public struct Guarded {
            public var tabs: [Tab]
            public var selectedTabIndex: Int
            public var selectedTab: Tab { tabs[selectedTabIndex] }
            #sourceLocation(file: "@__swiftmacro_3App11selectedTab6VerifyfMp_.swift", line: 1)
            func selectedTab_requires() -> Bool { tabs.count == 2 && selectedTabIndex >= 0 && selectedTabIndex <= 1 }
            func selectedTab_ensures(_ result: Tab) -> Bool {
                result.rawValue == (selectedTabIndex == 0 ? "recent" : "saved")
            }
            #sourceLocation()
        }

        public struct Divider {
            public var index: Int8
            public var divisors: [Int8]
            public var share: Int8 { 100 / divisors[Int(index & 1)] }
            #sourceLocation(file: "@__swiftmacro_3App5share6VerifyfMp_.swift", line: 1)
            func share_requires() -> Bool { divisors.count == 2 }
            func share_ensures(_ result: Int8) -> Bool { result <= 100 }
            #sourceLocation()
        }
        """

    static let literalSource = """
        public enum Tab: String, Equatable, Sendable, CaseIterable { case recent, saved }

        public struct Store {
            public var selectedTabIndex: Int
            public var selectedTab: Tab { Tab.allCases[selectedTabIndex] }
            #sourceLocation(file: "@__swiftmacro_3App11selectedTab6VerifyfMp_.swift", line: 1)
            func selectedTab_ensures(_ result: Tab) -> Bool {
                result.rawValue == (selectedTabIndex == 0 ? "recent" : "saved")
            }
            #sourceLocation()
        }

        public struct Guarded {
            public var selectedTabIndex: Int
            public var selectedTab: Tab { Tab.allCases[selectedTabIndex] }
            #sourceLocation(file: "@__swiftmacro_3App11selectedTab6VerifyfMp_.swift", line: 1)
            func selectedTab_requires() -> Bool { selectedTabIndex >= 0 && selectedTabIndex <= 1 }
            func selectedTab_ensures(_ result: Tab) -> Bool {
                result.rawValue == (selectedTabIndex == 0 ? "recent" : "saved")
            }
            #sourceLocation()
        }

        public struct Divider {
            public var index: Int8
            var divisors: [Int8] { [1, 2] }
            public var share: Int8 { 100 / divisors[Int(index & 1)] }
            #sourceLocation(file: "@__swiftmacro_3App5share6VerifyfMp_.swift", line: 1)
            func share_ensures(_ result: Int8) -> Bool { result <= 100 }
            #sourceLocation()
        }
        """

    @Test func aTrapThatDoesNotDependOnTheElementBreaksTheContract() throws {
        let report = try ExplainTests.scan(Self.source)
        let f = try #require(report.functions.first { $0.name == "Store.selectedTab.getter" })
        #expect(f.hasContract)
        #expect(f.status == .contractFails, "\(f.status) \(f.detail ?? "")")
        let example = try #require(f.counterexample)
        #expect(example.failure.contains("Index out of range"), "\(example.failure)")
        // Found either by the first proof or, when the solver first picks an index whose unknown element breaks the
        // ensures, by the proof without the ensures ("the ensures alone is undecided"); either way it is reported.
        if let detail = f.detail, detail.contains("ensures") { #expect(detail.contains("ensures alone is undecided"), "\(detail)") }
    }

    /// With the index bounded by `requires`, nothing traps: the ensures on the element is all that is left, undecided.
    @Test func withTheTrapExcludedTheEnsuresStaysUndecided() throws {
        let report = try ExplainTests.scan(Self.source)
        let f = try #require(report.functions.first { $0.name == "Guarded.selectedTab.getter" })
        #expect(f.status == .undecided, "\(f.status) \(f.detail ?? "")")
        #expect(f.category == Verifier.unmodelledCategory)
    }

    /// The division traps only for some element (zero), which logic does not model: never reported as a trap.
    @Test func aTrapThatDependsOnTheElementStaysUndecided() throws {
        let report = try ExplainTests.scan(Self.source)
        let f = try #require(report.functions.first { $0.name == "Divider.share.getter" })
        #expect(f.status == .undecided, "\(f.status) \(f.detail ?? "") \(f.counterexample?.failure ?? "")")
    }

    /// The same shapes over literal arrays (`Tab.allCases`, `[1, 2]`): their elements are known, so what was undecided
    /// above is decided — the guarded contract holds, the divisor is never zero, and the unguarded getter still breaks
    /// its contract at an index out of range.
    @Test func literalArraysDecideTheSameShapes() throws {
        let report = try ExplainTests.scan(Self.literalSource)
        let store = try #require(report.functions.first { $0.name == "Store.selectedTab.getter" })
        #expect(store.status == .contractFails, "\(store.status) \(store.detail ?? "")")
        #expect(store.counterexample?.failure.contains("Index out of range") == true, "\(store.counterexample?.failure ?? "")")
        let guarded = try #require(report.functions.first { $0.name == "Guarded.selectedTab.getter" })
        #expect(guarded.status == .contractHolds, "\(guarded.status) \(guarded.detail ?? "")")
        let divider = try #require(report.functions.first { $0.name == "Divider.share.getter" })
        #expect([.contractHolds, .safe].contains(divider.status), "\(divider.status) \(divider.detail ?? "")")
    }
}
