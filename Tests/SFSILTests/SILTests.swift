import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL
import SFTestSupport

/// End-to-end tests of the SIL frontend: real `swiftc` output is parsed, encoded, proved about, and compared
/// with the same source compiled and run natively.
enum Fixture {
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
        public func sumTo(_ n: Int32) -> Int32 {
            var s: Int32 = 0
            var i: Int32 = 0
            while i < n { s &+= i; i &+= 1 }
            return s
        }
        """

    /// name, parameter types, result type (as written in Swift)
    static let functions: [(name: String, params: [String], result: String)] = [
        ("clamp", ["Int32", "Int32", "Int32"], "Int32"),
        ("avg", ["Int32", "Int32"], "Int32"),
        ("div", ["Int32", "Int32"], "Int32"),
        ("rem", ["Int32", "Int32"], "Int32"),
        ("mulHi", ["UInt8", "UInt8"], "UInt16"),
        ("isEven", ["Int64"], "Bool"),
        ("sel", ["Bool", "Int8", "Int8"], "Int8"),
        ("wrapAdd", ["UInt32", "UInt32"], "UInt32"),
        ("shr", ["Int32", "Int32"], "Int32"),
        ("shl", ["Int32", "Int32"], "Int32"),
        ("narrow", ["Int32"], "Int8"),
        ("truncating", ["Int32"], "Int8"),
        ("pre", ["Int64"], "Int64"),
        ("widen", ["UInt8"], "Int"),
        ("neg", ["Int32"], "Int32"),
        ("ltAnd", ["UInt16", "UInt16"], "Bool"),
        ("useTwice", ["Int32"], "Int32"),
        ("mn", ["Int32", "Int32"], "Int32"),
    ]

    static let onone = try! SILCompiler.module(source: source, optimization: .none)
    static let speed = try! SILCompiler.module(source: source, optimization: .speed)

    static func symbol(_ name: String, _ module: SILModule) throws -> String {
        try module.symbol(module: "Fixture", name: name)
    }
}

@Suite(.tags(.slow)) struct SILFrontendTests {
    // MARK: native cross-check

    private static func run(_ args: [String]) throws -> (status: Int32, reason: Process.TerminationReason, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus, process.terminationReason, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self)
        )
    }

    /// A program that runs `name args...` lines from a file and prints `index result` after each case.
    private static func nativeMain() -> String {
        var cases = ""
        for f in Fixture.functions {
            let args = f.params.enumerated().map { i, t in
                t == "Bool" ? "a[\(i)] != 0" : "\(t)(truncatingIfNeeded: a[\(i)])"
            }.joined(separator: ", ")
            let call = "\(f.name)(\(args))"
            cases += "    case \"\(f.name)\": r = \(f.result == "Bool" ? "(\(call)) ? 1 : 0" : "UInt64(truncatingIfNeeded: \(call))")\n"
        }
        return """
            import Foundation
            let lines = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\\n")
            let start = Int(CommandLine.arguments[2])!
            for (index, line) in lines.enumerated() where index >= start {
                let f = line.split(separator: " ")
                let name = String(f[0])
                let a = f.dropFirst().map { UInt64($0)! }
                var r: UInt64 = 0
                switch name {
            \(cases)    default: fatalError("unknown")
                }
                print(index, r)
                fflush(stdout)
            }
            """
    }

    private enum Native: Equatable { case trap, value(UInt64) }

    /// Runs every case natively. A crash marks the case it died on as a trap and the run resumes after it.
    private static func runNative(binary: String, cases: [String]) throws -> [Native] {
        let dir = NSTemporaryDirectory() + "sf-cases-\(UUID().uuidString)"
        try cases.joined(separator: "\n").write(toFile: dir, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var results: [Native] = []
        var start = 0
        while start < cases.count {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [dir, String(start)]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let f = line.split(separator: " ")
                results.append(.value(UInt64(f[1])!))
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

    private static func mask(_ width: Int) -> UInt64 { width == 64 ? ~0 : (1 << UInt64(width)) - 1 }

    private static func samples(widths: [Int], count: Int, seed: UInt64) -> [[UInt64]] {
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
                0, 1, 2, 3, m, m - 1, top, top - 1, top + 1, 31 & m, 32 & m, 33 & m, UInt64(bitPattern: -32) & m, 7 & m, 127 & m,
                UInt64(bitPattern: -128) & m,
            ]
            if w == 1 { edges = [0, 1] }
            for _ in 0..<6 { edges.append(next() & m) }
            return edges
        }
        let pools = widths.map(pool)
        return (0..<count).map { _ in pools.map { $0[Int(next() % UInt64($0.count))] } }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")), .tags(.oracle))
    func encodingsAgreeWithNativeExecution() throws {
        let directory = NSTemporaryDirectory() + "sf-native-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try Fixture.source.write(toFile: directory + "/Fixture.swift", atomically: true, encoding: .utf8)
        try Self.nativeMain().write(toFile: directory + "/main.swift", atomically: true, encoding: .utf8)

        for (optimization, module) in [(Optimization.none, Fixture.onone), (.speed, Fixture.speed)] {
            let binary = directory + "/native\(optimization.rawValue)"
            let build = try Self.run([
                "swiftc", optimization.rawValue, directory + "/Fixture.swift", directory + "/main.swift", "-o", binary,
            ])
            try #require(build.status == 0, "native build failed: \(build.error)")

            var cases: [String] = []
            var meta: [(name: String, args: [UInt64], symbol: String, widths: [Int], resultWidth: Int)] = []
            for (k, f) in Fixture.functions.enumerated() {
                let symbol = try Fixture.symbol(f.name, module)
                guard let parsed = try? module.function(symbol) else { continue }  // fail-closed cases are tested elsewhere
                for args in Self.samples(widths: parsed.parameterWidths, count: 120, seed: UInt64(k + 1)) {
                    cases.append(([f.name] + args.map(String.init)).joined(separator: " "))
                    meta.append((f.name, args, symbol, parsed.parameterWidths, parsed.resultWidth))
                }
            }
            let native = try Self.runNative(binary: binary, cases: cases)
            try #require(native.count == cases.count)

            var trapsSeen = 0, mismatches: [String] = []
            for (i, m) in meta.enumerated() {
                let c = CNFBuilder()
                let args = zip(m.widths, m.args).map { c.constant($0.1, width: $0.0) }
                let e = try SILEncoder(module: module, builder: c).encode(symbol: m.symbol, arguments: args)
                guard e.trap == c.trueLit || e.trap == c.falseLit, e.undefined == c.falseLit,
                    let value = c.constantValue(e.result)
                else {
                    mismatches.append("\(cases[i]): circuit is not constant or reports undefined behaviour"); continue
                }
                let model: Native = e.trap == c.trueLit ? .trap : .value(value & Self.mask(m.resultWidth))
                var expected = native[i]
                if case .value(let v) = expected { expected = .value(v & Self.mask(m.resultWidth)) }
                if model == .trap { trapsSeen += 1 }
                if model != expected, mismatches.count < 5 {
                    mismatches.append("\(optimization.rawValue) \(cases[i]): model \(model), native \(expected)")
                }
            }
            #expect(mismatches.isEmpty, "\(mismatches)")
            #expect(trapsSeen > 50, "too few trapping cases exercised: \(trapsSeen)")
        }
    }

    // MARK: proofs

    @Test(arguments: [Optimization.none, .speed])
    func clampStaysInRange(_ optimization: Optimization) throws {
        let module = optimization == .none ? Fixture.onone : Fixture.speed
        let verdict = try SILVerifier.prove(
            try Fixture.symbol("clamp", module), in: module,
            requires: { c, a in c.sle(a[1], a[2]) },
            ensures: { c, a, r in c.and(c.sle(a[1], r), c.sle(r, a[2])) })
        #expect(verdict == .proved)
        // Without the precondition the claim is false, and the counterexample must be real.
        let bad = try SILVerifier.prove(
            try Fixture.symbol("clamp", module), in: module,
            ensures: { c, a, r in c.and(c.sle(a[1], r), c.sle(r, a[2])) })
        guard case .counterexample(let v) = bad else { Issue.record("expected a counterexample, got \(bad)"); return }
        #expect(Int32(truncatingIfNeeded: v[1]) > Int32(truncatingIfNeeded: v[2]))
    }

    @Test(arguments: [Optimization.none, .speed])
    func averageTrapsOnlyWhenTheSumOverflows(_ optimization: Optimization) throws {
        let module = optimization == .none ? Fixture.onone : Fixture.speed
        let symbol = try Fixture.symbol("avg", module)
        guard case .counterexample(let v) = try SILVerifier.prove(symbol, in: module) else {
            Issue.record("avg must be able to trap"); return
        }
        let (a, b) = (Int32(truncatingIfNeeded: v[0]), Int32(truncatingIfNeeded: v[1]))
        #expect(a.addingReportingOverflow(b).overflow)
        // Declaring both operands to fit in 31 bits removes the overflow, and proves it in milliseconds.
        let started = Date()
        let narrowed = try SILVerifier.prove(symbol, in: module, inputSignedBits: [31, 31])
        #expect(narrowed == .proved)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test(arguments: [Optimization.none, .speed])
    func divisionNeedsItsTwoPreconditions(_ optimization: Optimization) throws {
        let module = optimization == .none ? Fixture.onone : Fixture.speed
        let symbol = try Fixture.symbol("div", module)
        let safe: (CNFBuilder, [BV]) -> Int32 = { c, a in
            c.and(
                -c.eq(a[1], c.constant(0, width: 32)),
                -c.and(c.eq(a[0], c.constant(1 << 31, width: 32)), c.eq(a[1], c.constant(~0, width: 32))))
        }
        #expect(try SILVerifier.prove(symbol, in: module, requires: safe) == .proved)
        guard case .counterexample(let v) = try SILVerifier.prove(symbol, in: module) else {
            Issue.record("division must be able to trap"); return
        }
        let (a, b) = (Int32(truncatingIfNeeded: v[0]), Int32(truncatingIfNeeded: v[1]))
        #expect(b == 0 || (a == .min && b == -1))
    }

    @Test(arguments: [Optimization.none, .speed])
    func checkedNarrowingTrapsExactlyOutsideTheRange(_ optimization: Optimization) throws {
        let module = optimization == .none ? Fixture.onone : Fixture.speed
        let symbol = try Fixture.symbol("narrow", module)
        let inRange: (CNFBuilder, [BV]) -> Int32 = { c, a in
            c.and(c.sle(c.constant(UInt64(bitPattern: -128) & 0xFFFF_FFFF, width: 32), a[0]), c.sle(a[0], c.constant(127, width: 32)))
        }
        let value = try SILVerifier.prove(
            symbol, in: module, requires: inRange,
            ensures: { c, a, r in c.eq(c.signExtend(r, to: 32), a[0]) })
        #expect(value == .proved)
        guard case .counterexample(let v) = try SILVerifier.prove(symbol, in: module) else {
            Issue.record("narrowing must be able to trap"); return
        }
        #expect(Int8(exactly: Int32(truncatingIfNeeded: v[0])) == nil)
    }

    @Test(arguments: [Optimization.none, .speed])
    func smartShiftNeverTrapsAndMatchesAshrInRange(_ optimization: Optimization) throws {
        let module = optimization == .none ? Fixture.onone : Fixture.speed
        let symbol = try Fixture.symbol("shr", module)
        // `a >> n` is defined for every n, including negative and oversized ones: no trap, no undefined behaviour.
        #expect(try SILVerifier.prove(symbol, in: module) == .proved)
        let inRange: (CNFBuilder, [BV]) -> Int32 = { c, a in
            c.and(c.sle(c.constant(0, width: 32), a[1]), c.slt(a[1], c.constant(32, width: 32)))
        }
        #expect(
            try SILVerifier.prove(
                symbol, in: module, requires: inRange,
                ensures: { c, a, r in c.eq(r, c.arithmeticShiftRight(a[0], by: a[1])) }) == .proved)
    }

    @Test(arguments: [Optimization.none, .speed])
    func widenedUnsignedProductNeverWraps(_ optimization: Optimization) throws {
        let module = optimization == .none ? Fixture.onone : Fixture.speed
        let symbol = try Fixture.symbol("mulHi", module)
        // Cheap structural facts about the 8x8 -> 16 product, valid for every input.
        let verdict = try SILVerifier.prove(
            symbol, in: module,
            ensures: { c, a, r in
                let zero = c.or(c.eq(a[0], c.constant(0, width: 8)), c.eq(a[1], c.constant(0, width: 8)))
                let bound = c.ule(r, c.constant(255 * 255, width: 16))
                let parity = -c.xor(r.bits[0], c.and(a[0].bits[0], a[1].bits[0]))
                return c.and(c.and(c.or(-zero, c.eq(r, c.constant(0, width: 16))), bound), parity)
            })
        #expect(verdict == .proved)
    }

    @Test(arguments: [Optimization.none, .speed])
    func widenedUnsignedProductIsExactOnNibbles(_ optimization: Optimization) throws {
        let module = optimization == .none ? Fixture.onone : Fixture.speed
        let verdict = try SILVerifier.prove(
            try Fixture.symbol("mulHi", module), in: module,
            requires: { c, a in c.and(c.ult(a[0], c.constant(16, width: 8)), c.ult(a[1], c.constant(16, width: 8))) },
            ensures: { c, a, r in c.eq(r, c.mul(c.zeroExtend(a[0], to: 16), c.zeroExtend(a[1], to: 16), narrowing: false)) })
        #expect(verdict == .proved)
    }

    @Test(arguments: [Optimization.none, .speed])
    func callsAreInlined(_ optimization: Optimization) throws {
        let module = optimization == .none ? Fixture.onone : Fixture.speed
        let verdict = try SILVerifier.prove(
            try Fixture.symbol("useTwice", module), in: module,
            ensures: { c, a, r in c.eq(r, c.add(c.add(a[0], a[0]).sum, c.constant(1, width: 32)).sum) })
        #expect(verdict == .proved)
    }

    @Test(arguments: [Optimization.none, .speed])
    func failedPreconditionIsATrap(_ optimization: Optimization) throws {
        let module = optimization == .none ? Fixture.onone : Fixture.speed
        let symbol = try Fixture.symbol("pre", module)
        let positive: (CNFBuilder, [BV]) -> Int32 = { c, a in c.slt(c.constant(0, width: 64), a[0]) }
        #expect(try SILVerifier.prove(symbol, in: module, requires: positive) == .proved)
        guard case .counterexample(let v) = try SILVerifier.prove(symbol, in: module) else {
            Issue.record("precondition must be able to trap"); return
        }
        #expect(Int64(bitPattern: v[0]) <= 0)
    }

    // MARK: differential and fail-closed behaviour

    @Test func optimizedAndUnoptimizedCodeAgreeOnEverySupportedFunction() throws {
        var compared = 0
        for f in Fixture.functions {
            let a = try Fixture.symbol(f.name, Fixture.onone), b = try Fixture.symbol(f.name, Fixture.speed)
            guard (try? Fixture.onone.function(a)) != nil, (try? Fixture.speed.function(b)) != nil else { continue }
            let verdict = try SILVerifier.proveEquivalent(a, in: Fixture.onone, b, in: Fixture.speed)
            #expect(verdict == .proved, "\(f.name): -Onone and -O differ: \(verdict)")
            compared += 1
        }
        #expect(compared >= 16)
    }

    @Test func unsupportedConstructsAreRejectedNotGuessed() throws {
        // A loop: no fixpoint reasoning yet.
        for module in [Fixture.onone, Fixture.speed] {
            let symbol = try Fixture.symbol("sumTo", module)
            #expect(throws: SILError.self) { try SILVerifier.prove(symbol, in: module) }
        }
        // `min` is an unspecialized generic call at -Onone (an exact summary) and specialized code at -O.
        for module in [Fixture.onone, Fixture.speed] {
            let verdict = try SILVerifier.prove(
                try Fixture.symbol("mn", module), in: module,
                ensures: { c, a, r in c.eq(r, c.select(c.slt(a[1], a[0]), a[1], a[0])) })
            #expect(verdict == .proved)
        }
    }
}
