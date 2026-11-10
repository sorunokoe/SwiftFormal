import Foundation
import SFVerifyKit
import Testing
import SFTestSupport

/// The soundness zoo for Scan (`sfverify`): functions with a known fate, run through the whole pipeline (compile,
/// encode, prove or refute), then replayed natively.
///
/// - A function Scan calls `safe` or `contractHolds` must survive a sweep of edge inputs on the real compiled code.
/// - A function Scan calls `mayTrap` or `contractFails` must fail again when its counterexample is replayed natively.
/// - Wrong functions are never called safe; true controls are never refuted.
enum ScanZoo {
    enum Expectation: Sendable {
        /// Traps for some input: Scan must say `mayTrap`, and the counterexample must trap natively.
        case traps
        /// Violates its contract, by trapping or by a false `ensures`: Scan must refute it, and the replay must fail.
        case fails
        /// Never traps: Scan must prove it `safe`.
        case safe
        /// Meets its contract: Scan must prove `contractHolds`.
        case contractHolds
        /// Outside the supported subset: Scan must say `unsupported` and not guess.
        case unsupported
        /// Traps for some input, through something logic does not model (unknown keys): Scan must not say `safe`, and a
        /// counterexample, if it gives one, must trap natively.
        case notSafe
        /// A loop that really traps (at `Entry.trapsAt`, replayed natively): Scan must not call it safe. A failed loop
        /// proof is `undecided`, never `mayTrap`.
        case undecided
        /// True (never traps, meets its contract), but outside what logic proves: Scan must not refute it, and it must
        /// survive the native sweep like a `safe` one.
        case notRefuted
        /// Has a hand-written `_requires` / `_ensures`, which Scan does not read (only `@Verify` writes a contract): no
        /// contract verdict, true or false, and `ignoredContracts` names it. What is left is a verdict about traps,
        /// held to the sweep (`safe`) or the replay (`mayTrap`) like any other.
        case contractNotRead
    }

    struct Entry: Sendable {
        var name: String
        var parameterTypes: [String]
        var expectation: Expectation
        var hasContract = false
        /// For `.undecided`: inputs on which the function traps natively.
        var trapsAt: [String] = []
    }

