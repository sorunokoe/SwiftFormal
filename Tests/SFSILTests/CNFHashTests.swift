import Foundation
import SFBV
import SFSIL
import Testing

/// Plan item H0: a SHA-256 of the CNF of every function of `Examples/Metrics`, so that a refactor of the reader or
/// the encoder that claims to change nothing is checked to the byte (clause counts alone miss a renumbering).
///
/// An intended change re-records the hashes: `SF_RECORD_CNF_HASHES=1 swift test --filter CNFHashTests`, and the
/// commit says why. The test also encodes each function twice to check the encoding is deterministic.
@Suite(.tags(.slow)) struct CNFHashTests {
    private static let baseline = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Baselines/cnf-hashes.json")
    private static let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Examples/Metrics/Kernels.swift").standardizedFileURL

    /// DIMACS of `¬(assumption ⇒ ¬trap ∧ ¬undefined)` for `symbol`, hashed.
    private static func hash(_ symbol: String, in module: SILModule) throws -> String {
        let function = try module.function(symbol)
        let c = CNFBuilder()
        let inputs = function.parameterWidths.map { c.input(width: $0) }
        let encoded = try SILEncoder(module: module, builder: c).encode(symbol: symbol, arguments: inputs)
        let claim = c.or(-function.inputAssumption(c, inputs), c.and(-encoded.trap, -encoded.undefined))
        let cnf = c.cnf
        var text = "p cnf \(cnf.numVars) \(cnf.clauses.count + 1)\n"
        for clause in cnf.clauses { text += clause.map(String.init).joined(separator: " ") + " 0\n" }
        text += "\(-claim) 0\n"
        return ProofDigest.hash(text)
    }

    @Test func theCNFOfEveryMetricsFunctionIsUnchanged() throws {
        let module = try SILCompiler.module(
            source: String(contentsOf: Self.source, encoding: .utf8), name: "Metrics", optimization: .none)
        var hashes: [String: String] = [:]
        for symbol in module.symbols where symbol.hasPrefix("$s7Metrics") {
            guard let first = try? Self.hash(symbol, in: module) else { continue }
            #expect(try Self.hash(symbol, in: module) == first, "the encoding of \(symbol) is not deterministic")
            hashes[symbol] = first
        }
        #expect(hashes.count >= 5, "Examples/Metrics should give several encodable functions")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if ProcessInfo.processInfo.environment["SF_RECORD_CNF_HASHES"] == "1" {
            try encoder.encode(hashes).write(to: Self.baseline)
            return
        }
        let recorded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.baseline))
        for (symbol, hash) in hashes.sorted(by: { $0.key < $1.key }) {
            #expect(recorded[symbol] == hash, "CNF of \(symbol) changed; if intended, re-record (see the suite's comment)")
        }
        #expect(Set(recorded.keys) == Set(hashes.keys), "the set of encodable Metrics functions changed")
    }
}
