// Parsing one function: its signature, blocks, block parameters and terminators, and the line helpers the
// instruction parser shares (plan item H1).

import Foundation
import SFSemantics

// MARK: - parsing

func stripComment(_ line: String) -> String {
    var quoted = false, escaped = false
    var index = line.startIndex
    while index < line.endIndex {
        let ch = line[index]
        if escaped {
            escaped = false
        } else if ch == "\\" && quoted {
            escaped = true
        } else if ch == "\"" {
            quoted.toggle()
        } else if !quoted && line[index...].hasPrefix("//") {
            return String(line[..<index])
        }
        index = line.index(after: index)
    }
    return line
}

/// Splits on top-level commas, ignoring commas inside parentheses and quotes.
func splitTopLevel(_ text: String) -> [String] {
    var parts: [String] = []
    var depth = 0, quoted = false
    var current = ""
    var previous: Character = " "
    for ch in text {
        defer { previous = ch }
        if ch == "\"" { quoted.toggle() }
        if !quoted {
            if ch == "(" || ch == "<" { depth += 1 }
            if ch == ")" || (ch == ">" && previous != "-") { depth -= 1 }
            if ch == "," && depth == 0 { parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
        }
        current.append(ch)
    }
    let last = current.trimmingCharacters(in: .whitespaces)
    if !last.isEmpty { parts.append(last) }
    return parts
}

func isValue(_ s: String) -> Bool {
    s.hasPrefix("%") && s.count > 1 && s.dropFirst().allSatisfy(\.isNumber)
}

func parseValueList(_ text: String) throws(SILError) -> [String] {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return [] }
    let ids = splitTopLevel(t)
    guard ids.allSatisfy(isValue) else { throw SILError.invalid("bad value list: \(text)") }
    return ids
}

func parseEdge(_ text: String) throws(SILError) -> Edge {
    let t = text.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("bb") else { throw SILError.invalid("bad branch target: \(text)") }
    if let open = t.firstIndex(of: "(") {
        guard t.hasSuffix(")") else { throw SILError.invalid("bad branch target: \(text)") }
        let args = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
        return Edge(block: String(t[..<open]), arguments: try parseValueList(args))
    }
    return Edge(block: t, arguments: [])
}

private let failureFunctions = ["assertionFailure", "fatalErrorMessage", "preconditionFailure"]

/// Standard-library functions known to terminate the program. Only these may stand behind an `unreachable`.
private func isFailureSymbol(_ symbol: String) -> Bool {
    symbol.hasPrefix("$ss") && failureFunctions.contains { symbol.contains($0) }
}

/// `@Verify`'s contract checks: `if !condition { Contract.requiresFailed("...") }`. Outside a walk the call is an
/// `assertionFailure`, so a block that makes it is a trap. The checks exist only where the code was compiled with
/// `DEBUG` (or `checks: .always`); verdicts come from the `_requires` / `_ensures` peers, which are always there.
public enum ContractFailureCall {
    /// The mangled `Contract.requiresFailed` / `ensuresFailed` symbols, and the name each failure is reported under.
    public static let kinds = [
        "$s11SwiftFormal8ContractO14requiresFailed_4file4lineys12StaticStringV_AHSutFZ": "requires failed",
        "$s11SwiftFormal8ContractO13ensuresFailed_4file4lineys12StaticStringV_AHSutFZ": "ensures failed",
    ]

    /// The kind of contract check a SIL line calls, if it is a `function_ref` to one.
    public static func kind(of line: some StringProtocol) -> String? {
        guard let r = line.range(of: "function_ref @") else { return nil }
        return kinds[String(line[r.upperBound...].prefix { $0 != " " })]
    }
}

/// True for an optimized failure block: `%c = integer_literal $Builtin.Int1, -1` then `cond_fail %c, "..."`.
private func failsUnconditionally(_ lines: [String]) -> Bool {
    let alwaysTrue = Set(
        lines.compactMap { line -> String? in
            guard let eq = line.range(of: " = integer_literal $Builtin.Int1, ") else { return nil }
            let value = line[eq.upperBound...]
            return value == "-1" || value == "1" ? String(line[..<eq.lowerBound]) : nil
        })
    return lines.contains { line in
        guard line.hasPrefix("cond_fail ") else { return false }
        return alwaysTrue.contains(String(line.dropFirst("cond_fail ".count).prefix { $0 != "," && $0 != " " }))
    }
}

