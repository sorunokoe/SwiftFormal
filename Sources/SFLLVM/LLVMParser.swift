// Reading guide
// Entry point: `LLVMModule(text:)` splits `swiftc -emit-ir` output into function bodies;
// `LLVMModule.function(_:)` parses one body into blocks, phis, instructions and terminators.
// Phases, in file order: lexer, syntax types, token cursor, module, function parsing.
// This file only reads LLVM IR. Meaning is given by `LLVMEncoder.swift`; verdicts by `LLVMVerify.swift`.
// Tests: Tests/SFOracleTests/LLVMTests.swift (it runs the compiler, so it belongs to the slow lane).

import Foundation

/// A frontend for the scalar subset of textual LLVM IR as printed by `swiftc -emit-ir`. Anything outside the
/// subset is rejected with `LLVMError.unsupported`; nothing is guessed.
package enum LLVMError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)
    case invalid(String)
    case compilerFailed(String)

    package var description: String {
        switch self {
        case .unsupported(let s): "UNSUPPORTED: \(s)"
        case .invalid(let s): "INVALID LLVM IR: \(s)"
        case .compilerFailed(let s): "COMPILER FAILED: \(s)"
        }
    }
}

// MARK: - lexer

enum Token: Equatable {
    case word(String)
    case local(String)
    case global(String)
    case int(String)
    case meta(String)
    case string(String)
    case punct(Character)
}

private func isWordCharacter(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || c == "_" || c == "." || c == "$" || c == "-"
}

func lex(_ line: String) -> [Token] {
    let chars = Array(line)
    var tokens: [Token] = []
    var i = 0
    func quoted() -> String {
        i += 1  // opening quote
        var text = ""
        while i < chars.count, chars[i] != "\"" {
            if chars[i] == "\\" && i + 1 < chars.count { text.append(chars[i]); i += 1 }
            text.append(chars[i])
            i += 1
        }
        i += 1  // closing quote
        return text
    }
    func run() -> String {
        var text = ""
        while i < chars.count, isWordCharacter(chars[i]) { text.append(chars[i]); i += 1 }
        return text
    }
    while i < chars.count {
        let ch = chars[i]
        if ch == " " || ch == "\t" || ch == "\r" { i += 1; continue }
        if ch == ";" { break }
        if ch == "\"" { tokens.append(.string(quoted())); continue }
        if ch == "%" || ch == "@" {
            i += 1
            let name = (i < chars.count && chars[i] == "\"") ? quoted() : run()
            tokens.append(ch == "%" ? .local(name) : .global(name))
            continue
        }
        if ch == "!", i + 1 < chars.count, isWordCharacter(chars[i + 1]) {
            i += 1
            tokens.append(.meta(run()))
            continue
        }
        if isWordCharacter(ch) {
            let text = run()
            let digits = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { tokens.append(.int(text)) } else { tokens.append(.word(text)) }
            continue
        }
        tokens.append(.punct(ch))
        i += 1
    }
    return tokens
}

// MARK: - syntax

indirect enum LType: Equatable, Sendable {
    case int(Int)
    case void
    case ptr
    /// `{ a, b }`: fields at their natural alignment.
    case tuple([LType])
    /// `<{ a, b }>`: fields without padding between them (Swift prints its own types this way).
    case packed([LType])
    /// `[n x T]`.
    case array(Int, LType)
    case named(String)
    case other(String)

    var description: String {
        switch self {
        case .int(let n): "i\(n)"
        case .void: "void"
        case .ptr: "ptr"
        case .tuple(let t): "{\(t.map(\.description).joined(separator: ", "))}"
        case .packed(let t): "<{\(t.map(\.description).joined(separator: ", "))}>"
        case .array(let n, let t): "[\(n) x \(t.description)]"
        case .named(let n): "%\(n)"
        case .other(let s): s
        }
    }
}

enum Operand: Equatable {
    case local(String)
    case global(String)
    /// An integer literal, as its two's complement bit pattern (the width is known from the type).
    case constant(UInt64)
    /// `poison` and `undef`. Both are modelled as poison: reaching a use that matters is undefined behaviour.
    case poison
    case null
    /// `zeroinitializer`: every bit zero, of whatever type is expected.
    case zero
}

struct RangeAttribute: Equatable {
    let lo: UInt64
    let hi: UInt64
}

struct Argument {
    let type: LType
    let operand: Operand
}

