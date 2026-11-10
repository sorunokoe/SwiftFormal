import Foundation
import ScalarExtraction
import Testing

@testable import LeanProof

private let contractData = Data(
    #"""
    {"schema_version":1,"symbol":"$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF","requires":"nonnegative-int64-pair","ensures":"exact-clamped-subtraction","witness":["0","0"]}
    """#.utf8)

private func constantFunction(_ value: Int64) throws -> SILFunction {
    let contract = try ProofContract.decode(contractData)
    return try SILReader.extract(
        from: """
            sil_stage canonical
            sil @\(contract.symbol) : $@convention(thin) (Int64, Int64) -> Int64 {
            bb0(%0 : $Int64, %1 : $Int64):
              %2 = integer_literal $Builtin.Int64, \(value)
              %3 = struct $Int64 (%2)
              return %3
            }
            """, symbol: contract.symbol)
}

@Test func changedBodiesChangeTheModelAndReturnObligation() throws {
    let contract = try ProofContract.decode(contractData)
    let original = try LeanEmitter.generate(for: constantFunction(0), contract: contract)
    let changed = try LeanEmitter.generate(for: constantFunction(42), contract: contract)
    #expect(original.model != changed.model)
    #expect(changed.model.contains("(42 : Int)"))
    let returns = changed.obligations.filter { $0.kind == "return" }
    #expect(returns.count == 1)
    #expect(returns.first?.statement.contains("(42 : Int)") == true)
    #expect(changed.expectedTheorems.contains("SwiftFormalV003.preconditionWitness"))
    #expect(changed.expectedTheorems.contains("SwiftFormalV003.totalCorrectness"))
    #expect(changed.expectedTheorems.contains("SwiftFormalV003.noTrap"))
}

@Test(arguments: [
    ("nonnegative-int64-pair", "False"),
    ("exact-clamped-subtraction", "always-zero"),
    (#""witness":["0","0"]"#, #""witness":["0"]"#),
    (#""witness":["0","0"]"#, #""witness":["9223372036854775808","0"]"#),
])
func rejectsUnsupportedContracts(before: String, after: String) {
    let text = String(decoding: contractData, as: UTF8.self).replacingOccurrences(
        of: before, with: after)
    #expect(throws: ProofError.self) { try ProofContract.decode(Data(text.utf8)) }
}

@Test func unusedArithmeticStillRequiresSafety() throws {
    let contract = try ProofContract.decode(contractData)
    let function = try SILReader.extract(
        from: """
            sil_stage canonical
            sil @\(contract.symbol) : $@convention(thin) (Int64, Int64) -> Int64 {
            bb0(%0 : $Int64, %1 : $Int64):
              %2 = struct_extract %0, #Int64._value
              %3 = struct_extract %1, #Int64._value
              %4 = integer_literal $Builtin.Int1, -1
              %5 = builtin "sadd_with_overflow_Int64"(%2, %3, %4) : $(Builtin.Int64, Builtin.Int1)
              %6 = tuple_extract %5, 0
              %7 = tuple_extract %5, 1
              cond_fail %7, "arithmetic overflow"
              return %0
            }
            """, symbol: contract.symbol)
    let proof = try LeanEmitter.generate(for: function, contract: contract)
    let safety = try #require(proof.obligations.first { $0.kind == "safety" })
    #expect(safety.statement.contains("subtotal + discount"))
    #expect(proof.model.contains("Outcome.arithmeticTrap"))
    #expect(proof.source.contains("have p0 := safety_0 subtotal discount _inputs"))
}
