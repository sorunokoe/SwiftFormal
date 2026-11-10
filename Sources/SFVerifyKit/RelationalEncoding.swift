import SFBV
import SFCNF
import SFProve
import SFSIL

// Reading guide
// The queries of a relational claim (`RelationalProofs.swift` reads the chains and says what each claim means): each
// chain is encoded with Scan's encoder on free inputs, once per run, and the claim is proved like a contract.
// Tests: Tests/SFVerifyKitTests/RelationalProofTests.swift.

extension RelationalPair {
    /// A chain run on `value`: its result, and whether every step returned normally.
    private struct Run {
        var value: [BV]
        var normal: Int32
        var approximations: Set<String> = []
        var assumed: [Int32] = []
    }

    private func run(_ chain: [ChainStep], on value: [BV], _ encoder: SILEncoder, _ c: CNFBuilder) throws -> Run {
        var run = Run(value: value, normal: c.trueLit)
        for step in chain {
            if step.promotes { run.value = [c.constant(1, width: step.input.leafWidths[0])] + run.value }
            guard let function = step.function else { continue }
            var arguments: [BV] = []
            for (index, type) in function.parameterTypes.enumerated() {
                arguments += index == step.parameter ? run.value : type.leafWidths.map { c.constant(0, width: $0) }
            }
            let encoded: EncodedFunction
            do {
                encoded = try encoder.encode(symbol: step.symbol, arguments: arguments)
            } catch let error as SILError {
                throw RelationalRefusal(reason: "not read: \(step.display): \(error)")
            }
            run.normal = c.and(run.normal, c.and(c.and(-encoded.trap, -encoded.undefined), -(encoded.throwing ?? c.falseLit)))
            run.approximations.formUnion(encoded.approximations)
            if let assumption = encoded.assumption { run.assumed.append(assumption) }
            let count = step.output.leafWidths.count
            run.value = function.indirectResult != nil ? Array(encoded.writtenBack.prefix(count)) : encoded.results
            guard run.value.map(\.width) == step.output.leafWidths else {
                throw RelationalRefusal(reason: "not read: the result of \(step.display) has an unexpected layout")
            }
        }
        return run
    }

    /// The claim's literal over `inputs` (one input, or two for `Injective`): `safety` is that every chain returns
    /// normally on a valid input; otherwise the relation.
    private func claim(_ c: CNFBuilder, _ inputs: [BV], safety: Bool) throws -> (literal: Int32, approximations: Set<String>) {
        let encoder = SILEncoder(module: module, builder: c)
        let width = inputType.leafWidths.count
        let x = Array(inputs[0..<width])
        let valid = inputType.isValid(c, x[...])
        let f = try run(forward, on: x, encoder, c)
        var runs = [f]
        var literal: Int32
        if request.claim == .injective {
            if safety {
                literal = c.or(-valid, f.normal)
            } else {
                let y = Array(inputs[width..<(2 * width)])
                let g = try run(forward, on: y, encoder, c)
                runs.append(g)
                literal = c.or(-valid, try injective(c, x: x, f, y: y, g))
            }
        } else {
            let g = try run(other, on: request.claim == .roundTrip ? f.value : x, encoder, c)
            runs.append(g)
            let normal = c.and(valid, c.and(f.normal, g.normal))
            if safety {
                literal = c.or(-valid, c.and(f.normal, g.normal))
            } else {
                let holds = try request.claim == .roundTrip ? roundTrip(c, x: x, back: g.value) : agrees(c, f.value, g.value)
                literal = c.or(-normal, holds)
            }
        }
        let assumed = runs.flatMap(\.assumed)
        if !assumed.isEmpty { literal = c.or(-assumed.reduce(c.trueLit) { c.and($0, $1) }, literal) }
        return (literal, runs.reduce(into: Set<String>()) { $0.formUnion($1.approximations) })
    }

    /// Given a valid `x`: two valid inputs on which the rule returns normally and gives equal outputs are equal.
    private func injective(_ c: CNFBuilder, x: [BV], _ f: Run, y: [BV], _ g: Run) throws -> Int32 {
        let both = c.and(inputType.isValid(c, y[...]), c.and(f.normal, g.normal))
        guard let sameOutput = rule.output.equal(c, f.value[...], g.value[...]), let sameInput = inputType.equal(c, x[...], y[...]) else {
            throw RelationalRefusal(reason: "logic does not compare values of these types")
        }
        return c.or(-c.and(both, sameOutput), sameInput)
    }

