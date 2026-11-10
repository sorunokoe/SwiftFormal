import Foundation
import LeanProof
import ScalarExtraction
import Testing

@testable import TranslationValidation

private let symbol = "$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF"
private let contract = """
    {"schema_version":1,"symbol":"\(symbol)","requires":"nonnegative-int64-pair","ensures":"exact-clamped-subtraction","witness":["0","0"]}
    """

@Test func exportsBlockArgumentsInsteadOfTheSymbolicReturnExpression() throws {
    let function = try SILReader.extract(
        from: """
            sil_stage canonical
            sil @\(symbol) : $@convention(thin) (Int64, Int64) -> Int64 {
            bb0(%0 : $Int64, %1 : $Int64):
              br bb1(%1, %0)
            bb1(%2 : $Int64, %3 : $Int64):
              return %2
            }
            """, symbol: symbol)
    let result = try TranslationValidator.makeValidation(
        for: function, contract: ProofContract.decode(Data(contract.utf8)))
    #expect(result.program.contains("arguments := [1, 0]"))
    #expect(result.program.contains("parameters := [2, 3]"))
    #expect(result.program.contains(".returned 2"))
    #expect(result.modelSource.contains("Outcome.returned discount"))
    #expect(result.translation.source.contains("ReferenceIR.execute"))
    #expect(!result.translation.source.contains("theorem totalCorrectness"))
    #expect(result.proof.source.contains("theorem totalCorrectness"))
}
