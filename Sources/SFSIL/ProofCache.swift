package import Foundation
package import SFBV
import SFCNF
package import SFProve
import SFSemantics

// MARK: - the cache

package final class ProofCache: @unchecked Sendable {
    package enum Trust: Sendable {
        /// A stored `.proved` is returned without re-proving. Stored counterexamples are still replayed.
        case cachedProof
        /// Ignore stored verdicts: always prove again (and report whether the new verdict agrees with the stored one).
        case recheck
    }

    package struct Entry: Codable, Sendable, Equatable {
        package var formatVersion: Int
        /// The exact key, repeated inside the file so a renamed or copied file is detected.
        package var key: String
        /// What a stored entry can say. There is no "unknown" case: unknowns are not stored, and a file that says
        /// anything else fails to decode, so `lookup` rejects it.
        package enum Kind: String, Codable, Sendable {
            case proved
            case counterexample
        }

        package var verdict: Kind
        /// Counterexample inputs as hexadecimal strings, one per input.
        package var counterexample: [String]?
        package var fingerprint: CompilerFingerprint
        package var symbol: String
        package var claimID: String
        /// ISO 8601.
        package var timestamp: String

        package var counterexampleValues: [UInt64]? { counterexample?.compactMap { UInt64($0, radix: 16) } }
    }

    package struct Statistics: Sendable, Equatable {
        package var hits = 0, misses = 0, stores = 0
        /// Cached counterexamples that failed replay and were deleted.
        package var droppedCounterexamples = 0
        /// Files that were unreadable, from another format version, or whose key or fingerprint did not match.
        package var rejectedEntries = 0
    }

    package static let formatVersion = 1

    package let directory: URL
    private let lock = NSLock()
    private var counters = Statistics()

    /// - Parameter directory: where entries live, created on first store. There is no default: anyone who can write
    ///   there can forge a `.proved`, so a shared place such as the temporary directory needs `Trust.recheck`.
    package init(directory: URL) {
        self.directory = directory
    }

    package var statistics: Statistics { lock.lock(); defer { lock.unlock() }; return counters }

    func count(_ update: (inout Statistics) -> Void) { lock.lock(); update(&counters); lock.unlock() }

    package func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: ":", with: "-") + ".json")
    }

    /// The entry for `key`, if present, readable, of this format, for this exact key and fingerprint.
    package func lookup(key: String, fingerprint: CompilerFingerprint) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(forKey: key)) else { return nil }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data),
            entry.formatVersion == Self.formatVersion, entry.key == key, entry.fingerprint == fingerprint,
            entry.verdict == .proved || (entry.verdict == .counterexample && entry.counterexample != nil)
        else {
            count { $0.rejectedEntries += 1 }
            return nil
        }
        return entry
    }

    /// Writes atomically (temporary file, then rename), so concurrent readers see the old or the new entry, never a partial one.
    package func store(verdict: ProofVerdict, key: String, fingerprint: CompilerFingerprint, symbol: String, claimID: String) throws {
        let kind: Entry.Kind, values: [String]?
        switch verdict {
        case .proved: (kind, values) = (.proved, nil)
        case .counterexample(let v): (kind, values) = (.counterexample, v.map { String($0, radix: 16) })
        case .unknown: return  // never cache "unknown": it says nothing and a bigger budget may decide it
        }
        let entry = Entry(
            formatVersion: Self.formatVersion, key: key, verdict: kind, counterexample: values, fingerprint: fingerprint,
            symbol: symbol, claimID: claimID, timestamp: ISO8601DateFormatter().string(from: Date()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry).write(to: fileURL(forKey: key), options: .atomic)
        count { $0.stores += 1 }
    }

    package func remove(key: String) { try? FileManager.default.removeItem(at: fileURL(forKey: key)) }

    /// Deletes every entry in the directory.
    package func clear() { try? FileManager.default.removeItem(at: directory) }

    // MARK: keys

    /// Key for `SILVerifier.prove`. Inputs, all of them hashed:
    ///  - the parsed bodies of `symbol` and of every function reachable through `function_ref` (what the encoder consumes),
    ///  - the fingerprint (compiler, SDK, optimization, encoder version, S0 and encoder digests),
    ///  - `claimID`: **the caller must change it whenever `requires` or `ensures` change**; closures cannot be hashed,
    ///  - a behavioural probe of the two closures on a fixed battery of constants, which catches most forgotten claimID changes
    ///    but is a safety net, not a proof of equality,
    ///  - parameter and result widths, `inputSignedBits`, and the conflict-budget class (a power-of-two bucket).
    package static func key(
        symbol: String, in module: SILModule, claimID: String, fingerprint: CompilerFingerprint,
        inputSignedBits: [Int?]? = nil, conflictBudget: Int = 1_000_000,
        requires: (CNFBuilder, [BV]) -> Int32 = { c, _ in c.trueLit },
        ensures: (CNFBuilder, [BV], BV) -> Int32 = { c, _, _ in c.trueLit }
    ) throws -> String {
        let function = try module.function(symbol)
        var fields = Fields()
        fields.add("kind", "prove")
        fields.add("fingerprint", fingerprint.canonical)
        fields.add("claimID", claimID)
        fields.add(
            "claimProbe",
            ClaimProbe.digest(widths: function.parameterWidths, resultWidth: function.resultWidth, requires: requires, ensures: ensures))
        fields.add("symbol", symbol)
        fields.add("widths", "\(function.parameterWidths)->\(function.resultWidth)")
        fields.add("signedBits", inputSignedBits.map { $0.map { $0.map(String.init) ?? "nil" }.joined(separator: ",") } ?? "none")
        fields.add("budgetClass", String(budgetClass(conflictBudget)))
        fields.add("functions", try closureText(of: symbol, in: module))
        fields.add("tables", module.tablesText)
        return ProofDigest.hash(fields.text)
    }

    /// Key for `SILVerifier.proveEquivalent`.
    package static func equivalenceKey(
        _ symbolA: String, in a: SILModule, _ symbolB: String, in b: SILModule,
        fingerprint: CompilerFingerprint, conflictBudget: Int = 1_000_000
    ) throws -> String {
        var fields = Fields()
        fields.add("kind", "equivalent")
        fields.add("fingerprint", fingerprint.canonical)
        fields.add("symbolA", symbolA)
        fields.add("symbolB", symbolB)
        fields.add("budgetClass", String(budgetClass(conflictBudget)))
        fields.add("functionsA", try closureText(of: symbolA, in: a))
        fields.add("functionsB", try closureText(of: symbolB, in: b))
        fields.add("tablesA", a.tablesText)
        fields.add("tablesB", b.tablesText)
        return ProofDigest.hash(fields.text)
    }

    /// `k` such that `2^(k-1) <= budget < 2^k`; budgets in one class share cache entries.
    static func budgetClass(_ budget: Int) -> Int { Int.bitWidth - max(budget, 0).leadingZeroBitCount }

    private struct Fields {
        var text = "swiftformal proof key v2\n"
        /// Length-prefixed, so no field value can imitate the boundary of another.
        mutating func add(_ name: String, _ value: String) { text += "\(name)=\(value.utf8.count):\(value)\n" }
    }

    /// `value` as text that is the same in every process: dictionaries and sets sorted (their order depends on the
    /// process's hash seed), every other value field by field, through `Mirror`, so a field added later is included.
    package static func canonicalText(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .dictionary:
            let entries = mirror.children.map { entry in
                let pair = Mirror(reflecting: entry.value).children.map { canonicalText($0.value) }
                return pair.joined(separator: ": ")
            }
            return "[" + entries.sorted().joined(separator: ", ") + "]"
        case .set:
            return "{" + mirror.children.map { canonicalText($0.value) }.sorted().joined(separator: ", ") + "}"
        case .collection:
            return "[" + mirror.children.map { canonicalText($0.value) }.joined(separator: ", ") + "]"
        case .optional:
            return mirror.children.first.map { "some(" + canonicalText($0.value) + ")" } ?? "nil"
        case .enum:
            guard let payload = mirror.children.first else { return String(reflecting: value) }
            return "\(type(of: value)).\(payload.label ?? "_")(" + canonicalText(payload.value) + ")"
        case .struct, .class, .tuple:
            let fields = mirror.children.map { "\($0.label ?? "_"): \(canonicalText($0.value))" }
            return "\(type(of: value))(" + fields.joined(separator: ", ") + ")"
        default:
            return String(reflecting: value)
        }
    }

    /// The parsed form of `symbol` and of all its transitive callees, sorted by symbol. The parsed form is what the encoder reads:
    /// debug values, comments and SSA names that the parser ignores... are not ignored here (SSA names are kept), which can only
    /// cost a miss. A callee without a parseable body is recorded by name and error, so it also separates keys. Every witness
    /// of the module counts as a callee: the encoder calls witnesses by type and requirement, which no `function_ref` shows.
    package static func closureText(of symbol: String, in module: SILModule) throws -> String {
        var seen: Set<String> = [], queue = module.witnessSymbols + [symbol], parts: [String] = []
        while let current = queue.popLast() {
            guard seen.insert(current).inserted else { continue }
            let node = try closureNode(current, in: module, isRoot: current == symbol)
            parts.append(node.text)
            queue += node.callees
        }
        return parts.sorted().joined(separator: "\n")
    }

    /// One function's part of `closureText`, and the functions it refers to (read from that text, so two equal texts
    /// refer to the same functions). Only the root throws when it does not parse.
    package static func closureNode(_ symbol: String, in module: SILModule, isRoot: Bool) throws -> (text: String, callees: [String]) {
        do {
            let function = try module.function(symbol)
            var callees: [String] = []
            for block in function.blocks {
                for case .functionRef(_, let callee) in block.instructions { callees.append(callee) }
            }
            return ("fn \(symbol)\n\(canonicalText(function))", callees)
        } catch {
            if isRoot { throw error }
            // A generic function does not parse on its own, but the encoder reads its body at each call's types
            // (plan item L7): its text and what it refers to count.
            let body = module.bodyLines(of: symbol) ?? []
            let callees = body.compactMap { line in
                line.range(of: "function_ref @").map { String(line[$0.upperBound...].prefix { $0 != " " }) }
            }
            return ("fn \(symbol) unavailable: \(error)\n" + body.joined(separator: "\n"), callees)
        }
    }
}

