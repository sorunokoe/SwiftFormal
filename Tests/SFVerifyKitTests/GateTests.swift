import Foundation
import Testing
import SFVerifyKit

/// The build gate on real `swiftc` output: a gated function that is not proved must fail the build, with a line number.
/// A function is gated by `@Verify` (compiled here with the macro this package built, `VerifyMacroScanTests.macroArguments()`);
/// a `// sf:verify` comment and a hand-written contract are no longer read, and each fails the gate.
@Suite struct GateTests {
    private func gate(_ source: String, module: String = "Gated") throws -> GateResult {
        let dir = NSTemporaryDirectory() + "sfgate-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/gated.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var arguments: [String] = []
        if source.contains("import SwiftFormal") { arguments = try VerifyMacroScanTests.macroArguments() }
        return SFVerify.gate(CompileOptions(files: [file], moduleName: module, extraArguments: arguments))
    }

    /// `StepByStep` mangles as `06StepByA0` (a repeated word): the gated function is still found and proved.
    @Test func moduleNameWithARepeatedWordIsGated() throws {
        let result = try gate(
            """
            import SwiftFormal
            @Verify
            func half(_ x: Int) -> Int { x / 2 }
            """, module: "StepByStep")
        #expect(result.passed, "\(result.diagnostics)")
        #expect(result.gated == 1 && result.proved == 1)
    }

    @Test func provedVerifyFunctionPasses() throws {
        let result = try gate(
            """
            import SwiftFormal
            @Verify
            func clamp(_ x: Int8, _ lo: Int8, _ hi: Int8) -> Int8 {
                #requires(lo <= hi)
                #ensures { $0 >= lo && $0 <= hi }
                return x < lo ? lo : (x > hi ? hi : x)
            }
            """)
        #expect(result.passed, "\(result.diagnostics)")
        #expect(result.gated == 1 && result.proved == 1)
    }

    @Test func trappingVerifyFunctionFailsWithItsLine() throws {
        let result = try gate(
            """
            import SwiftFormal
            func fine() {}
            @Verify
            func next(_ x: Int8) -> Int8 {
                x + 1
            }
            """)
        #expect(!result.passed)
        let message = try #require(result.diagnostics.first { $0.contains(": error:") })
        #expect(message.contains("gated.swift:"), "\(result.diagnostics)")
        #expect(message.contains("x = 127"))
    }

    @Test func functionsWithoutVerifyAreIgnoredAndCostNoCompile() throws {
        let result = try gate("func next(_ x: Int8) -> Int8 { x + 1 }")
        #expect(result.passed)
        #expect(result.gated == 0)
    }

    @Test func gatedButUnsupportedFailsClosed() throws {
        let result = try gate(
            """
            import SwiftFormal
            @Verify
            func twice(_ f: (Int8) -> Int8) -> Int8 { f(f(1)) }
            """)
        #expect(!result.passed)
        #expect(result.diagnostics.contains { $0.contains("outside what sfverify can prove") })
    }