/// One parameter of a function definition, with the attributes the bridge to SIL needs.
struct LParameter {
    let type: LType
    let name: String
    /// Attribute words without their arguments: `noalias`, `swiftself`, `sret`, `swifterror`, `dereferenceable`, ...
    let attributes: Set<String>
    /// The byte count of `dereferenceable(N)`, if present.
    let dereferenceable: Int?
}

enum BinaryOp: String {
    case add, sub, mul, udiv, sdiv, urem, srem, shl, lshr, ashr, and, or, xor
}

enum Predicate: String {
    case eq, ne, ugt, uge, ult, ule, sgt, sge, slt, sle
}

enum CastKind: String {
    case zext, sext, trunc
}

struct PhiEntry {
    let operand: Operand
    let block: String
}

struct Phi {
    let result: String
    /// An integer or `ptr`.
    let type: LType
    let entries: [PhiEntry]
}

enum Instruction {
    case binary(result: String, op: BinaryOp, flags: Set<String>, width: Int, Operand, Operand)
    case icmp(result: String, predicate: Predicate, flags: Set<String>, width: Int, Operand, Operand)
    /// The chosen values are integers or `ptr` (`type`).
    case select(result: String, condition: Operand, type: LType, Operand, Operand)
    case cast(result: String, kind: CastKind, flags: Set<String>, from: Int, Operand, to: Int)
    case freeze(result: String, width: Int, Operand)
    /// `inttoptr i64 ... to ptr` (`toPointer`) and `ptrtoint ptr ... to i64`: the same 64 bits, seen as the other type.
    case pointerCast(result: String, toPointer: Bool, Operand)
    case extractValue(result: String, aggregate: LType, source: Operand, indices: [Int])
    case insertValue(result: String, aggregate: LType, base: Operand, element: LType, value: Operand, indices: [Int])
    case call(result: String?, callee: String, arguments: [Argument], returns: LType, range: RangeAttribute?)
    /// A call to a Swift standard-library failure function: the program stops here.
    case failure(callee: String)
    /// `call void asm sideeffect "nop", ""()`, which Swift emits as a debugger anchor.
    case nop
    case alloca(result: String, type: LType)
    /// The stored or loaded value is an integer or `ptr` (`type`).
    case store(type: LType, value: Operand, address: Operand)
    case load(result: String, type: LType, address: Operand)
    /// `getelementptr` with constant indices only: the first index steps over whole `source` values, the others
    /// select fields and array elements.
    case elementAddress(result: String, base: Operand, source: LType, indices: [Int64])
}

enum Terminator {
    case branch(String)
    case conditional(Operand, String, String)
    case returned(type: LType, Operand)
    case returnedVoid
    /// `switch iN %v, label %default [ iN k, label %target ... ]`.
    case switchInteger(width: Int, Operand, defaultTarget: String, cases: [(value: UInt64, target: String)])
    case unreachable
}

struct Block {
    let id: String
    let phis: [Phi]
    let instructions: [Instruction]
    let terminator: Terminator
}

package struct LLVMFunction {
    package let symbol: String
    let parameters: [LParameter]
    let returnType: LType
    let resultRange: RangeAttribute?
    let blocks: [Block]

    /// The width of each parameter: an integer's own width, 64 for a `ptr` (an opaque address-sized value).
    package var parameterWidths: [Int] {
        parameters.map { if case .int(let n) = $0.type { n } else { 64 } }
    }
    /// The width of an integer result; 64 for `ptr`, 0 for anything else.
    package var resultWidth: Int {
        switch returnType {
        case .int(let n): n
        case .ptr: 64
        default: 0
        }
    }
    var parameterNames: [String] { parameters.map(\.name) }
}

/// Calls to these functions never return: the Swift runtime reports a fatal error and the process dies.
/// Everything else that does not return is rejected, not guessed.
let failureFunctionPrefixes = ["$ss17_assertionFailure", "$ss18_fatalErrorMessage", "$ss13_preconditionFailure"]

// MARK: - cursor

private struct Cursor {
    let tokens: [Token]
    var index = 0

    init(_ tokens: [Token]) { self.tokens = tokens }

    var atEnd: Bool { index >= tokens.count }
    func peek(_ k: Int = 0) -> Token? { index + k < tokens.count ? tokens[index + k] : nil }

    mutating func next() throws -> Token {
        guard index < tokens.count else { throw LLVMError.invalid("unexpected end of line") }
        defer { index += 1 }
        return tokens[index]
    }

    mutating func eat(_ c: Character) -> Bool {
        if peek() == .punct(c) { index += 1; return true }
        return false
    }

