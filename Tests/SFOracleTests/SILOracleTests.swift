import Foundation
import Testing
import SFBV
import SFCNF
import SFSIL
import SFTestSupport

// C7: the compiler as a free oracle, and an exhaustive native check at 8 bits.
//
// Three independent routes to "what does f(args) do?":
//   circuit : the SIL encoder, evaluated here at concrete inputs (64 inputs per pass, bit-parallel);
//   fold    : swiftc -O constant-folds `probeN() { f(literals) }`; the folded SIL is read back;
//   native  : the compiled binary, run in a child process (a crash is a trap).
// All three start from the same front end (parser, type checker, SILGen). The fold route differs in the back
// end (SIL optimizer constant folder instead of LLVM codegen), the native route differs in everything after SIL.

// MARK: - shared helpers

private struct Spec {
    let name: String
    let params: [String]
    let result: String
}

private func bitWidth(_ type: String) -> Int {
    switch type {
    case "Bool": 1
    case "Int8", "UInt8": 8
    case "Int16", "UInt16": 16
    case "Int32", "UInt32": 32
    default: 64
    }
}

private func mask(_ width: Int) -> UInt64 { width == 64 ? ~0 : (1 << UInt64(width)) - 1 }

private enum Result: Equatable, CustomStringConvertible {
    case trap
    case value(UInt64)
    var description: String {
        switch self {
        case .trap: "trap"
        case .value(let v): "value \(v)"
        }
    }
}

/// Outcome of the circuit. `undefined` means an S0 precondition fails on a live path: no native meaning, never compared.
private enum CircuitOutcome: Equatable {
    case trap, undefined, value(UInt64)
}

private enum Folded: Equatable {
    case value(UInt64)
    /// The compiler flagged a definite trap, either as a diagnostic or by leaving `cond_fail <true>; unreachable`.
    case trap
    /// The compiler left real code in the probe (not inlined, loop, ...): no information.
    case unfolded

    /// Nil when the compiler gave no answer.
    func result(width: Int) -> Result? {
        switch self {
        case .trap: .trap
        case .value(let v): .value(v & mask(width))
        case .unfolded: nil
        }
    }
}

extension CircuitOutcome {
    /// Nil for `undefined`, which has no native meaning.
    fileprivate func result(width: Int) -> Result? {
        switch self {
        case .trap: .trap
        case .value(let v): .value(v & mask(width))
        case .undefined: nil
        }
    }
}

extension Result {
    fileprivate func masked(_ width: Int) -> Result {
        if case .value(let v) = self { return .value(v & mask(width)) }
        return self
    }
}

private func samples(widths: [Int], count: Int, seed: UInt64) -> [[UInt64]] {
    var state = seed
    func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    func pool(_ w: Int) -> [UInt64] {
        let m = mask(w)
        let top: UInt64 = 1 << UInt64(w - 1)
        var edges: [UInt64] = [
            0, 1, 2, 3, m, m - 1, top, top - 1, top + 1, 31 & m, 32 & m, 33 & m,
            UInt64(bitPattern: -32) & m, 7 & m, 127 & m, UInt64(bitPattern: -128) & m,
        ]
        if w == 1 { edges = [0, 1] }
        for _ in 0..<6 { edges.append(next() & m) }
        return edges
    }
    let pools = widths.map(pool)
    return (0..<count).map { _ in pools.map { $0[Int(next() % UInt64($0.count))] } }
}

// MARK: - circuit evaluation

/// Evaluates the encoder's circuit at concrete inputs without a solver. Every gate output `o` is the highest variable of
/// its clauses, and each gate is a total function of earlier variables, so `o` is the OR over its clauses that contain
/// `o` positively of "all other literals are false". Sixty-four inputs run at once, one per bit of a `UInt64`.
/// The result is checked against every clause of the circuit on every pass, so a wrong evaluator cannot go unnoticed.
private final class CircuitEvaluator {
    struct Malformed: Error { let reason: String }

    let widths: [Int]
    let resultWidth: Int
    private let numVars: Int
    private let inputVars: [[Int]]
    private let trap: Int32, undefined: Int32
    private let result: [Int32]
    private let gateVars: [Int]
    private let clausesOfGate: [Int]  // gate g owns positive clauses clausesOfGate[g]..<clausesOfGate[g+1]
    private let litsOfClause: [Int]  // clause k owns lits litsOfClause[k]..<litsOfClause[k+1]
    private let lits: [Int32]
    private let allClauses: [[Int32]]

    init(module: SILModule, symbol: String) throws {
        let c = CNFBuilder()
        let function = try module.function(symbol)
        let inputs = function.parameterWidths.map { c.input(width: $0) }
        let e = try SILEncoder(module: module, builder: c).encode(symbol: symbol, arguments: inputs)
        widths = function.parameterWidths
        resultWidth = function.resultWidth
        numVars = c.numVars
        inputVars = inputs.map { $0.bits.map { Int($0) } }
        trap = e.trap
        undefined = e.undefined
        result = e.result.bits
        allClauses = c.clauses

        let isInput = Set(inputVars.joined())
        var positive = [[[Int32]]](repeating: [], count: c.numVars + 1)
        for clause in c.clauses where clause != [1] {
            let top = clause.map { Int(abs($0)) }.max()!
            guard !isInput.contains(top) else { throw Malformed(reason: "clause constrains an input variable") }
            if let at = clause.firstIndex(of: Int32(top)) {
                var others = clause
                others.remove(at: at)
                positive[top].append(others)
            }
        }
        var gates: [Int] = [], gateStart = [0], clauseStart = [0], flat: [Int32] = []
        for v in 2...max(2, c.numVars) where v <= c.numVars && !isInput.contains(v) {
            guard !positive[v].isEmpty else { throw Malformed(reason: "variable \(v) has no defining clause") }
            gates.append(v)
            for others in positive[v] {
                flat.append(contentsOf: others)
                clauseStart.append(flat.count)
            }
            gateStart.append(clauseStart.count - 1)
        }
        gateVars = gates
        clausesOfGate = gateStart
        litsOfClause = clauseStart
        lits = flat
    }

