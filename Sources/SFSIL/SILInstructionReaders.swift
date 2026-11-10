// One reader per instruction name, grouped by what the instruction does (plan item H1). `parseInstruction`
// handles the lines that are not `%r = name …` first, then asks `readInstruction`.

import Foundation
import SFSemantics

/// The reader of each instruction name, nil for a name without one (plan item H1).
func readInstruction(_ t: InstructionText) throws(SILError) -> Instruction? {
    if let instruction = try readConstantOrAggregate(t) { return instruction }
    if let instruction = try readCall(t) { return instruction }
    if let instruction = try readAddress(t) { return instruction }
    if let instruction = try readReference(t) { return instruction }
    return nil
}

/// Constants (literals, metatypes, constant globals, key paths) and structs and tuples.
private func readConstantOrAggregate(_ t: InstructionText) throws(SILError) -> Instruction? {
    switch t.head {
    case "float_literal": try readFloatLiteral(t)
    case "integer_literal": try readIntegerLiteral(t)
    case "metatype": try readMetatype(t)
    case "global_value": try readGlobalValue(t)
    case "keypath": try readKeypath(t)
    case "struct": try readStruct(t)
    case "tuple": try readTuple(t)
    case "struct_extract", "struct_element_addr": try readStructExtract(t)
    case "tuple_extract", "tuple_element_addr": try readTupleExtract(t)
    default: nil
    }
}

/// Builtins, function values and calls.
private func readCall(_ t: InstructionText) throws(SILError) -> Instruction? {
    switch t.head {
    case "builtin": try readBuiltin(t)
    case "function_ref": try readFunctionRef(t)
    case "apply": try readApply(t)
    case "thin_to_thick_function", "partial_apply": try readThinToThickFunction(t)
    case "convert_function", "convert_escape_to_noescape", "mark_dependence": try readConvertFunction(t)
    case "end_apply", "abort_apply": try readEndApply(t)
    default: nil
    }
}

// MARK: Literals and other constants: numbers, metatypes, constant global tables, key path literals.

/// `float_literal`.
private func readFloatLiteral(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    // `float_literal $Builtin.FPIEEE64, 0x3FF0000000000000 // 1`: the bit pattern, exactly.
    let parts = splitTopLevel(rest)
    guard parts.count == 2, parts[0].hasPrefix("$Builtin.FPIEEE"), let w = scalarWidth(parts[0]), parts[1].hasPrefix("0x"),
        let bits = UInt64(parts[1].dropFirst(2), radix: 16)
    else { throw SILError.unsupported("float literal: \(line)") }
    return .literal(result: result, width: w, value: bits)
}

/// `integer_literal`.
private func readIntegerLiteral(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    let parts = splitTopLevel(rest)
    guard parts.count == 2, parts[0].hasPrefix("$Builtin."), let w = scalarWidth(parts[0]) else {
        throw SILError.unsupported("integer literal: \(line)")
    }
    let value: UInt64
    if let s = Int64(parts[1]) {
        value = UInt64(bitPattern: s)
    } else if let u = UInt64(parts[1]) {
        value = u
    } else {
        throw SILError.invalid("literal out of range: \(line)")
    }
    let mask: UInt64 = w == 64 ? ~0 : (1 << UInt64(w)) - 1
    return .literal(result: result, width: w, value: value & mask)
}

/// `metatype`.
private func readMetatype(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line, types) = (t.result, t.rest, t.line, t.types)
    let type = try types.resolve(rest)
    guard case .aggregate(_, let fields) = type, fields.isEmpty else { throw SILError.unsupported("metatype: \(line)") }
    return .makeAggregate(result: result, type: type, operands: [])
}

/// `global_value`.
private func readGlobalValue(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    guard let at = rest.range(of: "@"), isValue(result) else { throw SILError.unsupported("global_value: \(line)") }
    return .globalValue(result: result, symbol: String(rest[at.upperBound...].prefix { $0 != " " }))
}

/// `keypath`.
private func readKeypath(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line, types) = (t.result, t.rest, t.line, t.types)
    return .makeAggregate(result: result, type: try types.keyPathLiteral(rest, line), operands: [])
}

// MARK: Making and taking apart structs and tuples, and the addresses of their fields.

/// `struct`.
private func readStruct(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line, types) = (t.result, t.rest, t.line, t.types)
    guard let open = rest.firstIndex(of: "("), rest.hasSuffix(")"), !rest.hasPrefix("$Builtin") else {
        throw SILError.unsupported("struct: \(line)")
    }
    let typeText = String(rest[..<open])
    let operands = try parseValueList(String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]))
    if TypeContext.arrayElement(String(typeText.dropFirst())) != nil {
        throw SILError.unsupported("an array built from its buffer: \(line)")
    }
    if let w = scalarWidth(typeText) {
        guard operands.count == 1 else { throw SILError.unsupported("struct with several fields: \(line)") }
        return .retype(result: result, source: operands[0], width: w)
    }
    let type = try types.resolve(typeText)
    guard case .aggregate(_, let fields) = type, fields.count == operands.count else {
        throw SILError.invalid("struct operands do not match the stored properties: \(line)")
    }
    return .makeAggregate(result: result, type: type, operands: operands)
}

