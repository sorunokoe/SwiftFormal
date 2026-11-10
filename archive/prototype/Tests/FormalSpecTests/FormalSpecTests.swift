import Testing
@testable import FormalSpec

@Suite struct FormalSpecTests {
    let module = SpecModule("M") {
        Function("clampSub", ("a", .nat), ("b", .nat)) { p in p[0] - p[1] }
        Function("isSmall", ("a", .nat), returns: .bool) { p in p[0] < 10 }
        Theorem("clampSub_le", ("a", .nat), ("b", .nat)) { v in call("clampSub", v[0], v[1]) <= v[0] }
        Theorem("small_bound", ("a", .nat)) { v in call("isSmall", v[0]) ==> (v[0] < 10) }
    }

    @Test func interpreterUsesLeanNatSemantics() throws {
        let interp = SpecInterpreter(module)
        #expect(try interp.call("clampSub", [.nat(3), .nat(5)]) == .nat(0))
        #expect(try interp.eval(.div(7, 0), [:]) == .nat(0))
        #expect(throws: SpecInterpreter.Failure.overflow) { try interp.eval(.add(.natLiteral(.max), 1), [:]) }
    }

    @Test func emitsLeanWithPropAndBoolSides() {
        let lean = LeanEmitter.emit(module)
        #expect(lean.contains("def clampSub (a : Nat) (b : Nat) : Nat :=\n  (a - b)"))
        #expect(lean.contains("def isSmall (a : Nat) : Bool :=\n  decide (a < 10)"))
        #expect(lean.contains("(((isSmall a) = true) → (a < 10))"))
        #expect(lean.contains(":= by grind [clampSub, isSmall]"))
    }

    @Test func differentialTestFindsDivergence() throws {
        let bad = try differentialTest(module, function: "clampSub", arity: 2, iterations: 2_000) { args in
            .nat(args[0] &- args[1])
        }
        #expect(bad != nil)
        let good = try differentialTest(module, function: "clampSub", arity: 2, iterations: 2_000) { args in
            .nat(args[0] >= args[1] ? args[0] - args[1] : 0)
        }
        #expect(good == nil)
    }
}
