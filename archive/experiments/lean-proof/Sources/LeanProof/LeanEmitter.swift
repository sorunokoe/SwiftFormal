import ScalarExtraction

public struct ProofObligation: Encodable, Sendable {
    public let name: String
    public let kind: String
    public let statement: String
    public let silLine: Int?
    public let location: SourceLocation?

    public init(
        name: String, kind: String, statement: String,
        silLine: Int? = nil, location: SourceLocation? = nil
    ) {
        self.name = name
        self.kind = kind
        self.statement = statement
        self.silLine = silLine
        self.location = location
    }
}

public struct GeneratedProof: Encodable, Sendable {
    public let model: String
    /// The closed model module without contract proofs or audit commands.
    public let modelSource: String
    public let source: String
    public let obligations: [ProofObligation]
    public let expectedTheorems: [String]
}

public enum LeanEmitter {
    public static func generate(for function: SILFunction, contract: ProofContract) throws
        -> GeneratedProof
    {
        guard function.symbol == contract.symbol, function.parameterCount == 2 else {
            throw ProofError.unsupported(
                "The contract requires the selected two-argument Int64 function")
        }
        let builder = TreeBuilder(function: function)
        let tree = try builder.block(
            "bb0", arguments: [.integer("subtotal"), .integer("discount")],
            environment: [:], ancestors: []
        )
        let model =
            "def implementation (subtotal discount : Int) : Outcome :=\n" + indented(tree.model)
        var renderer = ProofRenderer()
        let totalProof = renderer.proof(for: tree, path: [])
        let witnessStatement =
            "theorem preconditionWitness : Inputs (\(contract.witness[0])) (\(contract.witness[1]))"
        let totalStatement = """
            theorem totalCorrectness (subtotal discount : Int) (_inputs : Inputs subtotal discount) :
                implementation subtotal discount = Outcome.returned (expectedResult subtotal discount)
            """
        let noTrapStatement = """
            theorem noTrap (subtotal discount : Int) (_inputs : Inputs subtotal discount) :
                Not (implementation subtotal discount = Outcome.arithmeticTrap)
            """
        let obligations =
            [
                ProofObligation(
                    name: qualified("preconditionWitness"), kind: "witness",
                    statement: witnessStatement, silLine: nil, location: nil)
            ] + renderer.obligations + [
                ProofObligation(
                    name: qualified("totalCorrectness"), kind: "total",
                    statement: totalStatement, silLine: nil, location: nil),
                ProofObligation(
                    name: qualified("noTrap"), kind: "no-trap",
                    statement: noTrapStatement, silLine: nil, location: nil),
            ]
        let names = obligations.map(\.name)
        let source = [
            prelude,
            model,
            witnessStatement + " := by decide",
            renderer.declarations.joined(separator: "\n\n"),
            totalStatement + " := by\n  unfold implementation\n" + indented(totalProof),
            noTrapStatement + """
                 := by
                  rw [totalCorrectness subtotal discount _inputs]
                  intro impossible
                  cases impossible
                """,
            names.map { "#print axioms \($0)" }.joined(separator: "\n"),
            "end SwiftFormalV003\n",
        ].joined(separator: "\n\n")
        return GeneratedProof(
            model: model,
            modelSource: [prelude, model, "end SwiftFormalV003\n"].joined(separator: "\n\n"),
            source: source, obligations: obligations, expectedTheorems: names)
    }
}

private func qualified(_ name: String) -> String { "SwiftFormalV003.\(name)" }

private func indented(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(
        separator: "\n")
}

private enum SymbolicValue {
    case integer(String)
    case condition(String)
    case overflowTuple(String)
    case overflowBit(String)

    func integer() throws -> String {
        guard case .integer(let expression) = self else {
            throw ProofError.unsupported("Expected a symbolic integer")
        }
        return expression
    }

