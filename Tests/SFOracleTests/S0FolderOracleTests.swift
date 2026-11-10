import Foundation
import SFSemantics
import SFTestSupport
import Testing

/// Plan item V5: the compiler's own constant folder as a second oracle for S0, including its undefined-behaviour
/// predicate (the native oracle skips every undefined case).
///
/// Each case is a raw SIL function that applies one builtin to integer literals. `swift-frontend -emit-sil -Onone` runs
/// the mandatory pipeline, whose constant folder either folds the call to a literal or rejects it with a diagnostic
/// (`division by zero`, `… results in an overflow`, `shift amount is greater than or equal to type size in bits`). The
/// check goes both ways: the folder diagnoses a case exactly when S0 says `.undefined`, and every folded literal equals
/// S0's value. Overflow builtins get `0` as their third operand, so they fold to `(value, overflow flag)` and the flag
/// is compared too. A diagnostic stops the whole compile, so each file is compiled twice: once to collect the
/// diagnosed cases, once without them to read the folded values.
///
/// Sampled by default (about 15,000 cases); `SF_FOLDER_ORACLE=full` runs the plan's sweep (every edge pair plus 300
/// random pairs per builtin and width, about 60,000 cases), which a run before a release does.
@Suite(.tags(.oracle), .requiresPinnedCompiler) struct S0FolderOracleTests {
    static let full = ProcessInfo.processInfo.environment["SF_FOLDER_ORACLE"] == "full"
    static let widths = [8, 16, 32, 64]
    /// Operations the folder does not fold (checked natively instead).
    static let notFolded: Set<S0Op> = [.ctlz, .cttz, .ctpop, .bswap]
    static let notFoldedPrefixes = ["int_ctlz_", "int_cttz_", "int_ctpop_", "int_bswap_"]

    @Test func theConstantFolderAgreesWithS0BothWays() throws {
        let cases = Self.cases()
        var tally = Tally()
        for result in Self.foldAll(cases) {
            for (c, outcome) in zip(result.cases, result.outcomes) { tally.add(c, outcome) }
        }
        #expect(tally.mismatches.isEmpty, "\(tally.mismatches.count) mismatches, first: \(tally.mismatches.prefix(5))")
        // Guards against an oracle that silently checks nothing.
        #expect(tally.folded + tally.diagnosed + tally.unfolded.count == cases.count)
        // The mandatory constant folder leaves bit counting and byte swaps alone; `S0BuiltinOracleTests` checks those
        // against the compiler's builtins executed natively.
        let folded = cases.filter { !Self.notFolded.contains($0.instance.op) }
        let unfolded = tally.unfolded.filter { name in !Self.notFoldedPrefixes.contains { name.hasPrefix($0) } }
        #expect(unfolded.count * 50 <= folded.count, "\(unfolded.count) did not fold, first: \(unfolded.prefix(3))")
        #expect(tally.diagnosed > 0)
        let instances = Set(folded.map(\.instance.builtinName))
        #expect(instances.isSubset(of: tally.checked), "never folded nor diagnosed: \(instances.subtracting(tally.checked).sorted())")
        print(
            "S0FolderOracleTests: \(cases.count) cases, \(tally.folded) folded, \(tally.diagnosed) diagnosed, "
                + "\(tally.unfolded.count) not folded")
    }

    /// The outcomes of every case, compiled in files of 200 functions (compile time grows faster than linearly with the
    /// number of functions in a file), several files at a time.
    private static func foldAll(_ cases: [FolderCase]) -> [ChunkResult] {
        let results = Locked<[ChunkResult]>([])
        let failures = Locked<[String]>([])
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
        for start in stride(from: 0, to: cases.count, by: 200) {
            let chunk = Array(cases[start..<min(cases.count, start + 200)])
            queue.addOperation {
                do {
                    let result = try fold(chunk)
                    results.withLock { $0.append(result) }
                } catch {
                    failures.withLock { $0.append("\(error)") }
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        for failure in failures.withLock({ $0 }).prefix(5) { Issue.record(Comment(rawValue: failure)) }
        return results.withLock { $0 }
    }

    /// The comparison with S0, both ways.
    private struct Tally {
        var mismatches: [String] = []
        var folded = 0
        var diagnosed = 0
        var unfolded: [String] = []
        /// Builtins with at least one folded or diagnosed case.
        var checked: Set<String> = []

        mutating func add(_ c: FolderCase, _ outcome: FolderOutcome) {
            switch (outcome, c.instance.evaluate(c.arguments)) {
            case (.diagnosed, .undefined):
                diagnosed += 1
                checked.insert(c.instance.builtinName)
            case (.folded(let values), .values(let want)):
                folded += 1
                checked.insert(c.instance.builtinName)
                let masks = c.instance.resultWidths.map { $0 == 64 ? UInt64.max : (1 << UInt64($0)) - 1 }
                if zip(values, masks).map({ $0 & $1 }) != want { mismatches.append("\(c): folded to \(values), S0 says \(want)") }
            case (.unfolded, .values):
                unfolded.append("\(c)")
            case (_, .undefined):
                mismatches.append("\(c): S0 says undefined, the compiler \(outcome)")
            case (.diagnosed(let message), .values(let want)):
                mismatches.append("\(c): the compiler says \(message), S0 says \(want)")
            }
        }
    }

    // MARK: cases

    /// Edge values first (0, 1, 2, width-1, width, the sign bit and its neighbours, all ones, alternating bits), then
    /// seeded random pairs.
    static func cases() -> [FolderCase] {
        var rng = SplitMix(seed: 0x5EED_F01D)
        var cases: [FolderCase] = []
        for width in widths {
            let mask = width == 64 ? UInt64.max : (1 << UInt64(width)) - 1
            let top: UInt64 = 1 << UInt64(width - 1)
            var edges = [0, 1, 2, UInt64(width - 1), UInt64(width), mask, mask &- 1, top, top &- 1, top &+ 1]
            if full { edges += [3, UInt64(width + 1), 0x5555_5555_5555_5555 & mask, 0xAAAA_AAAA_AAAA_AAAA & mask] }
            edges = Array(Set(edges.map { $0 & mask })).sorted()
            let randomPairs = full ? 300 : 40
            var pairs = edges.flatMap { a in edges.map { b in (a, b) } }
            pairs += (0..<randomPairs).map { _ in (rng.next() & mask, rng.next() & mask) }
            for op in S0Op.allCases {
                if [.trunc, .zext, .sext].contains(op) {
                    for target in widths where target != width {
                        guard let instance = S0Instance(op: op, width: width, resultWidth: target) else { continue }
                        let values = edges + (0..<(full ? 64 : 8)).map { _ in rng.next() & mask }
                        cases += values.map { FolderCase(instance: instance, arguments: [$0]) }
                    }
                    continue
                }
                guard let instance = S0Instance(op: op, width: width) else { continue }
                cases += pairs.map { FolderCase(instance: instance, arguments: arguments(instance, $0)) }
            }
        }
        return cases
    }

    /// Operands as `operandWidths` lays them out: one value, a value and a flag (ctlz/cttz: zero is not undefined), two
    /// values, or two values and the overflow builtins' diagnostic flag.
    private static func arguments(_ instance: S0Instance, _ pair: (UInt64, UInt64)) -> [UInt64] {
        switch instance.operandWidths.count {
        case 1: [pair.0]
        case 2 where instance.operandWidths[1] == 1 && instance.width != 1: [pair.0, 0]
        case 2: [pair.0, pair.1]
        default: [pair.0, pair.1, 0]
        }
    }

    // MARK: compiling

    private static func fold(_ cases: [FolderCase]) throws -> ChunkResult {
        let directory = NSTemporaryDirectory() + "sf-folder-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        var outcomes = [FolderOutcome](repeating: .unfolded, count: cases.count)
        let first = try compile(Array(cases.enumerated()), in: directory, name: "all")
        guard first.status != 0 else {
            try read(first.output, into: &outcomes)
            return ChunkResult(cases: cases, outcomes: outcomes)
        }
        for (index, message) in try diagnostics(first.errors, lines: first.lines) { outcomes[index] = .diagnosed(message) }
        let rest = cases.enumerated().filter {
            if case .diagnosed = outcomes[$0.offset] { return false }
            return true
        }
        let second = try compile(rest, in: directory, name: "folded")
        guard second.status == 0 else {
            throw FolderError.compile("the folder still rejects the undiagnosed cases: \(second.errors.prefix(600))")
        }
        try read(second.output, into: &outcomes)
        return ChunkResult(cases: cases, outcomes: outcomes)
    }

    private struct Compiled {
        var status: Int32
        var output: String
        var errors: String
        /// The first and last line of each case's function in the input file, by case index.
        var lines: [(index: Int, range: ClosedRange<Int>)]
    }

    private static func compile(_ cases: [(offset: Int, element: FolderCase)], in directory: String, name: String) throws -> Compiled {
        var text = "sil_stage raw\n\nimport Builtin\n"
        var lines: [(Int, ClosedRange<Int>)] = []
        var line = 4
        for (index, c) in cases {
            let function = c.sil(name: "f\(index)")
            let count = function.split(separator: "\n", omittingEmptySubsequences: false).count
            text += "\n" + function
            lines.append((index, (line + 1)...(line + count)))
            line += count
        }
        let input = directory + "/\(name).sil"
        let output = directory + "/\(name).out.sil"
        try text.write(toFile: input, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift-frontend", "-emit-sil", "-Onone", "-module-name", "Folder", input, "-o", output]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let folded = process.terminationStatus == 0 ? try String(contentsOfFile: output, encoding: .utf8) : ""
        return Compiled(status: process.terminationStatus, output: folded, errors: String(bytes: data, encoding: .utf8) ?? "", lines: lines)
    }

    /// The case each `file.sil:LINE:COL: error: …` belongs to. Any error outside the folder's three diagnostics fails:
    /// otherwise a malformed case would pass as "diagnosed".
    private static func diagnostics(_ errors: String, lines: [(index: Int, range: ClosedRange<Int>)]) throws -> [(Int, String)] {
        var found: [(Int, String)] = []
        for line in errors.split(separator: "\n") where line.hasPrefix("/") && line.contains(": error: ") {
            let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, let number = Int(parts[1]) else { continue }
            let message = parts[4].trimmingCharacters(in: .whitespaces)
            guard
                message == "division by zero" || message.hasSuffix("results in an overflow")
                    || message == "shift amount is greater than or equal to type size in bits"
                    // `assumeNonNegative` of a negative constant (plan item L8).
                    || (message.hasPrefix("assumed non-negative value '") && message.hasSuffix("' is negative"))
            else {
                throw FolderError.compile("unexpected compiler error: \(line)")
            }
            guard let owner = lines.first(where: { $0.range.contains(number) }) else {
                throw FolderError.compile("an error outside every case: \(line)")
            }
            found.append((owner.index, message))
        }
        guard !found.isEmpty else { throw FolderError.compile("the compile failed without a folder diagnostic: \(errors.prefix(600))") }
        return found
    }

    /// Reads `%n = integer_literal $Builtin.IntW, V`, `%t = tuple (%a, %b)` and `return %r` of each folded function.
    private static func read(_ output: String, into outcomes: inout [FolderOutcome]) throws {
        var index: Int?
        var literals: [String: UInt64] = [:]
        var tuples: [String: [String]] = [:]
        for raw in output.split(separator: "\n") {
            let line = raw.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("sil @f") {
                index = Int(line.dropFirst("sil @f".count).prefix { $0 != " " })
                literals = [:]
                tuples = [:]
            } else if let eq = line.range(of: " = integer_literal $Builtin.Int"), let comma = line.range(of: ", ", options: .backwards) {
                guard let value = Int64(line[comma.upperBound...]) else { throw FolderError.compile("literal: \(line)") }
                literals[String(line[..<eq.lowerBound])] = UInt64(bitPattern: value)
            } else if let eq = line.range(of: " = tuple ("), line.hasSuffix(")") {
                tuples[String(line[..<eq.lowerBound])] = line[eq.upperBound...].dropLast().components(separatedBy: ", ")
            } else if line.hasPrefix("return "), let current = index {
                let value = String(line.dropFirst("return ".count))
                if let literal = literals[value] {
                    outcomes[current] = .folded([literal])
                } else if let parts = tuples[value], case let values = parts.compactMap({ literals[$0] }), values.count == parts.count {
                    outcomes[current] = .folded(values)
                }
                index = nil
            }
        }
    }
}

struct FolderCase: CustomStringConvertible {
    let instance: S0Instance
    let arguments: [UInt64]

    var description: String { "\(instance.builtinName)(\(arguments.map(String.init).joined(separator: ", ")))" }

    /// The literal as SIL prints it: signed decimal at its width.
    private static func literal(_ value: UInt64, width: Int) -> String {
        let signBit: UInt64 = 1 << UInt64(width - 1)
        let mask = width == 64 ? UInt64.max : (1 << UInt64(width)) - 1
        return value & signBit == 0 ? String(value) : String(Int64(bitPattern: value | ~mask))
    }

    func sil(name: String) -> String {
        let w = instance.width
        let operandType = "$Builtin.Int\(w)"
        let resultTypes = instance.resultWidths.map { "Builtin.Int\($0)" }
        let result = resultTypes.count == 1 ? resultTypes[0] : "(\(resultTypes.joined(separator: ", ")))"
        var lines = ["sil @\(name) : $@convention(thin) () -> \(result) {", "bb0:"]
        var operands: [String] = []
        for (i, argument) in arguments.enumerated() {
            let width = instance.operandWidths[i]
            lines.append("  %\(i) = integer_literal $Builtin.Int\(width), \(Self.literal(argument, width: width))")
            operands.append("%\(i) : \(width == w ? operandType : "$Builtin.Int\(width)")")
        }
        lines.append("  %9 = builtin \"\(instance.builtinName)\"(\(operands.joined(separator: ", "))) : $\(result)")
        lines.append("  return %9 : $\(result)")
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}

enum FolderOutcome: CustomStringConvertible {
    case folded([UInt64])
    case diagnosed(String)
    case unfolded

    var description: String {
        switch self {
        case .folded(let values): "folds to \(values)"
        case .diagnosed(let message): "says \(message)"
        case .unfolded: "does not fold"
        }
    }
}

private struct ChunkResult {
    let cases: [FolderCase]
    let outcomes: [FolderOutcome]
}

private enum FolderError: Error, CustomStringConvertible {
    case compile(String)
    var description: String {
        switch self {
        case .compile(let s): s
        }
    }
}

/// A seeded generator, so a failure reproduces exactly.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A lock around a value, for the results of the concurrent compiles.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
