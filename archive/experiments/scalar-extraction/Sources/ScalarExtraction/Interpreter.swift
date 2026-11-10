private enum RuntimeValue {
    case int64(Int64)
    case bits(Int64)
    case bit(Bool)
    case overflow(Int64, Bool)
}

extension SILFunction {
    public func evaluate(arguments: [Int64]) throws -> Evaluation {
        guard arguments.count == parameterCount else {
            throw ExtractionError.invalidArtifact("Expected \(parameterCount) Int64 arguments")
        }
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        var values: [String: RuntimeValue] = [:]
        var next = "bb0"
        var incoming = arguments.map(RuntimeValue.int64)
        var visited: Set<String> = []

        func bits(_ id: String) throws -> Int64 {
            guard case .bits(let value) = values[id] else {
                throw ExtractionError.invalidArtifact("Expected integer bits: \(id)")
            }
            return value
        }
        func bit(_ id: String) throws -> Bool {
            guard case .bit(let value) = values[id] else {
                throw ExtractionError.invalidArtifact("Expected one-bit value: \(id)")
            }
            return value
        }
        func take(_ edge: Edge) throws {
            incoming = try edge.arguments.map { id in
                guard let value = values[id] else {
                    throw ExtractionError.invalidArtifact("Missing branch value: \(id)")
                }
                return value
            }
            next = edge.block
        }

        while let block = byID[next], visited.insert(next).inserted {
            for (parameter, value) in zip(block.parameters, incoming) {
                values[parameter.id] = value
            }
            for instruction in block.instructions {
                let result: RuntimeValue?
                switch instruction.operation {
                case .literal(let value, let type):
                    result = type == .bit ? .bit(value == -1) : .bits(value)
                case .unwrap(let id):
                    guard case .int64(let value) = values[id] else {
                        throw ExtractionError.invalidArtifact("Expected Int64 wrapper: \(id)")
                    }
                    result = .bits(value)
                case .wrap(let id):
                    result = .int64(try bits(id))
                case .lessThan(let a, let b):
                    result = .bit(try bits(a) < bits(b))
                case .arithmetic(let operation, let a, let b, _):
                    let lhs = try bits(a)
                    let rhs = try bits(b)
                    let pair =
                        switch operation {
                        case .add: lhs.addingReportingOverflow(rhs)
                        case .subtract: lhs.subtractingReportingOverflow(rhs)
                        }
                    result = .overflow(pair.partialValue, pair.overflow)
                case .project(let id, let index):
                    guard case .overflow(let partial, let overflow) = values[id] else {
                        throw ExtractionError.invalidArtifact("Expected overflow tuple: \(id)")
                    }
                    result = index == 0 ? .bits(partial) : .bit(overflow)
                case .trap(let id):
                    if try bit(id) { return .arithmeticTrap(instruction.location) }
                    result = nil
                case .debug:
                    result = nil
                case .branch(let edge):
                    try take(edge)
                    result = nil
                case .conditional(let id, let yes, let no):
                    try take(bit(id) ? yes : no)
                    result = nil
                case .returned(let id):
                    guard case .int64(let value) = values[id] else {
                        throw ExtractionError.invalidArtifact("Expected Int64 return: \(id)")
                    }
                    return .returned(value)
                }
                if let id = instruction.result, let result { values[id] = result }
            }
        }
        throw ExtractionError.invalidArtifact("Execution did not reach a return or modeled trap")
    }
}
