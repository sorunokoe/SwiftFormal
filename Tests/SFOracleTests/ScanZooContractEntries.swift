import Foundation
import SFVerifyKit
import Testing

/// Contracts: as `@Verify` writes them (the peers placed where the compiler places them, as `#sourceLocation` does
/// here), which Scan reads, and the same written by hand, which Scan must not read (only `@Verify`).
extension ScanZoo {
    static let contractSource = """
        public func safeMidpoint(_ lo: Int8, _ hi: Int8) -> Int8 { lo + (hi - lo) / 2 }
        #sourceLocation(file: "@__swiftmacro_3App12safeMidpoint6VerifyfMp_.swift", line: 1)
        public func safeMidpoint_requires(_ lo: Int8, _ hi: Int8) -> Bool { 0 <= lo && lo <= hi }
        public func safeMidpoint_ensures(_ lo: Int8, _ hi: Int8, _ r: Int8) -> Bool { lo <= r && r <= hi }
        #sourceLocation()
        public func wrongMidpoint(_ lo: Int8, _ hi: Int8) -> Int8 { (lo + hi) / 2 }
        #sourceLocation(file: "@__swiftmacro_3App13wrongMidpoint6VerifyfMp_.swift", line: 1)
        public func wrongMidpoint_requires(_ lo: Int8, _ hi: Int8) -> Bool { lo <= hi }
        public func wrongMidpoint_ensures(_ lo: Int8, _ hi: Int8, _ r: Int8) -> Bool { lo <= r && r <= hi }
        #sourceLocation()
        public func offByOne(_ x: UInt8) -> UInt8 { x &+ 1 }
        #sourceLocation(file: "@__swiftmacro_3App8offByOne6VerifyfMp_.swift", line: 1)
        public func offByOne_ensures(_ x: UInt8, _ r: UInt8) -> Bool { r > x }
        #sourceLocation()
        public func handWrittenOffByOne(_ x: UInt8) -> UInt8 { x &+ 1 }
        public func handWrittenOffByOne_ensures(_ x: UInt8, _ r: UInt8) -> Bool { r > x }
        public func handWrittenGuard(_ x: Int8) -> Int8 { x + 1 }
        public func handWrittenGuard_requires(_ x: Int8) -> Bool { x < 100 }
        """

    static let contractEntries: [Entry] = [
        Entry(name: "safeMidpoint", parameterTypes: ["Int8", "Int8"], expectation: .contractHolds, hasContract: true),
        Entry(name: "wrongMidpoint", parameterTypes: ["Int8", "Int8"], expectation: .fails, hasContract: true),
        Entry(name: "offByOne", parameterTypes: ["UInt8"], expectation: .fails, hasContract: true),
        // Not read: no `contractFails`, and no `contractHolds` either; the function cannot trap.
        Entry(name: "handWrittenOffByOne", parameterTypes: ["UInt8"], expectation: .contractNotRead),
        // Not read: the trap the precondition would exclude is found, and traps natively.
        Entry(name: "handWrittenGuard", parameterTypes: ["Int8"], expectation: .contractNotRead),
    ]
}

extension ScanZooTests {
    /// `.contractNotRead`: no contract verdict and `ignoredContracts` names the hand-written function; what is left is
    /// a verdict about traps, held to the native sweep (`safe`) or the replay (`mayTrap`).
    static func checkNotRead(_ entry: ScanZoo.Entry, _ function: FunctionReport, binary: String) throws {
        #expect(
            [.safe, .mayTrap].contains(function.status) && !function.hasContract && function.ignoredContracts?.isEmpty == false,
            "\(entry.name): a hand-written contract was read (\(function.status), \(function.ignoredContracts ?? []))")
        if function.status == .mayTrap {
            let inputs = (function.counterexample?.inputs ?? []).compactMap { $0.components(separatedBy: " = ").last }
            let (outcome, output) = try execute(binary, ["replay", entry.name] + inputs)
            #expect(outcome.trapped, "\(entry.name): the counterexample \(inputs) did not trap natively: \(output)")
        } else {
            let (outcome, output) = try execute(binary, ["sweep", entry.name])
            #expect(!outcome.trapped, "\(entry.name) was called safe but trapped natively: \(output)")
        }
    }
}