/// `tuple`.
private func readTuple(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    var list = Substring(rest)
    if list.hasPrefix("$(") {
        // A labeled tuple names its type first: `tuple $(w: Int32, h: Int32) (%1, %2)`. The labels carry no data.
        var depth = 0
        var end = list.index(after: list.startIndex)
        while end < list.endIndex {
            if list[end] == "(" { depth += 1 } else if list[end] == ")" { depth -= 1 }
            end = list.index(after: end)
            if depth == 0 { break }
        }
        list = list[end...].drop { $0 == " " }
    }
    guard list.hasPrefix("("), list.hasSuffix(")") else { throw SILError.unsupported("tuple: \(line)") }
    let operands = try parseValueList(String(list.dropFirst().dropLast()))
    return .makeAggregate(result: result, type: nil, operands: operands)  // the tuple type is built from the operands
}

/// `struct_extract`, `struct_element_addr`.
private func readStructExtract(_ t: InstructionText) throws(SILError) -> Instruction {
    let (head, result, rest, line, types) = (t.head, t.result, t.rest, t.line, t.types)
    let parts = splitTopLevel(rest)
    guard parts.count == 2, isValue(parts[0]), parts[1].hasPrefix("#"), let dot = parts[1].lastIndex(of: ".") else {
        throw SILError.unsupported("\(head): \(line)")
    }
    let typeName = String(parts[1][parts[1].index(after: parts[1].startIndex)..<dot])
    let fieldName = String(parts[1][parts[1].index(after: dot)...])
    if head == "struct_extract", ["#Array._buffer", "#_ArrayBuffer._storage", "#_BridgeStorage.rawValue"].contains(parts[1]) {
        return .arrayStorage(result: result, source: parts[0])
    }
    if fieldName == "_value", scalarWidth(typeName) != nil {
        // A scalar's only stored property is its builtin payload: same bits.
        return head == "struct_extract"
            ? .retype(result: result, source: parts[0], width: scalarWidth(typeName)!)
            : .alias(result: result, source: parts[0])
    }
    let (fields, owner) = try types.fieldOwner(typeName)
    guard let index = fields.firstIndex(of: fieldName) else {
        throw SILError.unsupported("\(head) of unknown field: \(line)")
    }
    return head == "struct_extract"
        ? .extract(result: result, source: parts[0], field: index, expected: owner)
        : .elementAddress(result: result, base: parts[0], field: index, expected: owner)
}

/// `tuple_extract`, `tuple_element_addr`.
private func readTupleExtract(_ t: InstructionText) throws(SILError) -> Instruction {
    let (head, result, rest, line) = (t.head, t.result, t.rest, t.line)
    let parts = splitTopLevel(rest)
    guard parts.count == 2, isValue(parts[0]), let index = Int(parts[1]), index >= 0 else {
        throw SILError.unsupported("\(head): \(line)")
    }
    return head == "tuple_extract"
        ? .extract(result: result, source: parts[0], field: index, expected: .tuple)
        : .elementAddress(result: result, base: parts[0], field: index, expected: .tuple)
}

// MARK: `builtin "…"`: the compiler's primitive operations (`S0`'s table).

/// `builtin`.
private func readBuiltin(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    guard rest.hasPrefix("\""), let endQuote = rest.dropFirst().firstIndex(of: "\"") else {
        throw SILError.invalid("bad builtin: \(line)")
    }
    let name = String(rest[rest.index(after: rest.startIndex)..<endQuote])
    let after = String(rest[rest.index(after: endQuote)...])
    // `builtin "sizeof"<T>()`: a builtin with generic arguments, which S0 has no model of (except `getEnumTag`).
    if after.hasPrefix("<") { return try readGenericBuiltin(name, result: result, after, line: line) }
    guard after.hasPrefix("("), let close = after.range(of: ") : ") else { throw SILError.invalid("bad builtin: \(line)") }
    let arguments = try parseValueList(String(after[after.index(after: after.startIndex)..<close.lowerBound]))
    let type = String(after[close.upperBound...])
    if name == "truncOrBitCast_Int64_Word" || name == "truncOrBitCast_Word_Int64" {
        guard arguments.count == 1, scalarWidth(type) == 64 else { throw SILError.invalid("bad builtin: \(line)") }
        return .retype(result: result, source: arguments[0], width: 64)
    }
    if let float = S0FloatInstance(builtinName: name) {
        guard arguments.count == float.operandWidths.count, scalarWidth(type) == float.resultWidth else {
            throw SILError.invalid("bad builtin: \(line)")
        }
        return .floatBuiltin(result: result, op: float, arguments: arguments)
    }
    guard let op = S0Instance(builtinName: name) else { throw SILError.unsupported("builtin \(name)") }
    guard arguments.count == op.arity else { throw SILError.invalid("wrong arity for \(name): \(line)") }
    let expected = op.resultWidths
    let typeOK =
        expected.count == 2
        ? overflowWidth(type) == expected[0]
        : (scalarWidth(type) == expected[0] && type.hasPrefix("$Builtin."))
    guard typeOK else { throw SILError.invalid("result type of \(name) disagrees with the table: \(type)") }
    return .builtin(result: result, op: op, arguments: arguments)
}

