import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL
import SFTestSupport

/// Structs, tuples and fixed-size array literals in real `swiftc` output.
enum AggFixture {
    static let source = """
        public struct P { public var x: Int32; public var y: Int32 }
        public struct Q { public var p: P; public var z: Int8 }
        public struct R { public var flag: Bool; public var b: UInt8 }
        public func addP(_ p: P) -> Int32 { p.x &+ p.y }
        public func swapP(_ p: P) -> P { P(x: p.y, y: p.x) }
        public func mkP(_ a: Int32, _ b: Int32) -> P { P(x: a, y: b) }
        public func nestQ(_ q: Q) -> Int32 { q.p.x &+ Int32(q.z) }
        public func mkQ(_ a: Int32, _ z: Int8) -> Q { Q(p: P(x: a, y: a &+ 1), z: z) }
        public func twoP(_ p: P, _ q: P) -> P { P(x: p.x &+ q.x, y: p.y &- q.y) }
        public func checkedP(_ p: P) -> Int32 { p.x + p.y }
        public func flagR(_ r: R) -> UInt8 { r.flag ? r.b : 0 }
        public func selP(_ c: Bool, _ p: P, _ q: P) -> P { c ? p : q }
        public func bumpP(_ p: P) -> P { var q = p; q.x = q.x &+ 1; return q }
        public func pair(_ a: Int32) -> (Int32, Bool) { (a, a > 0) }
        public func swapT(_ t: (Int32, Int32)) -> (Int32, Int32) { (t.1, t.0 &+ 1) }
        public func arr(_ i: Int) -> Int32 { let a: [Int32] = [1, 2, 3, 4]; return a[i] }
        public func arr2(_ i: Int) -> Int32 { let a: [Int32] = [10, 20, 30, 40]; return a[i] &+ a[3] }
        public func argsum(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { let x = [a, b, c]; return x[0] &+ x[1] &+ x[2] }
        public func argidx(_ a: Int32, _ b: Int32, _ i: Int) -> Int32 { let x = [a, b]; return x[i] }
        public func mutc(_ x: Int32) -> Int32 { var a: [Int32] = [1, 2, 3, 4]; a[2] = x; return a[2] &+ a[1] }
        public func mut(_ i: Int, _ x: Int32) -> Int32 { var a: [Int32] = [1, 2, 3, 4]; a[i] = x; return a[0] &+ a[3] }
        public func cnt(_ x: Int32) -> Int { let a = [x, x, x]; return a.count }
        public func lookup(_ i: Int8) -> UInt8 { let t: [UInt8] = [3, 1, 4, 1, 5, 9, 2, 6]; return t[Int(i)] }
        public func lookup2(_ i: Int32) -> Int32 { let t: [Int32] = [3, 1, 4, 1, 5, 9, 2, 6]; return t[Int(i) & 7] }
        public func sumLit() -> Int32 { var s: Int32 = 0; for x in [1, 2, 3, 4] as [Int32] { s &+= x }; return s }
        """

    static let onone = try! SILCompiler.module(source: source, name: "Ag", optimization: .none)
    static let speed = try! SILCompiler.module(source: source, name: "Ag", optimization: .speed)

    static func module(_ o: Optimization) -> SILModule { o == .none ? onone : speed }
    static func symbol(_ name: String, _ o: Optimization) throws -> String {
        try module(o).symbol(module: "Ag", name: name)
    }
}