    mutating func expect(_ c: Character) throws {
        guard eat(c) else { throw LLVMError.invalid("expected '\(c)' near \(String(describing: peek()))") }
    }

    mutating func eatWord(_ w: String) -> Bool {
        if peek() == .word(w) { index += 1; return true }
        return false
    }

    mutating func expectWord() throws -> String {
        guard case .word(let w) = try next() else { throw LLVMError.invalid("expected a keyword") }
        return w
    }

    /// Skips from just after an opening bracket to just after its closing one.
    mutating func skipBalanced(open: Character, close: Character) throws {
        var depth = 1
        while depth > 0 {
            let t = try next()
            if t == .punct(open) { depth += 1 }
            if t == .punct(close) { depth -= 1 }
        }
    }

    mutating func type() throws -> LType {
        switch try next() {
        case .word(let w):
            if w.hasPrefix("i"), let n = Int(w.dropFirst()) { return .int(n) }
            if w == "void" { return .void }
            if w == "ptr" { return .ptr }
            return .other(w)
        case .local(let name):
            return .named(name)
        case .punct("{"):
            return .tuple(try typeList(close: "}"))
        case .punct("<"):
            if eat("{") {
                let fields = try typeList(close: "}")
                try expect(">")
                return .packed(fields)
            }
            try skipBalanced(open: "<", close: ">")
            return .other("vector")
        case .punct("["):
            return try arrayType()
        case let t:
            throw LLVMError.invalid("expected a type, found \(t)")
        }
    }

    /// `[n x T]` after its `[`.
    private mutating func arrayType() throws -> LType {
        if case .int(let n)? = peek(), let count = Int(n), count >= 0, peek(1) == .word("x") {
            index += 2
            let element = try type()
            try expect("]")
            return .array(count, element)
        }
        try skipBalanced(open: "[", close: "]")
        return .other("array")
    }

    private mutating func typeList(close: Character) throws -> [LType] {
        var fields: [LType] = []
        if eat(close) { return fields }
        repeat { fields.append(try type()) } while eat(",")
        try expect(close)
        return fields
    }

    mutating func operand() throws -> Operand {
        switch try next() {
        case .local(let n): return .local(n)
        case .global(let n): return .global(n)
        case .int(let s): return .constant(try parseInteger(s))
        case .word("true"): return .constant(1)
        case .word("false"): return .constant(0)
        case .word("undef"), .word("poison"): return .poison
        case .word("null"): return .null
        case .word("zeroinitializer"): return .zero
        case let t: throw LLVMError.unsupported("operand \(t) (constant expressions and aggregates are not supported)")
        }
    }

    mutating func intType() throws -> Int {
        let t = try type()
        guard case .int(let n) = t, n >= 1, n <= 64 else {
            throw LLVMError.unsupported("type \(t.description): only integers of 1 to 64 bits are supported")
        }
        return n
    }

    mutating func typedOperand() throws -> (width: Int, operand: Operand) {
        let n = try intType()
        try skipAttributes()
        return (n, try operand())
    }

    /// An integer of 1 to 64 bits or `ptr`: the types a value of this subset can have outside an aggregate.
    mutating func valueType() throws -> LType {
        let t = try type()
        switch t {
        case .int(let n) where n >= 1 && n <= 64: return t
        case .ptr: return t
        default: throw LLVMError.unsupported("type \(t.description): only integers of 1 to 64 bits and ptr are supported")
        }
    }

    /// A list of constant indices (`, 0, 1`), as `extractvalue` and `insertvalue` print them.
    mutating func constantIndices() throws -> [Int] {
        var indices: [Int] = []
        while eat(",") {
            guard case .int(let k) = try next(), let index = Int(k), index >= 0 else {
                throw LLVMError.unsupported("aggregate index that is not a constant")
            }
            indices.append(index)
        }
        guard !indices.isEmpty else { throw LLVMError.invalid("aggregate access without an index") }
        return indices
    }

    /// Parameter attributes, collected: the words, and the byte count of `dereferenceable(N)`.
    mutating func parameterAttributes() throws -> (words: Set<String>, dereferenceable: Int?) {
        var words = Set<String>()
        var dereferenceable: Int?
        while case .word(let w)? = peek(), !["true", "false", "undef", "poison", "null"].contains(w) {
            index += 1
            words.insert(w)
            if w == "range" { throw LLVMError.unsupported("range attribute on a parameter") }
            if peek() == .punct("(") {
                if w == "dereferenceable", case .int(let n)? = peek(1), peek(2) == .punct(")"), let k = Int(n) {
                    dereferenceable = k
                    index += 3
                } else {
                    index += 1
                    try skipBalanced(open: "(", close: ")")
                }
            } else if w == "align", case .int? = peek() {
                index += 1
            }
        }
        return (words, dereferenceable)
    }

