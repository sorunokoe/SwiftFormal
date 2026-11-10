import Foundation
import SFVerifyKit
import Testing

/// Plan item U5: concrete playback. Counterexamples become Swift Testing tests, and `--confirm`'s outcomes are folded
/// back into the report (a counterexample that does not reproduce is a model/compiler disagreement).
@Suite struct PlaybackTests {
    static func report(configurations: String = #"["debug", "release"]"#) throws -> ScanReport {
        let json = """
            {"schemaVersion": 1, "module": "Kernels", "optimization": "-Onone", "configurations": \(configurations),
             "timing": {"compileSeconds": 0, "parseSeconds": 0, "verifySeconds": 0, "silBytes": 0},
             "summary": {"total": 0, "safe": 0, "mayTrap": 0, "contractHolds": 0, "contractFails": 0, "undecided": 0,
                         "unsupported": 0, "internalErrors": 0, "compilerGenerated": 0, "unsupportedByCategory": {}},
             "functions": [
              {"name": "percent(_:_:)", "symbol": "$s1", "status": "mayTrap", "hasContract": false, "seconds": 0,
               "counterexample": {"inputs": ["part = 0", "whole = 0"], "failure": "traps: Division by zero",
                                  "replay": "percent(0, 0)"}},
              {"name": "bad(_:)", "symbol": "$s2", "status": "contractFails", "hasContract": true, "seconds": 0,
               "counterexample": {"inputs": ["x = 255"], "result": "0", "failure": "ensures is false: bad_ensures(_:_:) returns false",
                                  "replay": "bad(255)", "ensuresCall": "bad_ensures(255, bad(255))"}},
              {"name": "onlyRelease(_:)", "symbol": "$s3", "status": "mayTrap", "hasContract": false, "seconds": 0,
               "counterexample": {"inputs": ["x = 3"], "failure": "in a release build (-assert-config Release): traps: arithmetic overflow",
                                  "replay": "onlyRelease(3)"}},
              {"name": "Box.inc()", "symbol": "$s4", "status": "mayTrap", "hasContract": false, "seconds": 0,
               "counterexample": {"inputs": ["self = Box(v: 127)"], "failure": "traps: arithmetic overflow"}},
              {"name": "shift(_:)", "symbol": "$s5", "status": "mayTrap", "hasContract": false, "seconds": 0,
               "counterexample": {"inputs": ["x = 9"], "failure": "undefined behaviour in a primitive operation", "replay": "shift(9)"}}
             ]}
            """
        return try JSONDecoder().decode(ScanReport.self, from: Data(json.utf8))
    }

    @Test func aTrapIsAnExitTestAndABrokenPostconditionAnEnsuresCheck() throws {
        let (tests, skipped) = Playback.tests(for: try Self.report())
        #expect(tests.map(\.name) == ["playback_1_percent", "playback_2_bad", "playback_3_onlyRelease"])
        #expect(tests[0].source.contains("await #expect(processExitsWith: .failure) { _ = percent(0, 0) }"))
        #expect(tests[0].source.contains("func playback_1_percent() async"))
        #expect(tests[1].source.contains("#expect(!bad_ensures(255, bad(255)))"))
        #expect(!tests[0].releaseOnly && !tests[1].releaseOnly)
        #expect(tests[2].releaseOnly)
        #expect(tests[2].source.hasPrefix("#if !DEBUG"))
        #expect(skipped.count == 2)
        #expect(skipped.contains { $0.hasPrefix("Box.inc()") })
        #expect(skipped.contains { $0.hasPrefix("shift(_:)") })
        let file = Playback.file(for: try Self.report())
        #expect(file.contains("@testable import Kernels"))
        #expect(file.contains("#if (os(macOS) || os(Linux)) && compiler(>=6.3)"))
        #expect(file.contains("//   Box.inc()"))
    }