    @inline(__always) private func lane(_ lit: Int32, _ vals: [UInt64]) -> UInt64 {
        lit > 0 ? vals[Int(lit)] : ~vals[Int(-lit)]
    }

    func evaluate(_ cases: [[UInt64]]) throws -> [CircuitOutcome] {
        var vals = [UInt64](repeating: 0, count: numVars + 1)
        var outcomes: [CircuitOutcome] = []
        outcomes.reserveCapacity(cases.count)
        var base = 0
        while base < cases.count {
            let n = min(64, cases.count - base)
            vals[1] = ~0
            for (i, bits) in inputVars.enumerated() {
                for (j, v) in bits.enumerated() {
                    var word: UInt64 = 0
                    for l in 0..<n { word |= ((cases[base + l][i] >> UInt64(j)) & 1) << UInt64(l) }
                    vals[v] = word
                }
            }
            for (g, o) in gateVars.enumerated() {
                var acc: UInt64 = 0
                for k in clausesOfGate[g]..<clausesOfGate[g + 1] {
                    var all: UInt64 = ~0
                    for p in litsOfClause[k]..<litsOfClause[k + 1] { all &= ~lane(lits[p], vals) }
                    acc |= all
                }
                vals[o] = acc
            }
            for clause in allClauses {
                var any: UInt64 = 0
                for l in clause { any |= lane(l, vals) }
                guard any == ~0 else { throw Malformed(reason: "evaluated assignment violates a circuit clause") }
            }
            let trapWord = lane(trap, vals), undefinedWord = lane(undefined, vals)
            let resultWords = result.map { lane($0, vals) }
            for l in 0..<n {
                if (trapWord >> UInt64(l)) & 1 == 1 {
                    outcomes.append(.trap)
                } else if (undefinedWord >> UInt64(l)) & 1 == 1 {
                    outcomes.append(.undefined)
                } else {
                    var v: UInt64 = 0
                    for (j, w) in resultWords.enumerated() { v |= ((w >> UInt64(l)) & 1) << UInt64(j) }
                    outcomes.append(.value(v))
                }
            }
            base += n
        }
        return outcomes
    }

    /// The same question answered by the builder's own constant folding (what `SILFrontendTests` does).
    static func constantOutcome(module: SILModule, symbol: String, arguments: [UInt64]) throws -> CircuitOutcome {
        let c = CNFBuilder()
        let function = try module.function(symbol)
        let args = zip(function.parameterWidths, arguments).map { c.constant($0.1, width: $0.0) }
        let e = try SILEncoder(module: module, builder: c).encode(symbol: symbol, arguments: args)
        guard e.trap == c.trueLit || e.trap == c.falseLit, e.undefined == c.trueLit || e.undefined == c.falseLit,
            let value = c.constantValue(e.result)
        else { throw Malformed(reason: "circuit did not fold to a constant") }
        if e.trap == c.trueLit { return .trap }
        if e.undefined == c.trueLit { return .undefined }
        return .value(value)
    }
}

// MARK: - the constant-folding oracle

private struct FoldCase {
    let spec: Int
    let arguments: [UInt64]
}

private enum FoldOracle {
    static func literal(_ v: UInt64, type: String) -> String {
        switch type {
        case "Bool": v & 1 == 1 ? "true" : "false"
        case "Int8": String(Int8(truncatingIfNeeded: v))
        case "Int16": String(Int16(truncatingIfNeeded: v))
        case "Int32": String(Int32(truncatingIfNeeded: v))
        case "Int", "Int64": String(Int64(bitPattern: v))
        default: String(v & mask(bitWidth(type)))
        }
    }

    /// Diagnostics that mean "the compiler proved this call traps". They abort the whole compile, so the probe is
    /// dropped and the batch is compiled again.
    private static let definiteTrapDiagnostics = ["results in an overflow", "division by zero", "overflows when stored into"]

    /// One swiftc invocation for the whole batch. Returns one entry per case.
    static func fold(fixture: String, specs: [Spec], cases: [FoldCase]) throws -> (results: [Folded], recompiles: Int) {
        var diagnosed = Set<Int>()
        var recompiles = 0
        let firstProbeLine = fixture.split(separator: "\n", omittingEmptySubsequences: false).count + 1
        while true {
            var emitted: [Int] = []
            var lines: [String] = []
            for (i, c) in cases.enumerated() where !diagnosed.contains(i) {
                let spec = specs[c.spec]
                let arguments = zip(spec.params, c.arguments).map { literal($1, type: $0) }.joined(separator: ", ")
                lines.append("public func probe\(i)() -> \(spec.result) { \(spec.name)(\(arguments)) }")
                emitted.append(i)
            }
            do {
                let text = try SILCompiler.emit(
                    source: ([fixture] + lines).joined(separator: "\n"), module: "Fixture", optimization: .speed)
                var folded = parseProbes(text, widths: cases.map { bitWidth(specs[$0.spec].result) })
                var results = [Folded](repeating: .unfolded, count: cases.count)
                for i in emitted { results[i] = folded.removeValue(forKey: i) ?? .unfolded }
                for i in diagnosed { results[i] = .trap }
                return (results, recompiles)
            } catch SILError.compilerFailed(let message) {
                var fresh = Set<Int>()
                for line in message.split(separator: "\n") {
                    guard let r = line.range(of: ": error: "), !line.hasPrefix(" ") else { continue }
                    let location = line[..<r.lowerBound].split(separator: ":")
                    guard location.count >= 3, let row = Int(location[location.count - 2]),
                        definiteTrapDiagnostics.contains(where: { line.contains($0) }),
                        row >= firstProbeLine, row - firstProbeLine < emitted.count
                    else { throw SILError.compilerFailed(message) }
                    fresh.insert(emitted[row - firstProbeLine])
                }
                guard !fresh.isEmpty, recompiles < 4 else { throw SILError.compilerFailed(message) }
                diagnosed.formUnion(fresh)
                recompiles += 1
            }
        }
    }

