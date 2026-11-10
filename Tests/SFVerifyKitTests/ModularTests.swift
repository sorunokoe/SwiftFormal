import Foundation
import SFVerifyKit
import Testing

/// Plan item H4: `--modular` proves, with the contracts of callees proved in the same run, what inlining leaves
/// undecided or cannot reach (a call chain deeper than the encoder inlines), and keeps every other verdict.
@Suite struct ModularTests {
    /// `c0` calls `c1` ... calls `c11`, each with the contract `x < 10` ⇒ `result == x + 1`; `w0` ... `w11` the same
    /// code with the weak contract `result > x`. Inlining stops at depth 8, so `c0`...`c3` are out of reach without
    /// contracts.
    static let source: String = {
        var lines: [String] = []
        for (prefix, ensures) in [("c", "x < 10 && result == x + 1"), ("w", "result > x")] {
            for k in 0..<12 {
                let body = k == 11 ? "x + 1" : "\(prefix)\(k + 1)(x)"
                lines += [
                    "public func \(prefix)\(k)(_ x: UInt8) -> UInt8 { \(body) }",
                    verifyPeers(
                        of: "\(prefix)\(k)",
                        """
                        public func \(prefix)\(k)_requires(_ x: UInt8) -> Bool { x < 10 }
                        public func \(prefix)\(k)_ensures(_ x: UInt8, _ result: UInt8) -> Bool { \(ensures) }
                        """),
                ]
            }
        }
        lines += [
            // Safe by the contract of c0.
            "public func top(_ x: UInt8) -> UInt8 { c0(x % 10) - 1 }",
            // Safe only by w0's code (it returns at most 10); its contract allows 255.
            "public func weakTop(_ x: UInt8) -> UInt8 { 20 - w0(x % 10) }",
            // Traps for x = 4; w0's contract allows that and more.
            "public func trapTop(_ x: UInt8) -> UInt8 { let r = w0(x % 10); precondition(r != 5); return r }",
            // c0(200) breaks c0's `requires`, and c0_ensures cannot hold there (200 < 10 is false). Really it returns
            // 201 and the precondition traps: assuming `ensures` there would make everything after it vacuous.
            "public func vacuous(_ x: UInt8) -> UInt8 { let r = c0(200); precondition(r < 100); return r &+ x }",
            // c0(255) breaks `requires`, and really overflows in c11: a call outside `requires` must count as a trap.
            "public func breaksRequires(_ x: UInt8) -> UInt8 { c0(255) &+ x }",
        ]
        return lines.joined(separator: "\n")
    }()

    static func scan(modular: Bool, configurations: [BuildConfiguration] = [.debug]) throws -> ScanReport {
        let directory = NSTemporaryDirectory() + "sfv-h4-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/chain.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = configurations
        options.modular = modular
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Chain"), options)
    }

    private static func function(_ report: ScanReport, _ name: String) throws -> FunctionReport {
        try #require(report.functions.first { $0.name.hasPrefix(name + "(") })
    }

    @Test func aChainTooDeepToInlineIsProvedByItsCalleesContracts() throws {
        let inlined = try Self.scan(modular: false)
        for name in ["c0", "c3", "top"] {
            #expect(try Self.function(inlined, name).category == "deep call chain", "\(name) without --modular")
        }
        #expect(try Self.function(inlined, "c4").status == .contractHolds)

        // c4...c11 are proved by inlining; c0...c3 then inline down to c4 and use its contract.
        let modular = try Self.scan(modular: true)
        for name in ["c0", "c1", "c2", "c3", "top"] {
            let f = try Self.function(modular, name)
            #expect(f.status == (name == "top" ? .safe : .contractHolds), "\(name): \(f.status) \(f.detail ?? "")")
            #expect(f.usesContracts == ["c4(_:)"], "\(name): \(f.usesContracts ?? [])")
        }
        #expect(modular.text().contains("used the contract of c4(_:)"))
        // What inlining decided is untouched, and has no contracts listed.
        let c4 = try Self.function(modular, "c4")
        #expect(c4.status == .contractHolds && c4.usesContracts == nil)
    }

    @Test func aWeakContractOrAViolatedRequiresNeverGivesSafe() throws {
        let modular = try Self.scan(modular: true)
        for name in ["weakTop", "trapTop", "vacuous", "breaksRequires"] {
            let f = try Self.function(modular, name)
            #expect(f.status == .unsupported && f.category == "deep call chain", "\(name): \(f.status) \(f.usesContracts ?? [])")
            #expect(f.usesContracts == nil)
        }
        // The w chain itself is proved: its contract is weak, not wrong.
        #expect(try Self.function(modular, "w0").status == .contractHolds)
        #expect(try Self.function(modular, "w0").usesContracts == ["w4(_:)"])
    }

    /// With both `assert` configurations the release build is the same code here: no recheck, the same proofs.
    @Test func bothConfigurationsKeepTheModularProofs() throws {
        let report = try Self.scan(modular: true, configurations: [.debug, .release])
        #expect(try Self.function(report, "c0").status == .contractHolds)
        #expect(try Self.function(report, "vacuous").status == .unsupported)
    }

    @Test func modularVerdictsAreTheSameEveryRun() throws {
        func verdicts(_ r: ScanReport) -> [String] {
            r.functions.map { "\($0.name) \($0.status) \($0.usesContracts ?? [])" }.sorted()
        }
        #expect(verdicts(try Self.scan(modular: true)) == verdicts(try Self.scan(modular: true)))
    }
}