    /// The inverse gives back `x` (present, when it ends in `!`).
    private func roundTrip(_ c: CNFBuilder, x: [BV], back value: [BV]) throws -> Int32 {
        guard var backType = other.last?.output else { throw RelationalRefusal(reason: "the inverse is not read") }
        var back = value
        var present = c.trueLit
        if request.unwrapsOther {
            guard let wrapped = backType.optionalWrapped else { throw RelationalRefusal(reason: "the inverse does not return an Optional") }
            present = c.eq(back[0], c.constant(1, width: back[0].width))
            back = Array(back[backType.payloadLeafRange(ofCase: 1)])
            backType = wrapped
        }
        guard backType == inputType, let same = inputType.equal(c, back[...], x[...]) else {
            throw RelationalRefusal(reason: "the inverse does not return the rule's input type")
        }
        return c.and(present, same)
    }

    /// The two rules give equal outputs.
    private func agrees(_ c: CNFBuilder, _ first: [BV], _ second: [BV]) throws -> Int32 {
        guard rule.output == other.last?.output, let same = rule.output.equal(c, first[...], second[...]) else {
            throw RelationalRefusal(reason: "the two rules return different types")
        }
        return same
    }

    // MARK: proving

    /// What `prove` concluded: the verdict, the counterexample's inputs, and what goes wrong there or why it is unknown.
    struct Decision {
        var verdict: RelationalResult.Verdict
        var inputs: String?
        var detail: String?
    }

    func prove(budget: Int) throws -> Decision {
        let width = inputType.leafWidths
        let safety = try Verifier.proveClaim(widths: width, budget: budget) { c, inputs in try claim(c, inputs, safety: true) }
        guard safety.verdict == .proved else {
            let why = safety.verdict == .unknown ? "no answer within the budget" : "it may trap, throw or fail on some input"
            return Decision(
                verdict: .unknown,
                detail: "the rule is not proved to return normally for every input (\(why)); logic decides the claim only then")
        }
        let widths = request.claim == .injective ? width + width : width
        let outcome = try Verifier.proveClaim(widths: widths, budget: budget) { c, inputs in try claim(c, inputs, safety: false) }
        switch outcome.verdict {
        case .proved: return Decision(verdict: .proved)
        case .unknown: return Decision(verdict: .unknown, detail: outcome.reason ?? "no answer within the budget")
        case .counterexample(let values):
            guard outcome.foreignResults == nil else {
                return Decision(verdict: .unknown, detail: "a counterexample needs values Objective-C calls return; it is not kept")
            }
            return Decision(verdict: .refuted, inputs: renderInputs(values), detail: describe(values))
        }
    }

    private func renderInputs(_ values: [UInt64]) -> String {
        let n = inputType.leafWidths.count
        return ValueRenderer.StandIns.$current.withValue(ValueRenderer.StandIns(module: module)) {
            if request.claim == .injective {
                return "a = \(ValueRenderer.render(inputType, values[0..<n])), b = \(ValueRenderer.render(inputType, values[n..<(2 * n)]))"
            }
            return ValueRenderer.render(inputType, values[0..<n])
        }
    }

    /// What the chains give on the counterexample, read by running the encoder on constants.
    private func describe(_ values: [UInt64]) -> String {
        let c = CNFBuilder()
        let encoder = SILEncoder(module: module, builder: c)
        let constants = zip(values, inputType.leafWidths + inputType.leafWidths).map { c.constant($0, width: $1) }
        func shown(_ chain: [ChainStep], _ input: [BV]) -> String {
            guard let run = try? run(chain, on: input, encoder, c), let output = chain.last?.output else { return "?" }
            let leaves = run.value.compactMap { c.constantValue($0) }
            guard leaves.count == run.value.count else { return "?" }
            return ValueRenderer.render(output, leaves[...])
        }
        let n = inputType.leafWidths.count
        let x = Array(constants[0..<n])
        return ValueRenderer.StandIns.$current.withValue(ValueRenderer.StandIns(module: module)) {
            switch request.claim {
            case .injective:
                return "both give \(shown(forward, x))"
            case .roundTrip:
                let there = (try? run(forward, on: x, encoder, c))?.value ?? []
                let back = there.isEmpty ? "?" : shown(other, there)
                return "gives \(shown(forward, x)), which the inverse reads back as \(back)"
            case .agrees:
                return "gives \(shown(forward, x)), the other rule \(shown(other, x))"
            }
        }
    }
}
