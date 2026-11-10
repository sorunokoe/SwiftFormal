import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import SwiftFormalMacros

private let macros: [String: MacroSpec] = ["Verify": MacroSpec(type: VerifyMacro.self)]

// `@Verify` on a computed property (here), and `@Verify` with nothing to walk (`VerifyWalkExpansionTests`): the contract is written in place, Scan proves
// it from the `_requires` / `_ensures` peers, and no `verify_` walk is written. `VerifyContractScanTests` scans the
// getter shapes; `InPlaceVerifyTests` compiles them.
@Suite struct VerifyInPlaceExpansionTests {
    /// A getter's contract: `<name>_requires()` and `<name>_ensures(_:)` next to the property, as Scan pairs them with
    /// the getter, and the same checks in the getter as in a function. A getter has no walk.
    @Test func aComputedPropertyGetsGetterPeersAndNoWalk() {
        assertExpansion(
            """
            struct Rule {
                var title: String
                @Verify
                var body: String {
                    #requires(!title.isEmpty)
                    #ensures { result in result.hasPrefix(title) }
                    title + "."
                }
            }
            """,
            expandedSource: """
                struct Rule {
                    var title: String
                    var body: String {
                        #if DEBUG
                        if !(!title.isEmpty) {
                            SwiftFormal.Contract.requiresFailed("!title.isEmpty")
                        }
                        #endif
                        let __sf_result: String = { () -> String in
                            title + "."
                        }()
                        #if DEBUG
                        if !(({ result in
                                    result.hasPrefix(title)
                                })(__sf_result)) {
                            SwiftFormal.Contract.ensuresFailed("{ result in result.hasPrefix(title) }")
                        }
                        #endif
                        return __sf_result
                    }

                    func body_requires() -> Bool {
                        (!title.isEmpty)
                    }

                    func body_ensures(_ __sf_result: String) -> Bool {
                        ({ result in
                                result.hasPrefix(title)
                            })(__sf_result)
                    }
                }
                """,
            macroSpecs: macros
        )
    }

    /// `static` and the access level go to the peers; `throws` stays on the body closure.
    @Test func aStaticPublicPropertyKeepsItsModifiersOnThePeers() {
        assertExpansion(
            """
            enum Limits {
                @Verify(checks: .always)
                public static var maximum: Int8 {
                    #ensures { $0 > 0 }
                    return 100
                }
            }
            """,
            expandedSource: """
                enum Limits {
                    public static var maximum: Int8 {
                        let __sf_result: Int8 = { () -> Int8 in
                            return 100
                        }()
                        if !(({ $0 > 0
                                })(__sf_result)) {
                            SwiftFormal.Contract.ensuresFailed("{ $0 > 0 }")
                        }
                        return __sf_result
                    }

                    public static func maximum_ensures(_ __sf_result: Int8) -> Bool {
                        ({
                                $0 > 0
                            })(__sf_result)
                    }
                }
                """,
            macroSpecs: macros
        )
    }

    /// On a `get` (a property with a setter) the checks go into the getter (the test harness runs only the body role
    /// on an accessor; the compiler also runs the peer role, `onAGetThePeerRoleWarnsThatScanGetsNoPeers`).
    @Test func onAGetTheChecksAreWrittenIntoTheGetter() {
        assertExpansion(
            """
            struct Box {
                var stored: Int8
                var value: Int8 {
                    @Verify get {
                        #ensures { $0 == stored }
                        return stored
                    }
                    set { stored = newValue }
                }
            }
            """,
            expandedSource: """
                struct Box {
                    var stored: Int8
                    var value: Int8 {
                        get {
                            let __sf_result: Int8 = { () -> Int8 in
                                return stored
                            }()
                            #if DEBUG
                            if !(({ $0 == stored
                                    })(__sf_result)) {
                                SwiftFormal.Contract.ensuresFailed("{ $0 == stored }")
                            }
                            #endif
                            return __sf_result
                        }
                        set { stored = newValue }
                    }
                }
                """,
            macroSpecs: macros
        )
    }

