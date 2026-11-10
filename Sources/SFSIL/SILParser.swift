// Reading guide
// Entry point: `SILModule(text:)` splits `swiftc -emit-sil` output into function bodies and constant global tables;
// `SILModule.function(_:)` parses one body on demand into blocks, instructions and terminators.
// The reader is split by what it reads (plan item H1): `SILValues.swift` (errors, `ValueType`), `SILTypeContext.swift`
// (declarations, type resolution), `SILInstructions.swift` (the closed `Instruction` enum, `SILFunction`), this file
// (the module and its lookup API), `SILFunctionParser.swift` and `SILInstructionParser.swift` (line by line).
// This file only reads SIL. Meaning is given by `SILEncoder.swift` (to circuits) and `SILVerify.swift` (to verdicts).
// Tests: Tests/SFSILTests (SILTests, SILAggregateTests, SILLoopTests); the compiler comparison is in Tests/SFOracleTests.

import Foundation
import SFSemantics

/// All function bodies found in one `-emit-sil` output. Bodies are parsed on demand.
package struct SILModule: Sendable {
    /// Parsed bodies (plan item S7, `SILParseCache.swift`); every stored property below starts a fresh one when it changes.
    private var parsed = ParsedBodies()
    private var bodies: [String: [String]] = [:] { didSet { parsed = ParsedBodies() } }
    private var headers: [String: String] = [:] { didSet { parsed = ParsedBodies() } }
    var types = TypeContext() { didSet { parsed = ParsedBodies() } }
    private var globals: [String: GlobalTable] = [:] { didSet { parsed = ParsedBodies() } }
    private var rejectedGlobals: [String: String] = [:] { didSet { parsed = ParsedBodies() } }
    /// The globals declared `sil_global … [let]`: stored only by their initializer (`SILGlobals.swift`).
    private var letGlobals: Set<String> = [] { didSet { parsed = ParsedBodies() } }
    /// `"Kind: #Hashable.hash"` -> the symbol of the witness, from the non-generic `sil_witness_table`s.
    private(set) var witnesses: [String: String] = [:] { didSet { parsed = ParsedBodies() } }
    /// Witness keys that two linked modules disagree on; never filled in again.
    private(set) var conflictingWitnesses: Set<String> = [] { didSet { parsed = ParsedBodies() } }
    private(set) var associatedTypes = AssociatedTypes() { didSet { parsed = ParsedBodies() } }
    /// `"Box: #CustomStringConvertible.description!getter"` for each requirement of a generic `sil_witness_table`
    /// (`<T> Box<T>: …`), keyed by the type's name without arguments. Their witnesses are not called (see `witness`).
    private(set) var genericWitnessRequirements: Set<String> = [] { didSet { parsed = ParsedBodies() } }
    /// The modules this SIL imports (`import Foundation`), in order, plus those of every linked module.
    package private(set) var imports: [String] = [] { didSet { parsed = ParsedBodies() } }
    /// False when a read module may install a fatal-error issue reporter, under which recording a state read can trap
    /// (see `StdlibSummary.recordsAccess`).
    package private(set) var trustsRecordedAccess = false { didSet { parsed = ParsedBodies() } }
    /// The `[_semantics "…"]` tags printed on each function's declaration or definition line, by symbol. Only a
    /// fail-closed cross-check of the summary table (plan item R9): a tag never decides what a call does.
    var semantics: [String: Set<String>] = [:] { didSet { parsed = ParsedBodies() } }

    package init(text: String) throws(SILError) {
        // Split by byte: Foundation's `components(separatedBy:)` compares characters and is several times slower.
        let lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(Substring($0)) }
        guard lines.first(where: { !$0.isEmpty }) == "sil_stage canonical" else {
            throw SILError.invalid("expected canonical SIL (use -emit-sil)")
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            Self.recordSemanticsTags(line, into: &semantics)
            Self.recordLetGlobal(line, into: &letGlobals)
            if line.hasPrefix("sil "), let at = line.range(of: " @"), line.hasSuffix("{") {
                let rest = line[line.index(after: at.lowerBound)...]
                guard let end = rest.range(of: " : ") else { i += 1; continue }
                let symbol = String(rest[rest.index(after: rest.startIndex)..<end.lowerBound])
                bodies[symbol] = Self.body(lines, after: &i)
                headers[symbol] = line
            } else if line.hasPrefix("sil_global "), line.hasSuffix("= {"), let at = line.range(of: " @") {
                let rest = line[line.index(after: at.lowerBound)...]
                let symbol = String(rest.dropFirst().prefix { $0 != " " })
                let body = Self.body(lines, after: &i).map { stripComment($0).trimmingCharacters(in: .whitespaces) }
                addGlobal(symbol, isLet: line.contains("[let]"), body: body)
            } else if let name = Self.importedModule(line) {
                if !imports.contains(name) { imports.append(name) }
            } else if line.hasPrefix("sil_witness_table "), line.hasSuffix("{") {
                let table = Self.body(lines, after: &i), entries = table.compactMap(Self.witnessEntry)
                if let type = Self.witnessTableType(line) {
                    for entry in entries { addWitness("\(type): \(entry.requirement)", entry.symbol) }
                    associatedTypes.add(of: type, table: table)
                } else if let base = Self.genericWitnessTableBase(line) {
                    for entry in entries { genericWitnessRequirements.insert("\(base): \(entry.requirement)") }
                }
            } else if !line.hasPrefix("sil"), !line.hasPrefix("//"), line.hasSuffix("{"), Self.declarationKind(line) != nil {
                i = Self.scanDeclaration(lines, from: i, prefix: "", into: &types)
                continue
            }
            i += 1
        }
        types.codeRunningDeinits = Self.codeRunningDeinits(bodies, headers: headers)
        trustsRecordedAccess = !Self.mayInstallIssueReporters(bodies)
        (types.foreign, types.binary) = (ForeignTypes.scan(lines), types.binary.readingExternals(lines))
    }

    /// Adds what another module of the same build declares and defines, so that its types, conformances and function
    /// bodies are known here. SIL names types without their module, so a type name declared in both becomes
    /// ambiguous (never resolved), and a conformance the two disagree on is dropped. Symbols are mangled with their
    /// module, so a body present in both is the same function.
    package mutating func link(_ other: SILModule) {
        for (symbol, body) in other.bodies where bodies[symbol] == nil {
            bodies[symbol] = body
            headers[symbol] = other.headers[symbol]
        }
        for (symbol, table) in other.globals where globals[symbol] == nil && rejectedGlobals[symbol] == nil {
            globals[symbol] = table
        }
        for (symbol, reason) in other.rejectedGlobals where globals[symbol] == nil { rejectedGlobals[symbol] = reason }
        letGlobals.formUnion(other.letGlobals)
        for (key, symbol) in other.witnesses { addWitness(key, symbol) }
        conflictingWitnesses.formUnion(other.conflictingWitnesses)
        genericWitnessRequirements.formUnion(other.genericWitnessRequirements)
        for key in other.conflictingWitnesses { witnesses[key] = nil }
        associatedTypes.link(other.associatedTypes)
        types.link(other.types)
        for (symbol, tags) in other.semantics { semantics[symbol, default: []].formUnion(tags) }
        for name in other.imports where !imports.contains(name) { imports.append(name) }
        types.codeRunningDeinits = Self.codeRunningDeinits(bodies, headers: headers)
        trustsRecordedAccess = !Self.mayInstallIssueReporters(bodies)
    }

    /// Names of the declared types this module can model (structs and enums, generic or not, outside nested
    /// generic contexts), for checking that no other visible module declares the same name.
    package var modelledTypeNames: [String] {
        (Array(types.structs.keys) + Array(types.enums.keys) + Array(types.generics.keys)).sorted()
    }

    /// Makes `names` ambiguous: another module the code can see declares a type with the same name.
    package mutating func markAmbiguous(_ names: some Sequence<String>) {
        for name in names { types.markAmbiguous(name) }
    }

    /// Two same-named types (in two files or two modules) can both conform: their tables would share the key.
    private mutating func addWitness(_ key: String, _ symbol: String) {
        guard !conflictingWitnesses.contains(key) else { return }
        if let mine = witnesses[key], mine != symbol {
            witnesses[key] = nil
            conflictingWitnesses.insert(key)
        } else {
            witnesses[key] = symbol
        }
    }

    /// Records a `sil_global` table, or why it cannot be used.
    private mutating func addGlobal(_ symbol: String, isLet: Bool, body: [String]) {
        do {
            guard isLet else { throw SILError.unsupported("mutable global \(symbol)") }
            globals[symbol] = try parseGlobalTable(body)
        } catch {
            rejectedGlobals[symbol] = "\(error)"
        }
    }

    /// The lines after `lines[i]` up to the closing `}`; leaves `i` at that brace.
    private static func body(_ lines: [String], after i: inout Int) -> [String] {
        let start = i + 1
        i = start
        while i < lines.count, !lines[i].hasPrefix("}") { i += 1 }
        return Array(lines[start..<i])
    }

    /// The conforming type of `sil_witness_table [linkage] Type: Protocol module M {`, nil for generic conformances.
    private static func witnessTableType(_ line: String) -> String? {
        var words = line.dropFirst("sil_witness_table ".count).split(separator: " ").map(String.init)
        let linkages: Set<String> = [
            "public", "hidden", "private", "shared", "package", "public_external", "hidden_external", "package_external",
        ]
        while let first = words.first, linkages.contains(first) || first.hasPrefix("[") { words.removeFirst() }
        let text = words.joined(separator: " ")
        guard !text.hasPrefix("<"), let colon = text.range(of: ": ", options: .backwards) else { return nil }
        let protocolPart = text[colon.upperBound...]
        guard protocolPart.hasSuffix(" {"), protocolPart.contains(" module ") else { return nil }
        return String(text[..<colon.lowerBound])
    }

    /// `method #Hashable.hash: <signature> : @symbol // comment` -> ("#Hashable.hash", "symbol").
    private static func witnessEntry(_ raw: String) -> (requirement: String, symbol: String)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("method #"), let colon = line.range(of: ": "),
            let at = line.range(of: " : @", options: .backwards)
        else { return nil }
        let requirement = String(line[line.index(line.startIndex, offsetBy: "method ".count)..<colon.lowerBound])
        let symbol = String(line[at.upperBound...].prefix { !$0.isWhitespace })
        return symbol.isEmpty ? nil : (requirement, symbol)
    }

    /// The symbol implementing `requirement` (for example `#Hashable.hash`) for `type`, from its witness table.
    package func witness(type: String, requirement: String) -> String? {
        encoderWitness(type: type, requirement: requirement)
    }

    /// The layout of a type spelled in SIL (for example a generic substitution).
    package func resolve(_ type: String) throws(SILError) -> ValueType {
        try types.resolve(type)
    }

    /// Whether destroying a value of `type` (spelled in SIL) cannot run code of this module (see `TypeContext`).
    package func destroysWithoutModuleCode(_ type: String) -> Bool {
        types.destroysWithoutModuleCode(type)
    }

    private static let declarationKeywords: Set<String> = ["struct", "class", "enum", "actor", "protocol", "extension"]

    private static func declarationKind(_ line: String) -> (kind: String, name: String, generic: Bool)? {
        let words = line.split(separator: " ").map(String.init)
        guard let k = words.firstIndex(where: { declarationKeywords.contains($0) }), k + 1 < words.count else { return nil }
        let stop: Set<String> = ["var", "let", "func", "init", "subscript", "case", "typealias", "deinit"]
        guard !words[..<k].contains(where: { stop.contains($0) }) else { return nil }
        let isExtension = words[k] == "extension"
        let name = String(words[k + 1].prefix { $0.isLetter || $0.isNumber || $0 == "_" || (isExtension && $0 == ".") })
        guard !name.isEmpty else { return nil }
        return (words[k], name, words[k + 1].contains("<"))
    }

    /// Reads one (possibly nested) type declaration whose first line is `lines[start]`; nested types are named
    /// `Outer.Inner`, the way SIL prints them in signatures. Returns the index after the closing brace.
    private static func scanDeclaration(_ lines: [String], from start: Int, prefix: String, into types: inout TypeContext) -> Int {
        guard let decl = declarationKind(lines[start]) else { return start + 1 }
        let indent = lines[start].prefix { $0 == " " }.count
        let name = prefix + decl.name
        var fields: [(name: String, type: String)] = []
        var cases: [(name: String, payload: String?)] = []
        var indirect = lines[start].contains("indirect ")
        // A `~Copyable` struct or enum with a `deinit`: destroying a value runs that code, and destroys are not
        // encoded (`destroy_addr`, `release_value` are ignored), so the type is refused (fails closed).
        var hasDeinit = false
        var members: [String] = []
        var i = start + 1
        while i < lines.count {
            let line = lines[i]
            let lineIndent = line.prefix { $0 == " " }.count
            let member = line.trimmingCharacters(in: .whitespaces)
            if lineIndent == indent, member.hasPrefix("}") { i += 1; break }
            if lineIndent > indent, member.hasSuffix("{"), declarationKind(line) != nil {
                i = scanDeclaration(lines, from: i, prefix: name + ".", into: &types)
                continue
            }
            members.append(member)
            if lineIndent > indent, member == "deinit" || member.hasPrefix("deinit ") || member.hasPrefix("deinit{") { hasDeinit = true }
            if member.hasPrefix("@_hasStorage"), let (n, t) = storedProperty(member) { fields.append((n, t)) }
            if decl.kind == "enum", let list = enumCaseList(member) {
                if list.indirect { indirect = true }
                cases += list.cases
            }
            i += 1
        }
        if decl.kind == "extension" { return i }
        if decl.kind == "class" {
            types.declareClass(name, line: lines[start], generic: decl.generic, hasDeinit: hasDeinit, fields: fields)
            return i
        }
        if let reason = rejection(kind: decl.kind, generic: decl.generic, indirect: indirect, hasDeinit: hasDeinit) {
            types.declare(name) { $0.rejected[name] = reason }
        } else if decl.generic {
            let parameters = genericParameters(lines[start], name: decl.name)
            types.declare(name) {
                if let parameters {
                    $0.generics[name] = .init(parameters: parameters, isEnum: decl.kind == "enum", fields: fields, cases: cases)
                } else {
                    $0.rejected[name] = "generic \(decl.kind)"
                }
            }
        } else if decl.kind == "enum" {
            types.declareEnum(name, cases: cases, line: lines[start])
        } else {
            types.declare(name) { $0.structs[name] = fields }
        }
        types.recordDeclaration(name, header: lines[start], members: members)
        return i
    }

    /// Why a declared type cannot be modelled, or nil for a struct or a non-indirect enum (generic or not) without a
    /// `deinit`. Types that contain a refused type are refused too: resolving the field or payload fails.
    private static func rejection(kind: String, generic: Bool, indirect: Bool, hasDeinit: Bool) -> String? {
        if hasDeinit, kind == "struct" || kind == "enum" { return "noncopyable \(kind) with a deinit (destroying it runs code)" }
        if kind == "enum" { return indirect ? "indirect enum" : nil }
        if kind == "struct" { return nil }
        return generic ? "generic \(kind)" : kind
    }

    /// `["A", "B"]` for a declaration line `public struct Pair<A, B> {` (constraints, if printed inline, dropped).
    private static func genericParameters(_ line: String, name: String) -> [String]? {
        guard let range = line.range(of: name + "<") else { return nil }
        var depth = 1
        var inner = ""
        for character in line[range.upperBound...] {
            if character == "<" { depth += 1 }
            if character == ">" { depth -= 1 }
            if depth == 0 { break }
            inner.append(character)
        }
        guard depth == 0 else { return nil }
        let parameters = splitTopLevel(inner).map { String($0.prefix { $0.isLetter || $0.isNumber || $0 == "_" }) }
        return parameters.contains(where: \.isEmpty) ? nil : parameters
    }

    /// `member` without leading attributes such as `@available(*, deprecated)`.
    private static func dropAttributes(_ member: String) -> String {
        var m = member
        while m.hasPrefix("@") {
            var index = m.index(after: m.startIndex)
            while index < m.endIndex, m[index].isLetter || m[index].isNumber || m[index] == "_" { index = m.index(after: index) }
            if index < m.endIndex, m[index] == "(" {
                var depth = 0
                while index < m.endIndex {
                    if m[index] == "(" { depth += 1 }
                    if m[index] == ")" { depth -= 1 }
                    index = m.index(after: index)
                    if depth == 0 { break }
                }
            }
            m = String(m[index...]).trimmingCharacters(in: .whitespaces)
        }
        return m
    }

    /// `case a, b(Int32), c(w: Int32, h: Int32)` gives [("a", nil), ("b", "Int32"), ("c", "(w: Int32, h: Int32)")].
    private static func enumCaseList(_ member: String) -> (cases: [(name: String, payload: String?)], indirect: Bool)? {
        var m = dropAttributes(member)
        let indirect = m.hasPrefix("indirect ")
        if indirect { m = String(m.dropFirst("indirect ".count)) }
        guard m.hasPrefix("case ") else { return nil }
        let cases = splitTopLevel(String(m.dropFirst("case ".count))).map { element -> (name: String, payload: String?) in
            var e = element
            if let eq = e.range(of: " = "), !e[..<eq.lowerBound].contains("(") { e = String(e[..<eq.lowerBound]) }
            guard let open = e.firstIndex(of: "("), e.hasSuffix(")") else { return (e.replacingOccurrences(of: "`", with: ""), nil) }
            let caseName = String(e[..<open]).replacingOccurrences(of: "`", with: "")
            let inner = splitTopLevel(String(e[e.index(after: open)..<e.index(before: e.endIndex)])).map { item -> String in
                var x = item
                if let eq = x.range(of: " = ") { x = String(x[..<eq.lowerBound]) }  // default argument
                return x
            }
            // A single unlabeled associated value is stored as its own type; a labeled one (`failed(code: Int8)`)
            // is a one-element tuple `(code: Int8)` in SIL.
            if inner.count == 1, let only = inner.first, !hasLabel(only) { return (caseName, only) }
            return (caseName, "(" + inner.joined(separator: ", ") + ")")
        }
        return (cases, indirect)
    }

    /// `code: Int8` has a label; `Int8`, `(a: Int8)` and `[String: Int8]` do not.
    private static func hasLabel(_ element: String) -> Bool {
        guard let colon = element.firstIndex(of: ":") else { return false }
        let label = element[..<colon]
        return !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `@_hasStorage public var x: Int32 { get set }` gives ("x", "Int32"). A `static` stored property is not part of
    /// the value, so it gives nil.
    private static func storedProperty(_ member: String) -> (String, String)? {
        guard let kw = member.range(of: " var ") ?? member.range(of: " let ") else { return nil }
        if member[..<kw.lowerBound].split(separator: " ").contains(where: { $0 == "static" || $0 == "class" }) { return nil }
        let rest = member[kw.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let name = String(rest[..<colon])
        var type = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if let brace = type.range(of: " {") { type = String(type[..<brace.lowerBound]) }
        return (name, type)
    }

    package var symbols: [String] { Array(bodies.keys).sorted() }

    /// The witness functions of the module's witness tables, sorted. The encoder calls them by type and requirement,
    /// with no `function_ref` in the caller.
    package var witnessSymbols: [String] { Set(witnesses.values).sorted() }

    /// The `sil ... @symbol : $signature {` line of `symbol`.
    package func header(of symbol: String) -> String? { headers[symbol] }

    /// The raw body lines of `symbol`, for tools that rewrite a function (mutation testing).
    package func bodyLines(of symbol: String) -> [String]? { bodies[symbol] }

    /// A copy of the module in which `symbol` has the body `lines`.
    package func replacingBody(of symbol: String, with lines: [String]) -> SILModule {
        var copy = self
        copy.bodies[symbol] = lines
        return copy
    }

    /// The unique function whose mangled name is `$s<module><name>...`, for example `("Fixture", "clamp")`.
    package func symbol(module: String, name: String) throws -> String {
        let prefix = "$s\(module.count)\(module)\(name.count)\(name)"
        // Autoclosures (`...fu_`, `...fu0_`) and closures (`...fU_`) inside the function share its mangled prefix.
        // Unsorted: at most one match is accepted, so the order of the keys cannot change the result.
        let found = bodies.keys.filter { $0.hasPrefix(prefix) && $0.firstMatch(of: /f[uU][0-9]*_/) == nil }
        guard found.count == 1 else {
            throw SILError.invalid("expected exactly one function \(module).\(name), found \(found.count)")
        }
        return found[0]
    }

    package func function(_ symbol: String) throws(SILError) -> SILFunction {
        try parsed.function(symbol) { () throws(SILError) in try DeinitAssumption.collecting { () throws(SILError) in try parse(symbol) } }
    }

    /// `symbol` parsed from its text, without the cache.
    private func parse(_ symbol: String) throws(SILError) -> SILFunction {
        if let (header, body) = try closureText(symbol) {
            return try parseFunction(symbol: symbol, header: header, body: body, types: types)
        }
        if let (header, body) = try specializedText(symbol) {
            return try parseFunction(symbol: symbol, header: header, body: body, types: types)
        }
        guard let body = bodies[symbol], let header = headers[symbol] else {
            throw SILError.unsupported("no body for \(symbol) (\(OpaqueValues.unreadCall(symbol) ?? "external or not emitted"))")
        }
        return try parseFunction(symbol: symbol, header: header, body: body, types: types)
    }

    func isLetGlobal(_ symbol: String) -> Bool { letGlobals.contains(symbol) }

    func globalTable(_ symbol: String) throws(SILError) -> GlobalTable {
        if let table = globals[symbol] { return table }
        throw SILError.unsupported("global \(symbol): \(rejectedGlobals[symbol] ?? "not a constant array literal")")
    }
}

/// Reads the `%initval = object $_ContiguousArrayStorage<T> (%header, [tail_elems] %e0, %e1, ...)` of a constant array.
private func parseGlobalTable(_ body: [String]) throws(SILError) -> GlobalTable {
    var literals: [String: (Int, UInt64)] = [:]
    var bodies: [String: UInt64] = [:]
    for line in body where !line.isEmpty {
        if line.hasPrefix("%initval = object $_ContiguousArrayStorage<") {
            guard let open = line.firstIndex(of: "("), line.hasSuffix(")"),
                let typeEnd = line.firstIndex(of: ">")
            else { throw SILError.unsupported("global object: \(line)") }
            let typeStart = line.index(line.startIndex, offsetBy: "%initval = object $_ContiguousArrayStorage<".count)
            guard let w = scalarWidth(String(line[typeStart..<typeEnd])) else {
                throw SILError.unsupported("array of non-scalar elements: \(line)")
            }
            let parts = String(line[line.index(after: open)..<line.index(before: line.endIndex)]).components(separatedBy: ", [tail_elems] ")
            guard parts.count == 2, let count = bodies[parts[0].trimmingCharacters(in: .whitespaces)] else {
                throw SILError.unsupported("global array header: \(line)")
            }
            let elements = parts[1].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var values: [UInt64] = []
            for e in elements {
                guard let (ew, v) = literals[e], ew == w else { throw SILError.unsupported("global array element \(e)") }
                values.append(v)
            }
            guard UInt64(values.count) == count else { throw SILError.unsupported("global array count disagrees with its header") }
            return GlobalTable(elementWidth: w, values: values)
        }
        guard let eq = line.range(of: " = ") else { throw SILError.unsupported("global initializer: \(line)") }
        let id = String(line[..<eq.lowerBound])
        let rhs = String(line[eq.upperBound...])
        let head = String(rhs.prefix { $0 != " " })
        let rest = String(rhs.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
        switch head {
        case "integer_literal":
            let parts = splitTopLevel(rest)
            guard parts.count == 2, let w = scalarWidth(parts[0]), let v = Int64(parts[1]) else {
                throw SILError.unsupported("global literal: \(line)")
            }
            literals[id] = (w, UInt64(bitPattern: v) & (w == 64 ? ~0 : (1 << UInt64(w)) - 1))
        case "struct":
            guard let open = rest.firstIndex(of: "("), rest.hasSuffix(")") else { throw SILError.unsupported("global struct: \(line)") }
            let type = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            let operands = splitTopLevel(String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]))
            if type == "$_SwiftArrayBodyStorage" {
                guard operands.count == 2, let count = literals[operands[0]] else { throw SILError.unsupported("array body: \(line)") }
                bodies[id] = count.1
                literals[id] = nil
            } else if type == "$_ArrayBody" {
                guard operands.count == 1, let count = bodies[operands[0]] else { throw SILError.unsupported("array body: \(line)") }
                bodies[id] = count
            } else if let w = scalarWidth(type), operands.count == 1, let inner = literals[operands[0]], inner.0 == w {
                literals[id] = inner
            } else {
                throw SILError.unsupported("global struct: \(line)")
            }
        default:
            throw SILError.unsupported("global initializer: \(line)")
        }
    }
    throw SILError.unsupported("global without an array object")
}