    /// Parameter attributes: names such as `noundef`, `align 8`, `sret(%T)`. A `range` attribute restricts the
    /// possible inputs (violations are poison), which this subset does not model, so it is rejected.
    mutating func skipAttributes() throws {
        while case .word(let w)? = peek(), !["true", "false", "undef", "poison", "null"].contains(w) {
            index += 1
            if w == "range" { throw LLVMError.unsupported("range attribute on an argument") }
            if peek() == .punct("(") {
                index += 1; try skipBalanced(open: "(", close: ")")
            } else if w == "align", case .int? = peek() {
                index += 1
            }
        }
    }

    /// `(i32 lo, hi)` after the keyword `range` was consumed.
    mutating func rangeAttribute() throws -> RangeAttribute {
        try expect("(")
        let n = try intType()
        guard case .int(let lo) = try next() else { throw LLVMError.invalid("range bound") }
        try expect(",")
        guard case .int(let hi) = try next() else { throw LLVMError.invalid("range bound") }
        try expect(")")
        let mask: UInt64 = n == 64 ? ~0 : (1 << UInt64(n)) - 1
        let (l, h) = (try parseInteger(lo) & mask, try parseInteger(hi) & mask)
        guard l != h else { throw LLVMError.unsupported("empty or full range attribute") }
        return RangeAttribute(lo: l, hi: h)
    }
}

private func parseInteger(_ text: String) throws -> UInt64 {
    if text.hasPrefix("-") {
        guard let v = Int64(text) else { throw LLVMError.unsupported("integer literal \(text) is wider than 64 bits") }
        return UInt64(bitPattern: v)
    }
    guard let v = UInt64(text) else { throw LLVMError.unsupported("integer literal \(text) is wider than 64 bits") }
    return v
}

// MARK: - module

/// All function bodies found in one `-emit-ir` output. Bodies are parsed on demand.
package struct LLVMModule: Sendable {
    private var bodies: [String: [String]] = [:]
    private var headers: [String: String] = [:]
    /// Named types (`%TSi = type <{ i64 }>`), by name. `type opaque` and other unreadable definitions are left out.
    private(set) var namedTypes: [String: LType] = [:]

    package init(text: String) throws {
        let lines = text.components(separatedBy: "\n")
        guard lines.contains(where: { $0.hasPrefix("target triple") || $0.hasPrefix("define ") }) else {
            throw LLVMError.invalid("expected textual LLVM IR (use -emit-ir)")
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("define ") {
                let tokens = lex(line)
                guard let symbol = tokens.compactMap({ t -> String? in if case .global(let s) = t { return s } else { return nil } }).first
                else { throw LLVMError.invalid("define without a name: \(line)") }
                var body: [String] = []
                i += 1
                while i < lines.count, lines[i] != "}" {
                    body.append(lines[i])
                    i += 1
                }
                bodies[symbol] = body
                headers[symbol] = line
            } else if line.hasPrefix("%") {
                var cursor = Cursor(lex(line))
                if case .local(let name)? = try? cursor.next(), cursor.eat("="), cursor.eatWord("type"),
                    let type = try? cursor.type(), cursor.atEnd
                {
                    switch type {
                    case .tuple, .packed, .array, .int, .ptr, .named: namedTypes[name] = type
                    default: break
                    }
                }
            }
            i += 1
        }
    }

    package var symbols: [String] { Array(bodies.keys).sorted() }

    /// The unique function whose mangled name is `$s<module><name>...`, for example `("Fixture", "clamp")`.
    /// Same rule as `SILModule.symbol`: Swift mangles identically in SIL and LLVM IR.
    package func symbol(module: String, name: String) throws -> String {
        let prefix = "$s\(module.count)\(module)\(name.count)\(name)"
        let found = bodies.keys.filter { $0.hasPrefix(prefix) && !$0.hasSuffix("fu_") && !$0.contains("fu0_") }
        guard found.count == 1 else {
            throw LLVMError.invalid("expected exactly one function \(module).\(name), found \(found.count)")
        }
        return found[0]
    }

    package func function(_ symbol: String) throws -> LLVMFunction {
        guard let body = bodies[symbol], let header = headers[symbol] else {
            throw LLVMError.unsupported("no body for \(symbol) (declaration only)")
        }
        return try parseFunction(symbol: symbol, header: header, body: body)
    }
}