    func condition() throws -> String {
        switch self {
        case .condition(let predicate): return predicate
        case .overflowBit(let expression): return "Not (Fits (\(expression)))"
        default: throw ProofError.unsupported("Expected a symbolic condition")
        }
    }
}

private indirect enum Tree {
    case returned(String, Instruction)
    case branch(String, Tree, Tree)
    case checked(String, Tree, Instruction)

    var model: String {
        switch self {
        case .returned(let expression, _):
            "Outcome.returned \(expression)"
        case .branch(let predicate, let yes, let no):
            "if \(predicate) then\n\(indented(yes.model))\nelse\n\(indented(no.model))"
        case .checked(let expression, let next, _):
            "if Fits (\(expression)) then\n\(indented(next.model))\nelse\n  Outcome.arithmeticTrap"
        }
    }
}

private struct TreeBuilder {
    let blocks: [String: Block]

    init(function: SILFunction) {
        blocks = Dictionary(uniqueKeysWithValues: function.blocks.map { ($0.id, $0) })
    }

    func block(
        _ id: String, arguments: [SymbolicValue], environment: [String: SymbolicValue],
        ancestors: Set<String>
    ) throws -> Tree {
        guard let block = blocks[id], !ancestors.contains(id),
            block.parameters.count == arguments.count
        else {
            throw ProofError.unsupported("Invalid or cyclic block during model generation")
        }
        var values = environment
        for (parameter, argument) in zip(block.parameters, arguments) {
            values[parameter.id] = argument
        }
        return try instructions(
            block.instructions[...], values: values, ancestors: ancestors.union([id]))
    }

    func instructions(
        _ sequence: ArraySlice<Instruction>, values original: [String: SymbolicValue],
        ancestors: Set<String>
    ) throws -> Tree {
        var values = original
        func value(_ id: String) throws -> SymbolicValue {
            guard let value = values[id] else {
                throw ProofError.unsupported("Missing symbolic value \(id)")
            }
            return value
        }
        func follow(_ edge: Edge) throws -> Tree {
            try block(
                edge.block, arguments: edge.arguments.map { try value($0) }, environment: values,
                ancestors: ancestors)
        }
        for (offset, instruction) in sequence.enumerated() {
            let result: SymbolicValue?
            switch instruction.operation {
            case .literal(let number, let type):
                result =
                    type == .bit
                    ? .condition(number == -1 ? "True" : "False") : .integer("(\(number) : Int)")
            case .unwrap(let id), .wrap(let id):
                result = .integer(try value(id).integer())
            case .lessThan(let a, let b):
                result = .condition(try "(\(value(a).integer()) < \(value(b).integer()))")
            case .arithmetic(let operation, let a, let b, _):
                let sign =
                    switch operation {
                    case .add: "+"
                    case .subtract: "-"
                    }
                result = .overflowTuple(try "(\(value(a).integer()) \(sign) \(value(b).integer()))")
            case .project(let id, let index):
                guard case .overflowTuple(let expression) = try value(id) else {
                    throw ProofError.unsupported("Expected a checked arithmetic tuple")
                }
                // The reader requires the projections to be followed immediately by the check.
                // The mathematical result is observable only on its in-range continuation.
                result = index == 0 ? .integer(expression) : .overflowBit(expression)
            case .trap(let id):
                guard case .overflowBit(let expression) = try value(id) else {
                    throw ProofError.unsupported("Trap is not tied to an arithmetic overflow bit")
                }
                return .checked(
                    expression,
                    try instructions(
                        sequence.dropFirst(offset + 1), values: values, ancestors: ancestors
                    ), instruction)
            case .debug:
                result = nil
            case .branch(let edge):
                return try follow(edge)
            case .conditional(let id, let yes, let no):
                return try .branch(value(id).condition(), follow(yes), follow(no))
            case .returned(let id):
                return try .returned(value(id).integer(), instruction)
            }
            if let id = instruction.result, let result { values[id] = result }
        }
        throw ProofError.unsupported("Missing terminator during model generation")
    }
}