    @Test func contractsAreGated() throws {
        let result = try gate(
            """
            import SwiftFormal
            @Verify
            func bump(_ x: UInt8) -> UInt8 {
                #ensures { $0 > x }
                return x &+ 1
            }
            """)
        #expect(!result.passed)
        #expect(result.gated == 1)
        #expect(
            result.diagnostics.contains { $0.contains("bump(_:) breaks its contract") && $0.contains("x = 255") }, "\(result.diagnostics)")
    }

    /// K11: a broken postcondition points at the `_ensures` function too when the source declares one (here written as
    /// `@Verify` places it), so the editor can jump to the spec.
    @Test func brokenContractNotesTheEnsuresDeclaration() throws {
        let result = try gate(
            """
            func bump(_ x: UInt8) -> UInt8 { x &+ 1 }

            #sourceLocation(file: "@__swiftmacro_5Gated4bump6VerifyfMp_.swift", line: 1)
            func bump_ensures(_ x: UInt8, _ r: UInt8) -> Bool { r > x }
            #sourceLocation()
            """)
        #expect(!result.passed)
        let note = try #require(result.diagnostics.first { $0.contains(": note:") && $0.contains("bump_ensures") })
        #expect(note.contains("gated.swift:4:"), "\(result.diagnostics)")
        #expect(note.contains("x = 255"))
    }

    /// Only `@Verify`: a hand-written contract is not read. The gate fails at the function, and never counts it proved,
    /// whether the contract is false (here) or not.
    @Test func aHandWrittenContractFailsTheGate() throws {
        let result = try gate(
            """
            func bump(_ x: UInt8) -> UInt8 { x &+ 1 }
            func bump_ensures(_ x: UInt8, _ r: UInt8) -> Bool { r > x }
            func inc(_ x: UInt8) -> UInt8 { x &+ 1 }
            func inc_ensures(_ x: UInt8, _ r: UInt8) -> Bool { r == x &+ 1 }
            """)
        #expect(!result.passed)
        #expect(result.gated == 2 && result.proved == 0)
        let errors = result.diagnostics.filter { $0.contains(": error:") }
        #expect(errors.count == 2, "\(result.diagnostics)")
        #expect(errors.allSatisfy { $0.contains("contract not read") && $0.contains("@Verify, #requires and #ensures") })
        #expect(errors.contains { $0.contains("gated.swift:1:") && $0.contains("bump_ensures(_:_:) is written by hand") })
    }

    /// A peer `@Verify` wrote in a shape Scan cannot pair checks nothing: the gate fails at it rather than prove the
    /// function without its contract (here `_ensures` takes an `Int16` result where `flag` returns `Int8`).
    @Test func aContractScanCannotPairFailsTheGate() throws {
        let result = try gate(
            """
            func flag() -> Int8 { 1 }
            #sourceLocation(file: "@__swiftmacro_5Gated4flag6VerifyfMp_.swift", line: 1)
            func flag_ensures(_ r: Int16) -> Bool { r == 1 }
            #sourceLocation()
            """)
        #expect(!result.passed && result.proved == 0, "\(result.diagnostics)")
        #expect(result.diagnostics.contains { $0.contains("flag_ensures(_:) checks nothing") && $0.contains(": error:") })
    }

    /// K11: a trap reported inside a callee also names the gated declaration and the input that reaches the trap.
    @Test func trapInACalleeNotesTheGatedDeclarationWithItsInputs() throws {
        let result = try gate(
            """
            import SwiftFormal
            @Verify
            func outer(_ x: Int8) -> Int8 {
                inner(x)
            }

            func inner(_ x: Int8) -> Int8 {
                x + 1
            }
            """)
        #expect(!result.passed)
        let error = try #require(result.diagnostics.first { $0.contains(": error:") })
        #expect(error.contains("gated.swift:8:"), "\(result.diagnostics)")
        let note = try #require(result.diagnostics.first { $0.contains(": note:") && $0.contains("gated.swift:3:") })
        #expect(note.contains("outer") && note.contains("x = 127"), "\(note)")
    }

    /// Only `@Verify`: a `// sf:verify` comment selects nothing. Each one is an error, found before any compiler run, so
    /// a broken file cannot hide it.
    @Test func anSfVerifyCommentIsAnErrorAndNeverStartsTheCompiler() throws {
        let result = try gate(
            """
            let x = undefinedThing
            // sf:verify
            func half(_ x: Int) -> Int { x / 2 }
            // sf:verify
            """)
        #expect(!result.passed && result.gated == 0)
        #expect(result.diagnostics.count == 2, "\(result.diagnostics)")
        #expect(result.diagnostics[0].contains("gated.swift:2:1: error:"))
        #expect(result.diagnostics[1].contains("gated.swift:4:1: error:"))
        #expect(result.diagnostics.allSatisfy { $0.contains("`// sf:verify` is no longer read: mark the function @Verify instead") })
    }

    @Test func compilerErrorsFail() throws {
        let broken = try gate(
            """
            import SwiftFormal
            @Verify
            func f(_ x: Int) -> Int { x + undefined }
            """)
        #expect(!broken.passed)
        #expect(broken.diagnostics.contains { $0.contains("error:") && $0.contains("undefined") })
    }
}