    /// The compiler runs the peer role on the `get` too: it can put nothing next to the property, so it warns that
    /// Scan sees the contract only as the checks in the getter, instead of losing it quietly.
    @Test func onAGetThePeerRoleWarnsThatScanGetsNoPeers() throws {
        let property: DeclSyntax = "var value: Int8 { get { stored } set { stored = newValue } }"
        let variable = try #require(property.as(VariableDeclSyntax.self))
        guard case .accessors(let accessors)? = variable.bindings.first?.accessorBlock?.accessors, let getter = accessors.first else {
            Issue.record("no accessors")
            return
        }
        let context = BasicMacroExpansionContext(lexicalContext: [Syntax(variable)])
        let peers = try VerifyMacro.expansion(of: "@Verify", providingPeersOf: getter, in: context)
        #expect(peers.isEmpty)
        let warning = try #require(context.diagnostics.first)
        #expect(warning.diagMessage.severity == .warning)
        #expect(warning.message.hasPrefix("@Verify on a `get` checks the contract in the getter, but cannot write `value_requires()`"))
    }

    @Test func aStoredPropertyIsRejected() {
        assertExpansion(
            """
            @Verify var count: Int = 0
            """,
            expandedSource: """
                var count: Int = 0
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Verify applies to a function or to a computed property, not to a stored property", line: 1, column: 1)
            ],
            macroSpecs: macros
        )
    }

}

// `@Verify` on a function with nothing to walk, and on one of five parameters.
@Suite struct VerifyWalkExpansionTests {
    /// Without `over:`, a parameter that is surely not `Finite` (`String`, `Int`, an optional of one) means no walk:
    /// no "type has no member 'domain'" error, only the contract Scan proves.
    @Test func aFunctionOverStringsGetsNoWalk() {
        assertExpansion(
            """
            @Verify
            func greeting(for name: String?, visits: Int) -> String {
                #requires(visits >= 0)
                #ensures { !$0.isEmpty }
                return visits == 0 ? "Hello" : "Welcome back"
            }
            """,
            expandedSource: """
                func greeting(for name: String?, visits: Int) -> String {
                    #if DEBUG
                    if !(visits >= 0) {
                        SwiftFormal.Contract.requiresFailed("visits >= 0")
                    }
                    #endif
                    let __sf_result: String = { () -> String in
                        return visits == 0 ? "Hello" : "Welcome back"
                    }()
                    #if DEBUG
                    if !(({ !$0.isEmpty
                            })(__sf_result)) {
                        SwiftFormal.Contract.ensuresFailed("{ !$0.isEmpty }")
                    }
                    #endif
                    return __sf_result
                }

                func greeting_requires(_ name: String?, _ visits: Int) -> Bool {
                    (visits >= 0)
                }

                func greeting_ensures(_ name: String?, _ visits: Int, _ __sf_result: String) -> Bool {
                    ({
                            !$0.isEmpty
                        })(__sf_result)
                }
                """,
            macroSpecs: macros
        )
    }

    /// No parameters: nothing to walk, so no `verify_` (pre-release builds reported "needs at least one parameter").
    @Test func aFunctionWithoutParametersGetsNoWalk() {
        assertExpansion(
            """
            @Verify
            func answer() -> Int8 {
                #ensures { $0 == 42 }
                42
            }
            """,
            expandedSource: """
                func answer() -> Int8 {
                    let __sf_result: Int8 = { () -> Int8 in
                        42
                    }()
                    #if DEBUG
                    if !(({ $0 == 42
                            })(__sf_result)) {
                        SwiftFormal.Contract.ensuresFailed("{ $0 == 42 }")
                    }
                    #endif
                    return __sf_result
                }

                func answer_ensures(_ __sf_result: Int8) -> Bool {
                    ({
                            $0 == 42
                        })(__sf_result)
                }
                """,
            macroSpecs: macros
        )
    }

    /// `over:` with nothing to range over is a mistake, reported at the domain.
    @Test func overWithoutParametersIsReported() {
        assertExpansion(
            """
            @Verify(over: .bool)
            func answer() -> Int8 {
                42
            }
            """,
            expandedSource: """
                func answer() -> Int8 {
                    42
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Verify(over:) needs a parameter to range over; without `over:`, Scan proves the contract", line: 1,
                    column: 15)
            ],
            macroSpecs: macros
        )
    }

    /// `inout` without `over:`: no walk and no `_ensures` (Scan pairs none for an `inout` parameter); `_requires` keeps
    /// `inout`, the form Scan pairs. A warning says the `#ensures` is only a check in the body.
    @Test func anInoutParameterGetsRequiresButNoEnsuresPeer() {
        assertExpansion(
            """
            @Verify
            func bump(_ x: inout Int8, by step: Int8 = 1) -> Bool {
                #requires(step > 0)
                #ensures { $0 }
                x &+= step
                return true
            }
            """,
            expandedSource: """
                func bump(_ x: inout Int8, by step: Int8 = 1) -> Bool {
                    #if DEBUG
                    if !(step > 0) {
                        SwiftFormal.Contract.requiresFailed("step > 0")
                    }
                    #endif
                    let __sf_result: Bool = { () -> Bool in
                        x &+= step
                            return true
                    }()
                    #if DEBUG
                    if !(({ $0
                            })(__sf_result)) {
                        SwiftFormal.Contract.ensuresFailed("{ $0 }")
                    }
                    #endif
                    return __sf_result
                }

                func bump_requires(_ x: inout Int8, _ step: Int8) -> Bool {
                    (step > 0)
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Scan checks no #ensures of a function with an inout parameter (it would see the value before the call); "
                        + "the check in the body still runs. Return the new value instead",
                    line: 1, column: 1, severity: .warning)
            ],
            macroSpecs: macros
        )
    }

    /// Five parameters without `over:` (the pre-release bug: a flat five-way product that does not exist, so the compiler
    /// picked the four-way one): nested pairs mapped back to the flat tuple, as `@Finite` builds a struct. A type the
    /// macro cannot judge (`Club`) takes `Domain.ofParameterType`, which is the type's domain when it is `Finite`.
    @Test func fiveParametersWalkANestedProductMappedToAFlatTuple() {
        assertExpansion(
            """
            @Verify
            func score(_ a: Bool, b: Bool?, _ c: Int8, d: UInt8, club e: Club) -> Bool {
                #ensures { _ in true }
                return a
            }
            """,
            expandedSource: """
                func score(_ a: Bool, b: Bool?, _ c: Int8, d: UInt8, club e: Club) -> Bool {
                    let __sf_result: Bool = { () -> Bool in
                        return a
                    }()
                    #if DEBUG
                    if !(({ _ in
                                true
                            })(__sf_result)) {
                        SwiftFormal.Contract.ensuresFailed("{ _ in true }")
                    }
                    #endif
                    return __sf_result
                }

                func verify_score(budget: SwiftFormal.Budget = .default) -> SwiftFormal.Report {
                    SwiftFormal._verifyContracts(
                        "score",
                        { (input: (Bool, Bool?, Int8, UInt8, Club)) -> Bool in
                            let __sf_result: Bool = score(input.0, b: input.1, input.2, d: input.3, club: input.4)
                            if !(({ _ in
                                        true
                                    })(__sf_result)) {
                                SwiftFormal.Contract.ensuresFailed("{ _ in true }")
                            }
                            return __sf_result
                        },
                        over: SwiftFormal.Domain.product(SwiftFormal.Domain.ofParameterType((Bool).self), SwiftFormal.Domain.product(SwiftFormal.Domain.ofParameterType((Bool?).self), SwiftFormal.Domain.product(SwiftFormal.Domain.ofParameterType((Int8).self), SwiftFormal.Domain.product(SwiftFormal.Domain.ofParameterType((UInt8).self), SwiftFormal.Domain.ofParameterType((Club).self))))).map {
                            ($0.0, $0.1.0, $0.1.1.0, $0.1.1.1.0, $0.1.1.1.1)
                        },
                        budget: budget
                    )
                }

                func score_ensures(_ a: Bool, _ b: Bool?, _ c: Int8, _ d: UInt8, _ e: Club, _ __sf_result: Bool) -> Bool {
                    ({ _ in
                            true
                        })(__sf_result)
                }
                """,
            macroSpecs: macros
        )
    }
}
