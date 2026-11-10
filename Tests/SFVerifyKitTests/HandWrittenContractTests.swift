import Foundation
import SFVerifyKit
import Testing

/// Only `@Verify`: Scan reads a contract only from the peers `@Verify` writes. A hand-written `f_requires` / `f_ensures`
/// of the right shape is reported on `f` (`ignoredContracts`) and never read, so `f`'s verdict is about traps only and
/// no contract verdict comes from it, true or false.
@Suite struct HandWrittenContractTests {
    /// `wrong` breaks its hand-written postcondition; `guarded` traps where its hand-written precondition would exclude
    /// it; `kept` is what `@Verify` writes, with the same false postcondition as `wrong`.
    static let source = """
        func wrong(_ x: UInt8) -> UInt8 { x &+ 1 }
        func wrong_ensures(_ x: UInt8, _ r: UInt8) -> Bool { r > x }

        func guarded(_ x: Int8) -> Int8 { x + 1 }
        func guarded_requires(_ x: Int8) -> Bool { x < 100 }

        func kept(_ x: UInt8) -> UInt8 { x &+ 1 }
        \(verifyPeers(of: "kept", "func kept_ensures(_ x: UInt8, _ r: UInt8) -> Bool { r > x }"))

        struct Meter {
            var value: Int8
            var next: Int8 { value &+ 1 }
            func next_ensures(_ r: Int8) -> Bool { r > value }
        }
        """

    static func scan(_ source: String = source) throws -> ScanReport {
        let directory = NSTemporaryDirectory() + "sfv-handwritten-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/App.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "App"))
    }

    static func function(_ report: ScanReport, _ name: String) throws -> FunctionReport {
        try #require(report.functions.first { $0.name.hasPrefix(name + "(") || $0.name == name }, "\(report.functions.map(\.name))")
    }

    @Test func aHandWrittenContractIsReportedAndNotRead() throws {
        let report = try Self.scan()

        // A false hand-written postcondition is no contract failure, and no contract holds by it either.
        let wrong = try Self.function(report, "wrong")
        #expect(wrong.status == .safe, "\(wrong)")
        #expect(!wrong.hasContract)
        #expect(wrong.ignoredContracts == ["wrong_ensures(_:_:)"])

        // A hand-written precondition does not narrow the inputs: the trap it would exclude is found.
        let guarded = try Self.function(report, "guarded")
        #expect(guarded.status == .mayTrap)
        #expect(guarded.ignoredContracts == ["guarded_requires(_:)"])

        let next = try Self.function(report, "Meter.next.getter")
        #expect(next.status == .safe && next.ignoredContracts == ["Meter.next_ensures(_:)"])

        // The hand-written functions are ordinary code now: scanned for traps like any other.
        #expect(try Self.function(report, "wrong_ensures").status == .safe)

        // Nothing written by hand is proved or broken as a contract.
        for function in report.functions where function.name.hasPrefix("wrong") || function.name.hasPrefix("guarded") {
            #expect(![.contractHolds, .contractFails].contains(function.status), "\(function.name)")
        }
        #expect(report.text().contains("contract not read: wrong_ensures(_:_:) is written by hand"))
        #expect(report.text().contains("write the contract in place with @Verify, #requires and #ensures"))
        #expect(try report.json().contains("\"ignoredContracts\""))
    }

    /// The same postcondition where `@Verify` puts it is read, and refuted.
    @Test func theContractVerifyWritesIsRead() throws {
        let report = try Self.scan()
        let kept = try Self.function(report, "kept")
        #expect(kept.status == .contractFails && kept.hasContract && kept.ignoredContracts == nil, "\(kept)")
        #expect(!report.functions.contains { $0.name.hasPrefix("kept_ensures") }, "a peer is verified with its function")
    }
}
