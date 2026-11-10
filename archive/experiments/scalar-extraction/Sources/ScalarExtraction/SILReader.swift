import Foundation

public enum SILReader {
    public static func extract(from text: String, symbol: String) throws -> SILFunction {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first(where: { !$0.isEmpty }) == "sil_stage canonical" else {
            throw ExtractionError.invalidArtifact("Expected canonical SIL")
        }
        let candidates = lines.indices.filter {
            lines[$0].hasPrefix("sil ") && lines[$0].contains("@\(symbol) :")
        }
        guard candidates.count == 1, let start = candidates.first else {
            throw ExtractionError.invalidArtifact("Expected exactly one body for \(symbol)")
        }
        guard
            let header = captures(
                #"sil @([^ ]+) : \$@convention\(thin\) \(([^)]*)\) -> Int64 \{"#, lines[start]
            ), header[0] == symbol
        else {
            throw ExtractionError.unsupported("Signature or function attributes: \(lines[start])")
        }
        let types = header[1].isEmpty ? [] : header[1].components(separatedBy: ", ")
        guard types.allSatisfy({ $0 == "Int64" }) else {
            throw ExtractionError.unsupported("Only Int64 parameters are supported")
        }

        var blocks: [Block] = []
        var closed = false
        for index in (start + 1)..<lines.count {
            let line = uncomment(lines[index]).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "}" {
                closed = true
                break
            }
            if let match = captures(#"(bb[0-9]+)(?:\((.*)\))?:"#, line) {
                let parameters = try parseParameters(match[1])
                blocks.append(Block(id: match[0], parameters: parameters, instructions: []))
            } else {
                guard !blocks.isEmpty else {
                    throw ExtractionError.invalidArtifact(
                        "Instruction outside block at SIL line \(index + 1)")
                }
                blocks[blocks.count - 1].instructions.append(
                    try parseInstruction(line, silLine: index + 1)
                )
            }
        }
        guard closed, let entry = blocks.first, entry.id == "bb0",
            entry.parameters.map(\.type.rawValue) == types
        else {
            throw ExtractionError.invalidArtifact("Missing body end or invalid entry parameters")
        }
        try validate(blocks)
        return SILFunction(symbol: symbol, blocks: blocks)
    }
}

private func captures(_ pattern: String, _ text: String) -> [String]? {
    // Patterns are fixed grammar rules, never supplied by the SIL input.
    let regex = try! NSRegularExpression(pattern: "^(?:\(pattern))$")
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else {
        return nil
    }
    return (1..<match.numberOfRanges).map {
        guard let range = Range(match.range(at: $0), in: text) else { return "" }
        return String(text[range])
    }
}

private func uncomment(_ line: String) -> String {
    var quoted = false
    var escaped = false
    var index = line.startIndex
    while index < line.endIndex {
        let character = line[index]
        if escaped {
            escaped = false
        } else if character == "\\" && quoted {
            escaped = true
        } else if character == "\"" {
            quoted.toggle()
        } else if !quoted && line[index...].hasPrefix("//") {
            return String(line[..<index])
        }
        index = line.index(after: index)
    }
    return line
}

