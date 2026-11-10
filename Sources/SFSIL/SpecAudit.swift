import Foundation
package import SFBV
import SFCNF
package import SFProve

// A `.proved` verdict says the code meets the spec. It says nothing about whether the spec means anything:
// an AI that writes both the code and the spec can write a spec that is empty, trivially true, or too weak
// to notice a wrong implementation. The audit below uses the prover itself to test the spec.
//
//   1. `requires` is satisfiable (otherwise every proof is vacuous).
//   2. `ensures` can fail for some result value (otherwise it says nothing).
//   3. Mutation: small edits to the function's SIL (flip a comparison, swap + and -, change a constant,
//      swap branch targets). A mutant that behaves differently on an input meeting `requires` but still
//      satisfies the spec is a *survivor*: the spec cannot tell the two apart, and the witness input shows how.
//
// Every verdict used here is a normal checked verdict (LRAT-checked proofs, replayable models).

/// One small edit of a function body.
package struct SpecMutant: Sendable, Equatable {
    /// Index into the function's SIL body lines.
    package let line: Int
    package let description: String
    let replacement: String

    /// The edited SIL line, for tools that want to show or replay the mutant.
    package var replacementLine: String { replacement }
}

package enum MutantStatus: Sendable, Equatable {
    /// The spec fails on the mutant, on these inputs.
    case killed(witness: [UInt64])
    /// The mutant differs from the original on these inputs, which meet `requires`, yet the spec still proves.
    case survived(witness: [UInt64])
    /// No input meeting `requires` tells the mutant from the original.
    case equivalent
    /// Not encodable, or out of solver budget.
    case undecided(String)
}

package struct MutantReport: Sendable, Equatable {
    package var mutant: SpecMutant
    package var status: MutantStatus
}

package struct SpecAudit: Sendable {
    /// The spec's own verdict on the original function. Mutants are only tried when this is `.proved`.
    package var original: ProofVerdict
    /// `false`: no input meets `requires`, so every proof is vacuous. `nil`: out of budget.
    package var requiresSatisfiable: Bool?
    /// `false`: `ensures` holds for every result value, so it says nothing. `nil`: out of budget.
    package var ensuresConstrainsResult: Bool?
    /// `true`: for each input meeting `requires`, `ensures` allows exactly one result (a full functional spec).
    /// `false`: it is a property, which several results satisfy. `nil`: out of budget.
    package var ensuresDeterminesResult: Bool?
    package var mutants: [MutantReport]

    package var killed: Int { mutants.count { if case .killed = $0.status { true } else { false } } }
    package var survivors: [MutantReport] { mutants.filter { if case .survived = $0.status { true } else { false } } }
    package var equivalent: Int { mutants.count { $0.status == .equivalent } }
    package var undecided: Int { mutants.count { if case .undecided = $0.status { true } else { false } } }

    /// Killed over killed plus survived. `nil` when no mutant was decided.
    package var mutationScore: Double? {
        let decided = killed + survivors.count
        return decided == 0 ? nil : Double(killed) / Double(decided)
    }

    /// The spec is empty or says nothing; a proof against it proves nothing.
    package var isVacuous: Bool { requiresSatisfiable == false || ensuresConstrainsResult == false }
}

