import Foundation
import SFBV
import SFSIL
import Testing

/// Plan item H0, extended before H1 and H5 move the reader and the encoder: a SHA-256 of the CNF of every function of
/// a fixture that uses each feature added since `Examples/Metrics` was hashed (classes, `for-in`, dictionaries and
/// sets, strings, ranges, floats, `throws`, generic calls), of the unrolling formula of each function with loops (it
/// goes through `run(makeState:)`, header states and arrivals), and of one encoding with a contract summary.
///
/// An intended change re-records the hashes: `SF_RECORD_CNF_HASHES=1 swift test --filter CNFFeatureHashTests`, and
/// the commit says why.
@Suite(.tags(.slow)) struct CNFFeatureHashTests {
    private static let baseline = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Baselines/cnf-feature-hashes.json")

    static let source = """
        public final class Counter {
            public var count: Int8 = 0
            public var limit: Int8 = 10
            public init() {}
            public func bump() { count += 1 }
            public func bumpBelow() { if count < limit { count += 1 } }
        }
        public func same(_ c: Counter) -> Counter { c }
        public func objects(_ n: Int8) -> Int8 { let c = Counter(); c.count = n; let r = same(c); r.bumpBelow(); return c.count }
        public func onParameter(_ c: Counter) -> Int8 { c.bump(); return c.count }
        public func dictionaries(_ x: Int8) -> Int { var d: [Int8: Int8] = [1: 10]; d[x] = 2; var s: Set<Int8> = [x]; s.insert(3); return d.count + s.count }
        public func strings(_ s: String) -> Bool { let t = s + "!"; return t == "ok!" || s.isEmpty }
        public func ranges(_ i: Int8, _ n: Int8) -> Int8 { (0...9).contains(i) && (0..<n).contains(i) ? i : 0 }
        public func floats(_ x: Double, _ y: Float) -> Int { x.isFinite && x > -1e9 && x < 1e9 && y < 1 ? Int(x) : 0 }
        public enum Bad: Error { case negative }
        public func checked(_ x: Int8) throws -> Int8 { if x < 0 { throw Bad.negative }; return x + 1 }
        public func caught(_ x: Int8) -> Int8 { do { return try checked(x) } catch { return -1 } }
        public func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T { x < lo ? lo : (x > hi ? hi : x) }
        public func clamped(_ a: Int8) -> Int8 { clamp(a, -60, 60) + 1 }
        public func optional(_ x: Int8?) -> Int8 { (x ?? 0) &+ 1 }
        public func half(_ x: Int8) -> Int8 { x / 2 }
        public func half_requires(_ x: Int8) -> Bool { x >= 0 }
        public func half_ensures(_ x: Int8, _ result: Int8) -> Bool { result <= x }
        public func useHalf(_ x: Int8) -> Int8 { half(x < 0 ? 0 : x) &+ 1 }
        public func whileLoop(_ n: Int8) -> Int8 { var x: Int8 = 100; var i: Int8 = 0; while i < n { x += 10; i += 1 }; return x }
        public func repeatLoop(_ n: Int8) -> Int8 { var i: Int8 = 0; repeat { i += 1 } while i < 100 && i < n; return i }
        public func forIn(_ n: UInt8) -> UInt8 { var s: UInt8 = 0; for i in 0..<n { s &+= i }; return s }
        public func forArray(_ n: UInt8) -> Int { var c = 0; for (i, _) in Array(repeating: Int8(0), count: Int(n)).enumerated() { c &+= i }; return c }
        """

    static func dimacs(_ c: CNFBuilder, _ claim: Int32) -> String {
        let cnf = c.cnf
        var text = "p cnf \(cnf.numVars) \(cnf.clauses.count + 1)\n"
        for clause in cnf.clauses { text += clause.map(String.init).joined(separator: " ") + " 0\n" }
        return ProofDigest.hash(text + "\(-claim) 0\n")
    }

    /// The encoding of `symbol`, as `CNFHashTests` hashes it; with `summaries`, calls to those callees use contracts.
    static func encoding(_ symbol: String, in module: SILModule, summaries: [String: ContractSummary] = [:]) throws -> String {
        let function = try module.function(symbol)
        let c = CNFBuilder()
        let inputs = function.parameterWidths.map { c.input(width: $0) }
        let encoder = SILEncoder(module: module, builder: c)
        encoder.contractSummaries = summaries
        let encoded = try encoder.encode(symbol: symbol, arguments: inputs)
        var claim = c.or(-function.inputAssumption(c, inputs), c.and(-encoded.trap, -encoded.undefined))
        if let assumption = encoded.assumption { claim = c.or(-assumption, claim) }
        return dimacs(c, claim)
    }

    /// The unrolling formula of a function with loops (3 header visits).
    static func unrolling(_ symbol: String, in module: SILModule) throws -> String {
        let function = try module.function(symbol)
        let c = CNFBuilder()
        let inputs = function.parameterWidths.map { c.input(width: $0) }
        let made = try SILVerifier.unwindClaim(symbol, in: module, times: 3, builder: c, arguments: inputs)
        return dimacs(c, c.or(-function.inputAssumption(c, inputs), made.noTrap))
    }

    static func hashes() throws -> [String: String] {
        let module = try SILCompiler.module(source: source, name: "Feat", optimization: .none)
        var hashes: [String: String] = [:]
        for symbol in module.symbols where symbol.hasPrefix("$s4Feat") {
            if let hash = try? encoding(symbol, in: module) {
                #expect(try encoding(symbol, in: module) == hash, "the encoding of \(symbol) is not deterministic")
                hashes["encode " + symbol] = hash
            } else if let hash = try? unrolling(symbol, in: module) {
                #expect(try unrolling(symbol, in: module) == hash, "the unrolling of \(symbol) is not deterministic")
                hashes["unwind " + symbol] = hash
            }
        }
        let half = try module.symbol(module: "Feat", name: "half")
        let summary = ContractSummary(
            requires: try module.symbol(module: "Feat", name: "half_requires"),
            ensures: try module.symbol(module: "Feat", name: "half_ensures"), ensuresArguments: { $0 + $1 })
        hashes["summary useHalf"] = try encoding(try module.symbol(module: "Feat", name: "useHalf"), in: module, summaries: [half: summary])
        return hashes
    }

    @Test func theCNFOfEveryFeatureFixtureIsUnchanged() throws {
        let hashes = try Self.hashes()
        for kind in ["unwind", "summary"] {
            #expect(hashes.keys.contains { $0.hasPrefix(kind) }, "no \(kind) formula was hashed")
        }
        #expect(hashes.count >= 20, "\(hashes.keys.sorted())")
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