// MARK: - function parsing

/// Words that may stand between `define` and the result type: linkage, visibility, calling convention and result
/// attributes. Any other word there is rejected, so a convention this reader does not know is never misread.
private let headerPrefixWords: Set<String> = [
    "define", "internal", "private", "hidden", "protected", "linkonce_odr", "weak_odr", "linkonce", "weak", "external",
    "dso_local", "dllexport", "swiftcc", "ccc", "fastcc", "coldcc", "noundef", "zeroext", "signext", "noalias", "nonnull",
    "local_unnamed_addr", "unnamed_addr",
]

/// What a `define` line says.
private struct Header {
    let parameters: [LParameter]
    let result: LType
    let range: RangeAttribute?
}

/// Skips linkage, visibility, calling convention and result attributes, up to the result type; returns a `range`
/// result attribute if there is one.
private func skipHeaderPrefix(_ cursor: inout Cursor, symbol: String) throws -> RangeAttribute? {
    var range: RangeAttribute?
    while true {
        switch cursor.peek() {
        case .word(let w)? where w == "range":
            cursor.index += 1
            range = try cursor.rangeAttribute()
        case .word(let w)? where w == "dereferenceable" || w == "align":
            cursor.index += 1
            if cursor.eat("(") { try cursor.skipBalanced(open: "(", close: ")") } else if case .int? = cursor.peek() { cursor.index += 1 }
        case .word(let w)? where headerPrefixWords.contains(w):
            cursor.index += 1
        case .word(let w)? where w == "void" || w == "ptr" || (w.hasPrefix("i") && Int(w.dropFirst()) != nil):
            return range
        case .punct("{")?, .punct("<")?, .local?:
            return range
        case .word(let w)?:
            throw LLVMError.unsupported("'\(w)' in the definition of \(symbol)")
        default:
            throw LLVMError.invalid("definition of \(symbol) without a result type")
        }
    }
}

/// A result type this reader handles: one value, `void`, or a struct of values (Swift's multi-value returns).
private func isResultType(_ type: LType) -> Bool {
    switch type {
    case .void: true
    case .tuple(let fields): !fields.isEmpty && fields.allSatisfy(isValueType)
    default: isValueType(type)
    }
}

private func parseHeader(_ header: String, symbol: String) throws -> Header {
    var cursor = Cursor(lex(header))
    let range = try skipHeaderPrefix(&cursor, symbol: symbol)
    let result = try cursor.type()
    guard isResultType(result) else { throw LLVMError.unsupported("result type \(result.description) of \(symbol)") }
    guard case .global = try cursor.next() else { throw LLVMError.invalid("definition without a name: \(symbol)") }
    try cursor.expect("(")
    var parameters: [LParameter] = []
    if !cursor.eat(")") {
        repeat {
            let type = try cursor.type()
            guard isValueType(type) else {
                throw LLVMError.unsupported("parameter of type \(type.description) in \(symbol)")
            }
            let attributes = try cursor.parameterAttributes()
            guard case .local(let name) = try cursor.next() else { throw LLVMError.invalid("unnamed parameter in \(symbol)") }
            parameters.append(
                LParameter(type: type, name: name, attributes: attributes.words, dereferenceable: attributes.dereferenceable))
        } while cursor.eat(",")
        try cursor.expect(")")
    }
    return Header(parameters: parameters, result: result, range: range)
}

/// An integer of 1 to 64 bits, or `ptr`.
func isValueType(_ type: LType) -> Bool {
    switch type {
    case .int(let n): n >= 1 && n <= 64
    case .ptr: true
    default: false
    }
}

/// Metadata attachments (`, !prof !17`) never change the meaning of a scalar instruction.
private func strippingMetadata(_ tokens: [Token]) -> [Token] {
    var t = tokens
    while case .meta? = t.last {
        t.removeLast()
        if case .meta? = t.last { t.removeLast() }
        if t.last == .punct(",") { t.removeLast() }
    }
    return t
}