private func parseParameters(_ text: String) throws -> [Parameter] {
    if text.isEmpty { return [] }
    return try text.components(separatedBy: ", ").map { parameter in
        guard
            let match = captures(#"(%[0-9]+) : \$(Int64|Builtin\.Int64|Builtin\.Int1)"#, parameter),
            let type = ValueType(rawValue: match[1])
        else {
            throw ExtractionError.unsupported("Block parameter: \(parameter)")
        }
        return Parameter(id: match[0], type: type)
    }
}

private func valueIDs(_ text: String) throws -> [String] {
    if text.isEmpty { return [] }
    let ids = text.components(separatedBy: ", ")
    guard ids.allSatisfy({ captures(#"(%[0-9]+)"#, $0) != nil }) else {
        throw ExtractionError.invalidArtifact("Invalid value list: \(text)")
    }
    return ids
}

private func parseEdge(_ text: String) throws -> Edge {
    guard let match = captures(#"(bb[0-9]+)(?:\((.*)\))?"#, text) else {
        throw ExtractionError.invalidArtifact("Invalid branch: \(text)")
    }
    return Edge(block: match[0], arguments: try valueIDs(match[1]))
}

private func parseInstruction(_ line: String, silLine: Int) throws -> Instruction {
    var code = line
    var location: SourceLocation?
    var scope: Int?
    if let match = captures(#"(.*), loc "([^"\\]+)":([0-9]+):([0-9]+), scope ([0-9]+)"#, code) {
        guard let row = Int(match[2]), let column = Int(match[3]), let id = Int(match[4]),
            row > 0, column > 0
        else {
            throw ExtractionError.invalidArtifact("Invalid source location at SIL line \(silLine)")
        }
        code = match[0]
        location = SourceLocation(file: match[1], line: row, column: column)
        scope = id
    } else if let match = captures(#"(.*), scope ([0-9]+)"#, code) {
        guard let id = Int(match[1]) else {
            throw ExtractionError.invalidArtifact("Invalid scope at SIL line \(silLine)")
        }
        code = match[0]
        scope = id
    }
    var result: String?
    if let match = captures(#"(%[0-9]+) = (.+)"#, code) {
        result = match[0]
        code = match[1]
    }

    let operation: Operation
    if let match = captures(#"integer_literal \$(Builtin\.Int64|Builtin\.Int1), (-?[0-9]+)"#, code)
    {
        guard let value = Int64(match[1]), let type = ValueType(rawValue: match[0]),
            type != .bit || value == -1 || value == 0
        else {
            throw ExtractionError.invalidArtifact("Out-of-range literal at SIL line \(silLine)")
        }
        operation = .literal(value, type)
    } else if let match = captures(#"struct_extract (%[0-9]+), #Int64\._value"#, code) {
        operation = .unwrap(match[0])
    } else if let match = captures(#"struct \$Int64 \((%[0-9]+)\)"#, code) {
        operation = .wrap(match[0])
    } else if let match = captures(#"builtin "([^"]+)"\(([^)]*)\) : \$(.+)"#, code) {
        let arguments = try valueIDs(match[1])
        switch match[0] {
        case "cmp_slt_Int64":
            guard arguments.count == 2, match[2] == ValueType.bit.rawValue else {
                throw ExtractionError.invalidArtifact(
                    "Invalid comparison signature at SIL line \(silLine)")
            }
            operation = .lessThan(arguments[0], arguments[1])
        case "sadd_with_overflow_Int64", "ssub_with_overflow_Int64":
            guard arguments.count == 3, match[2] == ValueType.overflow.rawValue else {
                throw ExtractionError.invalidArtifact(
                    "Invalid arithmetic signature at SIL line \(silLine)")
            }
            operation = .arithmetic(
                match[0] == "sadd_with_overflow_Int64" ? .add : .subtract,
                arguments[0], arguments[1], flag: arguments[2]
            )
        default:
            throw ExtractionError.unsupported("Builtin \(match[0]) at SIL line \(silLine)")
        }
    } else if let match = captures(#"tuple_extract (%[0-9]+), ([01])"#, code) {
        operation = .project(match[0], match[1] == "0" ? 0 : 1)
    } else if let match = captures(#"cond_fail (%[0-9]+), "arithmetic overflow""#, code) {
        operation = .trap(match[0])
    } else if let match = captures(
        #"debug_value (%[0-9]+), let, name "[A-Za-z_][A-Za-z_0-9]*"(?:, argno [0-9]+)?"#, code
    ) {
        operation = .debug(match[0])
    } else if let match = captures(#"br (bb[0-9]+(?:\([^)]*\))?)"#, code) {
        operation = .branch(try parseEdge(match[0]))
    } else if let match = captures(
        #"cond_br (%[0-9]+), (bb[0-9]+(?:\([^)]*\))?), (bb[0-9]+(?:\([^)]*\))?)"#, code
    ) {
        operation = .conditional(match[0], try parseEdge(match[1]), try parseEdge(match[2]))
    } else if let match = captures(#"return (%[0-9]+)"#, code) {
        operation = .returned(match[0])
    } else {
        throw ExtractionError.unsupported("Instruction at SIL line \(silLine): \(code)")
    }
    guard (result != nil) == (operation.resultType != nil) else {
        throw ExtractionError.invalidArtifact("Invalid result assignment at SIL line \(silLine)")
    }
    return Instruction(
        result: result, operation: operation, location: location, scope: scope, silLine: silLine)
}

private struct Definition {
    let type: ValueType
    let block: String
    let index: Int
    let operation: Operation?
}

private func validate(_ blocks: [Block]) throws {
    var byID: [String: Block] = [:]
    var definitions: [String: Definition] = [:]
    for block in blocks {
        guard byID.updateValue(block, forKey: block.id) == nil,
            block.instructions.last?.operation.isTerminator == true,
            !block.instructions.dropLast().contains(where: { $0.operation.isTerminator })
        else {
            throw ExtractionError.invalidArtifact(
                "Duplicate block or misplaced/missing terminator: \(block.id)")
        }
        for parameter in block.parameters {
            guard
                definitions.updateValue(
                    Definition(type: parameter.type, block: block.id, index: -1, operation: nil),
                    forKey: parameter.id
                ) == nil
            else {
                throw ExtractionError.invalidArtifact("Duplicate value: \(parameter.id)")
            }
        }
        for (index, instruction) in block.instructions.enumerated() {
            if let id = instruction.result, let type = instruction.operation.resultType {
                guard
                    definitions.updateValue(
                        Definition(
                            type: type, block: block.id, index: index,
                            operation: instruction.operation),
                        forKey: id
                    ) == nil
                else {
                    throw ExtractionError.invalidArtifact("Duplicate value: \(id)")
                }
            }
        }
    }

    var predecessors = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, Set<String>()) })
    for block in blocks {
        for edge in block.instructions.last!.operation.successors {
            guard let target = byID[edge.block], target.parameters.count == edge.arguments.count
            else {
                throw ExtractionError.invalidArtifact(
                    "Missing target or wrong branch arity from \(block.id)")
            }
            for (argument, parameter) in zip(edge.arguments, target.parameters) {
                guard definitions[argument]?.type == parameter.type else {
                    throw ExtractionError.invalidArtifact("Wrong branch argument type: \(argument)")
                }
            }
            predecessors[edge.block, default: []].insert(block.id)
        }
    }
    var reachable: Set<String> = ["bb0"]
    var pending = ["bb0"]
    while let id = pending.popLast() {
        for edge in byID[id]!.instructions.last!.operation.successors {
            if reachable.insert(edge.block).inserted { pending.append(edge.block) }
        }
    }
    guard reachable.count == blocks.count else {
        throw ExtractionError.unsupported("Unreachable blocks")
    }

    var remaining = blocks.map(\.id)
    var dominators: [String: Set<String>] = [:]
    while !remaining.isEmpty {
        guard
            let index = remaining.firstIndex(where: { id in
                predecessors[id]!.allSatisfy { dominators[$0] != nil }
            })
        else {
            throw ExtractionError.unsupported("Cyclic control flow")
        }
        let id = remaining.remove(at: index)
        let parents = predecessors[id]!
        let common = parents.reduce(Set(byID.keys)) { $0.intersection(dominators[$1]!) }
        dominators[id] = (parents.isEmpty ? [] : common).union([id])
    }

    for block in blocks {
        var checkedTraps: Set<Int> = []
        for (index, instruction) in block.instructions.enumerated() {
            for (id, expected) in instruction.operation.operands {
                guard let definition = definitions[id],
                    expected == nil || definition.type == expected,
                    dominators[block.id]!.contains(definition.block),
                    definition.block != block.id || definition.index < index
                else {
                    throw ExtractionError.invalidArtifact(
                        "Undefined, ill-typed, or non-dominating \(id) at SIL line \(instruction.silLine)"
                    )
                }
            }
            if case .arithmetic(_, _, _, let flag) = instruction.operation {
                // Only the observed checked lowering is accepted, never a name-only arithmetic guess.
                guard case .literal(-1, .bit) = definitions[flag]?.operation,
                    index + 3 < block.instructions.count,
                    case .project(let partialSource, 0) = block.instructions[index + 1].operation,
                    partialSource == instruction.result,
                    case .project(let overflowSource, 1) = block.instructions[index + 2].operation,
                    overflowSource == instruction.result,
                    case .trap(let condition) = block.instructions[index + 3].operation,
                    condition == block.instructions[index + 2].result
                else {
                    throw ExtractionError.unsupported(
                        "Unrecognized checked arithmetic or wrapping operation at SIL line \(instruction.silLine)"
                    )
                }
                checkedTraps.insert(index + 3)
            }
            if case .trap = instruction.operation, !checkedTraps.contains(index) {
                throw ExtractionError.unsupported(
                    "Trap not tied to checked arithmetic at SIL line \(instruction.silLine)")
            }
        }
    }
}
