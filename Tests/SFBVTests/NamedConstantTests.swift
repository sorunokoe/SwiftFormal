import Testing
import SFBV
import SFCNF
import SFSAT

/// `CNFBuilder.namedConstant`: a constant with an identity of its own. Circuits over it fold like circuits over the
/// constant; the bits themselves stay distinct, and the unit clause makes every model agree.
@Suite struct NamedConstantTests {
    @Test func circuitsOverNamedConstantsFoldLikeConstants() {
        let c = CNFBuilder()
        let six = BV(bits: (0..<8).map { c.namedConstant((6 >> $0) & 1 == 1) })
        let other = BV(bits: (0..<8).map { c.namedConstant((6 >> $0) & 1 == 1) })
        #expect(six.bits != other.bits, "two named constants of one value are different literals")
        #expect(six.bits != c.constant(6, width: 8).bits)
        #expect(c.constantValue(six) == 6)
        #expect(c.constantValue(c.add(six, c.constant(1, width: 8)).sum) == 7)
        #expect(c.eq(six, other) == c.trueLit)
        #expect(c.ult(six, c.constant(3, width: 8)) == c.falseLit)
        #expect(c.and(-six.bits[1], c.fresh()) == c.falseLit)
        #expect(c.xor(six.bits[2], six.bits[1]) == c.falseLit)
    }

    @Test func everyModelGivesTheNamedValue() throws {
        let c = CNFBuilder()
        let five = BV(bits: (0..<4).map { c.namedConstant((5 >> $0) & 1 == 1) })
        let x = c.input(width: 4)
        // `x == five` is satisfiable, and its model has the named bits at their value.
        c.addClause([c.eq(x, five)])
        guard case .sat(let model) = Solver.solve(c.cnf) else {
            Issue.record("x == 5 must be satisfiable")
            return
        }
        #expect(c.value(of: five, in: model) == 5)
        #expect(c.value(of: x, in: model) == 5)
    }
}
