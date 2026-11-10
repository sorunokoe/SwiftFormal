import Foundation
import SFVerifyKit
import Testing

/// Plan item V4: `--cross-check llvm` compares each proved function with its LLVM IR, read by the second encoder.
@Suite struct CrossCheckTests {
    private static func scan(_ mode: CrossCheck, source: String? = nil) throws -> ScanReport {
        let directory = NSTemporaryDirectory() + "sfv-v4-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/cross.swift"
        try
            (source
                ?? """
                public func wrapInc(_ x: Int8) -> Int8 { x &+ 1 }
                public func greeting(_ name: String) -> Int { name.isEmpty ? 0 : 1 }
                public func inc(_ x: Int8) -> Int8 { x + 1 }
                """).write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        options.crossCheck = mode
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Cross"), options)
    }

    @Test func provedFunctionsAreComparedWithTheirIR() throws {
        let report = try Self.scan(.llvm)
        func find(_ name: String) -> FunctionReport? { report.functions.first { $0.name.hasPrefix(name + "(") } }
        #expect(find("wrapInc")?.status == .safe)
        #expect(find("wrapInc")?.crossCheck == "agrees")
        #expect(find("greeting")?.status == .safe)
        #expect(find("greeting")?.crossCheck == "unread", "the IR reader does not call into the standard library")
        #expect(find("greeting")?.crossCheckReason?.contains("UNSUPPORTED") == true, "an unread proof says why")
        #expect(find("wrapInc")?.crossCheckReason == nil)
        #expect(find("inc")?.status == .mayTrap)
        #expect(find("inc")?.crossCheck == nil, "only proved functions are cross-checked")
        let off = try Self.scan(.off)
        #expect(off.functions.allSatisfy { $0.crossCheck == nil })
    }

    /// Round 6, item 6: the shapes app code is made of (accessors, memberwise initializers, synthesized `==`, enum
    /// switches) reach the IR reader through the signature bridge and agree.
    @Test func appShapedProofsAreCrossChecked() throws {
        let report = try Self.scan(
            .llvm,
            source: """
                public struct Club {
                    public var loft: Int
                    public var isActive: Bool
                    public var name: String
                    public var nickname: String?
                    public var onTap: (() -> Void)?
                    public init(loft: Int, isActive: Bool, name: String) {
                        self.loft = loft; self.isActive = isActive; self.name = name; nickname = nil; onTap = nil
                    }
                }
                public enum Kind: Equatable { case driver, iron, putter }
                public func rank(_ k: Kind) -> Int { switch k { case .driver: 1; case .iron: 2; case .putter: 3 } }
                public func orZero(_ x: Int?) -> Int { x ?? 0 }
                """)
        func find(_ name: String) -> FunctionReport? { report.functions.first { $0.name.hasPrefix(name) } }
        // The IR's exact shape (how a struct is cut into pieces, the debugger slots of -Onone) is the pinned compiler's;
        // on another compiler a proof may come back unread, but never as a disagreement.
        let pinned = (try? ScanToolchain.current().isPinned()) ?? false
        for name in [
            "Club.loft.getter", "Club.isActive.getter", "Club.name.getter", "Club.nickname.getter", "Club.onTap.getter",
            "Club.init(loft:isActive:name:)", "static Kind.__derived_enum_equals", "rank(", "orZero(",
        ] {
            #expect(find(name)?.status == .safe, "\(name)")
            if pinned { #expect(find(name)?.crossCheck == "agrees", "\(name): \(find(name)?.crossCheckReason ?? "")") }
        }
        // A setter's result is what it writes through `self`; the bridge does not compare memory results yet.
        #expect(find("Club.loft.setter")?.crossCheck == "unread")
        #expect(find("Club.loft.setter")?.crossCheckReason?.contains("written through an address") == true)
        #expect(!report.functions.contains { $0.crossCheck == "disagrees" })
    }

    @Test func strictModeTurnsAnUnconfirmedProofIntoUndecided() throws {
        let report = try Self.scan(.llvmStrict)
        #expect(report.functions.first { $0.name.hasPrefix("wrapInc(") }?.status == .safe)
        let greeting = try #require(report.functions.first { $0.name.hasPrefix("greeting(") })
        #expect(greeting.status == .undecided)
        #expect(greeting.detail?.contains("llvm-strict") == true)
    }
}