extension SILVerifier {
    /// Tests the spec `requires`/`ensures` for `symbol` as described at the top of this file.
    /// Scalar results only. `conflictBudget` applies to every solver run.
    package static func auditSpec(
        _ symbol: String,
        in module: SILModule,
        inputSignedBits: [Int?]? = nil,
        conflictBudget: Int = 200_000,
        refining: Bool = false,
        maxMutants: Int = 60,
        requires: (CNFBuilder, [BV]) -> Int32 = { c, _ in c.trueLit },
        ensures: (CNFBuilder, [BV], BV) -> Int32
    ) throws -> SpecAudit {
        let function = try module.function(symbol)
        let widths = function.parameterWidths
        let rw = function.resultWidth
        func solve(_ extra: [Int], _ claim: (CNFBuilder, [BV]) throws -> Int32) throws -> ProofVerdict {
            let signed = inputSignedBits.map { $0 + Array(repeating: nil, count: extra.count) }
            return try proveMaybeRefining(
                inputWidths: widths + extra, inputSignedBits: signed,
                conflictBudget: conflictBudget, refining: refining, claim: claim
            )
        }

        let original = try prove(
            symbol, in: module, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget,
            refining: refining, requires: requires, ensures: ensures
        )

        // A claim that holds for all inputs means the thing asked about never happens; a counterexample is a witness.
        let satisfiable: Bool? =
            switch try solve([], { c, x in -requires(c, x) }) {
            case .counterexample: true
            case .proved: false
            case .unknown: nil
            }
        let constrains: Bool? =
            switch try solve(
                [rw],
                { c, x in
                    c.or(-requires(c, Array(x.dropLast())), ensures(c, Array(x.dropLast()), x[x.count - 1]))
                })
            {
            case .counterexample: true
            case .proved: false
            case .unknown: nil
            }
        let determines: Bool? =
            switch try solve(
                [rw, rw],
                { c, x in
                    let inputs = Array(x.dropLast(2))
                    let both = c.and(ensures(c, inputs, x[x.count - 2]), ensures(c, inputs, x[x.count - 1]))
                    return c.or(-requires(c, inputs), c.or(-both, c.eq(x[x.count - 2], x[x.count - 1])))
                })
            {
            case .proved: true
            case .counterexample: false
            case .unknown: nil
            }

        var reports: [MutantReport] = []
        if original == .proved, let body = module.bodyLines(of: symbol) {
            for mutant in mutations(of: body).prefix(maxMutants) {
                var lines = body
                lines[mutant.line] = mutant.replacement
                let mutated = module.replacingBody(of: symbol, with: lines)
                reports.append(
                    MutantReport(
                        mutant: mutant,
                        status: try judge(
                            symbol, original: module, mutated: mutated, widths: widths,
                            inputSignedBits: inputSignedBits, conflictBudget: conflictBudget, refining: refining,
                            requires: requires, ensures: ensures
                        )))
            }
        }
        return SpecAudit(
            original: original, requiresSatisfiable: satisfiable, ensuresConstrainsResult: constrains,
            ensuresDeterminesResult: determines, mutants: reports
        )
    }

    private static func judge(
        _ symbol: String, original: SILModule, mutated: SILModule, widths: [Int],
        inputSignedBits: [Int?]?, conflictBudget: Int, refining: Bool,
        requires: (CNFBuilder, [BV]) -> Int32, ensures: (CNFBuilder, [BV], BV) -> Int32
    ) throws -> MutantStatus {
        do {
            switch try prove(
                symbol, in: mutated, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget,
                refining: refining, requires: requires, ensures: ensures
            ) {
            case .counterexample(let witness): return .killed(witness: witness)
            case .unknown: return .undecided("spec on mutant: solver budget")
            case .proved: break
            }
            // The spec accepts the mutant. That is only a weakness if the mutant really behaves differently.
            let verdict = try proveMaybeRefining(
                inputWidths: widths, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget, refining: refining
            ) { c, inputs in
                let a = try SILEncoder(module: original, builder: c).encode(symbol: symbol, arguments: inputs)
                let b = try SILEncoder(module: mutated, builder: c).encode(symbol: symbol, arguments: inputs)
                let same = c.and(
                    c.and(-c.xor(a.trap, b.trap), -c.xor(a.undefined, b.undefined)),
                    c.or(-c.and(-a.trap, -a.undefined), c.eq(a.result, b.result))
                )
                return c.or(-requires(c, inputs), same)
            }
            switch verdict {
            case .counterexample(let witness): return .survived(witness: witness)
            case .proved: return .equivalent
            case .unknown: return .undecided("difference check: solver budget")
            }
        } catch let error as SILError {
            return .undecided("\(error)")
        }
    }

    // MARK: mutation operators

