import Foundation
import SFBV
import SFCNF
import SFProve
import SFSIL
import Testing

/// Plan item L5: final classes without a superclass or deinit, read as their stored properties, one reference each.
@Suite struct SILClassTests {
    static let source = """
        public final class Counter {
            public var count: Int8 = 0
            public var limit: Int8 = 10
            public init() {}
            public func bump() { count += 1 }
            public func bumpBelow() { if count < limit { count += 1 } }
        }
        public func freshSafe(_ n: Int8) -> Int8 { let c = Counter(); c.count = n; c.bumpBelow(); return c.count }
        public func freshTraps(_ n: Int8) -> Int8 { let c = Counter(); c.count = n; c.bump(); return c.count }
        public func initialized(_ x: Int8) -> Int8 { let c = Counter(); return c.limit / (c.count + 1) &+ x }
        public func same(_ c: Counter) -> Counter { c }
        public func made() -> Counter { let c = Counter(); c.count = 100; return c }
        // `r` is `c`: the increment sees the 127 written through `c`.
        public func aliasTraps(_ x: Int8) -> Int8 {
            let c = Counter(); c.count = 0
            let r = same(c)
            c.count = x
            r.count += 1
            return r.count
        }
        // A new object is a new object: writing to `c` afterwards does not change `m`.
        public func madeIsFresh(_ x: Int8) -> Int8 { let m = made(); let c = Counter(); c.count = x; return m.count + 27 }
        public func onParameter(_ c: Counter) -> Int8 { c.bumpBelow(); return c.count }

        public class Open { public var x: Int8 = 0; public init() {} }
        public func useOpen(_ o: Open) -> Int8 { o.x }
        public final class Child: Base { public var y: Int8 = 0 }
        public class Base { public init() {} }
        public func useChild(_ c: Child) -> Int8 { c.y }
        // An empty deinit runs no code: the class is read.
        public final class WithDeinit { public var x: Int8 = 0; deinit { } }
        public func useDeinit(_ w: WithDeinit) -> Int8 { w.x &+ 1 }
        public final class Holder { public var inner: Counter = Counter() }
        public func useHolder(_ h: Holder) -> Int8 { h.inner.count }
        public struct Wrap { public var c: Counter }
        public func useWrap(_ w: Wrap) -> Int8 { w.c.count }
        public func two(_ a: Counter, _ b: Counter) -> Int8 { a.count &+ b.count }
        public func addTo(_ x: inout Int8, _ c: Counter) { x &+= c.count }
        public func overlap(_ c: Counter) { addTo(&c.count, c) }
        """

    static let module = try! SILCompiler.module(source: source, name: "Cls", optimization: .none)

    static func verdict(_ name: String) throws -> ProofVerdict {
        try SILVerifier.prove(try module.symbol(module: "Cls", name: name), in: module)
    }

    @Test func objectsCreatedHereAreReadAsTheirFields() throws {
        #expect(try Self.verdict("freshSafe") == .proved)
        #expect(try Self.verdict("initialized") == .proved)
        guard case .counterexample(let n) = try Self.verdict("freshTraps") else {
            Issue.record("bump overflows at 127")
            return
        }
        #expect(n == [127])
    }

    /// `same(c)` returns its parameter: the caller must bind the result to `c` itself, not to a copy of its fields.
    @Test func aReturnedParameterIsTheSameObject() throws {
        guard case .counterexample(let x) = try Self.verdict("aliasTraps") else {
            Issue.record("r is c: r.count += 1 overflows when x is 127")
            return
        }
        #expect(x == [127])
    }

    @Test func aCreatedObjectIsNew() throws {
        #expect(try Self.verdict("madeIsFresh") == .proved)
    }

    /// The encoding of a method on a parameter is exact; whether a caller holds an access is decided above (`SFVerifyKit`).
    @Test func aClassParameterIsItsFields() throws {
        let function = try Self.module.function(try Self.module.symbol(module: "Cls", name: "onParameter"))
        #expect(function.objectParameter == 0)
        #expect(function.parameterWidths == [8, 8])
        #expect(try Self.verdict("onParameter") == .proved)
    }

    @Test func anEmptyDeinitIsNoCode() throws {
        #expect(try Self.verdict("useDeinit") == .proved)
    }

    /// A deinit that can trap may run at any release, which logic does not encode: no class of the module is read.
    @Test func aDeinitThatRunsCodeRefusesEveryClass() throws {
        let module = try SILCompiler.module(
            source: Self.source + "\npublic final class Loud { public var x: Int8 = 0; deinit { precondition(x == 0) } }",
            name: "Cls", optimization: .none)
        #expect(throws: SILError.self) { _ = try SILVerifier.prove(try module.symbol(module: "Cls", name: "freshSafe"), in: module) }
    }

    @Test(arguments: ["useOpen", "useChild", "useHolder", "useWrap", "two", "overlap"])
    func everyOtherReferenceIsRefused(_ name: String) {
        #expect(throws: SILError.self, "\(name)") { _ = try Self.verdict(name) }
    }
}
