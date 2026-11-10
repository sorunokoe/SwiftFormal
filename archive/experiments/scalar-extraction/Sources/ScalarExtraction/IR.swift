public enum ExtractionError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupported(String)
    case invalidArtifact(String)

    public var description: String {
        switch self {
        case .unsupported(let detail): "UNSUPPORTED: \(detail)"
        case .invalidArtifact(let detail): "INVALID ARTIFACT: \(detail)"
        }
    }
}

public struct SourceLocation: Equatable, Sendable, Encodable {
    public let file: String
    public let line: Int
    public let column: Int
}

public enum Evaluation: Equatable, Sendable {
    case returned(Int64)
    case arithmeticTrap(SourceLocation?)
}

public struct SILFunction: Sendable {
    public let symbol: String
    public let blocks: [Block]

    public var parameterCount: Int { blocks.first?.parameters.count ?? 0 }
    public var blockCount: Int { blocks.count }
    public var instructionCount: Int { blocks.reduce(0) { $0 + $1.instructions.count } }
}

public enum ValueType: String, Sendable {
    case int64 = "Int64"
    case bits = "Builtin.Int64"
    case bit = "Builtin.Int1"
    case overflow = "(Builtin.Int64, Builtin.Int1)"
}

public struct Parameter: Sendable {
    public let id: String
    public let type: ValueType
}

public struct Edge: Sendable {
    public let block: String
    public let arguments: [String]
}

public struct Block: Sendable {
    public let id: String
    public let parameters: [Parameter]
    public internal(set) var instructions: [Instruction]
}

public enum Arithmetic: Sendable {
    case add
    case subtract
}

public enum Operation: Sendable {
    case literal(Int64, ValueType)
    case unwrap(String)
    case wrap(String)
    case lessThan(String, String)
    case arithmetic(Arithmetic, String, String, flag: String)
    case project(String, Int)
    case trap(String)
    case debug(String)
    case branch(Edge)
    case conditional(String, Edge, Edge)
    case returned(String)

    var resultType: ValueType? {
        switch self {
        case .literal(_, let type): type
        case .unwrap: .bits
        case .wrap: .int64
        case .lessThan: .bit
        case .arithmetic: .overflow
        case .project(_, let index): index == 0 ? .bits : .bit
        default: nil
        }
    }

    var operands: [(String, ValueType?)] {
        switch self {
        case .literal: []
        case .unwrap(let id): [(id, .int64)]
        case .wrap(let id): [(id, .bits)]
        case .lessThan(let a, let b): [(a, .bits), (b, .bits)]
        case .arithmetic(_, let a, let b, let flag): [(a, .bits), (b, .bits), (flag, .bit)]
        case .project(let id, _): [(id, .overflow)]
        case .trap(let id): [(id, .bit)]
        case .debug(let id): [(id, nil)]
        case .branch(let edge): edge.arguments.map { ($0, nil) }
        case .conditional(let id, let yes, let no):
            [(id, .bit)] + (yes.arguments + no.arguments).map { ($0, nil) }
        case .returned(let id): [(id, .int64)]
        }
    }

    var successors: [Edge] {
        switch self {
        case .branch(let edge): [edge]
        case .conditional(_, let yes, let no): [yes, no]
        default: []
        }
    }

    var isTerminator: Bool {
        switch self {
        case .branch, .conditional, .returned: true
        default: false
        }
    }
}

public struct Instruction: Sendable {
    public let result: String?
    public let operation: Operation
    public let location: SourceLocation?
    public let scope: Int?
    public let silLine: Int
}