    static let baseSource = """
        import Foundation
        public func absA(_ x: Int8) -> Int8 { if x < 0 { return -x }; return x }
        public func plusOne(_ x: Int8) -> Int8 { x + 1 }
        public func negate(_ x: Int8) -> Int8 { -x }
        public func times(_ a: Int8, _ b: Int8) -> Int8 { a * b }
        public func divide(_ a: Int8, _ b: Int8) -> Int8 { a / b }
        public func remainder(_ a: Int8, _ b: Int8) -> Int8 { a % b }
        public func narrow(_ x: Int16) -> Int8 { Int8(x) }
        public func toUnsigned(_ x: Int8) -> UInt8 { UInt8(x) }
        public func midpoint(_ a: Int8, _ b: Int8) -> Int8 { (a + b) / 2 }
        public func wrapAdd(_ a: Int8, _ b: Int8) -> Int8 { a &+ b }
        public func wrapMul(_ a: UInt8, _ b: UInt8) -> UInt8 { a &* b }
        public func truncate(_ x: Int16) -> Int8 { Int8(truncatingIfNeeded: x) }
        public func clampedNarrow(_ x: Int16) -> Int8 { x > 127 ? 127 : (x < -128 ? -128 : Int8(x)) }
        public func smartShift(_ x: Int8, _ n: Int8) -> Int8 { x << n }
        public func guardedAbs(_ x: Int8) -> Int8 { x == .min ? .max : (x < 0 ? -x : x) }
        public func guardedDivide(_ a: Int8, _ b: Int8) -> Int8 { (b == 0 || (a == .min && b == -1)) ? 0 : a / b }
        public func half(_ x: Double) -> Double { x / 2 }
        public func toInt(_ x: Double) -> Int { Int(x) }
        public func guardedToInt(_ x: Double) -> Int { x.isFinite && x > -1e9 && x < 1e9 ? Int(x) : 0 }
        public func isLess(_ a: Double, _ b: Double) -> Bool { a < b }
        public enum ZooError: Error { case negative }
        public func checked(_ x: Int8) throws -> Int8 { if x < 0 { throw ZooError.negative }; return x + 1 }
        public func typedChecked(_ x: Int8) throws(ZooError) -> Int8 { if x < 0 { throw .negative }; return x &+ 1 }
        public func orZero(_ x: Int8) -> Int8 { (try? checked(x)) ?? 0 }
        public func orMinusOne(_ x: Int8) -> Int8 { do { return try typedChecked(x) } catch { return -1 } }
        public func sumTo(_ n: Int8) -> Int8 { var s: Int8 = 0; var i: Int8 = 0; while i < n { s = s &+ i; i += 1 }; return s }
        public func countDown(_ n: Int8) -> Int8 { var i = n; while i > 0 { i -= 1 }; return i }
        public func dictFromEmpty(_ x: Int8) -> Int8 { let d: [Int8: Int8] = [:]; return d[x]! }
        public func dictDuplicateLiteral(_ x: Int8) -> Int { [x: 1, 0: 2].count }
        public func dictUniqueKeys(_ x: Int8) -> Int { Dictionary(uniqueKeysWithValues: [(x, 1), (1, 2)]).count }
        public func setInsertOnce(_ x: Int8) -> Int8 { var s = Set<Int8>(); s.insert(x); return x / Int8(s.count - 1) }
        public func dictDistinctLiteral(_ x: Int8) -> Int8 { let d: [Int8: Int8] = [1: 10, 2: 20]; return d[x] ?? 0 }
        public func setLiteralCount(_ x: Int8) -> Int8 { let s: Set<Int8> = [1, 2, 2]; return x / Int8(s.count) }
        public func dictAssignCount(_ x: Int8) -> Int8 { var d: [Int8: Int8] = [:]; d[x] = 1; return x / Int8(d.count) }
        public enum ZooKey: Hashable { case a, b }
        public func dictEnumDuplicate(_ x: Int8) -> Int { let d: [ZooKey: Int8] = [x > 0 ? .a : .b: 1, .a: 2]; return d.count }
        public class Box { public var x = 0 }
        public final class ZooCounter {
            public var count: Int8 = 0
            public var limit: Int8 = 10
            public init() {}
            public func bump() { count += 1 }
            public func bumpBelow() { if count < limit { count += 1 } }
        }
        public func zooSame(_ c: ZooCounter) -> ZooCounter { c }
        public func counterSafe(_ n: Int8) -> Int8 { let c = ZooCounter(); c.count = n; c.bumpBelow(); return c.count }
        public func counterTraps(_ n: Int8) -> Int8 { let c = ZooCounter(); c.count = n; c.bump(); return c.count }
        public func counterAlias(_ x: Int8) -> Int8 {
            let c = ZooCounter(); c.count = 0
            let r = zooSame(c)
            c.count = x
            r.count += 1
            return r.count
        }
        public func counterInit(_ x: Int8) -> Int8 { let c = ZooCounter(); return c.limit / (c.count + 1) &+ x }
        public func boxed(_ b: Box) -> Int { b.x }
        public func clampG<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T { x < lo ? lo : (x > hi ? hi : x) }
        public func clampedSum(_ a: Int8, _ b: Int8) -> Int8 { clampG(a, -60, 60) + clampG(b, -60, 60) }
        public func unclampedSum(_ a: Int8, _ b: Int8) -> Int8 { clampG(a, -60, 70) + clampG(b, -60, 60) }
        public protocol Scaler { func scaled() -> Int8 }
        public struct Triple: Scaler { public var v: Int8; public func scaled() -> Int8 { v * 3 } }
        public struct Halve: Scaler { public var v: Int8; public func scaled() -> Int8 { v / 2 } }
        public func scaleG<S: Scaler>(_ s: S) -> Int8 { s.scaled() }
        public func tripled(_ v: Int8) -> Int8 { scaleG(Triple(v: v)) }
        public func halved(_ v: Int8) -> Int8 { scaleG(Halve(v: v)) }
        public func rangeOffByOne(_ i: Int8, _ n: Int8) -> Int8 {
            let a = [Int8](repeating: 1, count: Int(max(n, 0)))
            return (0...a.count).contains(Int(i)) ? a[Int(i)] : 0
        }
        public func rangeGuarded(_ i: Int8, _ n: Int8) -> Int8 {
            let a = [Int8](repeating: 1, count: Int(max(n, 0)))
            return a.indices.contains(Int(i)) ? a[Int(i)] : 0
        }
        public func caseRange(_ x: UInt8, _ hi: UInt8) -> UInt8 {
            switch x {
            case 0...9: return 1
            case 10...hi: return 2
            default: return 3
            }
        }
        public func countUp(_ n: Int8) -> Int8 { var i: Int8 = 0; repeat { i += 1 } while i < 100 && i < n; return i }
        public func firstOnly(_ n: Int8) -> Int8 { var i = n; var k: Int8 = 0; repeat { i += 1; i = 0; k &+= 1 } while k < 3; return i }
        public func whileThird(_ n: Int8) -> Int8 { var x: Int8 = 100; var i: Int8 = 0; while i < n { x += 10; i += 1 }; return x }
        public func rangeSum(_ n: UInt8) -> UInt8 { var s: UInt8 = 0; for i in 0..<n { s &+= i }; return s }
        public func rangeOverflow(_ n: UInt8) -> UInt8 { var s: UInt8 = 0; for i in 0..<n { s += i }; return s }
        public func closedTop(_ n: Int8) -> Int8 { var last: Int8 = 0; for i in n...Int8.max { last = i }; return last }
        public func closedFrom(_ n: Int8) -> Int8 { var c: Int8 = 0; for _ in 0...n { c &+= 1 }; return c }
        public func strideSum(_ n: Int8) -> Int { var s = 0; for i in stride(from: 0, to: Int(n), by: 3) { s &+= i }; return s }
        public func strideEnd(_ k: UInt8) -> Int {
            var c = 0
            for _ in stride(from: Int.max - 300, through: Int.max, by: Int(k) + 1) { c &+= 1 }
            return c
        }
        public func strideStep(_ k: Int8) -> Int { var s = 0; for i in stride(from: 0, through: 10, by: Int(k)) { s &+= i }; return s }
        public func countedArray(_ n: UInt8) -> Int {
            var c = 0
            for (i, _) in Array(repeating: Int8(0), count: Int(n)).enumerated() { c &+= i }
            for i in [Int8](repeating: 1, count: Int(n)).indices { c &+= i }
            return c
        }
        public func narrowOffsets(_ n: UInt8) -> Int8 {
            var s: Int8 = 0
            for (i, _) in Array(repeating: Int8(0), count: Int(n)).enumerated() { s = Int8(i) }
            return s
        }
        public enum ZooClub: String { case driver, iron, putter }
        public func clubFromNumber(_ n: Int8) -> Int8 { if case .none = ZooClub(rawValue: "\\(n)") { return n }; return n + 1 }
        public func clubPick(_ n: Int8) -> Int8 { if case .iron? = ZooClub(rawValue: n == 1 ? "iron" : "wood") { return n + 127 }; return n }
        public func decimalEighteen(_ n: Int8) -> Int8 { "\\(n)" == "18" ? n * 10 : n }
        public func decimalOddForms(_ n: Int8) -> Int8 {
            let t = String(n)
            return t == "007" || t == "-0" || t == "+1" || t == "128" || t.isEmpty ? n + 127 + 1 : n
        }
        public func shoutedChess(_ n: Int8) -> Int8 { (n == 3 ? "CHESS" : "Chess").lowercased() == "chess" ? n + 125 : n }
        public func uuidSelf(_ x: Int8) -> Int8 { let u = UUID(); return u == u ? x + 1 : x }
        public func uuidCopy(_ x: Int8) -> Int8 { let u = UUID(); let v = u; return u == v ? x &+ 1 : x + 1 }
        public func uuidText(_ x: Int8) -> Int8 { let u = UUID(); return u.uuidString == u.uuidString ? x &+ 1 : x + 1 }
        public func nanDate(_ t: Double, _ x: Int8) -> Int8 { let d = Date(timeIntervalSince1970: t); return d == d ? x &+ 1 : x + 1 }
        """

