import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing
@testable import SwiftFormalMacros

private let macros: [String: MacroSpec] = ["Verify": MacroSpec(type: VerifyMacro.self)]

// The contract becomes plain `if` checks plus `_requires` / `_ensures` peers: the shape Scan proves on the compiled
// function. `VerifyContractScanTests` scans exactly this text, with and without `DEBUG`.
@Suite struct VerifyMacroExpansionTests {
    /// The checks in the body are inside `#if DEBUG`; the walk checks each `#ensures` itself, so it finds a broken
    /// contract in a release test build too.
    @Test func contractIsWrittenAsChecksAndSpecPeers() {
        assertExpansion(atLeastSource, expandedSource: atLeastExpanded, macroSpecs: macros)
    }

    /// `checks: .always` writes the same checks without `#if DEBUG`.
    @Test func checksAlwaysKeepsTheChecksInEveryBuild() {
        assertExpansion(alwaysSource, expandedSource: alwaysExpanded, macroSpecs: macros)
    }

    /// One expression after `#requires` stays the function's value (app study round 6, L21): it becomes the closure's
    /// value, as with `#ensures`, instead of an unused expression and a missing `return`.
    @Test func aSingleExpressionAfterRequiresIsReturned() {
        assertExpansion(
            """
            @Verify(over: .int(0 ... 3))
            func name(of index: Int) -> String {
                #requires(index >= 0)
                switch index {
                case 0: "zero"
                default: "many"
                }
            }
            """,
            expandedSource: """
                func name(of index: Int) -> String {
                    #if DEBUG
                    if !(index >= 0) {
                        SwiftFormal.Contract.requiresFailed("index >= 0")
                    }
                    #endif
                    return { () -> String in
                        switch index {
                            case 0:
                            "zero"
                            default:
                            "many"
                            }
                    }()
                }

                func verify_name(budget: SwiftFormal.Budget = .default) -> SwiftFormal.Report {
                    SwiftFormal._verifyContracts(
                        "name",
                        { (input: Int) in
                            name(of: input)
                        },
                        over: .int(0 ... 3),
                        budget: budget,
                        requires: { (input: Int) -> Bool in
                            let index = input
                            return (index >= 0)
                        }
                    )
                }

                func name_requires(_ index: Int) -> Bool {
                    (index >= 0)
                }
                """,
            macroSpecs: macros
        )
    }

    /// A `mutating` method keeps `self` before the call as `old`; its `_ensures` takes `old: Self` (Scan's form), and
    /// there is no walk, which would need values of `self` to start from.
    @Test func mutatingMethodComparesWithTheValueBeforeTheCall() {
        assertExpansion(stepSource, expandedSource: stepExpanded, macroSpecs: macros)
    }

    /// When every `#ensures` names `old` `_`, nothing can read it: no copy of `self` (whose storage the body changes in
    /// place) is made, `self` is passed instead, and `_ensures` keeps `old: Self` for Scan.
    @Test func mutatingMethodWhoseEnsuresIgnoreOldCopiesNothing() {
        assertExpansion(pushSource, expandedSource: pushExpanded, macroSpecs: macros)
    }
}

private let pushSource = """
    struct Stack {
        var items: [UInt8]
        @Verify
        mutating func push(_ x: UInt8) -> Int {
            #ensures { count, _ in count == items.count }
            items.append(x)
            return items.count
        }
    }
    """

private let pushExpanded = """
    struct Stack {
        var items: [UInt8]
        mutating func push(_ x: UInt8) -> Int {
            let __sf_result: Int = { () -> Int in
                items.append(x)
                        return items.count
            }()
            #if DEBUG
            if !(({ count, _ in
                        count == items.count
                    })(__sf_result, self)) {
                SwiftFormal.Contract.ensuresFailed("{ count, _ in count == items.count }")
            }
            #endif
            return __sf_result
        }

        func push_ensures(_ x: UInt8, _ __sf_result: Int, old: Self) -> Bool {
            ({ count, _ in
                    count == items.count
                })(__sf_result, old)
        }
    }
    """

private let stepSource = """
    struct Meter {
        var value: Int8
        @Verify
        mutating func step(by amount: Int8) -> Bool {
            #requires(amount >= 0)
            #ensures { moved, old in moved == (value != old.value) }
            #ensures { _, old in value >= old.value }
            if value > 100 { return false }
            value += amount
            return amount > 0
        }
    }
    """