    /// Reads the bodies of `probeN` functions. A body that is only literals, `struct` wrappers and a `return` is a value;
    /// `cond_fail <true literal>` is a trap; anything else is left alone.
    static func parseProbes(_ text: String, widths: [Int]) -> [Int: Folded] {
        var folded: [Int: Folded] = [:]
        var current: Int?
        var known: [String: UInt64] = [:]
        var outcome: Folded?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("sil "), let at = raw.range(of: " @") {
                current = probeIndex(String(raw[at.upperBound...].prefix { $0 != " " }))
                known = [:]
                outcome = nil
                continue
            }
            guard let index = current else { continue }
            if raw.hasPrefix("}") {
                folded[index] = outcome ?? .unfolded
                current = nil
                continue
            }
            var line = String(raw)
            if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("[") || line.hasPrefix("debug_value") || line.hasPrefix("bb0") || line == "unreachable" {
                continue
            }
            if outcome != nil { continue }
            if line.hasPrefix("return ") {
                if let v = known[String(line.dropFirst(7))] { outcome = .value(v & mask(widths[index])) } else { outcome = .unfolded }
            } else if line.hasPrefix("cond_fail ") {
                let operand = String(line.dropFirst(10).prefix { $0 != "," })
                if let v = known[operand] { if v != 0 { outcome = .trap } } else { outcome = .unfolded }
            } else if let eq = line.range(of: " = ") {
                let id = String(line[..<eq.lowerBound]), rhs = line[eq.upperBound...]
                if rhs.hasPrefix("integer_literal $Builtin.Int") {
                    let value = rhs.split(separator: ",").last!.trimmingCharacters(in: .whitespaces)
                    if let s = Int64(value) {
                        known[id] = UInt64(bitPattern: s)
                    } else if let u = UInt64(value) {
                        known[id] = u
                    } else {
                        outcome = .unfolded
                    }
                } else if rhs.hasPrefix("struct $"), let open = rhs.firstIndex(of: "("), let close = rhs.firstIndex(of: ")"),
                    let v = known[String(rhs[rhs.index(after: open)..<close])]
                {
                    known[id] = v
                } else {
                    outcome = .unfolded
                }
            } else {
                outcome = .unfolded
            }
        }
        return folded
    }

    /// `$s7Fixture6probe12s5Int32VyF` -> 12
    private static func probeIndex(_ symbol: String) -> Int? {
        let prefix = "$s7Fixture"
        guard symbol.hasPrefix(prefix) else { return nil }
        let rest = symbol.dropFirst(prefix.count)
        let digits = rest.prefix { $0.isNumber }
        guard let length = Int(digits) else { return nil }
        let name = rest.dropFirst(digits.count).prefix(length)
        guard name.hasPrefix("probe") else { return nil }
        return Int(name.dropFirst(5))
    }
}

// MARK: - native execution

private struct NativeHarness {
    let directory: String
    let binary: String

    private static func run(_ args: [String]) throws -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = args
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: e, as: UTF8.self))
    }

    /// Exit code 99 is how the child reports a trap: handlers for SIGILL and SIGTRAP stop the process without a crash report.
    private static func main(specs: [Spec]) -> String {
        var table = ""
        for f in specs {
            let args = f.params.enumerated().map { i, t in
                t == "Bool" ? "a[\(i)] != 0" : "\(t)(truncatingIfNeeded: a[\(i)])"
            }.joined(separator: ", ")
            let call = "\(f.name)(\(args))"
            table +=
                "    case \"\(f.name)\": fn = { a in \(f.result == "Bool" ? "(\(call)) ? 1 : 0" : "UInt64(truncatingIfNeeded: \(call))") }\n"
        }
        return """
            import Foundation
            signal(SIGILL) { _ in _exit(99) }
            signal(SIGTRAP) { _ in _exit(99) }
            let lines = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\\n")
            let start = Int(CommandLine.arguments[2])!
            let fn: ([UInt64]) -> UInt64
            switch CommandLine.arguments[3] {
            \(table)    default: fatalError("unknown function")
            }
            for index in start..<lines.count {
                let a = lines[index].split(separator: " ").map { UInt64($0)! }
                print(index, fn(a))
                fflush(stdout)
            }
            """
    }

    static func build(fixture: String, specs: [Spec], optimization: Optimization) throws -> (NativeHarness, seconds: Double) {
        let started = Date()
        let directory = NSTemporaryDirectory() + "sf-oracle-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try fixture.write(toFile: directory + "/Fixture.swift", atomically: true, encoding: .utf8)
        try main(specs: specs).write(toFile: directory + "/main.swift", atomically: true, encoding: .utf8)
        let binary = directory + "/native"
        let build = try run(["swiftc", optimization.rawValue, directory + "/Fixture.swift", directory + "/main.swift", "-o", binary])
        guard build.status == 0 else {
            try? FileManager.default.removeItem(atPath: directory)
            throw SILError.compilerFailed(build.error)
        }
        return (NativeHarness(directory: directory, binary: binary), Date().timeIntervalSince(started))
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: directory) }

    /// Runs every case in one process. A crash marks the case it died on as a trap, then the run resumes at the next case,
    /// so a batch with `k` traps costs `k + 1` processes.
    func run(_ function: String, cases: [[UInt64]]) throws -> (results: [Result], processes: Int, crashes: Int) {
        let path = directory + "/cases-\(UUID().uuidString)"
        try cases.map { $0.map(String.init).joined(separator: " ") }.joined(separator: "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var results: [Result] = []
        var processes = 0, crashes = 0
        results.reserveCapacity(cases.count)
        while results.count < cases.count {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [path, String(results.count), function]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            processes += 1
            Self.parse(data, into: &results)
            if process.terminationReason == .uncaughtSignal || process.terminationStatus == 99 {
                results.append(.trap)
                crashes += 1
            } else if process.terminationStatus != 0 {
                throw SILError.invalid("native run of \(function) exited with \(process.terminationStatus)")
            } else if results.count < cases.count {
                throw SILError.invalid("native run of \(function) ended early at \(results.count) of \(cases.count)")
            }
        }
        return (results, processes, crashes)
    }

    /// Lines `index value`; only complete lines count.
    private static func parse(_ data: Data, into results: inout [Result]) {
        var number: UInt64 = 0, first: UInt64 = 0, haveFirst = false, digits = false
        for byte in data {
            switch byte {
            case 0x30...0x39: number = number &* 10 &+ UInt64(byte - 0x30); digits = true
            case 0x20: first = number; number = 0; haveFirst = true; digits = false
            case 0x0A:
                if haveFirst, digits, Int(first) == results.count { results.append(.value(number)) }
                number = 0; haveFirst = false; digits = false
            default: break
            }
        }
    }
}