    static let baseEntries: [Entry] = [
        Entry(name: "absA", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "plusOne", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "negate", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "times", parameterTypes: ["Int8", "Int8"], expectation: .traps),
        Entry(name: "divide", parameterTypes: ["Int8", "Int8"], expectation: .traps),
        Entry(name: "remainder", parameterTypes: ["Int8", "Int8"], expectation: .traps),
        Entry(name: "narrow", parameterTypes: ["Int16"], expectation: .traps),
        Entry(name: "toUnsigned", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "midpoint", parameterTypes: ["Int8", "Int8"], expectation: .traps),
        Entry(name: "wrapAdd", parameterTypes: ["Int8", "Int8"], expectation: .safe),
        Entry(name: "wrapMul", parameterTypes: ["UInt8", "UInt8"], expectation: .safe),
        Entry(name: "truncate", parameterTypes: ["Int16"], expectation: .safe),
        Entry(name: "clampedNarrow", parameterTypes: ["Int16"], expectation: .safe),
        Entry(name: "smartShift", parameterTypes: ["Int8", "Int8"], expectation: .safe),
        Entry(name: "guardedAbs", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "guardedDivide", parameterTypes: ["Int8", "Int8"], expectation: .safe),
        Entry(name: "half", parameterTypes: ["Double"], expectation: .safe),
        Entry(name: "toInt", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "guardedToInt", parameterTypes: ["Double"], expectation: .safe),
        Entry(name: "isLess", parameterTypes: ["Double", "Double"], expectation: .safe),
        Entry(name: "orZero", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "orMinusOne", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "sumTo", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "countDown", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "dictFromEmpty", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "dictDuplicateLiteral", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "dictUniqueKeys", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "setInsertOnce", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "dictDistinctLiteral", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "setLiteralCount", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "dictAssignCount", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "dictEnumDuplicate", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "boxed", parameterTypes: ["Box"], expectation: .unsupported),
        // Plan item L5: a final class created in the function, read as its fields; `zooSame` returns its parameter.
        Entry(name: "counterSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "counterTraps", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "counterAlias", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "counterInit", parameterTypes: ["Int8"], expectation: .safe),
        // Plan item L7: generic functions of the module, read at the call's concrete types.
        Entry(name: "clampedSum", parameterTypes: ["Int8", "Int8"], expectation: .safe),
        Entry(name: "unclampedSum", parameterTypes: ["Int8", "Int8"], expectation: .traps),
        Entry(name: "tripled", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "halved", parameterTypes: ["Int8"], expectation: .safe),
        // Ranges (app study round 5): `...` where `..<` was meant reads one past the end.
        Entry(name: "rangeOffByOne", parameterTypes: ["Int8", "Int8"], expectation: .traps),
        Entry(name: "rangeGuarded", parameterTypes: ["Int8", "Int8"], expectation: .safe),
        Entry(name: "caseRange", parameterTypes: ["UInt8", "UInt8"], expectation: .traps),
        // Plan item L4: `for-in` through the iterator summaries. A loop that can trap is `undecided`.
        Entry(name: "rangeSum", parameterTypes: ["UInt8"], expectation: .safe),
        Entry(name: "rangeOverflow", parameterTypes: ["UInt8"], expectation: .undecided, trapsAt: ["255"]),
        Entry(name: "closedTop", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "closedFrom", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "strideSum", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "strideEnd", parameterTypes: ["UInt8"], expectation: .safe),
        Entry(name: "strideStep", parameterTypes: ["Int8"], expectation: .traps),
        // Plan item L3: a trap in the third iteration, found by unrolling (default bound 8) and replayed natively.
        Entry(name: "whileThird", parameterTypes: ["Int8"], expectation: .traps),
        // 2-induction: the exit test comes after the body; and a trap only the base case sees.
        Entry(name: "countUp", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "firstOnly", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "countedArray", parameterTypes: ["UInt8"], expectation: .safe),
        Entry(name: "narrowOffsets", parameterTypes: ["UInt8"], expectation: .undecided, trapsAt: ["200"]),
        // String facts: a `String` raw-value `init(rawValue:)`, the decimal text of an integer, case conversion.
        Entry(name: "clubFromNumber", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "clubPick", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "decimalEighteen", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "decimalOddForms", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "shoutedChess", parameterTypes: ["Int8"], expectation: .traps),
        // Foundation values as identities (`SILOpaqueValues.swift`): a UUID equals itself and its copy, and its text is
        // the same twice. A NaN date is not equal to itself: `Date` is its IEEE `Double`, so Scan finds that input.
        Entry(name: "uuidSelf", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "uuidCopy", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "uuidText", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "nanDate", parameterTypes: ["Double", "Int8"], expectation: .traps),
    ]

    static let workDirectory = FileManager.default.currentDirectoryPath + "/.build/scan-zoo-\(UUID().uuidString)"
}

extension ScanZoo {
    /// Native driver. `replay <name> <args...>` runs one call (exit 3 when an `ensures` is false; a trap is a signal).
    /// `sweep <name>` runs every combination of edge values, with the contract when there is one.
    static var driver: String {
        var lines = ["let args = CommandLine.arguments", "switch args[1] + \" \" + args[2] {"]
        for entry in entries where entry.expectation != .unsupported {
            let parsed = entry.parameterTypes.enumerated().map { "parse(\($1).self, args[\($0 + 3)])" }.joined(separator: ", ")
            lines.append("case \"replay \(entry.name)\":")
            if entry.hasContract {
                lines.append("    let r = \(entry.name)(\(parsed))")
                lines.append("    exit(\(entry.name)_ensures(\(([parsed, "r"]).filter { !$0.isEmpty }.joined(separator: ", "))) ? 0 : 3)")
            } else {
                lines.append("    _ = \(entry.name)(\(parsed))")
            }
            // Only functions Scan calls true are swept; the wrong ones are replayed at their counterexample.
            guard [.safe, .contractHolds, .notRefuted, .contractNotRead].contains(entry.expectation) else { continue }
            let names = entry.parameterTypes.indices.map { "a\($0)" }.joined(separator: ", ")
            let namesAndResult = ([names, "r"]).filter { !$0.isEmpty }.joined(separator: ", ")
            var sweep =
                entry.hasContract
                ? "if \(entry.name)_requires(\(names)) { let r = \(entry.name)(\(names)); if !\(entry.name)_ensures(\(namesAndResult)) { exit(3) } }"
                : "_ = \(entry.name)(\(names))"
            for (index, type) in entry.parameterTypes.enumerated().reversed() {
                sweep = "for a\(index) in edge(\(type).self) { \(sweep) }"
            }
            lines.append("case \"sweep \(entry.name)\":")
            lines.append("    \(sweep)")
        }
        lines.append("default: exit(2)")
        lines.append("}")
        return """
            import Foundation
            func edge<T: FixedWidthInteger>(_: T.Type) -> [T] { [T.min, T.min &+ 1, T(truncatingIfNeeded: -1), 0, 1, 2, T.max &- 1, T.max] }
            func edge(_: Double.Type) -> [Double] {
                [0, -0.0, 1, -1, 0.5, 1e9, -1e9, 1e300, -1e300, .infinity, -.infinity, .nan, .greatestFiniteMagnitude, .leastNonzeroMagnitude]
            }
            func parse<T: FixedWidthInteger>(_: T.Type, _ s: String) -> T { T(s)! }
            \(floatDriver)
            func parse(_: Double.Type, _ s: String) -> Double {
                switch s {
                case "Double.nan": return .nan
                case "Double.infinity": return .infinity
                case "-Double.infinity": return -.infinity
                default:
                    if s.hasPrefix("Double(bitPattern: 0x") { return Double(bitPattern: UInt64(s.dropFirst(21).dropLast(), radix: 16)!) }
                    return Double(s)!
                }
            }
            \(lines.joined(separator: "\n"))
            """
    }
}

struct ZooOutcome {
    var trapped: Bool
    var exitCode: Int32
}

func execute(_ path: String, _ arguments: [String]) throws -> (ZooOutcome, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (ZooOutcome(trapped: process.terminationReason == .uncaughtSignal, exitCode: process.terminationStatus), output)
}

@Suite(.tags(.oracle, .slow), .requiresPinnedCompiler) struct ScanZooTests {
    @Test func scanNeverCallsAWrongFunctionSafeAndEveryVerdictSurvivesNativeExecution() throws {
        let directory = ScanZoo.workDirectory
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let moduleFile = directory + "/Zoo.swift"
        let driverFile = directory + "/main.swift"
        let binary = directory + "/zoo"
        try ScanZoo.source.write(toFile: moduleFile, atomically: true, encoding: .utf8)
        try ScanZoo.driver.write(toFile: driverFile, atomically: true, encoding: .utf8)

        let (compile, compileOutput) = try execute("/usr/bin/xcrun", ["swiftc", "-Onone", moduleFile, driverFile, "-o", binary])
        try #require(compile.exitCode == 0, "the zoo and its driver must compile: \(compileOutput)")

        let report = try SFVerify.run(CompileOptions(files: [moduleFile], moduleName: "Zoo", extraArguments: []))

        for entry in ScanZoo.entries {
            let function = try #require(report.functions.first { $0.name.hasPrefix(entry.name + "(") }, "no report for \(entry.name)")
            try Self.check(entry, function, binary: binary)
        }
    }

    /// One zoo entry's verdict against its expectation, and against native execution.
    private static func check(_ entry: ScanZoo.Entry, _ function: FunctionReport, binary: String) throws {
        switch entry.expectation {
        case .traps, .fails:
            let wanted: [ScanStatus] = entry.expectation == .traps ? [.mayTrap] : [.mayTrap, .contractFails]
            #expect(
                wanted.contains(function.status), "\(entry.name): wrong function reported \(function.status) (\(function.detail ?? ""))"
            )
            guard wanted.contains(function.status) else { return }
            let inputs = (function.counterexample?.inputs ?? []).compactMap { $0.components(separatedBy: " = ").last }
            #expect(
                inputs.count == entry.parameterTypes.count, "\(entry.name): counterexample \(function.counterexample?.inputs ?? [])")
            let (outcome, output) = try execute(binary, ["replay", entry.name] + inputs)
            #expect(
                outcome.trapped || outcome.exitCode == 3,
                "\(entry.name): the counterexample \(inputs) did not fail natively (exit \(outcome.exitCode)): \(output)")
        case .safe, .contractHolds:
            let wanted: ScanStatus = entry.expectation == .safe ? .safe : .contractHolds
            #expect(function.status == wanted, "\(entry.name): true function reported \(function.status) (\(function.detail ?? ""))")
            let (outcome, output) = try execute(binary, ["sweep", entry.name])
            #expect(
                !outcome.trapped && outcome.exitCode == 0,
                "\(entry.name) was called \(function.status) but failed natively (trapped: \(outcome.trapped), exit \(outcome.exitCode)): \(output)"
            )
        case .unsupported:
            #expect(function.status == .unsupported, "\(entry.name): reported \(function.status) instead of declining")
        case .notSafe:
            #expect(
                [.mayTrap, .undecided].contains(function.status),
                "\(entry.name): wrong function reported \(function.status) (\(function.detail ?? ""))")
            guard function.status == .mayTrap else { return }
            let inputs = (function.counterexample?.inputs ?? []).compactMap { $0.components(separatedBy: " = ").last }
            let (outcome, output) = try execute(binary, ["replay", entry.name] + inputs)
            #expect(outcome.trapped, "\(entry.name): the counterexample \(inputs) did not trap natively: \(output)")
        case .notRefuted:
            #expect(
                ![.mayTrap, .contractFails].contains(function.status),
                "\(entry.name): true function refuted (\(function.detail ?? ""))")
            let (outcome, output) = try execute(binary, ["sweep", entry.name])
            #expect(
                !outcome.trapped && outcome.exitCode == 0,
                "\(entry.name) failed natively (trapped: \(outcome.trapped), exit \(outcome.exitCode)): \(output)")
        case .contractNotRead:
            try checkNotRead(entry, function, binary: binary)
        case .undecided:
            #expect(function.status == .undecided, "\(entry.name): a loop that traps reported \(function.status)")
            let (outcome, output) = try execute(binary, ["replay", entry.name] + entry.trapsAt)
            #expect(outcome.trapped, "\(entry.name) does not trap natively at \(entry.trapsAt): \(output)")
        }
    }
}
