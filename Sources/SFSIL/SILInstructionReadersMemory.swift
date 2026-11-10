// The readers of instructions on memory and references: stack slots, loads, addresses, array storage, reference
// casts and existential boxes (plan item H1; dispatched from `readInstruction`).

import Foundation
import SFSemantics

/// Stack slots, loads and addresses.
func readAddress(_ t: InstructionText) throws(SILError) -> Instruction? {
    switch t.head {
    case "alloc_stack": try readAllocStack(t)
    case "load": try readLoad(t)
    case "begin_access": try readBeginAccess(t)
    case "index_addr": try readIndexAddr(t)
    case "ref_tail_addr": try readRefTailAddr(t)
    case "ref_element_addr": try readRefElementAddr(t)
    case "global_addr": try readGlobalAddress(t)
    case "pointer_to_address": try readPointerToAddress(t)
    default: nil
    }
}

/// Reference casts that keep the same object, array storage and existential boxes.
func readReference(_ t: InstructionText) throws(SILError) -> Instruction? {
    switch t.head {
    case "upcast", "end_cow_mutation", "begin_dealloc_ref": try readUpcast(t)
    case "unchecked_ref_cast": try readUncheckedRefCast(t)
    case "alloc_ref": try readAllocRef(t)
    case "alloc_existential_box": try readAllocExistentialBox(t)
    case "project_existential_box": try readProjectExistentialBox(t)
    case "init_existential_addr": try readInitExistentialAddress(t)
    case "open_existential_ref": try readOpenExistentialRef(t)
    default: nil
    }
}

/// One `%r = head rest` instruction line, as the readers below see it.
struct InstructionText {
    let head: String
    let result: String
    let rest: String
    let line: String
    let types: TypeContext
}

// MARK: Stack slots, loads, addresses, array storage and the reference casts that keep the same object.

/// `alloc_existential_box`.
private func readAllocExistentialBox(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    let parts = splitTopLevel(rest)
    guard parts.count == 2, parts[0].hasPrefix("$any "), parts[1].hasPrefix("$") else {
        throw SILError.unsupported("alloc_existential_box: \(line)")
    }
    return .existentialBox(result: result, payload: String(parts[1].dropFirst()))
}

/// `project_existential_box`.
private func readProjectExistentialBox(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    guard let box = rest.range(of: " in "), isValue(String(rest[box.upperBound...])) else {
        throw SILError.unsupported("project_existential_box: \(line)")
    }
    return .boxedValueAddress(result: result)
}

/// `init_existential_addr %base, $T`.
private func readInitExistentialAddress(_ t: InstructionText) throws(SILError) -> Instruction {
    let parts = splitTopLevel(t.rest)
    guard parts.count == 2, isValue(parts[0]), parts[1].hasPrefix("$") else {
        throw SILError.unsupported("init_existential_addr: \(t.line)")
    }
    return .existentialAddress(result: t.result, base: parts[0], payload: String(parts[1].dropFirst()))
}

/// `alloc_stack`.
private func readAllocStack(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, types) = (t.result, t.rest, t.types)
    let operand = dropBracket(rest)
    let typeText = splitTopLevel(operand).first ?? operand  // `$Int32, var, name "s", type $Int32`
    // The error address of a call that cannot throw (`@error_indirect Never`, `SILOptionalMap.swift`): no value.
    if typeText == "$Never" { return .allocStack(result: result, type: .aggregate(name: "Never", fields: [])) }
    return .allocStack(result: result, type: try types.resolve(typeText))
}

/// `load`.
private func readLoad(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    let address = dropBracket(rest)
    guard isValue(address) else { throw SILError.unsupported("load: \(line)") }
    return .load(result: result, address: address)
}

/// `begin_access`.
private func readBeginAccess(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    let attributes = leadingAttributes(rest)
    let address = dropBracket(rest)
    guard attributes.contains("static"), !attributes.contains("dynamic"), isValue(address) else {
        throw SILError.unsupported("begin_access that is not statically enforced: \(line)")
    }
    return .alias(result: result, source: address)
}