/// Constructs the frontend must refuse. Each one is compiled in its own module.
private enum RejectFixture {
    static let source = """
        public class C { public var v: Int32 = 0; public init() {} }
        public enum E { case a, b(Int32) }
        public struct G<T> { public var v: T; public init(v: T) { self.v = v } }
        public struct Holder { public var o: Int32?; public var x: Int32 }
        public protocol Pr { var v: Int32 { get } }
        public func cls(_ c: C) -> Int32 { c.v }
        public func en(_ e: E) -> Int32 { switch e { case .a: return 0; case .b(let x): return x } }
        public func opt(_ x: Int32?) -> Int32 { x ?? 0 }
        public func gen<T: BinaryInteger>(_ x: T) -> T { x + 1 }
        public func gs(_ g: G<Int32>) -> Int32 { g.v }
        public func hold(_ h: Holder) -> Int32 { h.x }
        public func clo(_ f: (Int32) -> Int32) -> Int32 { f(1) }
        public func ex(_ p: any Pr) -> Int32 { p.v }
        public func arrayParam(_ a: [Int32]) -> Int32 { a.isEmpty ? 0 : a[0] }
        public func symbolicLength(_ n: Int) -> Int32 { let a = [Int32](repeating: 7, count: n); return a.isEmpty ? 0 : a[0] }
        public func returnsArray(_ x: Int32) -> [Int32] { [x, x] }
        """
    static let onone = try! SILCompiler.module(source: source, name: "Rj", optimization: .none)
    static let speed = try! SILCompiler.module(source: source, name: "Rj", optimization: .speed)
    static func module(_ o: Optimization) -> SILModule { o == .none ? onone : speed }
}

private func mask(_ width: Int) -> UInt64 { width == 64 ? ~0 : (1 << UInt64(width)) - 1 }

private struct NativeSpec {
    let name: String
    /// Swift type of each parameter leaf (the flattened signature).
    let leaves: [String]
    /// The call, with `{0}`, `{1}`, ... standing for the leaf values.
    let call: String
    /// Expressions over `r` that give the result leaves in declaration order.
    let results: [String]
    var arrays: Bool { ["arr", "arr2", "argsum", "argidx", "mutc", "mut", "cnt", "lookup", "lookup2", "sumLit"].contains(name) }
}

private let specs: [NativeSpec] = [
    .init(name: "addP", leaves: ["Int32", "Int32"], call: "addP(P(x: {0}, y: {1}))", results: ["r"]),
    .init(name: "swapP", leaves: ["Int32", "Int32"], call: "swapP(P(x: {0}, y: {1}))", results: ["r.x", "r.y"]),
    .init(name: "mkP", leaves: ["Int32", "Int32"], call: "mkP({0}, {1})", results: ["r.x", "r.y"]),
    .init(name: "nestQ", leaves: ["Int32", "Int32", "Int8"], call: "nestQ(Q(p: P(x: {0}, y: {1}), z: {2}))", results: ["r"]),
    .init(name: "mkQ", leaves: ["Int32", "Int8"], call: "mkQ({0}, {1})", results: ["r.p.x", "r.p.y", "r.z"]),
    .init(
        name: "twoP", leaves: ["Int32", "Int32", "Int32", "Int32"], call: "twoP(P(x: {0}, y: {1}), P(x: {2}, y: {3}))",
        results: ["r.x", "r.y"]),
    .init(name: "checkedP", leaves: ["Int32", "Int32"], call: "checkedP(P(x: {0}, y: {1}))", results: ["r"]),
    .init(name: "flagR", leaves: ["Bool", "UInt8"], call: "flagR(R(flag: {0}, b: {1}))", results: ["r"]),
    .init(
        name: "selP", leaves: ["Bool", "Int32", "Int32", "Int32", "Int32"], call: "selP({0}, P(x: {1}, y: {2}), P(x: {3}, y: {4}))",
        results: ["r.x", "r.y"]),
    .init(name: "bumpP", leaves: ["Int32", "Int32"], call: "bumpP(P(x: {0}, y: {1}))", results: ["r.x", "r.y"]),
    .init(name: "pair", leaves: ["Int32"], call: "pair({0})", results: ["r.0", "r.1"]),
    .init(name: "swapT", leaves: ["Int32", "Int32"], call: "swapT(({0}, {1}))", results: ["r.0", "r.1"]),
    .init(name: "arr", leaves: ["Int"], call: "arr({0})", results: ["r"]),
    .init(name: "arr2", leaves: ["Int"], call: "arr2({0})", results: ["r"]),
    .init(name: "argsum", leaves: ["Int32", "Int32", "Int32"], call: "argsum({0}, {1}, {2})", results: ["r"]),
    .init(name: "argidx", leaves: ["Int32", "Int32", "Int"], call: "argidx({0}, {1}, {2})", results: ["r"]),
    .init(name: "mutc", leaves: ["Int32"], call: "mutc({0})", results: ["r"]),
    .init(name: "mut", leaves: ["Int", "Int32"], call: "mut({0}, {1})", results: ["r"]),
    .init(name: "cnt", leaves: ["Int32"], call: "cnt({0})", results: ["r"]),
    .init(name: "lookup", leaves: ["Int8"], call: "lookup({0})", results: ["r"]),
    .init(name: "lookup2", leaves: ["Int32"], call: "lookup2({0})", results: ["r"]),
    .init(name: "sumLit", leaves: [], call: "sumLit()", results: ["r"]),
]