private func report(_ line: String) { print("[SILOracle] \(line)") }

private func seconds(_ since: Date) -> String { String(format: "%.2f s", Date().timeIntervalSince(since)) }

// MARK: - fixture A: the SILFrontendTests functions (32/64-bit), for the fold-versus-native-versus-circuit comparison

private enum Fixture {
    static let source = """
        public func clamp(_ x: Int32, _ lo: Int32, _ hi: Int32) -> Int32 {
            if x < lo { return lo }
            if x > hi { return hi }
            return x
        }
        public func avg(_ a: Int32, _ b: Int32) -> Int32 { (a + b) / 2 }
        public func div(_ a: Int32, _ b: Int32) -> Int32 { a / b }
        public func rem(_ a: Int32, _ b: Int32) -> Int32 { a % b }
        public func mulHi(_ a: UInt8, _ b: UInt8) -> UInt16 { UInt16(a) &* UInt16(b) }
        public func isEven(_ x: Int64) -> Bool { x & 1 == 0 }
        public func sel(_ c: Bool, _ a: Int8, _ b: Int8) -> Int8 { c ? a : b }
        public func wrapAdd(_ a: UInt32, _ b: UInt32) -> UInt32 { a &+ b }
        public func shr(_ a: Int32, _ n: Int32) -> Int32 { a >> n }
        public func shl(_ a: Int32, _ n: Int32) -> Int32 { a << n }
        public func narrow(_ x: Int32) -> Int8 { Int8(x) }
        public func truncating(_ x: Int32) -> Int8 { Int8(truncatingIfNeeded: x) }
        public func pre(_ x: Int64) -> Int64 { precondition(x > 0); return x - 1 }
        public func widen(_ x: UInt8) -> Int { Int(x) + 1 }
        public func neg(_ a: Int32) -> Int32 { -a }
        public func ltAnd(_ a: UInt16, _ b: UInt16) -> Bool { a < b && a != 0 }
        @inline(never) public func twice(_ x: Int32) -> Int32 { x &* 2 }
        public func useTwice(_ x: Int32) -> Int32 { twice(x) &+ 1 }
        public func mn(_ a: Int32, _ b: Int32) -> Int32 { min(a, b) }
        @_transparent public func addT(_ a: Int32, _ b: Int32) -> Int32 { a + b }
        """

    static let functions: [Spec] = [
        Spec(name: "clamp", params: ["Int32", "Int32", "Int32"], result: "Int32"),
        Spec(name: "avg", params: ["Int32", "Int32"], result: "Int32"),
        Spec(name: "div", params: ["Int32", "Int32"], result: "Int32"),
        Spec(name: "rem", params: ["Int32", "Int32"], result: "Int32"),
        Spec(name: "mulHi", params: ["UInt8", "UInt8"], result: "UInt16"),
        Spec(name: "isEven", params: ["Int64"], result: "Bool"),
        Spec(name: "sel", params: ["Bool", "Int8", "Int8"], result: "Int8"),
        Spec(name: "wrapAdd", params: ["UInt32", "UInt32"], result: "UInt32"),
        Spec(name: "shr", params: ["Int32", "Int32"], result: "Int32"),
        Spec(name: "shl", params: ["Int32", "Int32"], result: "Int32"),
        Spec(name: "narrow", params: ["Int32"], result: "Int8"),
        Spec(name: "truncating", params: ["Int32"], result: "Int8"),
        Spec(name: "pre", params: ["Int64"], result: "Int64"),
        Spec(name: "widen", params: ["UInt8"], result: "Int"),
        Spec(name: "neg", params: ["Int32"], result: "Int32"),
        Spec(name: "ltAnd", params: ["UInt16", "UInt16"], result: "Bool"),
        Spec(name: "useTwice", params: ["Int32"], result: "Int32"),
        Spec(name: "mn", params: ["Int32", "Int32"], result: "Int32"),
        Spec(name: "addT", params: ["Int32", "Int32"], result: "Int32"),
    ]

    static let onone = try! SILCompiler.module(source: source, optimization: .none)
    static let speed = try! SILCompiler.module(source: source, optimization: .speed)
}

// MARK: - fixture B: two-argument 8-bit functions, small enough to enumerate

