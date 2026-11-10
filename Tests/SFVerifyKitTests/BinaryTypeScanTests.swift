import Foundation
import Testing

@testable import SFSIL
@testable import SFVerifyKit

/// Mapper logic over types of binary modules (`BinaryFixture`): enums whose cases the compiler gives, calls with no
/// body that return any value of their type (each an assumption the report lists), and Objective-C objects.
@Suite struct BinaryTypeScanTests {
    static func scan(opaqueCalls: Bool = true) throws -> ScanReport {
        var options = VerifyOptions()
        options.configurations = [.debug]
        options.opaqueCalls = opaqueCalls
        return try SFVerify.run(try BinaryFixture.client(["Mappers.swift"], moduleName: "BinaryClient"), options)
    }

    static let report = Result { try scan() }
    static let strict = Result { try scan(opaqueCalls: false) }

    static func function(_ name: String, in report: Result<ScanReport, any Error> = report) throws -> FunctionReport {
        let functions = try report.get().functions
        return try #require(functions.first { $0.name.hasPrefix(name + "(") }, "\(functions.map(\.name))")
    }

    static func describe(_ f: FunctionReport) -> String {
        "\(f.name): \(f.status) \(f.detail ?? "") \(f.counterexample.map { "\($0.inputs) \($0.failure)" } ?? "") "
            + "assumes \(f.assumptions ?? [])"
    }

    @Test func closedBinaryEnumsProve() throws {
        for name in ["sealedTitle", "teeColour", "halfNumber", "puttSurfaceText", "identicalShot"] {
            let f = try Self.function(name)
            #expect(f.status == .contractHolds, "\(Self.describe(f))")
        }
        for name in ["surfaceObject", "puttSurface", "shotDistance"] {
            let f = try Self.function(name)
            #expect(f.status == .safe, "\(Self.describe(f))")
        }
    }

    /// A non-frozen enum of a module built with library evolution may hold a case added later.
    @Test func anOpenEnumReachesUnknownDefault() throws {
        let f = try Self.function("seasonMonth")
        #expect(f.status == .contractFails, "\(Self.describe(f))")
        #expect(f.counterexample?.inputs.joined().contains("unknown") == true, "\(Self.describe(f))")
    }

    /// A call with no body returns any value of its type, each call its own, and says so.
    @Test func callsWithNoBodyAreFreeValuesAndListedAssumptions() throws {
        let ordinal = try Self.function("surfaceOrdinal")
        #expect(ordinal.status == .contractFails, "\(Self.describe(ordinal))")
        #expect(
            ordinal.assumptions?.contains { $0.contains("Surface.ordinal") && $0.contains("Int32") } == true, "\(Self.describe(ordinal))")
        #expect(ordinal.assumptions?.contains { $0.contains("not to trap") } == true, "\(Self.describe(ordinal))")