    @Test func aReleaseOnlyScanMarksEveryTestReleaseOnly() throws {
        let (tests, _) = Playback.tests(for: try Self.report(configurations: #"["release"]"#))
        #expect(tests.allSatisfy { $0.releaseOnly })
    }

    @Test func aCounterexampleThatDoesNotReproduceIsAnInternalError() throws {
        let report = try Self.report()
        let confirmed = Playback.confirming(report, ["$s1": true, "$s2": false])
        let percent = try #require(confirmed.functions.first { $0.symbol == "$s1" })
        #expect(percent.status == .mayTrap)
        #expect(percent.counterexample?.confirmed == true)
        let bad = try #require(confirmed.functions.first { $0.symbol == "$s2" })
        #expect(bad.status == .internalError)
        #expect(bad.counterexample?.confirmed == false)
        #expect(bad.detail?.contains("disagree") == true)
        #expect(confirmed.functions.first { $0.symbol == "$s3" }?.counterexample?.confirmed == nil)
        #expect(confirmed.summary.mayTrap == 4)  // recounted, not copied
        #expect(confirmed.summary.contractFails == 0)
        #expect(confirmed.summary.internalErrors == 1)
        #expect(confirmed.configurations == report.configurations)
        #expect(confirmed.hasFailures)
    }

    @Test func aBrokenPostconditionCarriesItsEnsuresCall() throws {
        let directory = NSTemporaryDirectory() + "sfv-u5-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/bad.swift"
        try """
        func bad(by x: UInt8) -> UInt8 { x &+ 1 }
        #sourceLocation(file: "@__swiftmacro_3App3bad6VerifyfMp_.swift", line: 1)
        func bad_ensures(by x: UInt8, _ r: UInt8) -> Bool { r > x }
        #sourceLocation()
        """.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let report = try SFVerify.run(CompileOptions(files: [file], moduleName: "Bad"), options)
        let bad = try #require(report.functions.first { $0.name.hasPrefix("bad(") })
        #expect(bad.status == .contractFails)
        #expect(bad.counterexample?.ensuresCall == "bad_ensures(by: 255, bad(by: 255))")
    }

    @Test func aScratchBuildWithOtherSettingsLeavesANonReproductionUnconfirmed() throws {
        let plain = Playback.buildSettings(arguments: [], sources: [])
        #expect(plain.exact && plain.languageMode == "5" && plain.swiftc.isEmpty)
        let flags = Playback.buildSettings(
            arguments: ["-D", "FAST", "-enable-upcoming-feature", "ExistentialAny", "-swift-version", "6", "-I", "/x"], sources: [])
        #expect(flags.swiftc == ["-D", "FAST", "-enable-upcoming-feature", "ExistentialAny"])
        #expect(flags.languageMode == "6" && flags.exact)
        #expect(!Playback.buildSettings(arguments: ["-Xfrontend", "-something"], sources: []).exact)

        let report = try Self.report()
        let settled = Playback.settle(report, Playback.Confirmation(outcomes: ["$s1": true, "$s2": false], exact: false))
        #expect(settled.inconclusive == ["bad(_:)"])
        #expect(settled.report.functions.first { $0.symbol == "$s2" }?.status == .contractFails)
        #expect(settled.report.functions.first { $0.symbol == "$s2" }?.counterexample?.confirmed == nil)
        #expect(settled.report.functions.first { $0.symbol == "$s1" }?.counterexample?.confirmed == true)
    }

    @Test func aFunctionATestCannotCallGetsNoTest() throws {
        let directory = NSTemporaryDirectory() + "sfv-u5-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/odd.swift"
        try """
        private func hidden(_ x: Int8) -> Int8 { x + 1 }
        func bump(_ x: inout Int8)
            -> Int8 { x += 1; return x }
        func thrower(_ x: Int8) throws -> Int8 { x + 1 }
        func plain(_ x: Int8) -> Int8 { x + 1 }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        func function(_ name: String, line: Int) throws -> FunctionReport {
            let json = """
                {"name": "\(name)(_:)", "symbol": "$\(name)", "status": "mayTrap", "hasContract": false, "seconds": 0,
                 "location": {"file": "\(file)", "line": \(line), "column": 1},
                 "counterexample": {"inputs": ["x = 127"], "failure": "traps: arithmetic overflow", "replay": "\(name)(127)"}}
                """
            return try JSONDecoder().decode(FunctionReport.self, from: Data(json.utf8))
        }
        #expect(Playback.uncallable(try function("hidden", line: 1))?.hasPrefix("private") == true)
        #expect(Playback.uncallable(try function("bump", line: 2))?.contains("inout") == true)
        #expect(Playback.uncallable(try function("thrower", line: 4)) == "throws or async")
        #expect(Playback.uncallable(try function("plain", line: 5)) == nil)
    }

    /// A replayed NaN must be the NaN the model chose: a negative, payload or signalling NaN is written by its bits
    /// (`Double.nan` would replay a different value), the default NaN and every other value as before.
    @Test func aNaNInputIsReplayedWithItsOwnBits() {
        #expect(Verifier.floatLiteral(bits: 0xFFF8_0000_0000_0000, type: "Double") == "Double(bitPattern: 0xfff8000000000000)")
        #expect(Verifier.floatLiteral(bits: Double.signalingNaN.bitPattern, type: "Double") == "Double(bitPattern: 0x7ff4000000000000)")
        #expect(Verifier.floatLiteral(bits: Double.nan.bitPattern, type: "Double") == "Double.nan")
        #expect(Verifier.floatLiteral(bits: Double.infinity.bitPattern, type: "Double") == "Double.infinity")
        #expect(Verifier.floatLiteral(bits: (-0.0).bitPattern, type: "Double") == "-0.0")
        #expect(Verifier.floatLiteral(bits: 0x7FA0_0001, type: "Float") == "Float(bitPattern: 0x7fa00001)")
        #expect(Verifier.floatLiteral(bits: UInt64(Float.nan.bitPattern), type: "Float") == "Float.nan")
        #expect(Verifier.floatLiteral(bits: UInt64(Float(1.5).bitPattern), type: "Float") == "1.5")
    }
}
