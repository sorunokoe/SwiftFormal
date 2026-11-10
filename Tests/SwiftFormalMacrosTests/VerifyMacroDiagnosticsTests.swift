import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing
@testable import SwiftFormalMacros

private let macros: [String: MacroSpec] = ["Verify": MacroSpec(type: VerifyMacro.self)]

// Shapes `@Verify(over:)` cannot walk are reported at the parameter or clause that causes them, with what to do
// instead. Without `over:` such a function gets no walk (`VerifyLogicOnlyExpansionTests`), only the Scan contract.
@Suite struct VerifyMacroDiagnosticsTests {
    @Test func inoutParameterIsReportedAtItsType() {
        assertExpansion(
            """
            @Verify(over: .int(0 ... 3))
            func bump(_ x: inout Int) -> Int {
                return x
            }
            """,
            expandedSource: """
                func bump(_ x: inout Int) -> Int {
                    return x
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: "@Verify cannot walk an inout parameter; return the new value instead", line: 2, column: 16)
            ],
            macroSpecs: macros
        )
    }

    @Test func variadicAndGenericAreBothReported() {
        assertExpansion(
            """
            @Verify
            func total<T>(_ values: Int..., tag: T) -> Int {
                return values.count
            }
            """,
            expandedSource: """
                func total<T>(_ values: Int..., tag: T) -> Int {
                    return values.count
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: "@Verify cannot walk a generic function; verify a concrete wrapper instead", line: 2, column: 11),
                DiagnosticSpec(message: "@Verify cannot walk a variadic parameter; take an array instead", line: 2, column: 15),
            ],
            macroSpecs: macros
        )
    }

    /// The macro reads `checks:` from the source, so only the two cases written out can work.
    @Test func checksMustBeWrittenAsACase() {
        assertExpansion(
            """
            @Verify(checks: mode)
            func half(_ x: Bool) -> Bool {
                #ensures { $0 == x }
                return x
            }
            """,
            expandedSource: """
                func half(_ x: Bool) -> Bool {
                    #ensures { $0 == x }
                    return x
                }

                func verify_half(budget: SwiftFormal.Budget = .default) -> SwiftFormal.Report {
                    SwiftFormal._verifyContracts(
                        "half",
                        { (input: Bool) -> Bool in
                            let __sf_result: Bool = half(input)
                            let x = input
                            if !(({ $0 == x
                                    })(__sf_result)) {
                                SwiftFormal.Contract.ensuresFailed("{ $0 == x }")
                            }
                            return __sf_result
                        },
                        over: SwiftFormal.Domain.ofParameterType((Bool).self),
                        budget: budget
                    )
                }

                func half_ensures(_ x: Bool, _ __sf_result: Bool) -> Bool {
                    ({
                            $0 == x
                        })(__sf_result)
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "write `checks: .debugOnly` or `checks: .always`; @Verify reads the choice from the source", line: 1,
                    column: 17)
            ],
            macroSpecs: macros
        )
    }

    @Test func opaqueParameterIsReported() {
        assertExpansion(
            """
            @Verify(over: .samples([[1]]))
            func size(_ values: some Collection) -> Int {
                return values.count
            }
            """,
            expandedSource: """
                func size(_ values: some Collection) -> Int {
                    return values.count
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: "@Verify cannot walk an opaque `some` parameter; name a concrete type", line: 2, column: 21)
            ],
            macroSpecs: macros
        )
    }
}