private func leafWidth(_ type: String) -> Int {
    switch type {
    case "Bool": 1
    case "Int8", "UInt8": 8
    case "Int32", "UInt32": 32
    default: 64
    }
}

@Suite(.tags(.slow)) struct SILAggregateTests {
    private static let optimizations: [Optimization] = [.none, .speed]

    // MARK: native cross-check

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

    /// A program that runs `name args...` lines from a file and prints `index leaf0 leaf1 ...` after each case.
    private static func nativeMain() -> String {
        var cases = ""
        for spec in specs {
            var call = spec.call
            for (i, t) in spec.leaves.enumerated() {
                call = call.replacingOccurrences(of: "{\(i)}", with: t == "Bool" ? "(a[\(i)] != 0)" : "\(t)(truncatingIfNeeded: a[\(i)])")
            }
            let outputs = spec.results.map { "out.append(String(UInt64(truncatingIfNeeded: \($0))))" }
            cases += "    case \"\(spec.name)\": let r = \(call); "
            if spec.name == "pair" {
                cases += "out.append(String(UInt64(truncatingIfNeeded: r.0))); out.append(r.1 ? \"1\" : \"0\")\n"
            } else {
                cases += outputs.joined(separator: "; ") + "\n"
            }
        }
        return """
            import Foundation
            let lines = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\\n")
            let start = Int(CommandLine.arguments[2])!
            for (index, line) in lines.enumerated() where index >= start {
                let f = line.split(separator: " ")
                let name = String(f[0])
                let a = f.dropFirst().map { UInt64($0)! }
                var out: [String] = []
                switch name {
            \(cases)    default: fatalError("unknown")
                }
                print(index, out.joined(separator: " "))
                fflush(stdout)
            }
            """
    }

    private enum Native: Equatable { case trap, values([UInt64]) }

    /// With unknown array elements the result is not a constant. The trap must still be possible whenever the CPU
    /// traps, and never certain when it does not.
    private static func approximateMismatch(_ e: EncodedFunction, _ c: CNFBuilder, native: Native) -> String? {
        let wrong = native == .trap ? e.trap == c.falseLit : e.trap == c.trueLit
        return wrong ? "approximate model trap \(e.trap), native \(native)" : nil
    }

    /// Runs every case natively. A crash marks the case it died on as a trap and the run resumes after it.
    private static func runNative(binary: String, cases: [String], directory: String) throws -> [Native] {
        let file = directory + "/cases.txt"
        try cases.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        var results: [Native] = []
        var start = 0
        while start < cases.count {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [file, String(start)]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                results.append(.values(line.split(separator: " ").dropFirst().map { UInt64($0)! }))
            }
            if process.terminationReason == .uncaughtSignal {
                results.append(.trap)
            } else {
                try #require(process.terminationStatus == 0)
            }
            start = results.count
        }
        return results
    }

    private static func samples(widths: [Int], count: Int, seed: UInt64) -> [[UInt64]] {
        if widths.isEmpty { return [[]] }
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
            var edges: [UInt64] = [0, 1, 2, 3, 4, 5, 7, 8, m, m - 1, top, top - 1, top + 1, UInt64(bitPattern: -128) & m, 127 & m]
            if w == 1 { edges = [0, 1] }
            for _ in 0..<5 { edges.append(next() & m) }
            return edges
        }
        let pools = widths.map(pool)
        return (0..<count).map { _ in pools.map { $0[Int(next() % UInt64($0.count))] } }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")), .tags(.oracle))
    func encodingsAgreeWithNativeExecution() throws {
        let directory = FileManager.default.currentDirectoryPath + "/.sf-aggregate-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try AggFixture.source.write(toFile: directory + "/Ag.swift", atomically: true, encoding: .utf8)
        try Self.nativeMain().write(toFile: directory + "/main.swift", atomically: true, encoding: .utf8)

        for optimization in Self.optimizations {
            let module = AggFixture.module(optimization)
            let binary = directory + "/native\(optimization.rawValue)"
            let build = try Self.run(["swiftc", optimization.rawValue, directory + "/Ag.swift", directory + "/main.swift", "-o", binary])
            try #require(build.status == 0, "native build failed: \(build.error)")

            var cases: [String] = []
            var meta: [(spec: NativeSpec, args: [UInt64], symbol: String, widths: [Int], results: [Int])] = []
            var accepted: [String] = []
            for (k, spec) in specs.enumerated() {
                let symbol = try AggFixture.symbol(spec.name, optimization)
                // Fail-closed cases (arrays at -Onone) are tested elsewhere; here every accepted function must agree with the CPU.
                let probe = CNFBuilder()
                guard let f = try? module.function(symbol),
                    (try? SILEncoder(module: module, builder: probe).encode(
                        symbol: symbol, arguments: f.parameterWidths.map { probe.input(width: $0) })) != nil
                else { continue }
                #expect(f.parameterWidths == spec.leaves.map(leafWidth), "\(spec.name): flattened parameter widths")
                accepted.append(spec.name)
                for args in Self.samples(widths: f.parameterWidths, count: spec.leaves.isEmpty ? 1 : 150, seed: UInt64(k + 1)) {
                    cases.append(([spec.name] + args.map(String.init)).joined(separator: " "))
                    meta.append((spec, args, symbol, f.parameterWidths, f.resultWidths))
                }
            }
            #expect(accepted.count >= (optimization == .none ? 12 : specs.count), "\(optimization.rawValue) accepted only \(accepted)")
            let native = try Self.runNative(binary: binary, cases: cases, directory: directory)
            try #require(native.count == cases.count)

            var trapsSeen = 0, mismatches: [String] = []
            for (i, m) in meta.enumerated() {
                let c = CNFBuilder()
                let args = zip(m.widths, m.args).map { c.constant($0.1, width: $0.0) }
                let e = try SILEncoder(module: module, builder: c).encode(symbol: m.symbol, arguments: args)
                if !e.approximations.isEmpty {
                    trapsSeen += e.trap == c.trueLit ? 1 : 0
                    mismatches +=
                        Self.approximateMismatch(e, c, native: native[i]).map { ["\(optimization.rawValue) \(cases[i]): \($0)"] } ?? []
                    continue
                }
                guard e.trap == c.trueLit || e.trap == c.falseLit, e.undefined == c.falseLit,
                    let values = try? e.results.map({ try #require(c.constantValue($0)) })
                else {
                    mismatches.append("\(cases[i]): circuit is not constant or reports undefined behaviour"); continue
                }
                let model: Native = e.trap == c.trueLit ? .trap : .values(zip(values, m.results).map { $0 & mask($1) })
                var expected = native[i]
                if case .values(let v) = expected { expected = .values(zip(v, m.results).map { $0 & mask($1) }) }
                if model == .trap { trapsSeen += 1 }
                if model != expected, mismatches.count < 5 {
                    mismatches.append("\(optimization.rawValue) \(cases[i]): model \(model), native \(expected)")
                }
            }
            #expect(mismatches.isEmpty, "\(mismatches)")
            #expect(
                trapsSeen > (optimization == .none ? 10 : 100),
                "too few trapping cases exercised at \(optimization.rawValue): \(trapsSeen) of \(meta.count)")
        }
    }

    // MARK: structs and tuples in signatures

    private static func c32(_ c: CNFBuilder, _ v: Int64) -> BV { c.constant(UInt64(bitPattern: v) & 0xFFFF_FFFF, width: 32) }

    @Test(arguments: optimizations)
    func aStructParameterIsFlattenedToItsFields(_ o: Optimization) throws {
        let module = AggFixture.module(o)
        let q = try module.function(try AggFixture.symbol("nestQ", o))
        #expect(q.parameterWidths == [32, 32, 8] && q.resultWidths == [32])
        let two = try module.function(try AggFixture.symbol("twoP", o))
        #expect(two.parameterWidths == [32, 32, 32, 32] && two.resultWidths == [32, 32] && two.resultWidth == 64)

        // The single-result API still works unchanged for a struct parameter.
        let verdict = try SILVerifier.prove(
            try AggFixture.symbol("addP", o), in: module,
            ensures: { c, a, r in c.eq(r, c.add(a[0], a[1]).sum) })
        #expect(verdict == .proved)
        let nest = try SILVerifier.prove(
            try AggFixture.symbol("nestQ", o), in: module,
            ensures: { c, a, r in c.eq(r, c.add(a[0], c.signExtend(a[2], to: 32)).sum) })
        #expect(nest == .proved)
    }

    @Test(arguments: optimizations)
    func aStructResultIsAListOfLeaves(_ o: Optimization) throws {
        let module = AggFixture.module(o)
        let swap = try SILVerifier.proveAggregate(
            try AggFixture.symbol("swapP", o), in: module,
            ensures: { c, a, r in c.and(c.eq(r[0], a[1]), c.eq(r[1], a[0])) })
        #expect(swap == .proved)

        // A wrong claim yields a counterexample.
        let wrong = try SILVerifier.proveAggregate(
            try AggFixture.symbol("swapP", o), in: module, ensures: { c, a, r in c.and(c.eq(r[0], a[0]), c.eq(r[1], a[1])) })
        guard case .counterexample(let values) = wrong else { Issue.record("expected a counterexample, got \(wrong)"); return }
        #expect(values[0] != values[1])

        let mkQ = try SILVerifier.proveAggregate(
            try AggFixture.symbol("mkQ", o), in: module,
            ensures: { c, a, r in
                c.and(c.and(c.eq(r[0], a[0]), c.eq(r[1], c.add(a[0], c.constant(1, width: 32)).sum)), c.eq(r[2], a[1]))
            })
        #expect(mkQ == .proved)

        let twoP = try SILVerifier.proveAggregate(
            try AggFixture.symbol("twoP", o), in: module,
            ensures: { c, a, r in
                c.and(c.eq(r[0], c.add(a[0], a[2]).sum), c.eq(r[1], c.sub(a[1], a[3]).difference))
            })
        #expect(twoP == .proved)

        // Concatenated result for the single-value API: leaf 0 occupies the low bits.
        let concatenated = try SILVerifier.prove(
            try AggFixture.symbol("swapP", o), in: module,
            ensures: { c, a, r in c.eq(r, BV(bits: a[1].bits + a[0].bits)) })
        #expect(concatenated == .proved)
    }

    @Test(arguments: optimizations)
    func tuplesAndConditionalStructsFlattenToo(_ o: Optimization) throws {
        let module = AggFixture.module(o)
        let sel = try SILVerifier.proveAggregate(
            try AggFixture.symbol("selP", o), in: module,
            ensures: { c, a, r in
                let take = a[0].bits[0]
                return c.and(c.eq(r[0], c.select(take, a[1], a[3])), c.eq(r[1], c.select(take, a[2], a[4])))
            })
        #expect(sel == .proved)
        let pair = try SILVerifier.proveAggregate(
            try AggFixture.symbol("pair", o), in: module,
            ensures: { c, a, r in c.and(c.eq(r[0], a[0]), c.eq(r[1], BV(bits: [c.slt(c.constant(0, width: 32), a[0])]))) })
        #expect(pair == .proved)
        let swapT = try SILVerifier.proveAggregate(
            try AggFixture.symbol("swapT", o), in: module,
            ensures: { c, a, r in c.and(c.eq(r[0], a[1]), c.eq(r[1], c.add(a[0], c.constant(1, width: 32)).sum)) })
        #expect(swapT == .proved)
        let flag = try SILVerifier.proveAggregate(
            try AggFixture.symbol("flagR", o), in: module,
            ensures: { c, a, r in c.or(a[0].bits[0], c.eq(r[0], c.constant(0, width: 8))) })
        #expect(flag == .proved)
        let bump = try SILVerifier.proveAggregate(
            try AggFixture.symbol("bumpP", o), in: module,
            ensures: { c, a, r in c.and(c.eq(r[0], c.add(a[0], c.constant(1, width: 32)).sum), c.eq(r[1], a[1])) })
        #expect(bump == .proved)
    }

    @Test(arguments: optimizations)
    func trapsThroughAStructAreStillReported(_ o: Optimization) throws {
        let module = AggFixture.module(o)
        let symbol = try AggFixture.symbol("checkedP", o)
        let verdict = try SILVerifier.proveAggregate(symbol, in: module)
        guard case .counterexample(let v) = verdict else { Issue.record("expected an overflow counterexample, got \(verdict)"); return }
        #expect(Int32(truncatingIfNeeded: v[0]).addingReportingOverflow(Int32(truncatingIfNeeded: v[1])).overflow)
        // Excluding the overflow by a precondition proves the function safe.
        let safe = try SILVerifier.proveAggregate(
            symbol, in: module,
            requires: { c, a in
                let (lo, hi) = (c.constant(0, width: 32), c.constant(1 << 30, width: 32))
                return c.and(c.and(c.sle(lo, a[0]), c.slt(a[0], hi)), c.and(c.sle(lo, a[1]), c.slt(a[1], hi)))
            },
            ensures: { c, a, r in c.eq(r[0], c.add(a[0], a[1]).sum) })
        #expect(safe == .proved)
    }

    @Test func optimizedAndUnoptimizedStructCodeAgree() throws {
        var compared = 0
        for spec in specs where !spec.arrays {
            let a = try AggFixture.symbol(spec.name, .none), b = try AggFixture.symbol(spec.name, .speed)
            let verdict = try SILVerifier.proveEquivalent(a, in: AggFixture.onone, b, in: AggFixture.speed)
            #expect(verdict == .proved, "\(spec.name): -Onone and -O differ: \(verdict)")
            compared += 1
        }
        #expect(compared == 12)
    }

    // MARK: fixed-size arrays (only where -O lowers them to scalar operations)

    private static func lowBits(_ v: BV, _ n: Int) -> BV { BV(bits: Array(v.bits[0..<n])) }

    /// `table[index]` as a multiplexer chain.
    private static func lookup(_ c: CNFBuilder, _ index: BV, _ table: [UInt64], width: Int) -> BV {
        var result = c.constant(table[table.count - 1], width: width)
        for k in (0..<(table.count - 1)).reversed() {
            result = c.select(c.eq(index, c.constant(UInt64(k), width: index.width)), c.constant(table[k], width: width), result)
        }
        return result
    }

    private static func inRange(_ c: CNFBuilder, _ i: BV, _ count: Int) -> Int32 {
        c.and(c.sle(c.constant(0, width: i.width), i), c.slt(i, c.constant(UInt64(count), width: i.width)))
    }

    private static func outside(_ values: [UInt64], width: Int, count: Int) -> Bool {
        let i = Int64(bitPattern: values[0] << UInt64(64 - width)) >> Int64(64 - width)
        return i < 0 || i >= Int64(count)
    }

    @Test func fixedArraysAtOptimizationAreScalarOperations() throws {
        let o = Optimization.speed
        let module = AggFixture.speed
        func sym(_ n: String) throws -> String { try AggFixture.symbol(n, o) }
        let ranged = { (n: Int) in { (c: CNFBuilder, a: [BV]) in Self.inRange(c, a[a.count - 1], n) } }

        // a[i] of [1, 2, 3, 4]
        let arr = try SILVerifier.proveAggregate(
            try sym("arr"), in: module, requires: ranged(4),
            ensures: { c, a, r in c.eq(r[0], c.add(Self.lowBits(a[0], 32), c.constant(1, width: 32)).sum) })
        #expect(arr == .proved)
        // Without the bound the index can be out of range: the bounds check is a trap and is reported.
        let unbounded = try SILVerifier.proveAggregate(try sym("arr"), in: module)
        guard case .counterexample(let v) = unbounded else {
            Issue.record("expected an out-of-range counterexample, got \(unbounded)"); return
        }
        #expect(Self.outside(v, width: 64, count: 4))

        let arr2 = try SILVerifier.proveAggregate(
            try sym("arr2"), in: module, requires: ranged(4),
            ensures: { c, a, r in
                let i1 = c.add(Self.lowBits(a[0], 32), c.constant(1, width: 32)).sum
                return c.eq(r[0], c.add(c.mul(i1, c.constant(10, width: 32), narrowing: false), c.constant(40, width: 32)).sum)
            })
        #expect(arr2 == .proved)

        // Array elements that are runtime values.
        let argsum = try SILVerifier.proveAggregate(
            try sym("argsum"), in: module,
            ensures: { c, a, r in c.eq(r[0], c.add(c.add(a[0], a[1]).sum, a[2]).sum) })
        #expect(argsum == .proved)
        let argidx = try SILVerifier.proveAggregate(
            try sym("argidx"), in: module, requires: ranged(2),
            ensures: { c, a, r in c.eq(r[0], c.select(c.eq(a[2], c.constant(0, width: 64)), a[0], a[1])) })
        #expect(argidx == .proved)
        let argidxOpen = try SILVerifier.proveAggregate(try sym("argidx"), in: module)
        guard case .counterexample(let w) = argidxOpen else { Issue.record("expected a counterexample, got \(argidxOpen)"); return }
        #expect(Self.outside([w[2]], width: 64, count: 2))

        // Mutation of a local array.
        let mutc = try SILVerifier.proveAggregate(
            try sym("mutc"), in: module,
            ensures: { c, a, r in c.eq(r[0], c.add(a[0], c.constant(2, width: 32)).sum) })
        #expect(mutc == .proved)
        let mut = try SILVerifier.proveAggregate(
            try sym("mut"), in: module, requires: { c, a in Self.inRange(c, a[0], 4) },
            ensures: { c, a, r in
                let first = c.select(c.eq(a[0], c.constant(0, width: 64)), a[1], c.constant(1, width: 32))
                let last = c.select(c.eq(a[0], c.constant(3, width: 64)), a[1], c.constant(4, width: 32))
                return c.eq(r[0], c.add(first, last).sum)
            })
        #expect(mut == .proved)
        let mutOpen = try SILVerifier.proveAggregate(try sym("mut"), in: module)
        guard case .counterexample(let x) = mutOpen else { Issue.record("expected a counterexample, got \(mutOpen)"); return }
        #expect(Self.outside(x, width: 64, count: 4))

        // count and a literal-only loop.
        let cnt = try SILVerifier.proveAggregate(
            try sym("cnt"), in: module, ensures: { c, _, r in c.eq(r[0], c.constant(3, width: 64)) })
        #expect(cnt == .proved)
        let sumLit = try SILVerifier.proveAggregate(
            try sym("sumLit"), in: module, ensures: { c, _, r in c.eq(r[0], c.constant(10, width: 32)) })
        #expect(sumLit == .proved)
    }

    @Test func constantTablesAreLookedUpExactly() throws {
        let module = AggFixture.speed
        let table: [UInt64] = [3, 1, 4, 1, 5, 9, 2, 6]
        let lookup = try SILVerifier.proveAggregate(
            try AggFixture.symbol("lookup", .speed), in: module, requires: { c, a in Self.inRange(c, a[0], 8) },
            ensures: { c, a, r in c.eq(r[0], Self.lookup(c, a[0], table, width: 8)) })
        #expect(lookup == .proved)
        let open = try SILVerifier.proveAggregate(try AggFixture.symbol("lookup", .speed), in: module)
        guard case .counterexample(let v) = open else { Issue.record("expected a counterexample, got \(open)"); return }
        #expect(Self.outside(v, width: 8, count: 8))

        // `i & 7` keeps the index inside the table, so no precondition is needed.
        let masked = try SILVerifier.proveAggregate(
            try AggFixture.symbol("lookup2", .speed), in: module,
            ensures: { c, a, r in
                let index = BV(bits: Array(a[0].bits[0..<3]))
                return c.eq(r[0], Self.lookup(c, index, table, width: 32))
            })
        #expect(masked == .proved)
        // A wrong table entry is found.
        var wrong = table
        wrong[5] = 8
        let bad = try SILVerifier.proveAggregate(
            try AggFixture.symbol("lookup2", .speed), in: module,
            ensures: { c, a, r in c.eq(r[0], Self.lookup(c, BV(bits: Array(a[0].bits[0..<3])), wrong, width: 32)) })
        guard case .counterexample(let b) = bad else { Issue.record("expected a counterexample, got \(bad)"); return }
        #expect(b[0] & 7 == 5)
    }

    // MARK: fail-closed

    private static func rejection(_ name: String, _ o: Optimization, in module: SILModule, library: String) -> String? {
        do {
            let symbol = try module.symbol(module: library, name: name)
            let function = try module.function(symbol)
            let c = CNFBuilder()
            _ = try SILEncoder(module: module, builder: c).encode(
                symbol: symbol, arguments: function.parameterWidths.map { c.input(width: $0) })
            return nil
        } catch let error as SILError {
            return "\(error)"
        } catch {
            return "other error \(error)"
        }
    }

    @Test(arguments: optimizations)
    func unsupportedAggregatesAreRejectedWithAReason(_ o: Optimization) throws {
        let module = RejectFixture.module(o)
        var report: [String] = []
        // A generic struct used at a concrete type (`G<Int32>`) is modelled; generic functions are not.
        #expect(Self.rejection("gs", o, in: module, library: "Rj") == nil)
        // At -O an array is a heap buffer read directly; at -Onone it goes through `Array` calls (see SILArrayTests).
        let arrays = o == .none ? [] : ["arrayParam", "symbolicLength", "returnsArray"]
        for name in ["cls", "gen", "clo", "ex"] + arrays {
            let message = Self.rejection(name, o, in: module, library: "Rj")
            report.append("\(name): \(message ?? "ACCEPTED")")
            #expect(message != nil, "\(name) at \(o.rawValue) must be rejected")
            #expect(message?.hasPrefix("UNSUPPORTED") == true || message?.contains("not found") == true, "\(name): \(message ?? "")")
        }
        print("REJECT \(o.rawValue):\n" + report.joined(separator: "\n"))
    }

    @Test func fixedArraysAtNoOptimizationArePrecise() throws {
        // -Onone builds the array through `Array` calls: logic knows its count exactly, not its elements.
        func verdict(_ name: String) throws -> ProofVerdict {
            try SILVerifier.proveAggregate(try AggFixture.symbol(name, .none), in: AggFixture.onone)
        }
        for name in ["argsum", "mutc", "cnt", "lookup2"] {
            #expect(try verdict(name) == .proved, "\(name)")
        }
        // An index outside the literal traps: "Index out of range".
        #expect(try verdict("arr") == .counterexample([UInt64(bitPattern: Int64.min)]))
        #expect(try verdict("mut") == .counterexample([UInt64(bitPattern: Int64.min), 0]))
        #expect(try verdict("lookup") == .counterexample([128]))  // Int8(-128)
        guard case .counterexample(let v) = try verdict("argidx") else { Issue.record("x[i] with i outside 0...1"); return }
        #expect(Int64(bitPattern: v[2]) < 0 || v[2] > 1)
    }
}
