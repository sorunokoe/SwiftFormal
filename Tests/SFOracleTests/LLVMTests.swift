import Foundation
import Testing
import SFBV
import SFCNF
import SFLLVM
import SFProve
import SFSIL
import SFTestSupport

/// Tests of the LLVM IR frontend. Real `swiftc -emit-ir` output is parsed, encoded, compared with the same
/// function encoded from SIL (N-version check of the compiler lowering), and compared with native execution.
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
        public func sumTo(_ n: Int32) -> Int32 {
            var s: Int32 = 0
            var i: Int32 = 0
            while i < n { s &+= i; i &+= 1 }
            return s
        }
        public func mulChecked(_ a: UInt8, _ b: UInt8) -> UInt8 { a * b }
        public func subChecked(_ a: UInt16, _ b: UInt16) -> UInt16 { a - b }
        public func lshr(_ a: UInt32, _ n: UInt32) -> UInt32 { a >> n }
        public func popc(_ a: UInt32) -> Int { a.nonzeroBitCount }
        public func lz(_ a: UInt32) -> Int { a.leadingZeroBitCount }
        public func bsw(_ a: UInt32) -> UInt32 { a.byteSwapped }
        public func smax(_ a: Int32, _ b: Int32) -> Int32 { a > b ? a : b }
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
        ("sumTo", ["Int32"], "Int32"),
        ("mulChecked", ["UInt8", "UInt8"], "UInt8"),
        ("subChecked", ["UInt16", "UInt16"], "UInt16"),
        ("lshr", ["UInt32", "UInt32"], "UInt32"),
        ("popc", ["UInt32"], "Int"),
        ("lz", ["UInt32"], "Int"),
        ("bsw", ["UInt32"], "UInt32"),
        ("smax", ["Int32", "Int32"], "Int32"),
    ]

    static let silOnone = try! SILCompiler.module(source: source, optimization: .none)
    static let silSpeed = try! SILCompiler.module(source: source, optimization: .speed)
    static let irOnoneText = try! LLVMCompiler.emit(source: source, optimization: .none)
    static let irSpeedText = try! LLVMCompiler.emit(source: source, optimization: .speed)
    static let irOnone = try! LLVMModule(text: irOnoneText)
    static let irSpeed = try! LLVMModule(text: irSpeedText)

    static func sil(_ o: Optimization) -> SILModule { o == .none ? silOnone : silSpeed }
    static func ir(_ o: Optimization) -> LLVMModule { o == .none ? irOnone : irSpeed }
    static func irText(_ o: Optimization) -> String { o == .none ? irOnoneText : irSpeedText }
    static func symbol(_ name: String, _ module: LLVMModule) throws -> String { try module.symbol(module: "Fixture", name: name) }

    /// Whether the encoder gets through the whole function (a parsed header alone proves nothing).
    static func silAccepts(_ name: String, _ o: Optimization) -> Bool {
        guard let symbol = try? sil(o).symbol(module: "Fixture", name: name), let f = try? sil(o).function(symbol) else { return false }
        let c = CNFBuilder()
        return (try? SILEncoder(module: sil(o), builder: c).encode(symbol: symbol, arguments: f.parameterWidths.map { c.input(width: $0) }))
            != nil
    }

    static func irRejection(_ name: String, _ o: Optimization) -> String? {
        do {
            let symbol = try symbol(name, ir(o))
            let f = try ir(o).function(symbol)
            let c = CNFBuilder()
            _ = try LLVMEncoder(module: ir(o), builder: c).encode(symbol: symbol, arguments: f.parameterWidths.map { c.input(width: $0) })
            return nil
        } catch {
            return "\(error)"
        }
    }
}

private func mask(_ width: Int) -> UInt64 { width == 64 ? ~0 : (1 << UInt64(width)) - 1 }