        let twice = try Self.function("twoLooks")
        #expect(twice.status == .contractFails, "\(Self.describe(twice))")
        let looks = try Self.function("shotDistance")
        #expect(looks.assumptions?.contains { $0.contains("onEnum(of:)") && $0.contains("any case") } == true, "\(Self.describe(looks))")
        #expect(looks.assumptions?.contains { $0.contains("feet") } == true, "\(Self.describe(looks))")
        let bridged = try Self.function("puttSurface")
        #expect(
            bridged.assumptions?.contains { $0.contains("_unconditionallyBridgeFromObjectiveC") } == true, "\(Self.describe(bridged))")
        // Case lists come from the compiler: no assumption.
        #expect(try Self.function("sealedTitle").assumptions == nil)
        // Types as Swift spells them, without SIL's ownership conventions (`@autoreleased`).
        let all = try Self.report.get().functions.flatMap { $0.assumptions ?? [] }
        #expect(all.contains { $0.contains("KitSurface") } && !all.contains { $0.contains("@") }, "\(all)")
    }

    /// `==` on Objective-C objects calls `isEqual:`: either answer, even for the same object.
    @Test func objectiveCEqualityIsAFreeBool() throws {
        let f = try Self.function("sameShot")
        #expect(f.status == .contractFails, "\(Self.describe(f))")
        #expect(f.assumptions?.contains { $0.contains("isEqual:") } == true, "\(Self.describe(f))")
    }

    /// The mode is part of a function's proof cache key, and an answer taken from the cache keeps its assumptions.
    @Test func theProofCacheKeepsAssumptions() throws {
        let compiled = try ModuleCompiler.compile(try BinaryFixture.client(["Mappers.swift"], moduleName: "BinaryClient"))
        var strict = VerifyOptions()
        strict.opaqueCalls = false
        let symbol = try #require(compiled.functions.first { $0.displayName.hasPrefix("puttSurface(") }?.symbol)
        #expect(Verifier.proofCacheKeys(compiled)[symbol] != Verifier.proofCacheKeys(compiled, options: strict)[symbol])

        let directory = BinaryFixture.packageRoot.path + "/.build/sf-fixtures/proofs-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var options = VerifyOptions()
        options.configurations = [.debug]
        options.proofCache = ScanProofCache(directory: directory)
        let client = try BinaryFixture.client(["Mappers.swift"], moduleName: "BinaryClient")
        _ = try SFVerify.run(client, options)
        let again = try SFVerify.run(client, options)
        let f = try #require(again.functions.first { $0.name.hasPrefix("puttSurface(") })
        #expect(f.fromCache == true && f.status == .safe, "\(Self.describe(f))")
        #expect(f.assumptions == (try Self.function("puttSurface").assumptions), "\(Self.describe(f))")
    }

    /// `--no-opaque-calls`: a call with no body is refused again; the compiler's case lists still hold.
    @Test func strictModeRefusesCallsWithNoBody() throws {
        for name in ["surfaceOrdinal", "puttSurface", "shotDistance", "sameShot", "twoLooks"] {
            let f = try Self.function(name, in: Self.strict)
            #expect(f.status == .unsupported, "\(Self.describe(f))")
            #expect(f.detail?.contains("--no-opaque-calls") == true, "\(Self.describe(f))")
        }
        for name in ["sealedTitle", "teeColour", "halfNumber"] {
            let f = try Self.function(name, in: Self.strict)
            #expect(f.status == .contractHolds, "\(Self.describe(f))")
        }
        #expect(try Self.function("seasonMonth", in: Self.strict).status == .contractFails)
    }

    /// A proof that rests on a callee's (inlined, or its contract with `--modular`) trusts what the callee assumed.
    @Test func aCalleesAssumptionsAreItsCallersToo() throws {
        var options = VerifyOptions()
        options.configurations = [.debug]
        options.modular = true
        let chains = Result { try SFVerify.run(try BinaryFixture.client(["Chains.swift"], moduleName: "BinaryChains"), options) }
        for name in ["viaHelper", "chainTop", "ordinalChain0"] {
            let f = try Self.function(name, in: chains)
            #expect([.safe, .contractHolds].contains(f.status), "\(Self.describe(f))")
            #expect(f.assumptions?.contains { $0.contains("Surface.ordinal") } == true, "\(Self.describe(f))")
        }
        // Deeper than inlining goes, so a callee's contract stands for its code.
        #expect(try Self.function("chainTop", in: chains).usesContracts?.isEmpty == false)
    }

    /// Summaries say how many proofs rest on assumptions: the scan's, `swiftformal check`'s and the build check's.
    @Test func summariesCountProofsThatAssume() throws {
        let report = try Self.report.get()
        let assuming = report.functions.filter { [.safe, .contractHolds].contains($0.status) && $0.assumptions != nil }
        #expect(!assuming.isEmpty)
        #expect(report.summary.withAssumptions == assuming.count)
        let safe = assuming.count { $0.status == .safe }
        #expect(report.text().contains("Proved safe (cannot trap for any input): \(report.summary.safe) (\(safe) with assumptions)"))
        #expect(try report.json().contains("\"withAssumptions\" : \(assuming.count)"))

        let entries = report.functions.map { CheckEntry(module: report.module, package: nil, function: $0, walks: []) }
        let check = CheckReport(entries: entries, unlinkedWalks: [], ranWalks: 0, totalWalks: 0)
        let putt = try Self.function("puttSurface")
        let n = try #require(putt.assumptions?.count)
        let assumed = ", assuming \(n) call\(n == 1 ? "" : "s") with no body"
        #expect(check.text(showProved: true).contains("puttSurface(_:)\(Self.place(putt)) — cannot trap for any input\(assumed)"))
        #expect(check.text().contains("\(assuming.count) assuming calls with no body)"))
        #expect(check.diagnostics(showProved: true).contains("puttSurface(_:): cannot trap for any input (logic\(assumed))"))
        #expect(try check.json().contains("\"assumptions\" : ["))

        let built = BuildCheck.evaluate(report, promises: [])
        #expect(built.provedAssuming == assuming.count { $0.hasContract })
    }

    /// A call with no body into a module the scan knows nothing about says so, without calling it binary.
    @Test func callsWithNoBodyNameWhereTheBodyIs() throws {
        let all = try Self.report.get().functions.flatMap { $0.assumptions ?? [] }.filter { $0.contains("Kit") }
        #expect(!all.isEmpty && all.allSatisfy { !$0.contains("binary module") }, "\(all)")
        #expect(all.contains { $0.contains("no body available (module Kit)") }, "\(all)")

        let derived = "/Volumes/ci/Library/Developer/Xcode/DerivedData/App-abc/Build/Products/Debug-iphonesimulator"
        #expect(BinaryTypeCheck.origin(of: derived + "/Core.swiftmodule/arm64-apple-ios-simulator.swiftmodule") == .notScanned)
        #expect(BinaryTypeCheck.origin(of: "/p/.build/arm64-apple-macosx/debug/Modules/Core.swiftmodule") == .notScanned)
        #expect(BinaryTypeCheck.origin(of: "/p/build/SharedKt.framework/Modules/SharedKt.swiftmodule/arm64.swiftmodule") == .binary)
        #expect(BinaryTypeCheck.origin(of: derived + "/Kit.framework/Modules/Kit.swiftmodule/arm64.swiftmodule") == .unknown)
        #expect(BinaryTypeCheck.origin(of: "/p/.build/artifacts/x/Kit.xcframework/ios/Kit.framework/Modules/Kit.swiftmodule") == .binary)
        #expect(BinaryTypeCheck.origin(of: "/p/fixtures/Kit.swiftmodule") == .unknown)
        let source = SFSIL.ModuleOrigin.notScanned.describe("Core")
        #expect(source.contains("not scanned (module Core)") && source.contains("`--scan <dir>:Core`"), "\(source)")
    }

    private static func place(_ f: FunctionReport) -> String {
        f.location.map { " (\(URL(fileURLWithPath: $0.file).lastPathComponent):\($0.line))" } ?? ""
    }
}
