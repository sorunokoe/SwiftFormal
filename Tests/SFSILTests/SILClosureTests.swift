import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL

/// Closures in real `swiftc -Onone` output: a closure is an opaque value that can be made, stored, passed and
/// destroyed, but never called.
enum ClosureFixture {
    static let types = """
        public struct Field: Equatable, Sendable {
            public var value: String = ""
            public var isChanged: Bool = false
            public var validator: @Sendable (String) -> [String] = { _ in [] }
            public init() {}
            public static func == (l: Self, r: Self) -> Bool { l.value == r.value && l.isChanged == r.isChanged }
        }
        public struct Client: Sendable {
            public var load: @Sendable () -> Int8
            public var onDone: @MainActor @Sendable () -> Void
            public var onTap: (@Sendable () -> Void)?
            public var count: Int8
        }

        public func touched(_ s: Field) -> Bool { s.isChanged }
        public func reset(_ s: inout Field) { s.isChanged = false }
        public func fresh() -> Field { Field() }
        public func with(_ v: @escaping @Sendable (String) -> [String]) -> Field { var s = Field(); s.validator = v; return s }
        public func client(_ n: Int8) -> Client { Client(load: { n }, onDone: {}, onTap: nil, count: n) }
        public func same(_ a: Field, _ b: Field) -> Bool { a == b }
        public func handlers(_ c: Client) -> Int { [c.onDone, c.onDone].count }
        public func next(_ c: Client) -> Int8 { c.count + 1 }
        public func call(_ c: Client) -> Int8 { c.load() }
        """
    static func module(_ extra: String) throws -> SILModule {
        try SILCompiler.module(source: "import Observation\n" + types + "\n" + extra, name: "Clo", optimization: .none)
    }
    /// Deinits that only release, read or call code outside the read modules: implicit ones, an actor, an observable
    /// class (what `@Observable` expands to), a subclass, a deinit that cancels a task.
    static let quiet = try! module(
        """
        public final class Box { public var f: () -> Void = {}; public init() {} }
        public actor Worker { var n = 0 }
        public final class Model { let registrar = ObservationRegistrar(); public var n = 0; public init() {} }
        open class Base { public init() {} }
        public final class Sub: Base { var g: (Int) -> Int = { $0 } }
        public final class Job { var t: Task<Void, Never>?; public init() {}; deinit { t?.cancel() } }
        """)
    static func verdict(_ name: String, in module: SILModule = quiet) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try module.symbol(module: "Clo", name: name), in: module, ensures: { c, _, _ in c.trueLit })
    }
    static func rejection(_ name: String, in module: SILModule = quiet) -> String? {
        do {
            _ = try verdict(name, in: module)
            return nil
        } catch {
            return "\(error)"
        }
    }
}

@Suite(.tags(.slow)) struct SILClosureTests {
    @Test func valuesHoldingClosuresAreProved() throws {
        for name in ["touched", "reset", "fresh", "with", "client", "same", "handlers"] {
            #expect(try ClosureFixture.verdict(name) == .proved, "\(name)")
        }
    }

    @Test func aTrapNextToAClosureIsStillFound() throws {
        // The input's leaves are its closures (opaque handles), the optional closure, then `count`.
        guard case .counterexample(let inputs) = try ClosureFixture.verdict("next") else { Issue.record("count + 1 overflows"); return }
        #expect(inputs.last == 127, "\(inputs)")
    }

    @Test func callingAClosureIsNotRead() throws {
        let reason = try #require(ClosureFixture.rejection("call"))
        #expect(reason.contains("indirect call through a closure"), "\(reason)")
    }

    @Test(arguments: [
        "public final class Loud { var n = 0; deinit { precondition(n >= 0) } }",
        "public final class Count { nonisolated(unsafe) static var n = 0; deinit { Count.n += 0 } }",
        "public final class Calls { deinit { print(1) } }",
        "public final class Index { var a: [Int] = []; deinit { _ = a[3] } }",
        "public final class Stop { deinit { fatalError() } }",
        "public final class Own { func f() {}; deinit { f() } }",
        "import Foundation\npublic final class Bytes { var d = Data(); deinit { _ = d[3] } }",
        """
        public final class Job2 { var t: Task<Void, Never>?; deinit { t?.cancel() } }
        public func guarded() async { await withTaskCancellationHandler { } onCancel: { precondition(false) } }
        """,
    ])
    func aDeinitThatRunsCodeKeepsClosuresOut(_ declaration: String) throws {
        // Destroying a closure releases its captures, which may run this deinit: no closure is read in such a module.
        let module = try ClosureFixture.module(declaration)
        let reason = try #require(ClosureFixture.rejection("touched", in: module))
        #expect(reason.contains("destroying a closure may run a deinit"), "\(reason)")
    }
}
