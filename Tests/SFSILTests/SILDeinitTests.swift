import Foundation
import Testing
import SFProve
import SFSIL

/// What destroying a closure, an existential or an object of a read module may run (`SILDeinits.swift`).
enum DeinitFixture {
    static let mappers = """
        public struct Row { public var score: Int8; public var onTap: () -> Void }
        public final class Node { public init() {} }
        public func score(_ row: Row) -> Int8 { row.score }
        public func size(_ nodes: [Node]) -> Int { nodes.count }
        """

    static func module(_ extra: String, opaqueCalls: OpaqueCallMode) throws -> SILModule {
        var module = try SILCompiler.module(source: "import Foundation\n" + mappers + "\n" + extra, name: "Dei", optimization: .none)
        module.opaqueCalls = opaqueCalls
        return module
    }

    /// The verdict on `name`, and the assumptions its encoding recorded.
    static func verdict(_ name: String, in module: SILModule) throws -> (verdict: ProofVerdict, assumptions: [String]) {
        let assumptions = Assumptions()
        let verdict = try Assumptions.$current.withValue(assumptions) {
            try SILVerifier.proveAggregate(try module.symbol(module: "Dei", name: name), in: module, ensures: { c, _, _ in c.trueLit })
        }
        return (verdict, assumptions.all)
    }
}

@Suite(.tags(.slow)) struct SILDeinitTests {
    static let trapping = "public final class Loud { var n: Int8 = 0; deinit { precondition(n >= 0) } }"

    @Test func anObjectiveCSubclassWhoseDeinitOnlyCallsSuperRunsNoCode() throws {
        // `NSObject`'s `-dealloc`, called through `objc_super_method`, is code of the SDK, not of the read modules.
        let module = try DeinitFixture.module("public final class Delegate: NSObject { var n = 0 }", opaqueCalls: .objectiveC)
        for name in ["score", "size"] {
            let result = try DeinitFixture.verdict(name, in: module)
            #expect(result.verdict == .proved && result.assumptions.isEmpty, "\(name): \(result)")
        }
    }

    @Test func aDeinitThatRunsCodeIsAnAssumptionThatNamesItsClass() throws {
        let module = try DeinitFixture.module(Self.trapping, opaqueCalls: .all)
        for name in ["score", "size"] {
            // The same function twice: the parsed body is cached, and the assumption must be listed both times.
            for _ in 0..<2 {
                let result = try DeinitFixture.verdict(name, in: module)
                #expect(result.verdict == .proved, "\(name): \(result.verdict)")
                #expect(result.assumptions == [DeinitAssumption.text("Loud")], "\(name): \(result.assumptions)")
            }
        }
        #expect(DeinitAssumption.text("Loud").contains("deinit of Loud does not trap"))
    }

    @Test(arguments: [OpaqueCallMode.objectiveC, .none])
    func withoutOpaqueCallsADeinitThatRunsCodeKeepsClosuresAndObjectsOut(_ mode: OpaqueCallMode) throws {
        let module = try DeinitFixture.module(Self.trapping, opaqueCalls: mode)
        for name in ["score", "size"] {
            #expect(throws: SILError.self, "\(name)") { try DeinitFixture.verdict(name, in: module) }
        }
    }

    /// A superclass outside the read modules has a deinit Scan cannot inspect; only `NSObject`'s is known to run no
    /// code. Any other is an assumption that names the superclass, refused without opaque calls.
    @Test func anUnreadSuperclassDeinitIsAnAssumptionThatNamesIt() throws {
        let source = "public final class Job: Operation { var n = 0 }"
        let module = try DeinitFixture.module(source, opaqueCalls: .all)
        for name in ["score", "size"] {
            let result = try DeinitFixture.verdict(name, in: module)
            #expect(result.verdict == .proved, "\(name): \(result.verdict)")
            #expect(result.assumptions == [DeinitAssumption.text("Operation")], "\(name): \(result.assumptions)")
        }
        for mode in [OpaqueCallMode.objectiveC, .none] {
            let strict = try DeinitFixture.module(source, opaqueCalls: mode)
            #expect(throws: SILError.self) { try DeinitFixture.verdict("score", in: strict) }
        }
    }

    @Test func aSuperclassOfTheReadModulesIsInspected() throws {
        // `Leaf`'s `-dealloc` calls `Mid`'s, which calls `NSObject`'s; `Sub`'s deinit calls `Base`'s.
        let source = """
            public class Mid: NSObject { var n = 0 }
            public final class Leaf: Mid { var m = 0 }
            public class Base { var n: Int8 = 0 }
            public final class Sub: Base { var m: Int8 = 0 }
            """
        let module = try DeinitFixture.module(source, opaqueCalls: .objectiveC)
        let result = try DeinitFixture.verdict("score", in: module)
        #expect(result.verdict == .proved && result.assumptions.isEmpty, "\(result)")
    }

    @Test func objectsOfAReadModuleDestroyWithoutCodeWhenNoDeinitRunsCode() throws {
        let module = try DeinitFixture.module("", opaqueCalls: .objectiveC)
        let result = try DeinitFixture.verdict("size", in: module)
        #expect(result.verdict == .proved && result.assumptions.isEmpty, "\(result)")
    }
}
