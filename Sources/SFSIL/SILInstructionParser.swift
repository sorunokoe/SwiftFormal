// Parsing one instruction line into an `Instruction` (plan item H1).

import Foundation
import SFSemantics

func parseInstruction(_ line: String, types: TypeContext, dynamicAccesses: Set<String> = []) throws(SILError) -> Instruction {
    if IgnoredInstruction.matches(line) { return .ignored }
    if let object = try parseObjectInstruction(line, types: types, dynamicAccesses: dynamicAccesses) { return object }
    if let foreign = try parseForeignInstruction(line, types: types) { return foreign }
    if line.hasPrefix("("), let eq = line.range(of: ") = begin_apply ") {
        return try parseBeginApply(
            names: String(line[line.index(after: line.startIndex)..<eq.lowerBound]), String(line[eq.upperBound...]), line)
    }
    if line.hasPrefix("("), let eq = line.range(of: ") = begin_cow_mutation ") {
        let names = try parseValueList(String(line[line.index(after: line.startIndex)..<eq.lowerBound]))
        let source = dropBracket(String(line[eq.upperBound...]))
        guard names.count == 2, isValue(source), leadingAttributes(String(line[eq.upperBound...])) == ["native"] else {
            throw SILError.unsupported("begin_cow_mutation: \(line)")
        }
        return .beginCOW(flag: names[0], buffer: names[1], source: source)
    }
    if line.hasPrefix("cond_fail ") {
        let parts = splitTopLevel(String(line.dropFirst(10)))
        guard parts.count == 2 else { throw SILError.invalid("bad cond_fail: \(line)") }
        let operand = parts[0].components(separatedBy: " : ")
        guard isValue(operand[0]) else { throw SILError.invalid("bad cond_fail: \(line)") }
        return .condFail(operand[0])
    }
    if let enumInstruction = try parseEnumStatement(line) { return enumInstruction }
    if line.hasPrefix("store ") {
        let body = String(line.dropFirst(6))
        guard let to = body.range(of: " to ") else { throw SILError.invalid("bad store: \(line)") }
        let value = String(body[..<to.lowerBound])
        let address = dropBracket(String(body[to.upperBound...]))
        guard isValue(value), isValue(address) else { throw SILError.unsupported("store: \(line)") }
        return .store(value: value, address: address)
    }

    guard let eq = line.range(of: " = "), isValue(String(line[..<eq.lowerBound])) else {
        throw SILError.unsupported("instruction: \(line)")
    }
    let result = String(line[..<eq.lowerBound])
    let rhs = String(line[eq.upperBound...])
    let head = String(rhs.prefix { $0 != " " })
    let rest = String(rhs.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)

    // The bytes of a string literal: only the literal summary reads them (`StdlibSummary.TextOperation.literal`).
    if head == "string_literal" {
        let quoted = rest.hasPrefix("utf8 \"") && rest.hasSuffix("\"") && rest.count >= "utf8 \"\"".count
        let text = quoted ? StringIdentity.unescapeSIL(rest.dropFirst("utf8 \"".count).dropLast()) : nil
        return .stringLiteral(result: result, text: text)
    }
    // Failure-message plumbing (pointers, StaticString). Any live use of these values is rejected by the encoder.
    if (head == "struct"
        && (rest.hasPrefix("$StaticString")
            || rest.hasPrefix("$_ArrayBody") || rest.hasPrefix("$_SwiftArrayBodyStorage")))
        || (head == "builtin" && rest.hasPrefix("\"ptrtoint_Word\""))
    {
        return .ignored
    }

    if let enumInstruction = try parseEnumInstruction(head: head, result: result, rest: rest, types: types) {
        return enumInstruction
    }
    guard let instruction = try readInstruction(InstructionText(head: head, result: result, rest: rest, line: line, types: types))
    else { return try types.opaqueValueWitness(head: head, result: result, rest: rest, line: line) }
    return instruction
}

/// `(%a, %token) = begin_apply %f<T>(%i, %array) : $@yield_once @convention(method) <...> (...) -> @yields @inout T`.
private func parseBeginApply(names: String, _ rest: String, _ line: String) throws(SILError) -> Instruction {
    let results = try parseValueList(names)
    guard results.count == 2, let open = rest.firstIndex(of: "("), let close = rest.range(of: ") : $@yield_once ") else {
        throw SILError.unsupported("begin_apply: \(line)")
    }
    var callee = String(rest[..<open])
    var substitutions: [String] = []
    if let angle = callee.firstIndex(of: "<"), callee.hasSuffix(">") {
        substitutions = splitTopLevel(String(callee[callee.index(after: angle)..<callee.index(before: callee.endIndex)]))
        callee = String(callee[..<angle])
    }
    let signature = String(rest[close.upperBound...])
    guard isValue(callee), let arrow = signature.range(of: ") -> @yields @inout ", options: .backwards),
        let parameters = FunctionSignature(String(signature[..<arrow.lowerBound]) + ") -> ()")
    else {
        throw SILError.unsupported("begin_apply: \(line)")
    }
    let arguments = try parseValueList(String(rest[rest.index(after: open)..<close.lowerBound]))
    let conventions = parameters.parameters.map(\.convention)
    guard arguments.count == conventions.count else { throw SILError.invalid("begin_apply argument count: \(line)") }
    return .beginApply(
        address: results[0], callee: callee, arguments: arguments, substitutions: substitutions, conventions: conventions)
}