func parseFunction(symbol: String, header given: String, body: [String], types: TypeContext) throws(SILError) -> SILFunction {
    // A global's one-time initializer is `@convention(c)` only so that the runtime's `once` can call it (`SILGlobals.swift`).
    let header = given.contains(" [global_init_once_fn] ") ? given.replacing(" : $@convention(c) ", with: " : $@convention(thin) ") : given
    // sil [attributes] @symbol : $@convention(thin) (P1, P2) -> R {
    guard let colon = header.range(of: " : $"), header.hasSuffix(" {"),
        let signature = FunctionSignature(String(header[colon.upperBound...].dropLast(2)))
    else {
        throw SILError.unsupported("signature of \(symbol): \(header)")
    }
    if signature.errorIsIndirect { throw SILError.unsupported("\(symbol) throws through an error address (a generic error type)") }
    // `(@out A, @out B)`: several indirect results (real compiler output, plan item V8); only one is read.
    if signature.result.contains("@out ") { throw SILError.unsupported("several @out results in \(symbol)") }
    let (conventions, objectParameter) = try types.objectConventions(signature)
    let paramTypes = try signature.parameters.map { (p) throws(SILError) in try types.resolveObjectOrValue(p.type) }
    let indirectResult = try signature.indirectResult.map { (t) throws(SILError) in try types.resolve(t) }
    let resultType = try types.resolveObjectOrValue(signature.result)
    let errorType = try signature.errorType.map { (t) throws(SILError) in try types.resolve(t) }
    let widths = paramTypes.flatMap(\.leafWidths)

    // Group lines into blocks.
    var groups: [(header: String, lines: [String])] = []
    for raw in body {
        let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("[") { continue }
        if line.hasPrefix("bb"), line.hasSuffix(":") {
            groups.append((String(line.dropLast()), []))
        } else {
            guard !groups.isEmpty else { throw SILError.invalid("instruction before first block in \(symbol)") }
            groups[groups.count - 1].lines.append(line)
        }
    }
    guard !groups.isEmpty else { throw SILError.invalid("empty body: \(symbol)") }

    let dynamicAccesses = try checkDynamicAccesses(groups, types: types)
    var blocks: [Block] = []
    for group in groups {
        let (id, parameters) = try parseBlockHeader(group.header, types: types)
        guard let last = group.lines.last else { throw SILError.invalid("empty block \(id) in \(symbol)") }
        if group.lines.contains(where: { ContractFailureCall.kind(of: $0) != nil }) {
            blocks.append(Block(id: id, parameters: parameters, instructions: [], terminator: .trap))
            continue
        }
        if last == "unreachable" {
            guard
                group.lines.contains(where: { line in
                    guard let r = line.range(of: "function_ref @") else { return false }
                    let sym = line[r.upperBound...].prefix { $0 != " " }
                    return isFailureSymbol(String(sym))
                }) || failsUnconditionally(group.lines) || receivesUnthrownError(id, groups.flatMap(\.lines))
            else {
                throw SILError.unsupported("unreachable without a known failure call in \(id) of \(symbol)")
            }
            blocks.append(Block(id: id, parameters: parameters, instructions: [], terminator: .trap))
            continue
        }
        var instructions: [Instruction] = []
        for line in group.lines.dropLast() {
            instructions.append(try parseInstruction(line, types: types, dynamicAccesses: dynamicAccesses))
        }
        blocks.append(
            Block(id: id, parameters: parameters, instructions: instructions, terminator: try parseTerminator(last, types: types)))
    }
    let entryTypes = (indirectResult.map { [$0] } ?? []) + paramTypes
    let entryAddresses = (indirectResult == nil ? [] : [true]) + conventions.map { $0 != .value }
    guard blocks[0].id == "bb0", blocks[0].parameters.map(\.type) == entryTypes,
        blocks[0].parameters.map(\.isAddress) == entryAddresses
    else {
        throw SILError.invalid("entry block of \(symbol) does not match its signature")
    }
    guard blocks.dropFirst().allSatisfy({ $0.parameters.allSatisfy { !$0.isAddress } }) else {
        throw SILError.unsupported("address block parameter in \(symbol)")
    }
    var function = SILFunction(
        symbol: symbol, parameterWidths: widths, resultWidth: resultType.totalWidth,
        resultWidths: resultType.leafWidths, parameterTypes: paramTypes, resultType: resultType,
        conventions: conventions, indirectResult: indirectResult, blocks: blocks)
    function.errorType = errorType
    function.objectParameter = objectParameter
    function.returnsObject = types.objectLayout(signature.result) != nil
    return function
}