private enum Int8Fixture {
    static let source = """
        public func add8(_ a: Int8, _ b: Int8) -> Int8 { a + b }
        public func sub8(_ a: Int8, _ b: Int8) -> Int8 { a - b }
        public func mul8(_ a: Int8, _ b: Int8) -> Int8 { a * b }
        public func div8(_ a: Int8, _ b: Int8) -> Int8 { a / b }
        public func rem8(_ a: Int8, _ b: Int8) -> Int8 { a % b }
        public func shl8(_ a: Int8, _ b: Int8) -> Int8 { a << b }
        public func shr8(_ a: Int8, _ b: Int8) -> Int8 { a >> b }
        public func wadd8(_ a: Int8, _ b: Int8) -> Int8 { a &+ b }
        public func uadd8(_ a: UInt8, _ b: UInt8) -> UInt8 { a + b }
        public func usub8(_ a: UInt8, _ b: UInt8) -> UInt8 { a - b }
        public func umul8(_ a: UInt8, _ b: UInt8) -> UInt8 { a * b }
        public func udiv8(_ a: UInt8, _ b: UInt8) -> UInt8 { a / b }
        public func urem8(_ a: UInt8, _ b: UInt8) -> UInt8 { a % b }
        public func ushl8(_ a: UInt8, _ b: UInt8) -> UInt8 { a << b }
        public func ushr8(_ a: UInt8, _ b: UInt8) -> UInt8 { a >> b }
        public func clampHi(_ x: Int8, _ hi: Int8) -> Int8 { x > hi ? hi : x }
        public func clamp0(_ x: Int8, _ hi: Int8) -> Int8 {
            if x < 0 { return 0 }
            if x > hi { return hi }
            return x
        }
        public func absDiff(_ a: Int8, _ b: Int8) -> Int8 { a > b ? a - b : b - a }
        public func negate(_ a: Int8, _ b: Int8) -> Int8 { -a }
        public func narrowMul(_ a: Int8, _ b: Int8) -> Int8 { Int8(Int16(a) * Int16(b)) }
        public func narrowSum(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(Int(a) + Int(b)) }
        public func widenMul(_ a: Int8, _ b: Int8) -> Int { Int(a) * Int(b) }
        public func avgU(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((UInt16(a) + UInt16(b)) / 2) }
        public func lt8(_ a: Int8, _ b: Int8) -> Bool { a < b }
        public func mulHi8(_ a: UInt8, _ b: UInt8) -> UInt16 { UInt16(a) &* UInt16(b) }
        public func truncSum(_ a: Int8, _ b: Int8) -> Int8 { Int8(truncatingIfNeeded: Int(a) + Int(b)) }
        public func inClosed8(_ a: Int8, _ b: Int8) -> Bool { (0...b).contains(a) }
        public func tilde8(_ a: Int8, _ b: Int8) -> Bool { -5..<b ~= a }
        public func emptyR8(_ a: Int8, _ b: Int8) -> Bool { (a..<b).isEmpty }
        public func closedEmpty8(_ a: UInt8, _ b: UInt8) -> Bool { (a...b).isEmpty }
        public func caseRange8(_ a: UInt8, _ b: UInt8) -> UInt8 {
            switch a {
            case 0...9: return 1
            case 10...b: return 2
            case 200...: return 3
            case ..<100: return 4
            default: return 5
            }
        }
        """

    static let functions: [Spec] = {
        let signed: Set = [
            "add8", "sub8", "mul8", "div8", "rem8", "shl8", "shr8", "wadd8", "clampHi", "clamp0", "absDiff", "negate",
            "narrowMul", "widenMul", "lt8", "truncSum", "inClosed8", "tilde8", "emptyR8",
        ]
        let results = [
            "widenMul": "Int", "lt8": "Bool", "mulHi8": "UInt16", "inClosed8": "Bool", "tilde8": "Bool", "emptyR8": "Bool",
            "closedEmpty8": "Bool",
        ]
        return source.split(separator: "\n").compactMap { line -> Spec? in
            guard line.hasPrefix("public func ") else { return nil }
            let name = String(line.dropFirst("public func ".count).prefix { $0 != "(" })
            let type = signed.contains(name) ? "Int8" : "UInt8"
            return Spec(name: name, params: [type, type], result: results[name] ?? type)
        }
    }()

    /// Pair `p` is `(p & 255, p >> 8)`.
    static let allPairs: [[UInt64]] = (0..<65_536).map { [UInt64($0 & 255), UInt64($0 >> 8)] }
}

// MARK: - tests

