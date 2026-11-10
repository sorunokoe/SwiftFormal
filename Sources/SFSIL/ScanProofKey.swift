import Foundation

/// The identity of what Scan proves about the functions of one compiled module, for the Scan proof cache (plan
/// items D4, S5, X6). Built once per module and immutable afterwards, so that the threads verifying its functions can
/// share it.
///
/// A key covers everything the claim of a function is made from: the exact header and body text of every function
/// its code can reach (and those of its paired `_requires`/`_ensures`), the module's tables (types, globals, witness
/// tables, witness conflicts, the type names `TypeNameCheck` made ambiguous, the module-wide safety flags), the code
/// of every witness the encoder looks up by type alone (`SILModule.encoderWitnessRequirements`) with what it reaches,
/// the compilation (`compileIdentity`: compiler, SDK, target, arguments, assert configuration, linked modules) and the
/// versions of the tool (`versions(tool:)`). A function reaches every symbol with a body that its text names
/// (`@symbol`), a superset of the `function_ref`s the encoder follows, and every witness of the requirement a
/// `witness_method` of its text names (whichever type the call is specialized to). When any part
/// cannot be determined the key is nil, and the function is verified without the cache.
package final class ScanKeyContext: Sendable {
    private typealias Node = ScanKeyNode

    /// Whose answers this context may key: nil when the module has a part it cannot hash (see `init`).
    private let base: String?
    private let nodes: [String: Node]

    /// The tool's versions that a key includes: the Scan claim's and the encoder's version constants, the digest of
    /// the encoder's behaviour on fixed batteries, the hash algorithm, and `tool`, the UUIDs of the loaded images the
    /// answers come from (`ScanToolImages`), so a rebuilt `swiftformal`, `sfverify` or library never reuses what an
    /// older build proved. Nil (no keys) when `tool` is nil.
    package static func versions(tool: String?) -> String? {
        guard let tool else { return nil }
        var text = "claim=\(ScanClaimVersion.current) semantics=\(SILFrontendVersion.semantics)"
        text += " digest=\(SemanticsDigest.current) algorithm=\(ProofDigest.algorithm)"
        return text + " tool=" + tool
    }

    /// Seconds spent building this context.
    package let seconds: Double

    /// Hashes the functions `roots` and the encoder's witnesses reach, a level of callees at a time on several threads.
    ///
    /// - Parameters:
    ///   - compileIdentity: how the module was compiled (`CompiledModule.identity`); nil means unknown, and gives no keys.
    ///   - versions: the tool's versions (`versions(tool:)`); tests change it to simulate a new version. Nil gives no keys.
    package init(module: SILModule, compileIdentity: String?, roots: [String], versions: String?) {
        let started = Date()
        var nodes: [String: Node] = [:]
        var unknown: Set<String> = []
        let witnesses = ScanKeyWitnesses(module)
        var level = Array(Set(roots + witnesses.encoder))
        while !level.isEmpty {
            let jobs = level
            let hashed = ScanKeyNodes(count: jobs.count)
            DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
                hashed.set(index, Self.node(jobs[index], in: module, witnesses: witnesses))
            }
            var next: Set<String> = []
            for (index, symbol) in jobs.enumerated() {
                guard let node = hashed.value(index) else {
                    unknown.insert(symbol)
                    continue
                }
                nodes[symbol] = node
                next.formUnion(node.callees)
            }
            level = next.filter { nodes[$0] == nil && !unknown.contains($0) }
        }
        self.nodes = nodes
        let encoderWitnesses = Self.closureDigest(of: witnesses.encoder, in: nodes)
        // Without SHA-256 the digests are not collision resistant (plan item X6): no keys.
        if let versions, let compileIdentity, let encoderWitnesses, ProofDigest.algorithm == "sha256" {
            var fields = ScanKeyFields()
            fields.add("versions", versions)
            fields.add("compile", compileIdentity)
            fields.add("tables", ProofDigest.hash(module.tablesText))
            fields.add("encoderWitnesses", encoderWitnesses)
            base = fields.text
        } else {
            base = nil
        }
        seconds = Date().timeIntervalSince(started)
    }

    /// The key of the claim about `function` with the paired `requires` and `ensures` (symbols), for a run with
    /// `conflictBudget`. `claim` is the caller's description of everything else the claim is made from (names and
    /// types that decide how the contract's arguments are laid out). Nil when a function's code is not known.
    package func key(function: String, requires: String?, ensures: String?, claim: String, conflictBudget: Int) -> String? {
        guard let base, let code = Self.closureDigest(of: [function], in: nodes) else { return nil }
        var fields = ScanKeyFields()
        fields.add("kind", "scan-claim")
        fields.add("base", base)
        fields.add("budgetClass", String(ProofCache.budgetClass(conflictBudget)))
        fields.add("claim", claim)
        fields.add("function", function)
        fields.add("code", code)
        for (name, spec) in [("requires", requires), ("ensures", ensures)] {
            guard let spec else {
                fields.add(name, "none")
                continue
            }
            guard let digest = Self.closureDigest(of: [spec], in: nodes) else { return nil }
            fields.add(name, spec)
            fields.add(name + "Code", digest)
        }
        return ProofDigest.hash(fields.text)
    }

    /// The hash of the sorted digests of every function `roots` reach; nil when one of them could not be hashed.
    private static func closureDigest(of roots: [String], in nodes: [String: Node]) -> String? {
        var seen: Set<String> = []
        var queue = roots
        while let symbol = queue.popLast() {
            guard seen.insert(symbol).inserted else { continue }
            guard let node = nodes[symbol] else { return nil }
            queue += node.callees
        }
        var digests: [String] = []
        for symbol in seen.sorted() {
            guard let node = nodes[symbol] else { return nil }
            digests.append(node.digest)
        }
        return ProofDigest.hash(digests.joined(separator: "\n"))
    }

    /// The hash of `symbol`'s header and body lines (the parser's input, debug locations already removed) and the
    /// functions they reach: those with a body they name, and the witnesses of the requirement of each
    /// `witness_method` (of every requirement when one cannot be read); for a symbol without a body (a witness defined
    /// elsewhere), a hash that says so. Nil when the text names a symbol in quotes (`@"…"`), which the reading below
    /// would not follow.
    private static func node(_ symbol: String, in module: SILModule, witnesses: ScanKeyWitnesses) -> Node? {
        guard let header = module.header(of: symbol), let body = module.bodyLines(of: symbol) else {
            return Node(digest: ProofDigest.hash("no body: " + symbol), callees: [])
        }
        var callees: Set<String> = []
        for line in [header] + body {
            guard let names = referencedSymbols(in: line) else { return nil }
            for name in names where name != symbol && module.bodyLines(of: name) != nil { callees.insert(name) }
            if line.replacingOccurrences(of: "@convention(witness_method:", with: "").contains("witness_method") {
                callees.formUnion(witnesses.called(by: line))
            }
        }
        let text = canonicalArchetypes(in: [header] + body)
        var fields = ScanKeyFields()
        fields.add("symbol", symbol)
        fields.add("header", text[0])
        fields.add("body", text.dropFirst().joined(separator: "\n"))
        return Node(digest: ProofDigest.hash(fields.text), callees: callees.sorted())
    }

    /// Every name after an `@` in `line`, up to the next blank, also without trailing punctuation (`@f,` names `f,`
    /// and `f`); nil when a name starts with a quote. In a `string_literal` the text in quotes names nothing, but its
    /// names are listed too (a superset is harmless) and `@"` there (`"%@"`) is no quoted name; nil when that literal
    /// does not end on the line.
    package static func referencedSymbols(in line: String) -> [String]? {
        var literal: Range<String.Index>?
        if let instruction = line.range(of: "string_literal "), let open = line[instruction.upperBound...].firstIndex(of: "\"") {
            guard let end = endOfLiteral(line[line.index(after: open)...]) else { return nil }
            literal = open..<end
        }
        var names: [String] = []
        var rest = Substring(line)
        while let at = rest.firstIndex(of: "@") {
            let after = rest[rest.index(after: at)...]
            if after.first == "\"" {
                guard let literal, literal.contains(at) else { return nil }
                rest = after
                continue
            }
            let token = after.prefix { $0 != " " && $0 != "\t" }
            var name = token
            if !name.isEmpty { names.append(String(name)) }
            while let last = name.last, ",;:()[]{}<>\"".contains(last) {
                name = name.dropLast()
                names.append(String(name))
            }
            rest = after[token.endIndex...]
        }
        return names
    }

    /// Where the string literal whose contents start `text` ends (after its closing quote); nil when it does not.
    private static func endOfLiteral(_ text: Substring) -> Substring.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "\\":
                index = text.index(after: index)
                guard index < text.endIndex else { return nil }
            case "\"": return text.index(after: index)
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// `lines` with the identifier the compiler draws afresh for each opened archetype (`@opened("<UUID>", …)`,
    /// `@pack_element("<UUID>")`, `open_pack_element … uuid "<UUID>"`) replaced by `archetype-<n>`, numbered in order
    /// of first use, so that compiling the same code twice gives the same text. The renaming is one-to-one within the
    /// lines, and the identifiers only name archetypes within one function.
    package static func canonicalArchetypes(in lines: [String]) -> [String] {
        let markers = [#"@opened(""#, #"@pack_element(""#, #"uuid ""#]
        var numbers: [Substring: Int] = [:]
        return lines.map { line in
            guard markers.contains(where: line.contains) else { return line }
            var result = ""
            var rest = Substring(line)
            while let marker = markers.compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                let identifier = rest[marker.upperBound...].prefix(36)
                result += rest[..<marker.upperBound]
                rest = rest[marker.upperBound...]
                guard isUUID(identifier), rest.dropFirst(36).first == "\"" else { continue }
                let number = numbers[identifier] ?? numbers.count
                numbers[identifier] = number
                result += "archetype-\(number)"
                rest = rest[identifier.endIndex...]
            }
            return result + rest
        }
    }

    private static func isUUID(_ text: Substring) -> Bool {
        let dashes: Set<Int> = [8, 13, 18, 23]
        guard text.utf8.count == 36 else { return false }
        for (offset, byte) in text.utf8.enumerated() {
            let isDash = byte == UInt8(ascii: "-")
            guard dashes.contains(offset) ? isDash : !isDash && (byte >= 48 && byte <= 57 || byte >= 65 && byte <= 70) else {
                return false
            }
        }
        return true
    }
}