private struct PathCondition {
    let name: String
    let predicate: String
}

private struct ProofRenderer {
    var obligations: [ProofObligation] = []
    var declarations: [String] = []
    var returnCount = 0
    var safetyCount = 0

    mutating func obligation(
        name: String, kind: String, path: [PathCondition], conclusion: String,
        instruction: Instruction, tactic: String
    ) {
        let assumptions = path.map { "    (_\($0.name) : \($0.predicate))" }.joined(separator: "\n")
        let statement = """
            theorem \(name) (subtotal discount : Int) (_inputs : Inputs subtotal discount)
            \(assumptions) :
                \(conclusion)
            """
        let definitions =
            ["Inputs"]
            + (kind == "safety" || path.contains { $0.predicate.contains("Fits") } ? ["Fits"] : [])
            + (kind == "return" ? ["expectedResult"] : [])
        declarations.append(
            statement
                + " := by\n  simp only [\(definitions.joined(separator: ", "))] at *\n  \(tactic)")
        obligations.append(
            ProofObligation(
                name: qualified(name), kind: kind, statement: statement,
                silLine: instruction.silLine, location: instruction.location
            ))
    }

    mutating func proof(for tree: Tree, path: [PathCondition]) -> String {
        let arguments = (["subtotal", "discount", "_inputs"] + path.map(\.name)).joined(
            separator: " ")
        switch tree {
        case .returned(let expression, let instruction):
            let name = "return_\(returnCount)"
            returnCount += 1
            obligation(
                name: name, kind: "return", path: path,
                conclusion: "\(expression) = expectedResult subtotal discount",
                instruction: instruction, tactic: "all_goals (split <;> omega)")
            return "exact congrArg Outcome.returned (\(name) \(arguments))"
        case .checked(let expression, let next, let instruction):
            let name = "safety_\(safetyCount)"
            safetyCount += 1
            let predicate = "Fits (\(expression))"
            obligation(
                name: name, kind: "safety", path: path, conclusion: predicate,
                instruction: instruction, tactic: "all_goals omega")
            let hypothesis = "p\(path.count)"
            let nextProof = proof(
                for: next, path: path + [PathCondition(name: hypothesis, predicate: predicate)])
            return """
                have \(hypothesis) := \(name) \(arguments)
                rw [ite_eq_left \(hypothesis)]
                \(nextProof)
                """
        case .branch(let predicate, let yes, let no):
            let hypothesis = "p\(path.count)"
            let yesProof = proof(
                for: yes, path: path + [PathCondition(name: hypothesis, predicate: predicate)])
            let noProof = proof(
                for: no,
                path: path + [PathCondition(name: hypothesis, predicate: "Not (\(predicate))")])
            // Single rewrites preserve nested tests of the same predicate for later proof steps.
            return """
                by_cases \(hypothesis) : \(predicate)
                case pos =>
                  rw [ite_eq_left \(hypothesis)]
                \(indented(yesProof))
                case neg =>
                  rw [ite_eq_right \(hypothesis)]
                \(indented(noProof))
                """
        }
    }
}

private let prelude = #"""
    import Lean

    namespace SwiftFormalV003

    inductive Outcome where
      | returned (value : Int)
      | arithmeticTrap
      deriving DecidableEq

    def Fits (value : Int) : Prop :=
      -9223372036854775808 <= value /\ value <= 9223372036854775807

    instance (value : Int) : Decidable (Fits value) := inferInstanceAs (Decidable (_ /\ _))

    def Inputs (subtotal discount : Int) : Prop :=
      0 <= subtotal /\ subtotal <= 9223372036854775807 /\
      0 <= discount /\ discount <= 9223372036854775807

    instance (subtotal discount : Int) : Decidable (Inputs subtotal discount) :=
      inferInstanceAs (Decidable (_ /\ _ /\ _ /\ _))

    def expectedResult (subtotal discount : Int) : Int :=
      if discount <= subtotal then subtotal - discount else 0
    """#
