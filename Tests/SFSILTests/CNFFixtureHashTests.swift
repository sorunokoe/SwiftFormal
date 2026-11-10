import Foundation
import SFSIL
import Testing

/// Plan item H0, extended again before the encoder's `run` moves (H1): the CNF of every function of the fixtures of the
/// SIL suites, so the arms of `run` that `CNFFeatureHashTests` does not reach (foreign values, globals, optional map,
/// enum addresses, hashing and describing, array literals, the round-6 features) are guarded too. A function the
/// encoder refuses has no hash; one with loops is hashed as its unrolling (`CNFFeatureHashTests.unrolling`).
///
/// An intended change re-records the hashes: `SF_RECORD_CNF_HASHES=1 swift test --filter CNFFixtureHashTests`, and
/// the commit says why.
@Suite(.tags(.slow)) struct CNFFixtureHashTests {
    private static let baseline = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Baselines/cnf-fixture-hashes.json")

    /// Arms of `run` the suites' fixtures do not reach (found with code coverage of the hash suites).
    static let gaps = """
        import Foundation
        public struct P: Hashable { public var x: Int8 }
        public struct HoldsSet: Hashable { public var s: Set<Int8>; public var d: [Int8: P] }
        public struct Raw: RawRepresentable, Hashable { public var rawValue: Int8; public init(rawValue: Int8) { self.rawValue = rawValue } }
        public enum Bad: Error { case negative }
        public func setsEqual(_ a: [Set<P>], _ b: [Set<P>]) -> Bool { a == b }
        public func hashHolder(_ h: HoldsSet) -> Int { var s: Set<HoldsSet> = []; s.insert(h); return s.count }
        public func hashRaw(_ r: Raw) -> Int { var s: Set<Raw> = []; s.insert(r); return s.count }
        public func partial(_ x: Int8) -> Bool { (5...).contains(x) || (..<(-5)).contains(x) }
        public func typed(_ x: Int8) throws(Bad) -> Int8 { if x < 0 { throw .negative }; return x + 1 }
        public func callsTyped(_ x: Int8) -> Int8 { do { return try typed(x) } catch { return 0 } }
        public func bridged(_ s: String) -> Int { (s as NSString).length }
        public func pick(_ i: Int) -> P { let a = [P(x: 1), P(x: 2), P(x: 3)]; return i >= 0 && i < 3 ? a[i] : P(x: 0) }
        public func structs(_ x: Int8) -> Int { let a: [P?] = [P(x: x), nil]; return a.count }
        """
    static let gapsModule = try! SILCompiler.module(source: gaps, name: "Gaps", optimization: .none)

    /// Objective-C objects (round 6), read as opaque references once their types are confirmed foreign.
    static let foreignModule: SILModule = {
        let directory = NSTemporaryDirectory() + "sf-cnf-foreign-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let header = """
            #import <Foundation/Foundation.h>
            NS_ASSUME_NONNULL_BEGIN
            @interface GKTDomainX : NSObject
            @property (readonly) int32_t count;
            @property (readonly) NSString *name;
            @property (readonly, nullable) GKTDomainX *next;
            - (int32_t)scoreFor:(int32_t)hole;
            @end
            NS_ASSUME_NONNULL_END
            """
        try! "module GKT {\n  header \"GKT.h\"\n  export *\n}\n".write(
            toFile: directory + "/module.modulemap", atomically: true, encoding: .utf8)
        try! header.write(toFile: directory + "/GKT.h", atomically: true, encoding: .utf8)
        let source = """
            import GKT
            public func count(_ x: GKTDomainX) -> Int32 { x.count + 1 }
            public func pick(_ x: GKTDomainX) -> Int { [1, 2, 3][Int(x.count)] }
            public func nameIsEmpty(_ x: GKTDomainX) -> Bool { x.name.isEmpty }
            public func nextCount(_ x: GKTDomainX) -> Int32 { x.next?.count ?? 0 }
            public func score(_ x: GKTDomainX) -> Int32 { x.score(for: 4) &+ 1 }
            """
        var module = try! SILCompiler.module(source: source, name: "Fgn", optimization: .none, extraArguments: ["-I", directory])
        module.confirmForeignTypes(classes: ["GKTDomainX"], protocols: [])
        module.confirmUnrelatedForeignTypes(module.foreignSupertypeQuestion.types)
        return module
    }()

    /// The fixture modules, by a label unique among them.
    static func fixtures() -> [(label: String, module: SILModule)] {
        [
            ("Agg", AggFixture.onone), ("AggO", AggFixture.speed), ("ArrayLiteral", ArrayLiteralFixture.module),
            ("Array", ArrayFixture.onone), ("CGFloat", CGFloatFixture.confirmed), ("Closure", ClosureFixture.quiet),
            ("Class", SILClassTests.module), ("Dictionary", DictionaryFixture.onone), ("EnumTag", EnumTagFixture.module),
            ("Enum", EnumFixture.onone), ("EnumO", EnumFixture.speed), ("Existential", ExistentialFixture.plain),
            ("Float", FloatFixture.onone), ("Generic", GenericFixture.onone), ("Global", GlobalFixture.module),
            ("Iterator", IteratorFixture.onone), ("Loop", LoopFixture.onone), ("LoopO", LoopFixture.speed),
            ("Opaque", OpaqueFixture.confirmed), ("OptionalMap", OptionalMapFixture.module),
            ("OptionalMapNoisy", OptionalMapFixture.noisy), ("Package", PackageFixture.confirmed),
            ("Range", RangeFixture.onone), ("StringFacts", StringFactsFixture.onone), ("String", StringFixture.onone),
            ("Frontend", Fixture.onone), ("FrontendO", Fixture.speed), ("Audit", AuditFixture.onone),
            ("AuditO", AuditFixture.speed), ("Unwind", SILUnwindTests.module), ("Gaps", gapsModule),
            ("Foreign", foreignModule),
        ]
    }

    /// Every fixture on a thread of its own, with a 16 MB stack: inlining 8 calls deep overflows a 512 KB worker.
    static func hashes() -> [String: String] {
        let fixtures = fixtures()
        let collected = Collected()
        let done = DispatchGroup()
        for (label, module) in fixtures {
            done.enter()
            let work = UncheckedModule(module: module)
            let thread = Thread {
                collected.merge(hashes(label, work.module))
                done.leave()
            }
            thread.stackSize = 16 << 20
            thread.start()
        }
        done.wait()
        return collected.value
    }

    private static func hashes(_ label: String, _ module: SILModule) -> [String: String] {
        var found: [String: String] = [:]
        for symbol in module.symbols {
            if let hash = try? CNFFeatureHashTests.encoding(symbol, in: module) {
                #expect((try? CNFFeatureHashTests.encoding(symbol, in: module)) == hash, "\(label) \(symbol) is not deterministic")
                found["\(label) encode \(symbol)"] = hash
            } else if let hash = try? CNFFeatureHashTests.unrolling(symbol, in: module) {
                #expect((try? CNFFeatureHashTests.unrolling(symbol, in: module)) == hash, "\(label) \(symbol) is not deterministic")
                found["\(label) unwind \(symbol)"] = hash
            }
        }
        return found
    }

    private struct UncheckedModule: @unchecked Sendable { let module: SILModule }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var hashes: [String: String] = [:]
        func merge(_ found: [String: String]) { lock.withLock { hashes.merge(found) { a, _ in a } } }
        var value: [String: String] { lock.withLock { hashes } }
    }

    @Test func theCNFOfEveryFixtureFunctionIsUnchanged() throws {
        let hashes = Self.hashes()
        #expect(hashes.count >= 300, "\(hashes.count)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if ProcessInfo.processInfo.environment["SF_RECORD_CNF_HASHES"] == "1" {
            try encoder.encode(hashes).write(to: Self.baseline)
            return
        }
        let recorded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.baseline))
        for (key, hash) in hashes.sorted(by: { $0.key < $1.key }) {
            #expect(recorded[key] == hash, "CNF of \(key) changed; if intended, re-record (see the suite's comment)")
        }
        #expect(Set(recorded.keys) == Set(hashes.keys), "the set of hashed fixture formulas changed")
    }
}