/// The witnesses of a module's witness tables: those the encoder looks up by type alone, which every claim reaches,
/// and those of each requirement, which a `witness_method` reaches.
private struct ScanKeyWitnesses: Sendable {
    let encoder: [String]
    let byRequirement: [String: [String]]
    let all: [String]

    init(_ module: SILModule) {
        let byRequirement = module.witnessSymbolsByRequirement
        self.byRequirement = byRequirement
        encoder = SILModule.encoderWitnessRequirements.sorted().flatMap { byRequirement[$0] ?? [] }
        all = module.witnessSymbols
    }

    /// The witnesses `line` (which mentions `witness_method` other than as a calling convention) may call: those of
    /// its requirement, or every one.
    func called(by line: String) -> [String] {
        guard let method = WitnessMethodLine(line) else { return all }
        return byRequirement[method.requirement] ?? []
    }
}

/// One function's text, hashed, and the functions with a body its text names.
private struct ScanKeyNode: Sendable {
    let digest: String
    let callees: [String]
}

/// Length-prefixed `name=value` fields, so no value can imitate the boundary of another.
private struct ScanKeyFields {
    var text = "swiftformal scan key v1\n"
    mutating func add(_ name: String, _ value: String) { text += "\(name)=\(value.utf8.count):\(value)\n" }
}

/// The hashed nodes of one level, one per index (nil: the function could not be hashed), written by the threads of a
/// `concurrentPerform` and read after it returns.
private final class ScanKeyNodes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScanKeyNode??]

    init(count: Int) { storage = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ node: ScanKeyNode?) {
        lock.lock()
        storage[index] = .some(node)
        lock.unlock()
    }

    func value(_ index: Int) -> ScanKeyNode? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = storage[index] else { preconditionFailure("no node at \(index)") }
        return node
    }
}