/// The body with each multi-line `switch` joined into one line (its cases are printed one per line).
private func logicalLines(_ body: [String]) -> [String] {
    var lines: [String] = []
    var pending: String?
    for raw in body {
        let text = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        if var open = pending {
            open += " " + text
            if text.trimmingCharacters(in: .whitespaces) == "]" {
                lines.append(open)
                pending = nil
            } else {
                pending = open
            }
            continue
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("switch "), trimmed.hasSuffix("[") {
            pending = text
        } else {
            lines.append(raw)
        }
    }
    if let open = pending { lines.append(open) }  // unterminated: the parser reports it
    return lines
}

private let allowedFlags: [BinaryOp: Set<String>] = [
    .add: ["nuw", "nsw"], .sub: ["nuw", "nsw"], .mul: ["nuw", "nsw"], .shl: ["nuw", "nsw"],
    .udiv: ["exact"], .sdiv: ["exact"], .lshr: ["exact"], .ashr: ["exact"], .or: ["disjoint"],
    .urem: [], .srem: [], .and: [], .xor: [],
]

private func parseFunction(symbol: String, header: String, body: [String]) throws -> LLVMFunction {
    let parsed = try parseHeader(header, symbol: symbol)
    let (parameters, returnType, resultRange) = (parsed.parameters, parsed.result, parsed.range)

    var blocks: [Block] = []
    var label: String?
    var phis: [Phi] = []
    var instructions: [Instruction] = []

    func finish(_ terminator: Terminator) throws {
        guard let id = label else { throw LLVMError.invalid("terminator outside a block in \(symbol)") }
        blocks.append(Block(id: id, phis: phis, instructions: instructions, terminator: terminator))
        label = nil; phis = []; instructions = []
    }

    for raw in logicalLines(body) {
        let tokens = strippingMetadata(lex(raw))
        if tokens.isEmpty { continue }
        if !raw.hasPrefix(" "), !raw.hasPrefix("\t") {
            guard label == nil else { throw LLVMError.invalid("block \(label ?? "") has no terminator in \(symbol)") }
            guard tokens.count == 2, tokens[1] == .punct(":") else { throw LLVMError.invalid("unexpected line in \(symbol): \(raw)") }
            switch tokens[0] {
            case .word(let w), .int(let w), .string(let w): label = w
            default: throw LLVMError.invalid("bad label: \(raw)")
            }
            continue
        }
        if label == nil, blocks.isEmpty { label = "" }  // an unnamed entry block cannot be referenced
        guard label != nil else { throw LLVMError.invalid("instruction outside a block in \(symbol): \(raw)") }
        var cursor = Cursor(tokens)
        var resultName: String?
        if case .local(let name)? = cursor.peek(), cursor.peek(1) == .punct("=") {
            resultName = name
            cursor.index += 2
        }
        let opcode = try cursor.expectWord()
        func need() throws -> String {
            guard let r = resultName else { throw LLVMError.invalid("\(opcode) without a result in \(symbol)") }
            return r
        }
        func branchTarget() throws -> String {
            guard cursor.eatWord("label"), case .local(let target) = try cursor.next() else {
                throw LLVMError.invalid("branch target in \(symbol)")
            }
            return target
        }
        switch opcode {
        case "add", "sub", "mul", "udiv", "sdiv", "urem", "srem", "shl", "lshr", "ashr", "and", "or", "xor":
            guard let op = BinaryOp(rawValue: opcode), let allowed = allowedFlags[op] else { throw LLVMError.invalid(opcode) }
            var flags = Set<String>()
            while case .word(let w)? = cursor.peek(), allowed.contains(w) { flags.insert(w); cursor.index += 1 }
            let n = try cursor.intType()
            let a = try cursor.operand()
            try cursor.expect(",")
            let b = try cursor.operand()
            instructions.append(.binary(result: try need(), op: op, flags: flags, width: n, a, b))
        case "icmp":
            var flags = Set<String>()
            if cursor.eatWord("samesign") { flags.insert("samesign") }
            guard let predicate = Predicate(rawValue: try cursor.expectWord()) else {
                throw LLVMError.unsupported("icmp predicate in \(raw)")
            }
            let n = try cursor.intType()
            let a = try cursor.operand()
            try cursor.expect(",")
            let b = try cursor.operand()
            instructions.append(.icmp(result: try need(), predicate: predicate, flags: flags, width: n, a, b))
        case "select":
            let cond = try cursor.typedOperand()
            guard cond.width == 1 else { throw LLVMError.unsupported("select on a non-i1 condition") }
            try cursor.expect(",")
            let ta = try cursor.valueType()
            let a = try cursor.operand()
            try cursor.expect(",")
            let tb = try cursor.valueType()
            let b = try cursor.operand()
            guard ta == tb else { throw LLVMError.invalid("select operand types differ") }
            instructions.append(.select(result: try need(), condition: cond.operand, type: ta, a, b))
        case "zext", "sext", "trunc":
            var flags = Set<String>()
            while case .word(let w)? = cursor.peek(), ["nneg", "nuw", "nsw"].contains(w) { flags.insert(w); cursor.index += 1 }
            let from = try cursor.typedOperand()
            guard cursor.eatWord("to") else { throw LLVMError.invalid("cast without 'to': \(raw)") }
            let to = try cursor.intType()
            guard let kind = CastKind(rawValue: opcode) else { throw LLVMError.invalid(opcode) }
            instructions.append(.cast(result: try need(), kind: kind, flags: flags, from: from.width, from.operand, to: to))
        case "inttoptr", "ptrtoint":
            let from = try cursor.type()
            let operand = try cursor.operand()
            guard cursor.eatWord("to") else { throw LLVMError.invalid("cast without 'to': \(raw)") }
            let to = try cursor.type()
            let toPointer = opcode == "inttoptr"
            guard (toPointer ? (from, to) : (to, from)) == (.int(64), .ptr), cursor.atEnd else {
                throw LLVMError.unsupported("\(opcode) other than between i64 and ptr in \(symbol)")
            }
            instructions.append(.pointerCast(result: try need(), toPointer: toPointer, operand))
        case "freeze":
            let v = try cursor.typedOperand()
            instructions.append(.freeze(result: try need(), width: v.width, v.operand))
        case "phi":
            let type = try cursor.valueType()
            var entries: [PhiEntry] = []
            repeat {
                try cursor.expect("[")
                let value = try cursor.operand()
                try cursor.expect(",")
                guard case .local(let from) = try cursor.next() else { throw LLVMError.invalid("phi predecessor in \(raw)") }
                try cursor.expect("]")
                entries.append(PhiEntry(operand: value, block: from))
            } while cursor.eat(",")
            guard instructions.isEmpty else { throw LLVMError.invalid("phi after a non-phi instruction in \(symbol)") }
            phis.append(Phi(result: try need(), type: type, entries: entries))
        case "br":
            if case .word("label")? = cursor.peek() {
                try finish(.branch(try branchTarget()))
            } else {
                let cond = try cursor.typedOperand()
                guard cond.width == 1 else { throw LLVMError.invalid("br on a non-i1 value") }
                try cursor.expect(",")
                let yes = try branchTarget()
                try cursor.expect(",")
                let no = try branchTarget()
                try finish(.conditional(cond.operand, yes, no))
            }
        case "switch":
            let value = try cursor.typedOperand()
            try cursor.expect(",")
            let otherwise = try branchTarget()
            try cursor.expect("[")
            var cases: [(value: UInt64, target: String)] = []
            while !cursor.eat("]") {
                let k = try cursor.typedOperand()
                guard k.width == value.width, case .constant(let v) = k.operand else {
                    throw LLVMError.invalid("switch case in \(symbol)")
                }
                try cursor.expect(",")
                cases.append((v, try branchTarget()))
            }
            guard cursor.atEnd else { throw LLVMError.invalid("text after a switch in \(symbol)") }
            try finish(.switchInteger(width: value.width, value.operand, defaultTarget: otherwise, cases: cases))
        case "ret":
            if cursor.eatWord("void") {
                try finish(.returnedVoid)
            } else {
                let type = try cursor.type()
                try finish(.returned(type: type, try cursor.operand()))
            }
        case "unreachable":
            try finish(.unreachable)
        case "extractvalue":
            let aggregate = try cursor.type()
            let source = try cursor.operand()
            instructions.append(
                .extractValue(result: try need(), aggregate: aggregate, source: source, indices: try cursor.constantIndices()))
        case "insertvalue":
            let aggregate = try cursor.type()
            let base = try cursor.operand()
            try cursor.expect(",")
            let element = try cursor.type()
            let value = try cursor.operand()
            instructions.append(
                .insertValue(
                    result: try need(), aggregate: aggregate, base: base, element: element, value: value,
                    indices: try cursor.constantIndices()))
        case "alloca":
            let type = try cursor.type()
            instructions.append(.alloca(result: try need(), type: type))
            if cursor.eat(",") {
                guard cursor.eatWord("align"), case .int? = cursor.peek() else {
                    throw LLVMError.unsupported("alloca with a count or address space")
                }
                cursor.index += 1
                if !cursor.atEnd { throw LLVMError.unsupported("alloca with extra operands: \(raw)") }
            }
        case "store":
            if cursor.peek() == .word("volatile") || cursor.peek() == .word("atomic") {
                throw LLVMError.unsupported("volatile or atomic store in \(symbol)")
            }
            let type = try cursor.valueType()
            let value = try cursor.operand()
            try cursor.expect(",")
            guard try cursor.type() == .ptr else { throw LLVMError.invalid("store through a non-pointer") }
            let address = try cursor.operand()
            instructions.append(.store(type: type, value: value, address: address))
        case "load":
            if cursor.peek() == .word("volatile") || cursor.peek() == .word("atomic") {
                throw LLVMError.unsupported("volatile or atomic load in \(symbol)")
            }
            let type = try cursor.valueType()
            try cursor.expect(",")
            guard try cursor.type() == .ptr else { throw LLVMError.invalid("load through a non-pointer") }
            let address = try cursor.operand()
            instructions.append(.load(result: try need(), type: type, address: address))
        case "getelementptr":
            while case .word(let w)? = cursor.peek(), w == "inbounds" || w == "nuw" || w == "nusw" { cursor.index += 1 }
            let source = try cursor.type()
            try cursor.expect(",")
            guard try cursor.type() == .ptr else { throw LLVMError.unsupported("vector getelementptr") }
            let base = try cursor.operand()
            var indices: [Int64] = []
            while cursor.eat(",") {
                let index = try cursor.typedOperand()
                guard case .constant(let v) = index.operand else {
                    throw LLVMError.unsupported("getelementptr with a variable index in \(symbol)")
                }
                // Sign-extend from the index type's width: indices are signed.
                let shift = UInt64(64 - index.width)
                indices.append(Int64(bitPattern: v << shift) >> Int64(shift))
            }
            guard !indices.isEmpty else { throw LLVMError.invalid("getelementptr without an index in \(symbol)") }
            instructions.append(.elementAddress(result: try need(), base: base, source: source, indices: indices))
        case "call", "tail", "musttail", "notail":
            if opcode != "call" { guard cursor.eatWord("call") else { throw LLVMError.invalid("call expected") } }
            instructions.append(try parseCall(&cursor, result: resultName, raw: raw))
        default:
            throw LLVMError.unsupported("instruction '\(opcode)' in \(symbol)")
        }
    }
    guard label == nil else { throw LLVMError.invalid("block \(label ?? "") has no terminator in \(symbol)") }
    guard !blocks.isEmpty else { throw LLVMError.invalid("\(symbol) has no body") }
    return LLVMFunction(symbol: symbol, parameters: parameters, returnType: returnType, resultRange: resultRange, blocks: blocks)
}

private func parseCall(_ cursor: inout Cursor, result: String?, raw: String) throws -> Instruction {
    var range: RangeAttribute?
    // calling convention, fast-math flags and return attributes
    let skippable: Set<String> = [
        "swiftcc", "ccc", "fastcc", "coldcc", "swifttailcc", "noundef", "zeroext", "signext", "nnan", "ninf",
        "nsz", "arcp", "contract", "afn", "reassoc", "fast", "noalias", "nonnull",
    ]
    while case .word(let w)? = cursor.peek(), skippable.contains(w) || w == "range" {
        cursor.index += 1
        if w == "range" { range = try cursor.rangeAttribute() }
    }
    let returns = try cursor.type()
    switch try cursor.next() {
    case .word("asm"):
        while case .word? = cursor.peek() { cursor.index += 1 }  // sideeffect, alignstack, ...
        guard cursor.peek() == .string("nop"), cursor.peek(1) == .punct(","), cursor.peek(2) == .string(""),
            cursor.peek(3) == .punct("("), cursor.peek(4) == .punct(")")
        else {
            throw LLVMError.unsupported("inline assembly: \(raw)")
        }
        return .nop
    case .global(let callee):
        if failureFunctionPrefixes.contains(where: { callee.hasPrefix($0) }) { return .failure(callee: callee) }
        try cursor.expect("(")
        var arguments: [Argument] = []
        if !cursor.eat(")") {
            repeat {
                let type = try cursor.type()
                try cursor.skipAttributes()
                arguments.append(Argument(type: type, operand: try cursor.operand()))
            } while cursor.eat(",")
            try cursor.expect(")")
        }
        if cursor.peek() == .punct("[") { throw LLVMError.unsupported("operand bundles: \(raw)") }
        return .call(result: result, callee: callee, arguments: arguments, returns: returns, range: range)
    case let t:
        throw LLVMError.unsupported("callee \(t) (indirect calls are not supported)")
    }
}
