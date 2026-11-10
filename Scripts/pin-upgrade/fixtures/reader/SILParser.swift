// Self-test input: a few lines in the shape of Sources/SFSIL/SILParser.swift. Never compiled. Each instruction name
// below is matched the way the real reader matches it, so the derivation must find all of them.

private func parseTerminator(_ line: String) throws -> Terminator {
    if line.hasPrefix("br ") { return .branch(try parseEdge(String(line.dropFirst(3)))) }
    if line.hasPrefix("cond_br ") { return try conditional(line) }
    if line.hasPrefix("return "), isValue(String(line.dropFirst(7))) { return .returned(String(line.dropFirst(7))) }
    throw SILError.unsupported("terminator: \(line)")
}

private func parseInstruction(_ line: String, types: TypeContext) throws -> Instruction {
    if line.hasPrefix("debug_value ") || line.hasPrefix("strong_retain ") { return .ignored }
    let head = String(line.prefix { $0 != " " })
    if head == "builtin" && line.hasPrefix("\"ptrtoint_Word\"") { return .ignored }
    let attributes = leadingAttributes(line)
    guard attributes.contains("stack") else { throw SILError.unsupported("not \("on the \("stack")"): \(line)") }
    switch head {
    case "unchecked_take_enum_data_addr", "unchecked_inplace_enum_data_addr":
        return try enumPayloadAddress(line)
    default:
        // "alloc_box" in a comment is not a literal, so the reader does not depend on alloc_box.
        throw SILError.unsupported("instruction \(head.isEmpty ? "(none)" : head): \(line)")
    }
}