/// The text of a SIL function type: `@convention(thin|method|witness_method: P) [<generics>] (params) -> result`.
struct FunctionSignature {
    let parameters: [(convention: ParameterConvention, type: String)]
    /// The type text of a single `@out` result, if the function returns indirectly.
    let indirectResult: String?
    /// `()` when the result is indirect.
    let result: String
    /// The type text of the error a throwing function throws (`any Error`, or `E` for `throws(E)`); nil when it does
    /// not throw (plan item L6).
    let errorType: String?
    /// True when the type has generic parameters (`<τ_0_0 where ...>`).
    let isGeneric: Bool
    /// True for `@error_indirect E`: the error is written through an address passed after the `@out` one.
    let errorIsIndirect: Bool

    init?(_ text: String) {
        var t = Substring(text.trimmingCharacters(in: .whitespaces))
        guard t.hasPrefix("@convention("), let close = t.firstIndex(of: ")") else { return nil }
        let convention = t[t.index(t.startIndex, offsetBy: "@convention(".count)..<close]
        guard convention == "thin" || convention == "method" || convention.hasPrefix("witness_method: ") else { return nil }
        t = t[t.index(after: close)...].drop { $0 == " " }
        isGeneric = t.hasPrefix("<")
        // `<Key, Value where ...><S where ...>`: a generic method of a generic type has two signatures.
        while t.hasPrefix("<") {
            guard let end = matchingClose(t, open: "<", close: ">") else { return nil }
            t = t[t.index(after: end)...].drop { $0 == " " }
        }
        guard t.hasPrefix("("), let end = matchingClose(t, open: "(", close: ")") else { return nil }
        let params = String(t[t.index(after: t.startIndex)..<end])
        let rest = t[t.index(after: end)...]
        guard rest.hasPrefix(" -> ") else { return nil }
        var result = String(rest.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        parameters = splitTopLevel(params).map(Self.convention)
        errorIsIndirect =
            result.hasPrefix("(") && result.hasSuffix(")")
            && splitTopLevel(String(result.dropFirst().dropLast())).last?.hasPrefix("@error_indirect ") == true
        (result, errorType) = Self.splitError(result)
        if result.hasPrefix("@out ") {
            indirectResult = String(result.dropFirst("@out ".count))
            result = "()"
        } else if let (direct, indirect) = Self.splitIndirect(result) {
            // `(Bool, @out τ_0_0)` (`Set.insert`): one direct result, and an `@out` one passed first like any other.
            (result, indirectResult) = (direct, indirect)
        } else {
            indirectResult = nil
        }
        self.result = result
    }

    /// `(Int8, @error any Error)` -> ("Int8", "any Error"); `@error E` -> ("()", "E"); otherwise no error.
    private static func splitError(_ result: String) -> (String, String?) {
        if result.hasPrefix("@error ") { return ("()", String(result.dropFirst("@error ".count))) }
        guard result.hasPrefix("("), result.hasSuffix(")") else { return (result, nil) }
        var elements = splitTopLevel(String(result.dropFirst().dropLast()))
        guard let last = elements.last, let prefix = ["@error ", "@error_indirect "].first(where: { last.hasPrefix($0) }) else {
            return (result, nil)
        }
        elements.removeLast()
        let rest = elements.count == 1 ? elements[0] : "(" + elements.joined(separator: ", ") + ")"
        return (rest, String(last.dropFirst(prefix.count)))
    }

    /// `(A, @out B)` -> ("A", "B"): a tuple result with exactly one `@out` element; nil for any other result.
    private static func splitIndirect(_ result: String) -> (String, String)? {
        guard result.hasPrefix("("), result.hasSuffix(")") else { return nil }
        var elements = splitTopLevel(String(result.dropFirst().dropLast()))
        let indirect = elements.indices.filter { elements[$0].hasPrefix("@out ") }
        guard indirect.count == 1, elements.count >= 2 else { return nil }
        let out = String(elements.remove(at: indirect[0]).dropFirst("@out ".count))
        return (elements.count == 1 ? elements[0] : "(" + elements.joined(separator: ", ") + ")", out)
    }

    /// `@inout T` -> (.inout, "T"). Unknown attributes stay in the type text, which then fails to resolve.
    private static func convention(_ text: String) -> (ParameterConvention, String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        // Marks a value a closure captured from its context; it is passed like any other argument.
        if t.hasPrefix("@closureCapture ") { t.removeFirst("@closureCapture ".count) }
        for (prefix, convention) in [
            ("@inout ", ParameterConvention.inout), ("@inout_aliasable ", .inout), ("@in_guaranteed ", .indirect),
            ("@in ", .indirect),
        ] where t.hasPrefix(prefix) {
            return (convention, String(t.dropFirst(prefix.count)))
        }
        return (.value, t)
    }
}

/// The index of the bracket closing the one that `text` starts with (`->` does not count as a closing `>`).
func matchingClose(_ text: Substring, open: Character, close: Character) -> Substring.Index? {
    var depth = 0
    var previous: Character = " "
    for i in text.indices {
        let ch = text[i]
        defer { previous = ch }
        if ch == open { depth += 1 }
        if ch == close && !(close == ">" && previous == "-") {
            depth -= 1
            if depth == 0 { return i }
        }
    }
    return nil
}

private func parseBlockHeader(_ text: String, types: TypeContext) throws(SILError) -> (String, [BlockParameter]) {
    guard let open = text.firstIndex(of: "(") else { return (text, []) }
    guard text.hasSuffix(")") else { throw SILError.invalid("bad block header: \(text)") }
    let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
    let parameters = try splitTopLevel(inner).map { (p) throws(SILError) -> BlockParameter in
        let parts = p.components(separatedBy: " : ")
        guard parts.count == 2, isValue(parts[0]) else { throw SILError.unsupported("block parameter: \(p)") }
        var type = parts[1]
        if type.hasPrefix("@closureCapture ") { type.removeFirst("@closureCapture ".count) }
        if type.hasPrefix("$*") {
            return BlockParameter(id: parts[0], type: try types.resolve(String(type.dropFirst(2))), isAddress: true)
        }
        // A reference to an object is the address of its fields (plan item L5).
        if let object = types.objectLayout(type) { return BlockParameter(id: parts[0], type: object, isAddress: true) }
        return BlockParameter(id: parts[0], type: try types.resolve(type))
    }
    return (String(text[..<open]), parameters)
}

private func parseTerminator(_ line: String, types: TypeContext) throws(SILError) -> Terminator {
    if line.hasPrefix("br ") { return .branch(try parseEdge(String(line.dropFirst(3)))) }
    if line.hasPrefix("throw "), isValue(String(line.dropFirst(6))) { return .thrown(String(line.dropFirst(6))) }
    if line.hasPrefix("try_apply ") { return .tryApply(try parseTryApply(line, types: types)) }
    if line.hasPrefix("cond_br ") {
        let parts = splitTopLevel(String(line.dropFirst(8)))
        guard parts.count == 3, isValue(parts[0]) else { throw SILError.invalid("bad cond_br: \(line)") }
        return .conditional(parts[0], try parseEdge(parts[1]), try parseEdge(parts[2]))
    }
    if line.hasPrefix("return "), isValue(String(line.dropFirst(7))) { return .returned(String(line.dropFirst(7))) }
    if let switchEnum = try parseSwitchEnum(line) { return switchEnum }
    throw SILError.unsupported("terminator: \(line)")
}

/// `try_apply %2(%0) : $@convention(thin) (Int8) -> (Int8, @error any Error), normal bb1, error bb8`.
private func parseTryApply(_ line: String, types: TypeContext) throws(SILError) -> TryApply {
    guard let normal = line.range(of: ", normal ", options: .backwards), let error = line.range(of: ", error ", options: .backwards),
        normal.upperBound <= error.lowerBound
    else { throw SILError.invalid("bad try_apply: \(line)") }
    let call = "%0 = apply " + line[line.index(line.startIndex, offsetBy: "try_apply ".count)..<normal.lowerBound]
    guard case .apply(_, let callee, let arguments, _, let substitutions, let conventions) = try parseInstruction(call, types: types)
    else { throw SILError.invalid("bad try_apply: \(line)") }
    return TryApply(
        callee: callee, arguments: arguments, substitutions: substitutions, conventions: conventions,
        normal: String(line[normal.upperBound..<error.lowerBound]), error: String(line[error.upperBound...]))
}

func dropBracket(_ s: String) -> String {
    var t = s
    while t.hasPrefix("[") { t = String(t.drop { $0 != "]" }.dropFirst()).trimmingCharacters(in: .whitespaces) }
    return t
}

/// The bracketed attributes at the start of an operand, e.g. ["static", "no_nested_conflict"].
func leadingAttributes(_ s: String) -> [String] {
    var t = s, out: [String] = []
    while t.hasPrefix("["), let end = t.firstIndex(of: "]") {
        out.append(String(t[t.index(after: t.startIndex)..<end]))
        t = String(t[t.index(after: end)...]).trimmingCharacters(in: .whitespaces)
    }
    return out
}
