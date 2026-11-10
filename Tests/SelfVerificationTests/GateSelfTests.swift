import SFBV
import SFCNF
import SFSAT
import SwiftFormal
import SwiftFormalTesting
import Testing

/// The Tseitin gates and the bit-vector circuits against Swift's own operators.
///
/// With constant inputs the builder folds every gate to a constant, so `fold` reads an operator's result straight
/// off the circuit. With variable inputs the gates become clauses, so `solved` fixes the inputs with unit clauses
/// and asks the solver for the output. Both are compared with the real Swift operator.
enum Circuit {
    /// Builds `operation` on two constants of `width` bits and returns the constant it folds to (nil if it did not fold).
    static func fold(_ width: Int, _ a: UInt64, _ b: UInt64, _ operation: (CNFBuilder, BV, BV) -> BV) -> UInt64? {
        let builder = CNFBuilder()
        return builder.constantValue(operation(builder, builder.constant(a, width: width), builder.constant(b, width: width)))
    }

    /// Builds a one-bit `flag` on two constants and returns whether it folded to true (nil if it did not fold).
    static func foldFlag(_ width: Int, _ a: UInt64, _ b: UInt64, _ flag: (CNFBuilder, BV, BV) -> Int32) -> Bool? {
        let builder = CNFBuilder()
        let literal = flag(builder, builder.constant(a, width: width), builder.constant(b, width: width))
        if literal == builder.trueLit { return true }
        if literal == builder.falseLit { return false }
        return nil
    }

    /// Value of a gate output for the given input values, decided by the SAT solver rather than by constant folding.
    static func solved(inputs: [Bool], gate: (CNFBuilder, [Int32]) -> Int32) -> Bool? {
        let builder = CNFBuilder()
        let variables = inputs.map { _ in builder.fresh() }
        let output = gate(builder, variables)
        for (variable, value) in zip(variables, inputs) { builder.addClause([value ? variable : -variable]) }
        guard case .sat(let model) = Solver.solve(builder.cnf) else { return nil }
        let literalValue = model[Int(abs(output)) - 1]
        return output > 0 ? literalValue : !literalValue
    }

    static func bitwise(_ c: CNFBuilder, _ a: BV, _ b: BV, _ gate: (Int32, Int32) -> Int32) -> BV {
        BV(bits: zip(a.bits, b.bits).map { gate($0, $1) })
    }
}

@Suite struct GateSelfTests {
    /// Every two-input gate, built as clauses (not folded), equals the Swift Boolean operator on all four inputs.
    @Test func tseitinGatesAreSwiftsBooleanOperators() {
        let pairs = Domain<(Bool, Bool)>.product(.bool, .bool)
        Prove(
            "and/or/xor/mux gates",
            it: { (pair: (Bool, Bool)) -> [Bool?] in
                let inputs = [pair.0, pair.1]
                return [
                    Circuit.solved(inputs: inputs) { c, v in c.and(v[0], v[1]) },
                    Circuit.solved(inputs: inputs) { c, v in c.or(v[0], v[1]) },
                    Circuit.solved(inputs: inputs) { c, v in c.xor(v[0], v[1]) },
                    Circuit.solved(inputs: inputs) { c, v in c.not(c.and(v[0], v[1])) },
                ]
            },
            over: pairs
        ) {
            Property.matches("Swift operators") { pair in [pair.0 && pair.1, pair.0 || pair.1, pair.0 != pair.1, !(pair.0 && pair.1)] }
        }
    }

    @Test func muxIsSwiftsTernaryOperator() {
        let triples = Domain<(Bool, Bool, Bool)>.product(.bool, .bool, .bool)
        Prove(
            "mux gate",
            it: { (t: (Bool, Bool, Bool)) -> Bool? in Circuit.solved(inputs: [t.0, t.1, t.2]) { c, v in c.mux(v[0], v[1], v[2]) } },
            over: triples
        ) {
            Property.matches("condition ? a : b") { t in t.0 ? t.1 : t.2 }
        }
    }

    /// Constants come back as the same value, and `not` is an involution on literals (the DIMACS encoding round trip).
    @Test func constantsRoundTripAndNegationIsAnInvolution() {
        Prove(
            "constant(value) round trip",
            it: { (value: Int) -> [UInt64?] in
                let builder = CNFBuilder()
                return [8, 16, 64].map { builder.constantValue(builder.constant(UInt64(truncatingIfNeeded: value), width: $0)) }
            },
            over: .int(0...255)
        ) {
            Property.matches("same value at every width") { [UInt64($0), UInt64($0), UInt64($0)] }
        }
        let builder = CNFBuilder()
        let fresh = (0..<20).map { _ in builder.fresh() }
        #expect(fresh.allSatisfy { builder.not(builder.not($0)) == $0 && $0 > 1 })
        #expect(builder.not(builder.trueLit) == builder.falseLit)
    }

    /// `CNF.isSatisfied` against hand-written Boolean formulas on every assignment of three variables.
    @Test func cnfSatisfactionIsTheBooleanFormula() {
        let cnf = CNF(numVars: 3, clauses: [[1, -2], [2, 3], [-1, -3]])
        let assignments = Domain<(Bool, Bool, Bool)>.product(.bool, .bool, .bool)
        Prove(
            "(x1 | !x2) & (x2 | x3) & (!x1 | !x3)",
            it: { (a: (Bool, Bool, Bool)) in cnf.isSatisfied(by: [a.0, a.1, a.2]) },
            over: assignments
        ) {
            Property.matches("hand-written formula") { a in (a.0 || !a.1) && (a.1 || a.2) && (!a.0 || !a.2) }
        }
    }
}