    private static let swapped: [String: String] = [
        "cmp_slt": "cmp_sle", "cmp_sle": "cmp_slt", "cmp_sgt": "cmp_sge", "cmp_sge": "cmp_sgt",
        "cmp_ult": "cmp_ule", "cmp_ule": "cmp_ult", "cmp_ugt": "cmp_uge", "cmp_uge": "cmp_ugt",
        "cmp_eq": "cmp_ne", "cmp_ne": "cmp_eq",
        "sadd_with_overflow": "ssub_with_overflow", "ssub_with_overflow": "sadd_with_overflow",
        "uadd_with_overflow": "usub_with_overflow", "usub_with_overflow": "uadd_with_overflow",
        "smul_with_overflow": "sadd_with_overflow", "umul_with_overflow": "uadd_with_overflow",
        "add": "sub", "sub": "add", "mul": "add", "and": "or", "or": "and", "xor": "or",
    ]

    static func mutations(of body: [String]) -> [SpecMutant] {
        var result: [SpecMutant] = []
        for (index, line) in body.enumerated() {
            if let mutant = builtinMutation(line, index) ?? literalMutation(line, index) ?? branchMutation(line, index) {
                result.append(mutant)
            }
        }
        return result
    }

    /// `builtin "cmp_slt_Int32"(...)` becomes `builtin "cmp_sle_Int32"(...)`, and so on.
    private static func builtinMutation(_ line: String, _ index: Int) -> SpecMutant? {
        guard let open = line.range(of: "builtin \"") else { return nil }
        let rest = line[open.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let name = String(rest[..<close])
        guard let cut = name.range(of: "_Int", options: .backwards), !name.contains("Literal") else { return nil }
        let base = String(name[..<cut.lowerBound]), suffix = String(name[cut.lowerBound...])
        guard let to = swapped[base] else { return nil }
        var edited = line
        edited.replaceSubrange(open.upperBound..<rest.index(close, offsetBy: 0), with: to + suffix)
        return SpecMutant(line: index, description: "\(base) -> \(to) (\(suffix.dropFirst()))", replacement: edited)
    }

    /// `integer_literal $Builtin.Int32, 5` becomes `... 6`. Single-bit literals (overflow flags) are left alone.
    private static func literalMutation(_ line: String, _ index: Int) -> SpecMutant? {
        guard let mark = line.range(of: "integer_literal $Builtin.Int") else { return nil }
        let rest = line[mark.upperBound...]
        guard let comma = rest.range(of: ", "), let bits = Int(rest[..<comma.lowerBound]), bits > 1, bits <= 63 else { return nil }
        let tail = rest[comma.upperBound...]
        let digits = tail.prefix { $0 == "-" || $0.isNumber }
        guard let value = Int64(digits) else { return nil }
        let limit = Int64(1) << Int64(bits - 1)
        let new = value + 1 < limit ? value + 1 : value - 1
        var edited = line
        edited.replaceSubrange(comma.upperBound..<tail.index(tail.startIndex, offsetBy: digits.count), with: String(new))
        return SpecMutant(line: index, description: "literal \(value) -> \(new) (Int\(bits))", replacement: edited)
    }

    /// `cond_br %c, bb1, bb2` becomes `cond_br %c, bb2, bb1` (the condition is negated).
    private static func branchMutation(_ line: String, _ index: Int) -> SpecMutant? {
        let code = line.components(separatedBy: "//")[0]
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("cond_br ") else { return nil }
        let parts = trimmed.dropFirst("cond_br ".count).components(separatedBy: ", ")
        guard parts.count == 3, !parts[1].contains("("), !parts[2].contains("("),
            parts[1].hasPrefix("bb"), parts[2].hasPrefix("bb")
        else { return nil }
        let indent = String(code.prefix { $0 == " " })
        let comment = line.range(of: "//").map { " " + line[$0.lowerBound...] } ?? ""
        return SpecMutant(
            line: index, description: "swap branch targets \(parts[1]) <-> \(parts[2])",
            replacement: "\(indent)cond_br \(parts[0]), \(parts[2]), \(parts[1])\(comment)"
        )
    }
}