@Suite(.tags(.oracle, .slow), .requiresPinnedCompiler) struct LLVMIRTests {
    // MARK: native cross-check of the IR encoder alone

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

    /// A crash marks the case it died on as a trap; the run resumes after it.
    private static func runNative(binary: String, cases: [String]) throws -> [Native] {
        let path = NSTemporaryDirectory() + "sf-llvm-cases-\(UUID().uuidString)"
        try cases.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var results: [Native] = []
        var start = 0
        while start < cases.count {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [path, String(start)]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                results.append(.value(UInt64(line.split(separator: " ")[1])!))
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

    @Test
    func irEncodingAgreesWithNativeExecution() throws {
        let directory = NSTemporaryDirectory() + "sf-llvm-native-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try Fixture.source.write(toFile: directory + "/Fixture.swift", atomically: true, encoding: .utf8)
        try Self.nativeMain().write(toFile: directory + "/main.swift", atomically: true, encoding: .utf8)

        for optimization in [Optimization.none, .speed] {
            let module = Fixture.ir(optimization)
            let binary = directory + "/native\(optimization.rawValue)"
            let build = try Self.run([
                "swiftc", optimization.rawValue, directory + "/Fixture.swift", directory + "/main.swift", "-o", binary,
            ])
            try #require(build.status == 0, "native build failed: \(build.error)")

            var cases: [String] = []
            var meta: [(name: String, args: [UInt64], symbol: String, widths: [Int], resultWidth: Int)] = []
            for (k, f) in Fixture.functions.enumerated() where Fixture.irRejection(f.name, optimization) == nil {
                let symbol = try Fixture.symbol(f.name, module)
                let parsed = try module.function(symbol)
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
                let e = try LLVMEncoder(module: module, builder: c).encode(symbol: m.symbol, arguments: args)
                guard e.trap == c.trueLit || e.trap == c.falseLit, e.undefined == c.falseLit,
                    let value = c.constantValue(e.result)
                else {
                    mismatches.append("\(cases[i]): circuit is not constant or reports undefined behaviour"); continue
                }
                let model: Native = e.trap == c.trueLit ? .trap : .value(value & mask(m.resultWidth))
                var expected = native[i]
                if case .value(let v) = expected { expected = .value(v & mask(m.resultWidth)) }
                if model == .trap { trapsSeen += 1 }
                if model != expected, mismatches.count < 5 {
                    mismatches.append("\(optimization.rawValue) \(cases[i]): model \(model), native \(expected)")
                }
            }
            #expect(mismatches.isEmpty, "\(mismatches)")
            #expect(trapsSeen > 50, "too few trapping cases exercised: \(trapsSeen)")
            print(
                "native check \(optimization.rawValue): \(cases.count) cases, \(trapsSeen) traps, \(Set(meta.map(\.name)).count) functions")
        }
    }

    // MARK: SIL ≡ IR

    private struct Row { var name: String; var sil: [Bool]; var ir: [String?]; var proved: [String] }

    @Test func llvmAgreesWithSILOnEveryFunctionBothEncodersAccept() throws {
        var rows: [Row] = []
        var proofs = 0
        for f in Fixture.functions {
            var row = Row(name: f.name, sil: [], ir: [], proved: [])
            for o in [Optimization.none, .speed] {
                let silOK = Fixture.silAccepts(f.name, o)
                let irError = Fixture.irRejection(f.name, o)
                row.sil.append(silOK)
                row.ir.append(irError)
                if silOK, irError == nil {
                    let symbol = try Fixture.symbol(f.name, Fixture.ir(o))
                    let started = Date()
                    let verdict = try LLVMVerifier.proveEquivalentToSIL(
                        symbol: symbol, silModule: Fixture.sil(o), llvmModule: Fixture.ir(o))
                    #expect(verdict == .proved, "\(f.name) \(o.rawValue): SIL and IR differ: \(verdict)")
                    row.proved.append(verdict == .proved ? String(format: "proved %.2fs", Date().timeIntervalSince(started)) : "\(verdict)")
                    proofs += 1
                } else {
                    row.proved.append("-")
                }
            }
            rows.append(row)
        }
        var table = "function      | SIL -Onone | SIL -O | IR -Onone | IR -O | SIL≡IR -Onone | SIL≡IR -O\n"
        for r in rows {
            let irCell: (String?) -> String = { $0 == nil ? "yes" : "NO" }
            table +=
                "\(r.name.padding(toLength: 13, withPad: " ", startingAt: 0)) | \(r.sil[0] ? "yes" : "NO") | \(r.sil[1] ? "yes" : "NO") | \(irCell(r.ir[0])) | \(irCell(r.ir[1])) | \(r.proved[0]) | \(r.proved[1])\n"
        }
        for r in rows {
            for (i, o) in ["-Onone", "-O"].enumerated() { if let e = r.ir[i] { table += "IR rejects \(r.name) \(o): \(e.prefix(160))\n" } }
        }
        print(table)
        #expect(proofs >= 30, "only \(proofs) SIL≡IR proofs")
    }

    // MARK: mutation: a deliberately wrong IR semantics must be caught

    /// Applies a textual substitution inside one function of the IR.
    private static func mutate(_ text: String, symbol: String, _ from: String, _ to: String) throws -> String {
        let header = text.range(of: "@\"\(symbol)\"(")
        let start = try #require(header)
        let end = try #require(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
        let body = String(text[start.lowerBound..<end.lowerBound])
        try #require(body.contains(from), "no `\(from)` in \(symbol)")
        return text.replacingCharacters(in: start.lowerBound..<end.lowerBound, with: body.replacingOccurrences(of: from, with: to))
    }

    @Test(arguments: [
        (Optimization.none, "shr", "ashr", "lshr"),
        (.speed, "shr", "ashr", "lshr"),
        (.none, "avg", "sadd.with.overflow", "ssub.with.overflow"),
        (.speed, "avg", "sadd.with.overflow", "ssub.with.overflow"),
        (.speed, "widen", "add nuw nsw", "sub nuw nsw"),
        (.speed, "clamp", "llvm.smin.i32", "llvm.smax.i32"),
        (.none, "mulChecked", "umul.with.overflow", "uadd.with.overflow"),
        (.speed, "ltAnd", "icmp ult", "icmp ugt"),
    ])
    func mutatedIRIsCaughtByTheCrossCheck(_ optimization: Optimization, _ name: String, _ from: String, _ to: String) throws {
        let symbol = try Fixture.symbol(name, Fixture.ir(optimization))
        let mutated = try LLVMModule(text: try Self.mutate(Fixture.irText(optimization), symbol: symbol, from, to))
        let verdict = try LLVMVerifier.proveEquivalentToSIL(symbol: symbol, silModule: Fixture.sil(optimization), llvmModule: mutated)
        guard case .counterexample(let v) = verdict else {
            Issue.record("mutation \(from)->\(to) in \(name) went unnoticed: \(verdict)"); return
        }

        // The counterexample is real: on it the two encodings genuinely disagree.
        let parsed = try mutated.function(symbol)
        let c = CNFBuilder()
        let args = zip(parsed.parameterWidths, v).map { c.constant($0.1, width: $0.0) }
        let s = try SILEncoder(module: Fixture.sil(optimization), builder: c).encode(symbol: symbol, arguments: args)
        let l = try LLVMEncoder(module: mutated, builder: c).encode(symbol: symbol, arguments: args)
        let differs =
            s.trap != l.trap || s.undefined != l.undefined
            || (s.trap == c.falseLit && s.undefined == c.falseLit && c.constantValue(s.result) != c.constantValue(l.result))
        #expect(differs, "counterexample \(v) does not separate the two encodings")
    }

    @Test func mutatedShiftChangesTheConcreteResult() throws {
        // Concrete evaluation: -8 >> 1 is -4 with ashr and a huge positive number with lshr.
        let symbol = try Fixture.symbol("shr", Fixture.irSpeed)
        let mutated = try LLVMModule(text: try Self.mutate(Fixture.irSpeedText, symbol: symbol, "ashr", "lshr"))
        let c = CNFBuilder()
        let args = [c.constant(UInt64(bitPattern: -8) & 0xFFFF_FFFF, width: 32), c.constant(1, width: 32)]
        let good = try LLVMEncoder(module: Fixture.irSpeed, builder: c).encode(symbol: symbol, arguments: args)
        let bad = try LLVMEncoder(module: mutated, builder: c).encode(symbol: symbol, arguments: args)
        #expect(c.constantValue(good.result) == UInt64(bitPattern: -4) & 0xFFFF_FFFF)
        #expect(c.constantValue(bad.result) != c.constantValue(good.result))
    }

    // MARK: IR alone: proofs and fail-closed behaviour

    @Test(arguments: [Optimization.none, .speed])
    func proofsWorkDirectlyOnIR(_ optimization: Optimization) throws {
        let module = Fixture.ir(optimization)
        let clamp = try Fixture.symbol("clamp", module)
        #expect(
            try LLVMVerifier.prove(
                clamp, in: module,
                requires: { c, a in c.sle(a[1], a[2]) },
                ensures: { c, a, r in c.and(c.sle(a[1], r), c.sle(r, a[2])) }) == .proved)
        let div = try Fixture.symbol("div", module)
        guard case .counterexample(let v) = try LLVMVerifier.prove(div, in: module) else {
            Issue.record("division must be able to trap"); return
        }
        let (a, b) = (Int32(truncatingIfNeeded: v[0]), Int32(truncatingIfNeeded: v[1]))
        #expect(b == 0 || (a == .min && b == -1))
    }

    @Test func unsupportedConstructsAreRejectedNotGuessed() throws {
        // A loop, and the unspecialised generic call (pointer arguments) at -Onone.
        #expect(Fixture.irRejection("sumTo", .none) != nil)
        #expect(Fixture.irRejection("mn", .none) != nil)
        // -O removes the loop (closed form in i33) and specialises `min`: both are accepted and still agree with SIL where SIL accepts.
        #expect(Fixture.irRejection("sumTo", .speed) == nil)
        #expect(Fixture.irRejection("mn", .speed) == nil)

        func rejects(_ ir: String, _ fragment: String) {
            do {
                let module = try LLVMModule(text: ir)
                let f = try module.function("f")
                let c = CNFBuilder()
                _ = try LLVMEncoder(module: module, builder: c).encode(symbol: "f", arguments: f.parameterWidths.map { c.input(width: $0) })
                Issue.record("accepted: \(fragment)")
            } catch let error as LLVMError {
                #expect("\(error)".isEmpty == false)
            } catch {
                Issue.record("unexpected error type for \(fragment): \(error)")
            }
        }
        rejects("define i32 @f(i32 %a) {\nentry:\n  %r = fadd float 1.0, 2.0\n  ret i32 %a\n}\n", "float")
        rejects("define i32 @f(<2 x i32> %a) {\nentry:\n  ret i32 0\n}\n", "vector")
        rejects("define i32 @f(ptr %a) {\nentry:\n  %v = load i32, ptr %a\n  ret i32 %v\n}\n", "pointer load")
        rejects(
            "define i32 @f(i32 %a) {\nentry:\n  %p = alloca [4 x i32], align 4\n  %q = getelementptr [4 x i32], ptr %p, i32 0, i32 %a\n  ret i32 0\n}\n",
            "variable index")
        rejects(
            "define i32 @f(i32 %a) {\nentry:\n  br label %l\nl:\n  %i = phi i32 [ %a, %entry ], [ %n, %l ]\n  %n = add i32 %i, 1\n  br label %l\n}\n",
            "loop")
        rejects(
            "define i32 @f(i32 %a) {\nentry:\n  %r = call i32 @unknown(i32 %a)\n  ret i32 %r\n}\ndeclare i32 @unknown(i32)\n",
            "unknown callee")
    }

    // MARK: instruction semantics against a Swift reference, on handwritten IR

    private struct BinaryCase {
        var text: String
        var reference: (UInt8, UInt8) -> UInt8?  // nil: poison or undefined behaviour
    }

    private static func binaryCases() -> [BinaryCase] {
        func s(_ x: UInt8) -> Int8 { Int8(bitPattern: x) }
        func u(_ x: Int8) -> UInt8 { UInt8(bitPattern: x) }
        var cases: [BinaryCase] = [
            .init(text: "add i8") { $0 &+ $1 },
            .init(text: "sub i8") { $0 &- $1 },
            .init(text: "mul i8") { $0 &* $1 },
            .init(text: "add nuw i8") {
                let r = $0.addingReportingOverflow($1); return r.overflow ? nil : r.partialValue
            },
            .init(text: "add nsw i8") {
                let r = s($0).addingReportingOverflow(s($1)); return r.overflow ? nil : u(r.partialValue)
            },
            .init(text: "sub nuw i8") {
                let r = $0.subtractingReportingOverflow($1); return r.overflow ? nil : r.partialValue
            },
            .init(text: "sub nsw i8") {
                let r = s($0).subtractingReportingOverflow(s($1)); return r.overflow ? nil : u(r.partialValue)
            },
            .init(text: "mul nuw i8") {
                let r = $0.multipliedReportingOverflow(by: $1); return r.overflow ? nil : r.partialValue
            },
            .init(text: "mul nsw i8") {
                let r = s($0).multipliedReportingOverflow(by: s($1)); return r.overflow ? nil : u(r.partialValue)
            },
            .init(text: "udiv i8") { $1 == 0 ? nil : $0 / $1 },
            .init(text: "urem i8") { $1 == 0 ? nil : $0 % $1 },
            .init(text: "sdiv i8") { $1 == 0 || (s($0) == .min && s($1) == -1) ? nil : u(s($0) / s($1)) },
            .init(text: "srem i8") { $1 == 0 || (s($0) == .min && s($1) == -1) ? nil : u(s($0) % s($1)) },
            .init(text: "udiv exact i8") { $1 == 0 || $0 % $1 != 0 ? nil : $0 / $1 },
            .init(text: "sdiv exact i8") { $1 == 0 || (s($0) == .min && s($1) == -1) || s($0) % s($1) != 0 ? nil : u(s($0) / s($1)) },
            .init(text: "shl i8") { $1 >= 8 ? nil : $0 << $1 },
            .init(text: "lshr i8") { $1 >= 8 ? nil : $0 >> $1 },
            .init(text: "ashr i8") { $1 >= 8 ? nil : u(s($0) >> s($1)) },
            .init(text: "shl nuw i8") { $1 >= 8 || (($0 << $1) >> $1) != $0 ? nil : $0 << $1 },
            .init(text: "shl nsw i8") { $1 >= 8 || (s($0 << $1) >> s($1)) != s($0) ? nil : $0 << $1 },
            .init(text: "lshr exact i8") { $1 >= 8 || (($0 >> $1) << $1) != $0 ? nil : $0 >> $1 },
            .init(text: "ashr exact i8") { $1 >= 8 || u((s($0) >> s($1)) << s($1)) != $0 ? nil : u(s($0) >> s($1)) },
            .init(text: "and i8") { $0 & $1 },
            .init(text: "or i8") { $0 | $1 },
            .init(text: "or disjoint i8") { $0 & $1 != 0 ? nil : $0 | $1 },
            .init(text: "xor i8") { $0 ^ $1 },
        ]
        let predicates: [(String, (UInt8, UInt8) -> Bool)] = [
            ("eq", { $0 == $1 }), ("ne", { $0 != $1 }),
            ("ult", { $0 < $1 }), ("ule", { $0 <= $1 }), ("ugt", { $0 > $1 }), ("uge", { $0 >= $1 }),
            ("slt", { s($0) < s($1) }), ("sle", { s($0) <= s($1) }), ("sgt", { s($0) > s($1) }), ("sge", { s($0) >= s($1) }),
        ]
        for (name, f) in predicates { cases.append(.init(text: "icmp \(name) i8") { f($0, $1) ? 1 : 0 }) }
        return cases
    }

    @Test func everyBinaryInstructionMatchesTheLangRefReference() throws {
        let pool: [UInt8] = [0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 63, 64, 100, 127, 128, 129, 200, 254, 255]
        var checked = 0
        for test in Self.binaryCases() {
            let isCompare = test.text.hasPrefix("icmp")
            let resultType = isCompare ? "i1" : "i8"
            let ir = "define \(resultType) @f(i8 %a, i8 %b) {\nentry:\n  %r = \(test.text) %a, %b\n  ret \(resultType) %r\n}\n"
            let module = try LLVMModule(text: ir)
            for a in pool {
                for b in pool {
                    let c = CNFBuilder()
                    let e = try LLVMEncoder(module: module, builder: c).encode(
                        symbol: "f", arguments: [c.constant(UInt64(a), width: 8), c.constant(UInt64(b), width: 8)])
                    let expected = test.reference(a, b)
                    #expect(e.trap == c.falseLit)
                    #expect((e.undefined == c.trueLit) == (expected == nil), "\(test.text) \(a) \(b): undefined=\(e.undefined)")
                    if let expected, e.undefined == c.falseLit {
                        #expect(c.constantValue(e.result) == UInt64(expected), "\(test.text) \(a) \(b)")
                    }
                    checked += 1
                }
            }
        }
        #expect(checked == Self.binaryCases().count * pool.count * pool.count)
    }

    @Test func overflowIntrinsicsAndBitIntrinsicsMatchTheReference() throws {
        func module(_ body: String, _ result: String, declare: String) throws -> LLVMModule {
            try LLVMModule(text: "define \(result) @f(i8 %a, i8 %b) {\nentry:\n\(body)\n}\n\(declare)\n")
        }
        func s(_ x: UInt8) -> Int8 { Int8(bitPattern: x) }
        let pool: [UInt8] = [0, 1, 2, 3, 7, 8, 15, 16, 100, 127, 128, 129, 200, 254, 255]
        let overflow: [(String, (UInt8, UInt8) -> (UInt8, Bool))] = [
            (
                "sadd",
                {
                    let r = s($0).addingReportingOverflow(s($1)); return (UInt8(bitPattern: r.partialValue), r.overflow)
                }
            ),
            (
                "uadd",
                {
                    let r = $0.addingReportingOverflow($1); return (r.partialValue, r.overflow)
                }
            ),
            (
                "ssub",
                {
                    let r = s($0).subtractingReportingOverflow(s($1)); return (UInt8(bitPattern: r.partialValue), r.overflow)
                }
            ),
            (
                "usub",
                {
                    let r = $0.subtractingReportingOverflow($1); return (r.partialValue, r.overflow)
                }
            ),
            (
                "smul",
                {
                    let r = s($0).multipliedReportingOverflow(by: s($1)); return (UInt8(bitPattern: r.partialValue), r.overflow)
                }
            ),
            (
                "umul",
                {
                    let r = $0.multipliedReportingOverflow(by: $1); return (r.partialValue, r.overflow)
                }
            ),
        ]
        for (name, f) in overflow {
            let declare = "declare { i8, i1 } @llvm.\(name).with.overflow.i8(i8, i8)"
            let call = "  %p = call { i8, i1 } @llvm.\(name).with.overflow.i8(i8 %a, i8 %b)\n"
            let value = try module(call + "  %v = extractvalue { i8, i1 } %p, 0\n  ret i8 %v", "i8", declare: declare)
            let flag = try module(call + "  %v = extractvalue { i8, i1 } %p, 1\n  ret i1 %v", "i1", declare: declare)
            for a in pool {
                for b in pool {
                    let (v, o) = f(a, b)
                    let c = CNFBuilder()
                    let args = [c.constant(UInt64(a), width: 8), c.constant(UInt64(b), width: 8)]
                    let ev = try LLVMEncoder(module: value, builder: c).encode(symbol: "f", arguments: args)
                    let ef = try LLVMEncoder(module: flag, builder: c).encode(symbol: "f", arguments: args)
                    #expect(c.constantValue(ev.result) == UInt64(v), "\(name) \(a) \(b) value")
                    #expect(c.constantValue(ef.result) == (o ? 1 : 0), "\(name) \(a) \(b) flag")
                    #expect(ev.undefined == c.falseLit && ef.undefined == c.falseLit)
                }
            }
        }

        let unary: [(String, String, (UInt8) -> UInt8?)] = [
            ("ctpop.i8(i8 %a)", "declare i8 @llvm.ctpop.i8(i8)", { UInt8($0.nonzeroBitCount) }),
            ("ctlz.i8(i8 %a, i1 false)", "declare i8 @llvm.ctlz.i8(i8, i1)", { UInt8($0.leadingZeroBitCount) }),
            ("cttz.i8(i8 %a, i1 false)", "declare i8 @llvm.cttz.i8(i8, i1)", { UInt8($0.trailingZeroBitCount) }),
            ("ctlz.i8(i8 %a, i1 true)", "declare i8 @llvm.ctlz.i8(i8, i1)", { $0 == 0 ? nil : UInt8($0.leadingZeroBitCount) }),
            ("cttz.i8(i8 %a, i1 true)", "declare i8 @llvm.cttz.i8(i8, i1)", { $0 == 0 ? nil : UInt8($0.trailingZeroBitCount) }),
        ]
        for (call, declare, f) in unary {
            let m = try module("  %r = call i8 @llvm.\(call)\n  ret i8 %r", "i8", declare: declare)
            for a in 0...255 {
                let c = CNFBuilder()
                let e = try LLVMEncoder(module: m, builder: c).encode(
                    symbol: "f", arguments: [c.constant(UInt64(a), width: 8), c.constant(0, width: 8)])
                if let expected = f(UInt8(a)) {
                    #expect(e.undefined == c.falseLit && c.constantValue(e.result) == UInt64(expected), "\(call) \(a)")
                } else {
                    #expect(e.undefined == c.trueLit, "\(call) \(a) must be poison")
                }
            }
        }
        let reverse = try module(
            "  %r = call i8 @llvm.bitreverse.i8(i8 %a)\n  ret i8 %r", "i8", declare: "declare i8 @llvm.bitreverse.i8(i8)")
        for a in 0...255 {
            let c = CNFBuilder()
            let e = try LLVMEncoder(module: reverse, builder: c).encode(
                symbol: "f", arguments: [c.constant(UInt64(a), width: 8), c.constant(0, width: 8)])
            var expected: UInt64 = 0
            for bit in 0..<8 where a & (1 << bit) != 0 { expected |= 1 << UInt64(7 - bit) }
            #expect(c.constantValue(e.result) == expected, "bitreverse \(a)")
        }
    }

    @Test func undefinedBehaviourAfterATrapIsMasked() throws {
        // `sdiv` after a trapping guard: where the guard traps the function traps, and is not additionally undefined.
        let ir = """
            define i32 @f(i32 %a, i32 %b) {
            entry:
              %z = icmp eq i32 %b, 0
              br i1 %z, label %fail, label %ok
            fail:
              call void @llvm.trap()
              unreachable
            ok:
              %q = sdiv i32 %a, %b
              ret i32 %q
            }
            declare void @llvm.trap()
            """
        let module = try LLVMModule(text: ir)
        // b == 0 traps without being undefined; INT_MIN / -1 is undefined and does not trap.
        let verdict = try SFProve.prove(inputWidths: [32, 32]) { c, inputs in
            let e = try LLVMEncoder(module: module, builder: c).encode(symbol: "f", arguments: inputs)
            let zero = c.eq(inputs[1], c.constant(0, width: 32))
            let overflow = c.and(c.eq(inputs[0], c.constant(1 << 31, width: 32)), c.eq(inputs[1], c.constant(~0 & 0xFFFF_FFFF, width: 32)))
            return c.and(c.and(-c.xor(e.trap, zero), -c.xor(e.undefined, overflow)), c.or(-zero, -e.undefined))
        }
        #expect(verdict == .proved)
    }
}
