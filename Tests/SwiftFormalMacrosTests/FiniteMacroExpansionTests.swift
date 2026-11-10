import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing
@testable import SwiftFormalMacros

private let macros: [String: MacroSpec] = ["Finite": MacroSpec(type: FiniteMacro.self), "Values": MacroSpec(type: ValuesMacro.self)]
private let macroSpecs: [String: MacroSpec] = [
    "Finite": MacroSpec(type: FiniteMacro.self, conformances: ["Finite"]),
    "Values": MacroSpec(type: ValuesMacro.self),
]

@Suite struct FiniteMacroExpansionTests {
    @Test func structBecomesAProductOfItsFields() {
        assertExpansion(
            """
            @Finite struct Order {
                @Values(.int(0 ... 3)) var quantity: Int
                var express: Bool
                var note = "x"
            }
            """,
            expandedSource: """
                struct Order {
                    var quantity: Int
                    var express: Bool
                    var note = "x"
                }

                extension Order: SwiftFormal.Finite {
                    static var domain: SwiftFormal.Domain<Order> {
                        SwiftFormal.Domain.product(.int(0 ... 3), Bool.domain).map {
                            Order(quantity: $0.0, express: $0.1)
                        }
                    }
                }
                """,
            macroSpecs: macroSpecs
        )
    }

    @Test func enumCasesBecomeAUnion() {
        assertExpansion(
            """
            @Finite public enum Payment {
                case cash
                case card(Plan)
            }
            """,
            expandedSource: """
                public enum Payment {
                    case cash
                    case card(Plan)
                }

                extension Payment: SwiftFormal.Finite {
                    public static var domain: SwiftFormal.Domain<Payment> {
                        SwiftFormal.Domain<Self>.union([
                                SwiftFormal.Domain<Self>.just(.cash),
                                Plan.domain.map {
                                    .card($0)
                                }
                            ])
                    }
                }
                """,
            macroSpecs: macroSpecs
        )
    }

    @Test func classesAreRejected() {
        assertExpansion(
            "@Finite class Box { var flag: Bool = false }",
            expandedSource: "class Box { var flag: Bool = false \n}",
            diagnostics: [DiagnosticSpec(message: "@Finite applies to structs and enums", line: 1, column: 1)],
            macroSpecs: macros
        )
    }

    @Test func propertyWithoutATypeIsRejected() {
        assertExpansion(
            "@Finite struct Box { var flag }",
            expandedSource: "struct Box { var flag \n}",
            diagnostics: [DiagnosticSpec(message: "@Finite needs a type annotation on 'flag'", line: 1, column: 1)],
            macroSpecs: macros
        )
    }
}
