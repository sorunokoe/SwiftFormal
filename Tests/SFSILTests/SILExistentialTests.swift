import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL

/// Existentials in real `swiftc -Onone` output: an `any P` is an opaque value that can be stored, copied, passed and
/// destroyed, but never opened to call a requirement.
enum ExistentialFixture {
    static let types = """
        public protocol Tracker: Sendable { func track(_ e: String) }
        public protocol RefTracker: AnyObject { func track(_ e: String) }
        public struct Store: Sendable {
            let load: @Sendable () -> Int8
            let tracker: any Tracker
            var count: Int8 = 0
            public init(load: @escaping @Sendable () -> Int8, tracker: any Tracker) { self.load = load; self.tracker = tracker }
        }
        public struct Config { public var tracker: Tracker; public var n: Int8 }
        public func make(_ c: Config) -> Store { Store(load: { 0 }, tracker: c.tracker) }
        public func trackerOf(_ s: Store) -> any Tracker { s.tracker }
        public func swap(_ c: inout Config, _ t: any Tracker) { c.tracker = t }
        public func pick(_ a: any Tracker, _ b: any Tracker, _ first: Bool) -> any Tracker { first ? a : b }
        public func maybe(_ t: (any Tracker)?) -> Bool { t != nil }
        public func next(_ s: Store) -> Int8 { s.count + 1 }
        public func fire(_ s: Store) { s.tracker.track("x") }
        public func ref(_ r: any RefTracker, _ n: Int8) -> Int8 { _ = r; return n &+ 1 }
        public func keep(_ r: any RefTracker) -> any RefTracker { r }
        public func err(_ e: any Error, _ n: Int8) -> Int8 { n &+ 1 }
        public struct Named: Tracker { public func track(_ e: String) {} }
        public func wrap() -> any Tracker { Named() }
        public struct Holder { public let t: any Tracker; public let n: Int8 }
        public func show(_ t: any Tracker) -> String { "\\(t)" }
        public func show2(_ t: any Tracker) -> String { String(describing: t) }
        public func showHolder(_ h: Holder) -> String { "\\(h)" }
        public func showArray(_ t: [any Tracker]) -> String { "\\(t)" }
        public func showMaybe(_ t: (any Tracker)?) -> String { "\\(t as Any)" }
        public func showError(_ e: any Error) -> String { "\\(e)" }
        """
    static func module(_ extra: String = "") throws -> SILModule {
        try SILCompiler.module(source: types + "\n" + extra, name: "Ex", optimization: .none)
    }
    static let plain = try! module()
    static func verdict(_ name: String, in module: SILModule = plain) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try module.symbol(module: "Ex", name: name), in: module, ensures: { c, _, _ in c.trueLit })
    }
    static func rejection(_ name: String, in module: SILModule = plain) -> String? {
        do {
            _ = try verdict(name, in: module)
            return nil
        } catch {
            return "\(error)"
        }
    }
}

@Suite(.tags(.slow)) struct SILExistentialTests {
    @Test func valuesHoldingExistentialsAreProved() throws {
        for name in ["make", "trackerOf", "swap", "pick", "maybe", "ref", "keep", "err"] {
            #expect(try ExistentialFixture.verdict(name) == .proved, "\(name): \(ExistentialFixture.rejection(name) ?? "")")
        }
    }

    @Test func aTrapNextToAnExistentialIsStillFound() throws {
        guard case .counterexample(let inputs) = try ExistentialFixture.verdict("next") else {
            Issue.record("count + 1 overflows")
            return
        }
        #expect(inputs.last == 127, "\(inputs)")
    }

    @Test func callingARequirementIsNotRead() throws {
        let reason = try #require(ExistentialFixture.rejection("fire"))
        #expect(reason.contains("open_existential"), "\(reason)")
    }

    @Test func printingAnExistentialIsNotRead() throws {
        // Printing one runs the description of the value inside, which may trap.
        for name in ["show", "show2", "showHolder", "showArray", "showError"] {
            let reason = try #require(ExistentialFixture.rejection(name), "\(name)")
            #expect(reason.contains("existential") || reason.contains("any "), "\(name): \(reason)")
        }
        #expect(ExistentialFixture.rejection("showMaybe") != nil)
    }

    @Test func makingAnExistentialIsNotRead() throws {
        // Boxing a concrete value would need its conformance; that is out of scope, so it is refused, not guessed.
        let reason = try #require(ExistentialFixture.rejection("wrap"))
        #expect(reason.contains("init_existential"), "\(reason)")
    }

    @Test func aDeinitThatRunsCodeKeepsExistentialsOut() throws {
        // Destroying an existential destroys the value inside, which may run this deinit.
        let module = try ExistentialFixture.module(
            "public final class Stop: RefTracker { public func track(_ e: String) {}; deinit { fatalError() } }")
        let reason = try #require(ExistentialFixture.rejection("keep", in: module))
        #expect(reason.contains("may run a deinit"), "\(reason)")
    }
}