/// `upcast`, `end_cow_mutation`, `begin_dealloc_ref`.
private func readUpcast(_ t: InstructionText) throws(SILError) -> Instruction {
    let (head, result, rest, line, types) = (t.head, t.result, t.rest, t.line, t.types)
    let operand = dropBracket(rest)
    let source = String(operand.prefix { $0 != " " })
    guard isValue(source) else { throw SILError.unsupported("\(head): \(line)") }
    if head == "upcast", !operand.hasSuffix("$__ContiguousArrayStorageBase"), !types.isKeyPathCast(operand) {
        throw SILError.unsupported("class upcast: \(line)")
    }
    return .alias(result: result, source: source)
}

/// `unchecked_ref_cast`.
private func readUncheckedRefCast(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    // Only the array buffer's own representation changes (`BridgeObject` is how `Array` stores its buffer).
    guard let to = rest.range(of: " to "), isValue(String(rest[..<to.lowerBound])),
        ["$Builtin.BridgeObject", "$__ContiguousArrayStorageBase"].contains(String(rest[to.upperBound...]))
    else {
        throw SILError.unsupported("unchecked_ref_cast: \(line)")
    }
    return .alias(result: result, source: String(rest[..<to.lowerBound]))
}

/// `alloc_ref`.
private func readAllocRef(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    // alloc_ref [bare] [stack] [tail_elems $Int32 * %n] $_ContiguousArrayStorage<Int32>
    let attributes = leadingAttributes(rest)
    let elementPrefix = "tail_elems "
    guard attributes.contains("stack"), let tail = attributes.first(where: { $0.hasPrefix(elementPrefix) }),
        let star = tail.range(of: " * ")
    else {
        throw SILError.unsupported("heap or non-array allocation: \(line)")
    }
    var elementType = String(tail[tail.index(tail.startIndex, offsetBy: elementPrefix.count)..<star.lowerBound])
    if elementType.hasPrefix("$") { elementType.removeFirst() }
    guard rest.hasSuffix("$_ContiguousArrayStorage<\(elementType)>"), let w = scalarWidth(elementType) else {
        throw SILError.unsupported("array of non-scalar elements: \(line)")
    }
    let count = String(tail[star.upperBound...])
    guard isValue(count) else { throw SILError.unsupported("alloc_ref: \(line)") }
    return .allocArray(result: result, width: w, count: count)
}

/// `ref_tail_addr`.
private func readRefTailAddr(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    let operand = dropBracket(rest)
    let parts = splitTopLevel(operand)
    guard parts.count == 2, isValue(parts[0]) else { throw SILError.unsupported("ref_tail_addr: \(line)") }
    return .refTailAddress(result: result, source: parts[0], width: scalarWidth(parts[1]))
}

/// `index_addr`.
private func readIndexAddr(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    let parts = splitTopLevel(dropBracket(rest))
    guard parts.count == 2, isValue(parts[0]), isValue(parts[1]) else { throw SILError.unsupported("index_addr: \(line)") }
    return .indexAddress(result: result, base: parts[0], index: parts[1])
}

/// `ref_element_addr`.
private func readRefElementAddr(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line) = (t.result, t.rest, t.line)
    guard rest.hasSuffix("#__ContiguousArrayStorageBase.countAndCapacity") else {
        throw SILError.unsupported("ref_element_addr: \(line)")
    }
    return .headerAddress(result: result)
}

/// `open_existential_ref`.
private func readOpenExistentialRef(_ t: InstructionText) throws(SILError) -> Instruction {
    let (result, rest, line, types) = (t.result, t.rest, t.line, t.types)
    // `any KeyPath<A, B> & Sendable` opened to its concrete class: the same handle.
    guard types.isKeyPathCast(rest) else { throw SILError.unsupported("open_existential_ref: \(line)") }
    return .alias(result: result, source: String(rest.prefix { $0 != " " }))
}