// MARK: Function values and calls.

/// `function_ref`.
private func readFunctionRef(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    guard rest.hasPrefix("@"), let end = rest.firstIndex(of: " ") else { throw SILError.invalid("bad function_ref: \(line)") }
    return .functionRef(result: result, symbol: String(rest[rest.index(after: rest.startIndex)..<end]))
}

/// `apply`.
private func readApply(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line, types) = (t.result, t.rest, t.line, t.types)
    // The arguments open after the substitutions, which may themselves hold parentheses (`<() -> ()>`).
    var argumentsFrom = rest.startIndex
    if let a = rest.firstIndex(of: "<"), let p = rest.firstIndex(of: "("), a < p,
        let c = matchingClose(rest[a...], open: "<", close: ">")
    {
        argumentsFrom = c
    }
    guard let open = rest[argumentsFrom...].firstIndex(of: "(") else { throw SILError.unsupported("apply: \(line)") }
    var callee = String(rest[..<open])
    var substitutions: [String] = []
    if let angle = callee.firstIndex(of: "<"), callee.hasSuffix(">") {
        // `apply %5<Int32>(...)`: only calls with a standard-library summary accept substitutions (the encoder checks).
        substitutions = splitTopLevel(String(callee[callee.index(after: angle)..<callee.index(before: callee.endIndex)]))
        callee = String(callee[..<angle])
    }
    guard isValue(callee) else { throw SILError.unsupported("apply (indirect): \(line)") }
    guard let close = rest.range(of: ") : $"),
        let signature = FunctionSignature(String(rest[close.upperBound...]))
            ?? thickSignature(String(rest[close.upperBound...])).flatMap(FunctionSignature.init)
    else {
        // A callee without `@convention(...)` that `thickSignature` cannot read: a generic or `@substituted` closure.
        let thick = rest.range(of: ") : $").map { !rest[$0.upperBound...].hasPrefix("@convention(") } ?? false
        throw SILError.unsupported(thick ? "indirect call through a closure: \(line)" : "apply: \(line)")
    }
    let arguments = try parseValueList(String(rest[rest.index(after: open)..<close.lowerBound]))
    // An `@out` result is passed as an extra first argument: the address the callee writes it to.
    let parameterConventions = try types.objectConventions(signature).conventions
    let conventions =
        (signature.indirectResult == nil ? [] : [ParameterConvention.out]) + (signature.errorIsIndirect ? [.out] : [])
        + parameterConventions
    guard arguments.count == conventions.count else { throw SILError.invalid("apply argument count: \(line)") }
    let type = try types.resolveObjectOrValue(signature.result)
    return .apply(
        result: result, callee: callee, arguments: arguments, type: type, substitutions: substitutions, conventions: conventions)
}

/// `end_apply`, `abort_apply`.
private func readEndApply(_ t: InstructionText) throws(SILError) -> Instruction {
    return .ignored
}

/// `thin_to_thick_function`, `partial_apply`.
private func readThinToThickFunction(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, types) = (t.result, t.rest, t.types)
    // A new closure. A literal is run only by `Optional.map` (`SILOptionalMap.swift`) and through its identity
    // (`SILClosureCalls.swift`); any other closure is never called. A non-escaping one (`[on_stack]`, `to $@noescape`) is never destroyed.
    let operand = dropBracket(rest)
    let callee = String(operand.prefix { $0 != "(" && $0 != " " })
    var captures: [String] = []
    if t.head == "partial_apply", let open = operand.firstIndex(of: "("), let close = operand.range(of: ") : ") {
        captures = try parseValueList(String(operand[operand.index(after: open)..<close.lowerBound]))
    }
    let noescape = rest.contains("[on_stack]") || rest.contains(" to $@noescape ")
    let type = noescape ? TypeContext.closure : try types.closureType(rest)
    guard isValue(callee) else { return .makeAggregate(result: result, type: type, operands: []) }
    return .closure(result: result, type: type, callee: callee, captures: captures)
}

/// `convert_function`, `convert_escape_to_noescape`, `mark_dependence`.
private func readConvertFunction(_ t: InstructionText) throws(SILError) -> Instruction {
    let (head, result, rest, line) = (t.head, t.result, t.rest, t.line)
    let source = String(dropBracket(rest).prefix { $0 != " " })
    guard isValue(source) else { throw SILError.unsupported("\(head): \(line)") }
    return .alias(result: result, source: source)
}