@Suite(.tags(.oracle, .slow), .requiresPinnedCompiler) struct SILOracleTests {
    /// The evaluator is a second implementation of "run the circuit"; it must equal the builder's own constant folding.
    @Test(arguments: [Optimization.none, .speed])
    func laneEvaluatorMatchesConstantFolding(_ optimization: Optimization) throws {
        let module = try SILCompiler.module(source: Int8Fixture.source, optimization: optimization)
        var compared = 0
        for (k, spec) in Int8Fixture.functions.enumerated() {
            let symbol = try module.symbol(module: "Fixture", name: spec.name)
            guard let evaluator = try? CircuitEvaluator(module: module, symbol: symbol) else { continue }
            let cases = samples(widths: [8, 8], count: 150, seed: UInt64(k + 100))
            let lanes = try evaluator.evaluate(cases)
            for (args, lane) in zip(cases, lanes) {
                let constant = try CircuitEvaluator.constantOutcome(module: module, symbol: symbol, arguments: args)
                #expect(lane == constant, "\(spec.name)\(args): lanes \(lane), constant folding \(constant)")
                compared += 1
            }
        }
        #expect(compared >= 20 * 150)
    }

    /// What swiftc -O does with literal calls: folds values, leaves `cond_fail true; unreachable`, or (for a call that was
    /// inlined by the mandatory pass) refuses to compile with a diagnostic, which is also a definite trap.
    @Test
    func foldingClassifiesValuesTrapsAndOpaqueCalls() throws {
        func index(_ name: String) -> Int { Fixture.functions.firstIndex { $0.name == name }! }
        let cases: [(FoldCase, Folded)] = [
            (FoldCase(spec: index("div"), arguments: [7, 2]), .value(3)),
            (FoldCase(spec: index("div"), arguments: [7, 0]), .trap),
            (FoldCase(spec: index("div"), arguments: [0x8000_0000, 0xFFFF_FFFF]), .trap),
            (FoldCase(spec: index("avg"), arguments: [0x7FFF_FFFF, 1]), .trap),
            (FoldCase(spec: index("narrow"), arguments: [300]), .trap),
            (FoldCase(spec: index("narrow"), arguments: [UInt64(bitPattern: -128) & 0xFFFF_FFFF]), .value(0x80)),
            (FoldCase(spec: index("shl"), arguments: [1, 40]), .value(0)),
            (FoldCase(spec: index("clamp"), arguments: [5, 0, 3]), .value(3)),
            (FoldCase(spec: index("isEven"), arguments: [10]), .value(1)),
            (FoldCase(spec: index("useTwice"), arguments: [21]), .unfolded),
            // @_transparent is inlined before the diagnostics pass, so the compile fails with an overflow error.
            (FoldCase(spec: index("addT"), arguments: [0x7FFF_FFFF, 1]), .trap),
            (FoldCase(spec: index("addT"), arguments: [2, 3]), .value(5)),
        ]
        let (results, recompiles) = try FoldOracle.fold(fixture: Fixture.source, specs: Fixture.functions, cases: cases.map(\.0))
        for ((c, expected), got) in zip(cases, results) {
            #expect(got == expected, "\(Fixture.functions[c.spec].name)\(c.arguments): expected \(expected), compiler gave \(got)")
        }
        #expect(recompiles == 1, "the transparent overflow must cost exactly one extra compile")
    }

    /// Fold route, native route and circuit on the same inputs. Reports throughput of both routes.
    @Test
    func constantFoldingAgreesWithNativeExecutionAndTheCircuit() throws {
        let specs = Fixture.functions
        var cases: [FoldCase] = []
        for (k, spec) in specs.enumerated() {
            for args in samples(widths: spec.params.map(bitWidth), count: 120, seed: UInt64(k + 1)) {
                cases.append(FoldCase(spec: k, arguments: args))
            }
        }

        let foldStarted = Date()
        let (folded, recompiles) = try FoldOracle.fold(fixture: Fixture.source, specs: specs, cases: cases)
        let foldTime = Date().timeIntervalSince(foldStarted)

        let buildStarted = Date()
        let (native, _) = try NativeHarness.build(fixture: Fixture.source, specs: specs, optimization: .speed)
        defer { native.cleanup() }
        let buildTime = Date().timeIntervalSince(buildStarted)
        let runStarted = Date()
        var nativeResults = [Result](repeating: .trap, count: cases.count)
        var processes = 0, crashes = 0
        for (k, spec) in specs.enumerated() {
            let indices = cases.indices.filter { cases[$0].spec == k }
            let out = try native.run(spec.name, cases: indices.map { cases[$0].arguments })
            for (i, r) in zip(indices, out.results) { nativeResults[i] = r }
            processes += out.processes
            crashes += out.crashes
        }
        let runTime = Date().timeIntervalSince(runStarted)

        var circuitMismatches: [String] = [], nativeMismatches: [String] = [], foldVsNative: [String] = []
        var comparedCircuit = 0, comparedNative = 0, undefinedSkipped = 0, noCircuit = 0
        for module in [Fixture.onone, Fixture.speed] {
            var outcomes = [CircuitOutcome?](repeating: nil, count: cases.count)
            for (k, spec) in specs.enumerated() {
                guard let symbol = try? module.symbol(module: "Fixture", name: spec.name),
                    let evaluator = try? CircuitEvaluator(module: module, symbol: symbol)
                else { continue }
                let indices = cases.indices.filter { cases[$0].spec == k }
                let out = try evaluator.evaluate(indices.map { cases[$0].arguments })
                for (i, o) in zip(indices, out) { outcomes[i] = o }
            }
            for (i, c) in cases.enumerated() {
                let width = bitWidth(specs[c.spec].result)
                let label = "\(specs[c.spec].name)\(c.arguments)"
                guard let circuit = outcomes[i] else { noCircuit += 1; continue }
                if circuit == .undefined { undefinedSkipped += 1; continue }
                let circuitResult = circuit.result(width: width)!
                if let foldResult = folded[i].result(width: width) {
                    comparedCircuit += 1
                    if foldResult != circuitResult, circuitMismatches.count < 8 {
                        circuitMismatches.append("\(label): fold \(foldResult), circuit \(circuitResult)")
                    }
                }
                let n = nativeResults[i].masked(width)
                if n != circuitResult, nativeMismatches.count < 8 {
                    nativeMismatches.append("\(label): native \(n), circuit \(circuitResult)")
                }
            }
        }
        for (i, c) in cases.enumerated() {
            let width = bitWidth(specs[c.spec].result)
            guard let foldResult = folded[i].result(width: width) else { continue }
            let n = nativeResults[i].masked(width)
            comparedNative += 1
            if foldResult != n, foldVsNative.count < 8 {
                foldVsNative.append("\(specs[c.spec].name)\(c.arguments): fold \(foldResult), native \(n)")
            }
        }

        let foldedCount = folded.filter { $0 != .unfolded }.count
        let trapCount = folded.filter { $0 == .trap }.count
        let unfoldedNames = Set(cases.indices.filter { folded[$0] == .unfolded }.map { specs[cases[$0].spec].name }).sorted()
        report(
            "fold route: \(cases.count) inputs in ONE swiftc -emit-sil -O run = \(String(format: "%.2f", foldTime)) s "
                + "(\(String(format: "%.0f", Double(cases.count) / foldTime)) inputs/s incl. startup; \(recompiles) recompiles for diagnosed traps); "
                + "folded \(foldedCount) (\(trapCount) traps), left unfolded \(cases.count - foldedCount) in \(unfoldedNames)")
        report(
            "native route: swiftc -O build \(String(format: "%.2f", buildTime)) s + run \(String(format: "%.2f", runTime)) s "
                + "(\(processes) processes, \(crashes) crashes) = \(String(format: "%.0f", Double(cases.count) / (buildTime + runTime))) inputs/s overall, "
                + "\(String(format: "%.0f", Double(cases.count) / runTime)) inputs/s run only")
        report(
            "compared fold~circuit \(comparedCircuit) (-Onone and -O circuits), fold~native \(comparedNative), undefined skipped \(undefinedSkipped), no circuit \(noCircuit)"
        )

        #expect(circuitMismatches.isEmpty, "\(circuitMismatches)")
        #expect(nativeMismatches.isEmpty, "\(nativeMismatches)")
        #expect(foldVsNative.isEmpty, "\(foldVsNative)")
        #expect(trapCount > 50, "too few trapping probes: \(trapCount)")
        #expect(Set(unfoldedNames).isSubset(of: ["useTwice"]), "unexpected unfolded probes: \(unfoldedNames)")
    }

    /// All 65,536 input pairs of every two-argument 8-bit function against the circuit.
    ///
    /// Design. A trap cannot be caught in-process and Swift cannot fork, so a crash costs one child process. The circuit
    /// is evaluated on all pairs first. Then:
    ///  * pairs the circuit says do NOT trap run natively in one process (resumable at the case after a crash): every value is
    ///    compared, and a crash there means the circuit missed a trap;
    ///  * pairs the circuit says DO trap run natively only as a sample (edge pairs plus random), one child per crash;
    ///    each must crash;
    ///  * a further sample of both kinds goes through the constant-folding route (one swiftc run for all functions).
    /// So value agreement is exhaustive, trap agreement is exhaustive on the "circuit missed a trap" side and sampled on the
    /// "circuit invents a trap" side at the native level. That halves the independence of the trap set; the fold sample adds
    /// an independent view of it (same front end, different back end).
    @Test(arguments: [Optimization.none, .speed])
    func exhaustiveInt8AgainstNativeExecution(_ optimization: Optimization) throws {
        let started = Date()
        let specs = Int8Fixture.functions
        let module = try SILCompiler.module(source: Int8Fixture.source, optimization: optimization)
        let (native, buildTime) = try NativeHarness.build(fixture: Int8Fixture.source, specs: specs, optimization: optimization)
        defer { native.cleanup() }

        // Functions are independent, and each crash costs a child process, so they run on all cores.
        let slots = Slots<Int8Report>(count: specs.count)
        DispatchQueue.concurrentPerform(iterations: specs.count) { k in
            slots.set(k, Int8Report.check(spec: specs[k], index: k, module: module, native: native))
        }
        let reports = slots.items.compactMap { $0 }
        #expect(reports.count == specs.count)
        let failures = reports.compactMap(\.error)
        #expect(failures.isEmpty, "\(failures)")

        let skipped = reports.filter(\.skipped).map(\.name)
        var mismatches = reports.flatMap(\.mismatches)
        let foldCases = reports.flatMap(\.foldCases), foldExpected = reports.flatMap(\.foldExpected)
        let checkedNative = reports.map(\.nativeChecked).reduce(0, +), trapPairs = reports.map(\.trapPairs).reduce(0, +)
        let undefinedPairs = reports.map(\.undefinedPairs).reduce(0, +), trapSampled = reports.map(\.trapSampled).reduce(0, +)
        let trapsConfirmed = reports.map(\.trapsConfirmed).reduce(0, +)
        let processes = reports.map(\.processes).reduce(0, +), crashes = reports.map(\.crashes).reduce(0, +)
        let evalTime = reports.map(\.evalTime).reduce(0, +)

        let foldStarted = Date()
        let (folded, recompiles) = try FoldOracle.fold(fixture: Int8Fixture.source, specs: specs, cases: foldCases)
        let foldTime = Date().timeIntervalSince(foldStarted)
        var foldChecked = 0, foldTraps = 0
        for (i, c) in foldCases.enumerated() {
            guard let got = folded[i].result(width: bitWidth(specs[c.spec].result)) else { continue }
            foldChecked += 1
            if got == .trap { foldTraps += 1 }
            if got != foldExpected[i], mismatches.count < 8 {
                mismatches.append("fold \(specs[c.spec].name)\(c.arguments): circuit \(foldExpected[i]), compiler \(got)")
            }
        }

        let covered = specs.count - skipped.count
        report(
            "Int8 exhaustive \(optimization.rawValue): \(covered) functions x 65536 pairs = \(covered * 65_536) circuit evaluations in \(String(format: "%.2f", evalTime)) s (summed over threads); "
                + "skipped (circuit unsupported) \(skipped)")
        report(
            "  native exhaustive on non-trapping pairs: \(checkedNative) values compared; trapping pairs \(trapPairs): native sample \(trapSampled) (\(trapsConfirmed) crashed as predicted), "
                + "undefined pairs not run \(undefinedPairs); \(processes) processes, \(crashes) crashes; native build \(String(format: "%.2f", buildTime)) s"
        )
        report(
            "  fold route: \(foldCases.count) probes (\(foldChecked) folded, \(foldTraps) traps, \(recompiles) recompiles) in \(String(format: "%.2f", foldTime)) s; total test \(seconds(started)) (other agents running: timings noisy)"
        )

        #expect(mismatches.isEmpty, "\(mismatches)")
        #expect(skipped.isEmpty, "functions the frontend rejected: \(skipped)")
        #expect(checkedNative + trapPairs + undefinedPairs == specs.count * 65_536)
        #expect(undefinedPairs == 0, "no fixture function may reach undefined behaviour")
        #expect(trapSampled > 1_000)
        #expect(foldChecked * 10 >= foldCases.count * 9, "the folder must fold at least 90% of the probes")
    }

    /// Mutation check for the exhaustive harness itself: natives built from deliberately wrong sources must be caught,
    /// both for a wrong value and for a trap that the circuit does and does not predict.
    @Test
    func exhaustiveCheckCatchesMutatedNativeCode() throws {
        let mutations = [
            (
                "public func wadd8(_ a: Int8, _ b: Int8) -> Int8 { a &+ b }",
                "public func wadd8(_ a: Int8, _ b: Int8) -> Int8 { a &+ b &+ 1 }"
            ),
            ("public func add8(_ a: Int8, _ b: Int8) -> Int8 { a + b }", "public func add8(_ a: Int8, _ b: Int8) -> Int8 { a &+ b }"),
            (
                "public func lt8(_ a: Int8, _ b: Int8) -> Bool { a < b }",
                "public func lt8(_ a: Int8, _ b: Int8) -> Bool { precondition(b != 5); return a < b }"
            ),
        ]
        var mutated = Int8Fixture.source
        for (original, replacement) in mutations {
            try #require(mutated.contains(original))
            mutated = mutated.replacingOccurrences(of: original, with: replacement)
        }
        let specs = Int8Fixture.functions
        let module = try SILCompiler.module(source: Int8Fixture.source, optimization: .speed)
        let (native, _) = try NativeHarness.build(fixture: mutated, specs: specs, optimization: .speed)
        defer { native.cleanup() }
        for name in ["wadd8", "add8", "lt8", "sub8"] {
            let k = try #require(specs.firstIndex { $0.name == name })
            let report = Int8Report.check(spec: specs[k], index: k, module: module, native: native)
            #expect(report.error == nil)
            if name == "sub8" {
                #expect(report.mismatches.isEmpty, "an unmutated function must still agree")
            } else {
                #expect(!report.mismatches.isEmpty, "mutation of \(name) was not detected")
            }
        }
    }
}

