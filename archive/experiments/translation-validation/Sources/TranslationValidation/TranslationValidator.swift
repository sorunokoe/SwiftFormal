import Foundation
import LeanProof
import ScalarExtraction

/// A generated Lean source and its exact required theorem inventory.
public struct ValidationProof: Encodable, Sendable {
    public let source: String
    public let obligations: [ProofObligation]
    public let expectedTheorems: [String]
}

/// An observation from the existing Swift IR interpreter, not a proof.
public struct Sample: Encodable, Sendable {
    public let inputs: [String]
    public let status: String
    public let value: String?
}

/// Independent instruction and symbolic-model representations with correspondence obligations.
public struct GeneratedValidation: Sendable {
    public let referenceSource: String
    public let program: String
    public let fuel: Int
    public let modelSource: String
    public let samples: [Sample]
    public let translation: ValidationProof
    public let proof: ValidationProof
}

/// Builds translation-validation obligations for the fixed discount contract.
public enum TranslationValidator {
    /// Creates direct IR data, an all-signed-input correspondence proof, and contract transfer.
    public static func makeValidation(
        for function: SILFunction, contract: ProofContract
    ) throws -> GeneratedValidation {
        guard function.instructionCount <= 256 else {
            throw ProofError.unsupported(
                "The translation experiment is limited to 256 instructions")
        }
        let model = try LeanEmitter.generate(for: function, contract: contract)
        guard let resource = Bundle.module.url(forResource: "ReferenceIR", withExtension: "lean")
        else {
            throw ProofError.unsupported("Missing independent reference interpreter")
        }
        let reference = try String(contentsOf: resource, encoding: .utf8)
        let program = try encodedProgram(function)
        let fuel = function.instructionCount + 1
        let predicates = model.model.split(separator: "\n").compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("if "), text.hasSuffix(" then") else { return nil }
            return String(text.dropFirst(3).dropLast(5))
        }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard predicates.count <= 8 else {
            throw ProofError.unsupported(
                "The proof experiment is limited to eight distinct predicates")
        }
        let correspondence = ProofObligation(
            name: "SwiftFormalV004.correspondence", kind: "correspondence",
            statement: """
                theorem correspondence (subtotal discount : Int)
                    (_subtotal : SwiftFormalV003.Fits subtotal) (_discount : SwiftFormalV003.Fits discount) :
                    ReferenceIR.execute \(fuel) program subtotal discount =
                      lift (SwiftFormalV003.implementation subtotal discount)
                """
        )
        let cases = predicates.enumerated().map { "by_cases p\($0.offset) : (\($0.element))" }
        let simpNames =
            [
                "ReferenceIR.execute", "program", "ReferenceIR.findBlock", "ReferenceIR.bind",
                "ReferenceIR.run", "ReferenceIR.evaluate", "ReferenceIR.lookup",
                "ReferenceIR.arithmetic",
                "ReferenceIR.jump", "ReferenceIR.arguments", "SwiftFormalV003.implementation",
                "lift", "fitsAgree", "wrapAgree",
            ] + predicates.indices.map { "p\($0)" }
        let tactic = (cases + ["simp [\(simpNames.joined(separator: ", "))]"]).joined(
            separator: " <;>\n    ")
        let correspondenceProof = """
            set_option linter.unusedSimpArgs false in
            \(correspondence.statement) := by
              \(tactic)
            """
        let boundary: [Int64] = [.min, .min + 1, -1, 0, 1, .max - 1, .max]
        let inputs: [[Int64]] =
            boundary.flatMap { a in boundary.map { b in [a, b] } } + [[10, 3], [-10, -3]]
        var samples: [Sample] = []
        var sampleClaims: [String] = []
        for pair in inputs {
            let expectation: String
            switch try function.evaluate(arguments: pair) {
            case .returned(let value):
                samples.append(
                    Sample(inputs: pair.map(String.init), status: "RETURNED", value: String(value)))
                expectation = ".returned (\(value))"
            case .arithmeticTrap:
                samples.append(
                    Sample(inputs: pair.map(String.init), status: "ARITHMETIC TRAP", value: nil))
                expectation = ".arithmeticTrap"
            }
            sampleClaims.append(
                "(ReferenceIR.execute \(fuel) program (\(pair[0])) (\(pair[1])) = \(expectation))")
        }
        let agreement = ProofObligation(
            name: "SwiftFormalV004.sampledAgreement", kind: "sample",
            statement: "theorem sampledAgreement :\n  " + sampleClaims.joined(separator: " /\\\n  ")
        )
        let transfer = ProofObligation(
            name: "SwiftFormalV004.totalCorrectness", kind: "transfer",
            statement: """
                theorem totalCorrectness (subtotal discount : Int)
                    (_inputs : SwiftFormalV003.Inputs subtotal discount) :
                    ReferenceIR.execute \(fuel) program subtotal discount =
                      ReferenceIR.Outcome.returned (SwiftFormalV003.expectedResult subtotal discount)
                """
        )
        let noTrap = ProofObligation(
            name: "SwiftFormalV004.noTrap", kind: "no-trap",
            statement: """
                theorem noTrap (subtotal discount : Int)
                    (_inputs : SwiftFormalV003.Inputs subtotal discount) :
                    Not (ReferenceIR.execute \(fuel) program subtotal discount = ReferenceIR.Outcome.arithmeticTrap)
                """
        )
        let transferredProofs = """
            \(transfer.statement) := by
              have hs : SwiftFormalV003.Fits subtotal := by
                unfold SwiftFormalV003.Inputs at _inputs
                unfold SwiftFormalV003.Fits
                omega
              have hd : SwiftFormalV003.Fits discount := by
                unfold SwiftFormalV003.Inputs at _inputs
                unfold SwiftFormalV003.Fits
                omega
              rw [correspondence subtotal discount hs hd,
                SwiftFormalV003.totalCorrectness subtotal discount _inputs]
              rfl

            \(noTrap.statement) := by
              rw [totalCorrectness subtotal discount _inputs]
              intro impossible
              cases impossible
            """
        let declarations = """
            namespace SwiftFormalV004
            open SwiftFormalV003

            \(program)

            def lift : SwiftFormalV003.Outcome -> ReferenceIR.Outcome
              | .returned value => .returned value
              | .arithmeticTrap => .arithmeticTrap

            private theorem fitsAgree (value : Int) :
                ReferenceIR.Fits value = SwiftFormalV003.Fits value := rfl

            private theorem wrapAgree (value : Int) (h : SwiftFormalV003.Fits value) :
                ReferenceIR.wrap64 value = value := ReferenceIR.wrap64_of_fits value h

            \(correspondenceProof)

            \(agreement.statement) := by decide
            """
        let translationObligations = [correspondence, agreement]
        let fullObligations = translationObligations + [transfer, noTrap]
        func audits(_ obligations: [ProofObligation]) -> String {
            obligations.map { "#print axioms \($0.name)" }.joined(separator: "\n")
                + "\nend SwiftFormalV004\n"
        }
        let translation = ValidationProof(
            source: [model.modelSource, reference, declarations, audits(translationObligations)]
                .joined(separator: "\n\n"),
            obligations: translationObligations,
            expectedTheorems: translationObligations.map(\.name)
        )
        let proof = ValidationProof(
            source: [
                model.source, reference, declarations, transferredProofs, audits(fullObligations),
            ].joined(separator: "\n\n"),
            obligations: model.obligations + fullObligations,
            expectedTheorems: model.expectedTheorems + fullObligations.map(\.name)
        )
        return GeneratedValidation(
            referenceSource: reference, program: program, fuel: fuel,
            modelSource: model.modelSource,
            samples: samples, translation: translation, proof: proof
        )
    }

    private static func identifier(_ text: String, prefix: String) throws -> String {
        guard text.hasPrefix(prefix), let number = UInt64(text.dropFirst(prefix.count)) else {
            throw ProofError.unsupported("Unrepresentable IR identifier: \(text)")
        }
        return String(number)
    }

    private static func value(_ text: String) throws -> String { try identifier(text, prefix: "%") }

    private static func edge(_ edge: Edge) throws -> String {
        try
            "{ block := \(identifier(edge.block, prefix: "bb")), arguments := [\(edge.arguments.map(value).joined(separator: ", "))] }"
    }

    private static func encodedProgram(_ function: SILFunction) throws -> String {
        let blocks = try function.blocks.map { block in
            let parameters = try block.parameters.map { try value($0.id) }.joined(separator: ", ")
            let instructions = try block.instructions.map(encodedInstruction).joined(
                separator: ",\n      ")
            return """
                  (\(try identifier(block.id, prefix: "bb")), { parameters := [\(parameters)], instructions := [
                      \(instructions)
                  ] })
                """
        }
        return "def program : ReferenceIR.Program := [\n" + blocks.joined(separator: ",\n") + "\n]"
    }

    private static func encodedInstruction(_ instruction: Instruction) throws -> String {
        let operation: String
        switch instruction.operation {
        case .debug: return ".debug"
        case .trap(let flag): return try ".trap \(value(flag))"
        case .branch(let destination): return try ".branch \(edge(destination))"
        case .conditional(let condition, let yes, let no):
            return try ".conditional \(value(condition)) \(edge(yes)) \(edge(no))"
        case .returned(let operand): return try ".returned \(value(operand))"
        case .literal(let number, let type):
            switch type {
            case .bits: operation = ".literal (\(number))"
            case .bit: operation = ".bit \(number == -1 ? "true" : "false")"
            default: throw ProofError.unsupported("Unexpected literal type")
            }
        case .unwrap(let operand): operation = try ".unbox \(value(operand))"
        case .wrap(let operand): operation = try ".box \(value(operand))"
        case .lessThan(let left, let right):
            operation = try ".lessThan \(value(left)) \(value(right))"
        case .arithmetic(let arithmetic, let left, let right, let flag):
            let name =
                switch arithmetic {
                case .add: "add"
                case .subtract: "subtract"
                }
            operation = try ".\(name) \(value(left)) \(value(right)) \(value(flag))"
        case .project(let operand, let index): operation = try ".project \(value(operand)) \(index)"
        }
        guard let result = instruction.result else {
            throw ProofError.unsupported("Missing instruction result")
        }
        return try ".assign \(value(result)) (\(operation))"
    }
}
