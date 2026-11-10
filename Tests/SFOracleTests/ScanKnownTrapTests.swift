import Foundation
import SFVerifyKit
import Testing
import SFTestSupport

/// Functions that trap natively for a known input, each a false `safe` that Scan once reported (docs/TRUST.md,
/// ADR 0006). Scan may refute them, refuse them or give up, but must never prove them. The native run is part of the
/// case: if the call stops trapping, the case is wrong, not Scan.
///
/// The fixtures come from archive/research/2026-11-07-swift-internals/fixtures.
private enum KnownTraps {
    struct Entry: Sendable {
        /// The reported function's name up to `(`, for example `describeWrap` or `Outer.hash`.
        var function: String
        /// What the plan calls it (R1, V1, ...), for the failure message.
        var finding: String
        /// Swift statements that call the function at an input that traps.
        var trappingCall: String
        /// Compiler flags for the native build (`-O` where the trap only exists in a release build).
        var nativeFlags: [String] = ["-Onone"]
    }

    static let source = """
        public struct Bad: CustomStringConvertible {
            public var x: Int
            public var description: String { let y = x + 1; return "\\(y)" }
        }
        public struct Wrap { public var bad: Bad }
        public enum E { case one(Bad) }
        public func describeWrap(_ x: Int) -> Int {
            let s = String(describing: Wrap(bad: Bad(x: x)))
            return s.isEmpty ? 0 : 1
        }
        public func describeEnum(_ x: Int) -> Int {
            let s = String(describing: E.one(Bad(x: x)))
            return s.isEmpty ? 0 : 1
        }
        public func interpWrap(_ x: Int) -> Int {
            let s = "\\(Wrap(bad: Bad(x: x)))"
            return s.isEmpty ? 0 : 1
        }
        public struct Reflect: CustomReflectable {
            public var x: Int
            public var customMirror: Mirror { let y = x + 1; return Mirror(self, children: ["y": y]) }
        }
        public func describeReflect(_ x: Int) -> Int {
            let s = String(describing: Reflect(x: x))
            return s.isEmpty ? 0 : 1
        }
        public struct Key: Hashable {
            public var k: Int
            public func hash(into h: inout Hasher) { h.combine(k + 1) }
        }
        public struct RR: RawRepresentable, Hashable {
            public var rawValue: Key
            public init(rawValue: Key) { self.rawValue = rawValue }
        }
        public struct Outer: Hashable { public var r: RR }
        public func hashRR(_ k: Int) -> Int {
            var h = Hasher()
            h.combine(RR(rawValue: Key(k: k)))
            return 0
        }
        public func interp(_ n: Int) -> Int {
            let d = DefaultStringInterpolation(literalCapacity: n, interpolationCount: 1)
            return String(stringInterpolation: d).isEmpty ? 0 : 1
        }
        public struct Guard: ~Copyable {
            public var x: Int32
            public init(x: Int32) { self.x = x }
            deinit { precondition(x > 0) }
        }
        public func consume(_ g: consuming Guard) -> Int32 { 1 }
        public struct GuardBox: ~Copyable { public var g: Guard }
        public func consumeBox(_ b: consuming GuardBox) -> Int32 { 1 }
        public func makeCount(_ n: Int) -> Int {
            let a = Array(repeating: 0, count: n)
            return a.count
        }
        public func appendWrap(_ n: Int) -> Int {
            var a = Array(repeating: 0, count: n)
            a.append(1)
            return a.count
        }
        public func afterAssert(_ x: Int) -> Int {
            var a = [x]
            assert(a.popLast() != nil)
            return a.count == 0 ? 0 : 10 / (a.count - 1)
        }
        """

    static let entries: [Entry] = [
        Entry(function: "describeWrap", finding: "R1", trappingCall: "_ = describeWrap(Int.max)"),
        Entry(function: "describeEnum", finding: "R1", trappingCall: "_ = describeEnum(Int.max)"),
        Entry(function: "interpWrap", finding: "R1", trappingCall: "_ = interpWrap(Int.max)"),
        Entry(function: "describeReflect", finding: "R1", trappingCall: "_ = describeReflect(Int.max)"),
        Entry(function: "hashRR", finding: "R2", trappingCall: "_ = hashRR(Int.max)"),
        Entry(
            function: "Outer.hash", finding: "R2",
            trappingCall: "var h = Hasher(); Outer(r: RR(rawValue: Key(k: Int.max))).hash(into: &h)"),
        Entry(function: "interp", finding: "R3", trappingCall: "_ = interp(Int.max)"),
        Entry(function: "consume", finding: "V1", trappingCall: "_ = consume(Guard(x: 0))"),
        Entry(function: "consumeBox", finding: "V1", trappingCall: "_ = consumeBox(GuardBox(g: Guard(x: 0)))"),
        Entry(function: "makeCount", finding: "R4", trappingCall: "_ = makeCount(1 << 50)"),
        Entry(function: "appendWrap", finding: "R4", trappingCall: "_ = appendWrap(Int.max)"),
        Entry(function: "afterAssert", finding: "R5", trappingCall: "_ = afterAssert(1)", nativeFlags: ["-O"]),
    ]

    static let workDirectory = FileManager.default.currentDirectoryPath + "/.build/scan-known-traps-\(UUID().uuidString)"
}

private struct Outcome {
    var trapped: Bool
    var status: Int32
    var output: String
}

private func run(_ path: String, _ arguments: [String]) throws -> Outcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    return Outcome(trapped: process.terminationReason == .uncaughtSignal, status: process.terminationStatus, output: output)
}

@Suite(.tags(.oracle, .slow), .requiresPinnedCompiler) struct ScanKnownTrapTests {
    @Test func everyKnownTrapTrapsNativelyAndIsNeverProved() throws {
        let directory = KnownTraps.workDirectory
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let moduleFile = directory + "/Traps.swift"
        try KnownTraps.source.write(toFile: moduleFile, atomically: true, encoding: .utf8)

        let report = try SFVerify.run(CompileOptions(files: [moduleFile], moduleName: "Traps", extraArguments: []))

        for (index, entry) in KnownTraps.entries.enumerated() {
            let function = try #require(
                report.functions.first { $0.name.hasPrefix(entry.function + "(") }, "\(entry.finding): no report for \(entry.function)")
            #expect(
                function.status != .safe && function.status != .contractHolds,
                "\(entry.finding): \(entry.function) traps natively but Scan reported \(function.status)")

            // Top-level code must live in a file named main.swift.
            let driver = directory + "/main.swift"
            let binary = directory + "/traps\(index)"
            try entry.trappingCall.write(toFile: driver, atomically: true, encoding: .utf8)
            let compile = try run("/usr/bin/xcrun", ["swiftc"] + entry.nativeFlags + [moduleFile, driver, "-o", binary])
            try #require(compile.status == 0, "\(entry.finding): the native driver must compile: \(compile.output)")
            let native = try run(binary, [])
            #expect(native.trapped, "\(entry.finding): `\(entry.trappingCall)` no longer traps natively (exit \(native.status))")
        }
    }
}