/// Fixed-size result slots that several threads may fill.
private final class Slots<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T?]
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: T) { lock.lock(); storage[index] = value; lock.unlock() }
    var items: [T?] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Everything one function contributes to the exhaustive Int8 check.
private struct Int8Report: Sendable {
    var name = ""
    var skipped = false
    var error: String?
    var nativeChecked = 0, trapPairs = 0, undefinedPairs = 0, trapSampled = 0, trapsConfirmed = 0, processes = 0, crashes = 0
    var evalTime = 0.0
    var mismatches: [String] = []
    var foldCases: [FoldCase] = []
    var foldExpected: [Result] = []

    static let trapSample = 200
    static let foldSample = 500

    static func check(spec: Spec, index k: Int, module: SILModule, native: NativeHarness) -> Int8Report {
        var report = Int8Report()
        report.name = spec.name
        do {
            let symbol = try module.symbol(module: "Fixture", name: spec.name)
            guard let evaluator = try? CircuitEvaluator(module: module, symbol: symbol) else { report.skipped = true; return report }
            let pairs = Int8Fixture.allPairs
            let width = bitWidth(spec.result)

            let evalStarted = Date()
            let outcomes = try evaluator.evaluate(pairs)
            report.evalTime = Date().timeIntervalSince(evalStarted)

            var valuePairs: [Int] = [], trapList: [Int] = []
            for (p, o) in outcomes.enumerated() {
                switch o {
                case .value: valuePairs.append(p)
                case .trap: trapList.append(p)
                case .undefined: report.undefinedPairs += 1
                }
            }
            report.trapPairs = trapList.count

            // Exhaustive: every pair the circuit says is fine must run natively and give the same value.
            if !valuePairs.isEmpty {
                let out = try native.run(spec.name, cases: valuePairs.map { pairs[$0] })
                report.processes += out.processes
                report.crashes += out.crashes
                for (p, r) in zip(valuePairs, out.results) {
                    guard case .value(let expected) = outcomes[p] else { continue }
                    report.nativeChecked += 1
                    if r.masked(width) == .value(expected & mask(width)) { continue }
                    if report.mismatches.count < 4 {
                        report.mismatches.append("\(spec.name)\(pairs[p]): circuit value \(expected), native \(r)")
                    }
                }
            }

            // Sampled: edge pairs first (trap boundaries), then a fixed pseudo-random fill. Each must crash.
            let edge: Set<UInt64> = [0, 1, 2, 127, 128, 255]
            var chosen = trapList.filter { edge.contains(pairs[$0][0]) && edge.contains(pairs[$0][1]) }.prefix(trapSample / 4).map { $0 }
            var state = UInt64(k + 1) &* 0x9E37_79B9_7F4A_7C15
            var attempts = 0
            while chosen.count < min(trapSample, trapList.count), attempts < 100_000 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let candidate = trapList[Int((state >> 33) % UInt64(trapList.count))]
                if !chosen.contains(candidate) { chosen.append(candidate) }
                attempts += 1
            }
            if !chosen.isEmpty {
                let out = try native.run(spec.name, cases: chosen.map { pairs[$0] })
                report.processes += out.processes
                report.crashes += out.crashes
                for (p, r) in zip(chosen, out.results) {
                    report.trapSampled += 1
                    if r == .trap {
                        report.trapsConfirmed += 1
                    } else if report.mismatches.count < 4 {
                        report.mismatches.append("\(spec.name)\(pairs[p]): circuit trap, native \(r)")
                    }
                }
            }

            for p in valuePairs.shuffledDeterministically(seed: UInt64(k + 7)).prefix(foldSample) {
                guard case .value(let v) = outcomes[p] else { continue }
                report.foldCases.append(FoldCase(spec: k, arguments: pairs[p]))
                report.foldExpected.append(.value(v & mask(width)))
            }
            for p in trapList.shuffledDeterministically(seed: UInt64(k + 9)).prefix(foldSample) {
                report.foldCases.append(FoldCase(spec: k, arguments: pairs[p]))
                report.foldExpected.append(.trap)
            }
        } catch {
            report.error = "\(spec.name): \(error)"
        }
        return report
    }
}

private extension Array {
    func shuffledDeterministically(seed: UInt64) -> [Element] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15
        var items = self
        guard items.count > 1 else { return items }
        for i in stride(from: items.count - 1, to: 0, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            items.swapAt(i, Int((state >> 33) % UInt64(i + 1)))
        }
        return items
    }
}
