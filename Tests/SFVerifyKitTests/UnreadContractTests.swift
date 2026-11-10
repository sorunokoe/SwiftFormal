import Foundation
import Testing
@testable import SFVerifyKit

/// A contract Scan cannot read is never dropped in silence (round 6, L9), and it never hides a trap (L5). A
/// function whose contract is not read is `unsupported` with the category "contract not read" and the reason, and is
/// counted as a contract not checked; when the function alone is readable and traps for an input its `requires` allows,
/// that trap breaks the contract whatever the `ensures` says.
@Suite struct UnreadContractTests {
    static let source = """
        struct Wrong {
            let input: Int8
            var flag: Bool { input > 0 }
            #sourceLocation(file: "@__swiftmacro_6Unread4flag6VerifyfMp_.swift", line: 1)
            func flag_ensures(_ result: Int8) -> Bool { result > 0 }
            #sourceLocation()
        }

        struct Closure {
            let input: Int8
            var half: Int8 { input / 2 }
            #sourceLocation(file: "@__swiftmacro_6Unread4half6VerifyfMp_.swift", line: 1)
            func half_ensures(_ result: Int8) -> Bool { [result].sorted { $0 < $1 }.count == 1 }
            #sourceLocation()
        }

        struct Hidden {
            let input: Int8
            var ratio: Int8 { 100 / input }
            #sourceLocation(file: "@__swiftmacro_6Unread5ratio6VerifyfMp_.swift", line: 1)
            func ratio_requires() -> Bool { input >= 0 }
            func ratio_ensures(_ result: Int8) -> Bool { [result].sorted { $0 < $1 }.count == 1 }
            #sourceLocation()
        }

        struct Guarded {
            let input: Int8
            var ratio: Int8 { 100 / input }
            #sourceLocation(file: "@__swiftmacro_6Unread5ratio6VerifyfMp_.swift", line: 1)
            func ratio_requires() -> Bool { input > 0 }
            func ratio_ensures(_ result: Int8) -> Bool { [result].sorted { $0 < $1 }.count == 1 }
            #sourceLocation()
        }
        """

    static func scan() throws -> ScanReport {
        let directory = NSTemporaryDirectory() + "sfv-unread-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/Unread.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Unread"), options)
    }

    @Test func aContractScanCannotReadIsReportedAndNotProved() throws {
        let report = try Self.scan()
        func named(_ name: String) throws -> FunctionReport { try #require(report.functions.first { $0.name == name }, "\(name)") }

        // A spec of the wrong shape: the getter cannot trap, but its contract is not read, so it is not "safe".
        let wrong = try named("Wrong.flag.getter")
        #expect(wrong.status == .unsupported && wrong.category == Verifier.contractNotReadCategory, "\(wrong)")
        #expect(wrong.hasContract)
        #expect(wrong.detail?.contains("Wrong.flag_ensures(_:)") == true, "\(wrong.detail ?? "")")

        // An ensures logic cannot read, on a function it reads: the contract is the blocker, not the function.
        let closure = try named("Closure.half.getter")
        #expect(closure.status == .unsupported && closure.category == Verifier.contractNotReadCategory, "\(closure)")
        #expect(closure.detail?.contains("Closure.half_ensures(_:)") == true, "\(closure.detail ?? "")")

        // The function traps for an input its requires allows: a broken contract with that input, not "not read".
        let hidden = try named("Hidden.ratio.getter")
        #expect(hidden.status == .contractFails, "\(hidden)")
        #expect(hidden.counterexample?.inputs.joined().contains("input: 0") == true, "\(String(describing: hidden.counterexample))")

        // Where the requires rules the trap out, the ensures still decides: not proved.
        let guarded = try named("Guarded.ratio.getter")
        #expect(guarded.status == .unsupported && guarded.category == Verifier.contractNotReadCategory, "\(guarded)")

        #expect(report.text().contains("Contracts: 0 hold, 1 fail, 3 not checked"), "\(report.text())")
        #expect(report.summary.unsupportedByCategory[Verifier.contractNotReadCategory] == 3)
    }

    /// `swiftformal check --gate` names the contract as what logic cannot read.
    @Test func verifySaysTheContractWasNotRead() throws {
        let result = BuildCheck.evaluate(try Self.scan(), promises: [])
        let closure = result.diagnostics.filter { $0.contains("Closure.half.getter") }
        #expect(closure.count == 1, "\(result.diagnostics)")
        #expect(closure.first?.contains("logic cannot read its contract") == true, "\(closure)")
        #expect(result.diagnostics.contains { $0.contains("Hidden.ratio.getter") && $0.contains(": error: ") }, "\(result.diagnostics)")
    }
}