/// Evaluates `requires` and `ensures` on constants. Closures cannot be compared, but their behaviour on a fixed grid of
/// inputs can be hashed. A non-constant literal is recorded as `?`.
enum ClaimProbe {
    static func digest(widths: [Int], resultWidth: Int, requires: (CNFBuilder, [BV]) -> Int32, ensures: (CNFBuilder, [BV], BV) -> Int32)
        -> String
    {
        func mask(_ w: Int) -> UInt64 { w == 64 ? ~0 : (1 << UInt64(w)) - 1 }
        var state: UInt64 = 0x243F_6A88_85A3_08D3
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        func pool(_ w: Int) -> [UInt64] {
            let m = mask(w), top: UInt64 = 1 << UInt64(w - 1)
            return [0, 1, 2, m, m &- 1, top, top &- 1, top &+ 1, 7 & m, 100 & m, UInt64(bitPattern: -100) & m].map { $0 & m }
        }
        let pools = widths.map(pool)
        func flag(_ c: CNFBuilder, _ l: Int32) -> String { l == c.trueLit ? "T" : l == c.falseLit ? "F" : "?" }
        var out = ""
        for round in 0..<48 {
            let c = CNFBuilder()
            let args = zip(widths, pools).map { w, p in round < 24 ? p[Int(next() % UInt64(p.count))] : next() & mask(w) }
            let inputs = zip(widths, args).map { c.constant($1, width: $0) }
            out += flag(c, requires(c, inputs))
            for candidate in [0, 1, ~0, next(), args.first ?? 0] {
                out += flag(c, ensures(c, inputs, c.constant(candidate & mask(resultWidth), width: resultWidth)))
            }
        }
        return out
    }
}

extension SILModule {
    /// Everything besides the function bodies that the encoder may read (types, constant global tables, witness tables
    /// and the module's flags), in a fixed order, for proof-cache keys. Read field by field through `Mirror`, so a table
    /// added to `SILModule` later is covered without a change here. A cache stored in `SILModule` (parsed bodies,
    /// digests) would be read too: leave it out here by label, as `bodies` and `headers` are.
    package var tablesText: String {
        Mirror(reflecting: self).children.filter { !["bodies", "headers", "parsed"].contains($0.label) }
            .map { "\($0.label ?? "_") = \(ProofCache.canonicalText($0.value))" }.joined(separator: "\n")
    }
}
