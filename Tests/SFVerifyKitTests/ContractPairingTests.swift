import Foundation
import Testing
@testable import SFVerifyKit

/// App study round 6, L7 and L9: a contract whose types hold a value another module lays out (here `Data`; in the app `URL`, `UUID`, SwiftUI's
/// `Color`), or whose result is a tuple, was not paired with its function. Scan then reported the function with
/// `hasContract: false` and the contract as a separate "function", and `swiftformal check --gate` failed the build with a
/// false "checks nothing" shape error. Such a contract is paired; that Scan cannot read the type is the reason given.
@Suite struct ContractPairingTests {
    static let source = """
        import Foundation

        enum Loading<T> { case loading, loaded(T) }
        struct Details { var url: Data; var count: Int }
        enum ViewState {
            case loading, success(Details)
            var loadingState: Loading<Details> {
                switch self {
                case .loading: .loading
                case .success(let details): .loaded(details)
                }
            }
            #sourceLocation(file: "@__swiftmacro_3App12loadingState6VerifyfMp_.swift", line: 1)
            func loadingState_ensures(_ result: Loading<Details>) -> Bool {
                switch (self, result) {
                case (.loading, .loading), (.success, .loaded): true
                default: false
                }
            }
            #sourceLocation()
        }

        struct LinkRule {
            let input: Int
            var body: (Int, Data?) { (input, nil) }
            #sourceLocation(file: "@__swiftmacro_3App4body6VerifyfMp_.swift", line: 1)
            func body_ensures(_ result: (Int, Data?)) -> Bool { result.0 == input }
            #sourceLocation()
        }

        struct PlaceRule {
            let input: Int8
            var body: (Int8, Bool) { (input, input > 3) }
            #sourceLocation(file: "@__swiftmacro_3App4body6VerifyfMp_.swift", line: 1)
            func body_ensures(_ result: (Int8, Bool)) -> Bool { result.0 == input && result.1 == (input > 3) }
            #sourceLocation()
        }

        struct Odd {
            let input: Int8
            var flag: Bool { input > 0 }
            #sourceLocation(file: "@__swiftmacro_3App4flag6VerifyfMp_.swift", line: 1)
            func flag_ensures(_ result: Int8) -> Bool { result > 0 }
            #sourceLocation()
        }
        """

    static func scan() throws -> ScanReport {
        let directory = NSTemporaryDirectory() + "sfv-pairing-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/Pairing.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Pairing"), options)
    }

    @Test func aContractOverAnOpaqueOrTupleResultIsPaired() throws {
        let report = try Self.scan()
        func named(_ name: String) -> FunctionReport? { report.functions.first { $0.name == name } }
        for name in ["ViewState.loadingState_ensures(_:)", "LinkRule.body_ensures(_:)", "PlaceRule.body_ensures(_:)"] {
            #expect(named(name) == nil, "\(name) is reported as a function of its own")
        }
        let loading = try #require(named("ViewState.loadingState.getter"))
        #expect(loading.hasContract)
        #expect(loading.status == .unsupported && loading.category == "type Data", "\(loading.status) \(loading.category ?? "")")
        let link = try #require(named("LinkRule.body.getter"))
        #expect(link.hasContract && link.status == .unsupported)
        let place = try #require(named("PlaceRule.body.getter"))
        #expect(place.status == .contractHolds, "\(place.status) \(place.detail ?? "")")
        // A spec of the wrong shape is still not paired, but the getter says its contract was not read.
        let odd = try #require(named("Odd.flag.getter"))
        #expect(odd.hasContract && odd.status == .unsupported && odd.category == Verifier.contractNotReadCategory, "\(odd)")
        #expect(named("Odd.flag_ensures(_:)") != nil)
    }

    /// The text report says how many contracts were not checked, and which with `--show-unsupported`.
    @Test func theReportCountsContractsItCouldNotCheck() throws {
        let text = try Self.scan().text(showUnsupported: true)
        #expect(text.contains("Contracts: 1 hold, 0 fail, 3 not checked"), "\(text)")
        #expect(text.contains("ViewState.loadingState.getter") && text.contains("its contract is not checked"), "\(text)")
    }

    /// `swiftformal check --gate`: the paired contract is a warning that names the type, not a "checks nothing" error; the
    /// spec of the wrong shape keeps its error.
    @Test func verifyWarnsWithTheRealReason() throws {
        let result = BuildCheck.evaluate(try Self.scan(), promises: [])
        let loading = result.diagnostics.filter { $0.contains("loadingState") }
        #expect(loading.count == 1, "\(result.diagnostics)")
        #expect(loading.first?.contains(": warning: ") == true && loading.first?.contains("type Data") == true, "\(loading)")
        #expect(loading.first?.contains("its contract is not checked") == true, "\(loading)")
        #expect(!result.diagnostics.contains { $0.contains("body_ensures") && $0.contains("checks nothing") }, "\(result.diagnostics)")
        #expect(result.diagnostics.contains { $0.contains("Odd.flag_ensures(_:) checks nothing") && $0.contains(": error: ") })
    }

    @Test func passingFormDropsConventionsAndSplitsTuples() {
        #expect(SpecIndex.passingForm("@out Loading<Details>") == ["Loading<Details>"])
        #expect(SpecIndex.passingForm("(Int, @out Optional<Data>)") == ["Int", "Optional<Data>"])
        #expect(SpecIndex.passingForm("((Int8, Int8), Bool)") == ["Int8", "Int8", "Bool"])
        #expect(SpecIndex.passingForm("()") == [])
        #expect(SpecIndex.passingForm("(Dictionary<Int, Int>)") == ["(Dictionary<Int, Int>)"])
        #expect(SpecIndex.passingForm("@guaranteed @callee_guaranteed (Int) -> Int") == ["@callee_guaranteed (Int) -> Int"])
    }
}