private let stepExpanded = """
    struct Meter {
        var value: Int8
        mutating func step(by amount: Int8) -> Bool {
            #if DEBUG
            if !(amount >= 0) {
                SwiftFormal.Contract.requiresFailed("amount >= 0")
            }
            let __sf_old = self
            #endif
            let __sf_result: Bool = { () -> Bool in
                if value > 100 {
                    return false
                }
                        value += amount
                        return amount > 0
            }()
            #if DEBUG
            if !(({ moved, old in
                        moved == (value != old.value)
                    })(__sf_result, __sf_old)) {
                SwiftFormal.Contract.ensuresFailed("{ moved, old in moved == (value != old.value) }")
            }
            if !(({ _, old in
                        value >= old.value
                    })(__sf_result, __sf_old)) {
                SwiftFormal.Contract.ensuresFailed("{ _, old in value >= old.value }")
            }
            #endif
            return __sf_result
        }

        func step_requires(_ amount: Int8) -> Bool {
            (amount >= 0)
        }

        func step_ensures(_ amount: Int8, _ __sf_result: Bool, old: Self) -> Bool {
            ({ moved, old in
                    moved == (value != old.value)
                })(__sf_result, old) && ({ _, old in
                    value >= old.value
                })(__sf_result, old)
        }
    }
    """

private let atLeastSource = """
    struct Bag {
        @Verify(over: .int(0 ... 9))
        static func atLeast(_ x: Int8) -> Int8 {
            #requires(x >= 0)
            #ensures { $0 >= x }
            return x < 10 ? 10 : x
        }
    }
    """

private let atLeastExpanded = """
    struct Bag {
        static func atLeast(_ x: Int8) -> Int8 {
            #if DEBUG
            if !(x >= 0) {
                SwiftFormal.Contract.requiresFailed("x >= 0")
            }
            #endif
            let __sf_result: Int8 = { () -> Int8 in
                return x < 10 ? 10 : x
            }()
            #if DEBUG
            if !(({ $0 >= x
                    })(__sf_result)) {
                SwiftFormal.Contract.ensuresFailed("{ $0 >= x }")
            }
            #endif
            return __sf_result
        }

        static func verify_atLeast(budget: SwiftFormal.Budget = .default) -> SwiftFormal.Report {
            SwiftFormal._verifyContracts(
                "atLeast",
                { (input: Int8) -> Int8 in
                    let __sf_result: Int8 = atLeast(input)
                    let x = input
                    if !(({ $0 >= x
                            })(__sf_result)) {
                        SwiftFormal.Contract.ensuresFailed("{ $0 >= x }")
                    }
                    return __sf_result
                },
                over: .int(0 ... 9),
                budget: budget,
                requires: { (input: Int8) -> Bool in
                    let x = input
                    return (x >= 0)
                }
            )
        }

        static func atLeast_requires(_ x: Int8) -> Bool {
            (x >= 0)
        }

        static func atLeast_ensures(_ x: Int8, _ __sf_result: Int8) -> Bool {
            ({
                    $0 >= x
                })(__sf_result)
        }
    }
    """

private let alwaysSource = """
    @Verify(over: .int(0 ... 9), checks: .always)
    func atLeast(_ x: Int8) -> Int8 {
        #requires(x >= 0)
        #ensures { $0 >= x }
        return x < 10 ? 10 : x
    }
    """

private let alwaysExpanded = """
    func atLeast(_ x: Int8) -> Int8 {
        if !(x >= 0) {
            SwiftFormal.Contract.requiresFailed("x >= 0")
        }
        let __sf_result: Int8 = { () -> Int8 in
            return x < 10 ? 10 : x
        }()
        if !(({ $0 >= x
                })(__sf_result)) {
            SwiftFormal.Contract.ensuresFailed("{ $0 >= x }")
        }
        return __sf_result
    }

    func verify_atLeast(budget: SwiftFormal.Budget = .default) -> SwiftFormal.Report {
        SwiftFormal._verifyContracts(
            "atLeast",
            { (input: Int8) -> Int8 in
                let __sf_result: Int8 = atLeast(input)
                let x = input
                if !(({ $0 >= x
                        })(__sf_result)) {
                    SwiftFormal.Contract.ensuresFailed("{ $0 >= x }")
                }
                return __sf_result
            },
            over: .int(0 ... 9),
            budget: budget,
            requires: { (input: Int8) -> Bool in
                let x = input
                return (x >= 0)
            }
        )
    }

    func atLeast_requires(_ x: Int8) -> Bool {
        (x >= 0)
    }

    func atLeast_ensures(_ x: Int8, _ __sf_result: Int8) -> Bool {
        ({
                $0 >= x
            })(__sf_result)
    }
    """
