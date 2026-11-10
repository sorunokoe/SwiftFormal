import Foundation
import SFBV
import SFCNF
import SFCheck
import SFLLVM
import SFSAT
import SFSIL
import SwiftFormal
import Testing

/// Fuzzing of the text front ends and of the proof checkers.
///
/// The rule: arbitrary text must produce either a result or a typed error. It must never crash, never hang, and a
/// proof checker must never accept a proof of a formula that is satisfiable. Every input is derived from a fixed seed
/// (printed on failure), so a failure reproduces exactly. Set `SF_FUZZ_ROUNDS` to run more mutations (before a release).
private let rounds: Int = ProcessInfo.processInfo.environment["SF_FUZZ_ROUNDS"].flatMap(Int.init) ?? 150

private let perInputLimit: Duration = .seconds(10)

private enum Fixtures {
    static let silClamp = """
        sil_stage canonical
        import Builtin
        import Swift

        sil @$s7Fixture5clampys5Int32VAD_A2DtF : $@convention(thin) (Int32, Int32, Int32) -> Int32 {
        bb0(%0 : $Int32, %1 : $Int32, %2 : $Int32):
        debug_value %0, let, name "x", argno 1
        %6 = struct_extract %0, #Int32._value
        %7 = struct_extract %1, #Int32._value
        %8 = builtin "cmp_slt_Int32"(%6, %7) : $Builtin.Int1
        cond_br %8, bb1, bb2
        bb1:
        br bb5(%1)
        bb2:
        %11 = struct_extract %2, #Int32._value
        %12 = builtin "cmp_slt_Int32"(%11, %6) : $Builtin.Int1
        cond_br %12, bb3, bb4
        bb3:
        br bb5(%2)
        bb4:
        br bb5(%0)
        bb5(%16 : $Int32):
        return %16
        }
        """
    static let silClampSymbol = "$s7Fixture5clampys5Int32VAD_A2DtF"

    static let silAverage = """
        sil_stage canonical
        import Builtin
        import Swift

        sil @$s7Fixture3avgys5Int32VAD_ADtF : $@convention(thin) (Int32, Int32) -> Int32 {
        bb0(%0 : $Int32, %1 : $Int32):
        %4 = struct_extract %0, #Int32._value
        %5 = struct_extract %1, #Int32._value
        %6 = integer_literal $Builtin.Int1, -1
        %7 = builtin "sadd_with_overflow_Int32"(%4, %5, %6) : $(Builtin.Int32, Builtin.Int1)
        %8 = tuple_extract %7, 0
        %9 = tuple_extract %7, 1
        cond_fail %9, "arithmetic overflow"
        %11 = integer_literal $Builtin.Int32, 2
        %17 = builtin "sdiv_Int32"(%8, %11) : $Builtin.Int32
        %18 = struct $Int32 (%17)
        return %18
        }
        """
    static let silAverageSymbol = "$s7Fixture3avgys5Int32VAD_ADtF"

    static let llvmBranchy = """
        target triple = "arm64-apple-macosx14.0.0"

        define i32 @f(i32 %a, i32 %b) {
        entry:
          %c = icmp slt i32 %a, %b
          br i1 %c, label %t, label %e
        t:
          %s = add nsw i32 %a, %b
          br label %m
        e:
          %d = sub i32 %a, %b
          br label %m
        m:
          %r = phi i32 [ %s, %t ], [ %d, %e ]
          %q = select i1 %c, i32 %r, i32 %a
          %z = and i32 %q, 255
          %w = shl i32 %z, 3
          ret i32 %w
        }
        """

    static let llvmIntrinsic = """
        define i8 @f(i8 %a, i8 %b) {
        entry:
          %p = call { i8, i1 } @llvm.sadd.with.overflow.i8(i8 %a, i8 %b)
          %v = extractvalue { i8, i1 } %p, 0
          %o = extractvalue { i8, i1 } %p, 1
          %r = select i1 %o, i8 0, i8 %v
          ret i8 %r
        }
        declare { i8, i1 } @llvm.sadd.with.overflow.i8(i8, i8)
        """

    /// The shapes `-Onone` app code has (round 6, item 6): a packed stack slot, field addresses, a `switch`, an
    /// aggregate built with `insertvalue`, an opaque pointer through the reference-counting runtime.
    static let llvmMemory = """
        %TSi = type <{ i64 }>
        %TPair = type <{ %TSi, i8, [7 x i8], ptr }>

        define i64 @f(i64 %a, i8 %t, ptr %o) {
        entry:
          %s = alloca %TPair, align 8
          call void @llvm.memset.p0.i64(ptr align 8 %s, i8 0, i64 24, i1 false)
          %x = getelementptr inbounds nuw %TPair, ptr %s, i32 0, i32 0
          %xv = getelementptr inbounds nuw %TSi, ptr %x, i32 0, i32 0
          store i64 %a, ptr %xv, align 8
          %y = getelementptr inbounds nuw %TPair, ptr %s, i32 0, i32 1
          store i8 %t, ptr %y, align 8
          %z = getelementptr inbounds nuw %TPair, ptr %s, i32 0, i32 3
          %r = call ptr @swift_retain(ptr returned %o)
          store ptr %r, ptr %z, align 8
          %agg = insertvalue { i64, i8 } undef, i64 %a, 0
          %agg2 = insertvalue { i64, i8 } %agg, i8 %t, 1
          switch i8 %t, label %other [
            i8 0, label %zero
            i8 1, label %one
          ]
        zero:
          %l = load i64, ptr %xv, align 8
          br label %done
        one:
          %w = extractvalue { i64, i8 } %agg2, 0
          %i = ptrtoint ptr %r to i64
          %sum = add i64 %w, %i
          br label %done
        other:
          br label %done
        done:
          %v = phi i64 [ %l, %zero ], [ %sum, %one ], [ 7, %other ]
          call void @swift_release(ptr %r)
          ret i64 %v
        }
        declare ptr @swift_retain(ptr returned)
        declare void @swift_release(ptr)
        declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)
        """
}

/// The checked-in SIL seeds in `FuzzSeeds/` (generated by `Scripts/make-fuzz-seeds.py`).
private enum GeneratedSeeds {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("FuzzSeeds")
    static let names: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".sil") }.sorted()
    }()

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    /// The symbols of the `sil … @symbol : … {` lines.
    static func definedSymbols(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("sil "), line.hasSuffix("{"), let at = line.range(of: " @") else { return nil }
            return String(line[at.upperBound...].prefix { $0 != " " })
        }
    }

    /// A stable seed for the mutations of one file.
    static func fixtureNumber(_ name: String) -> UInt64 {
        name.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

/// Seeded damage to a text: a byte replaced, a line removed, duplicated or swapped, a span cut.
private func mutate(_ text: String, rng: inout SplitMix64) -> String {
    var bytes = Array(text.utf8)
    var lines = text.components(separatedBy: "\n")
    switch Int.random(in: 0..<5, using: &rng) {
    case 0:
        guard !bytes.isEmpty else { return text }
        bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 32...126, using: &rng)
        return String(decoding: bytes, as: UTF8.self)
    case 1:
        guard !lines.isEmpty else { return text }
        lines.remove(at: Int.random(in: 0..<lines.count, using: &rng))
    case 2:
        guard !lines.isEmpty else { return text }
        let index = Int.random(in: 0..<lines.count, using: &rng)
        lines.insert(lines[index], at: index)
    case 3:
        guard lines.count > 1 else { return text }
        lines.swapAt(Int.random(in: 0..<lines.count, using: &rng), Int.random(in: 0..<lines.count, using: &rng))
    default:
        guard bytes.count > 2 else { return text }
        let start = Int.random(in: 0..<bytes.count - 1, using: &rng)
        bytes.removeSubrange(start..<min(bytes.count, start + Int.random(in: 1...12, using: &rng)))
        return String(decoding: bytes, as: UTF8.self)
    }
    return lines.joined(separator: "\n")
}

/// The inputs for one fixture: every `prefixStride`th prefix, then seeded mutations. `fixture` seeds the generator.
private func fuzzInputs(
    of text: String, fixture: UInt64, prefixStride: Int = 7, rounds: Int = rounds
) -> [(label: String, text: String)] {
    let bytes = Array(text.utf8)
    var inputs: [(String, String)] = stride(from: 0, to: bytes.count, by: prefixStride).map {
        ("prefix of \($0) bytes", String(decoding: bytes[0..<$0], as: UTF8.self))
    }
    for round in 0..<rounds {
        var rng = SplitMix64(seed: fixture &* 1_000_003 &+ UInt64(round))
        var damaged = text
        for _ in 0..<Int.random(in: 1...3, using: &rng) { damaged = mutate(damaged, rng: &rng) }
        inputs.append(("fixture \(fixture) round \(round)", damaged))
    }
    return inputs
}

/// Runs one parse/encode attempt: a typed error or a result are both fine; a hang is not.
private func attempt<ExpectedError: Error>(_ label: String, text: String, errors _: ExpectedError.Type, _ body: () throws -> Void) {
    let clock = ContinuousClock()
    let start = clock.now
    do {
        try body()
    } catch is ExpectedError {
    } catch {
        Issue.record("untyped error \(error) for \(label):\n\(text)")
    }
    let elapsed = clock.now - start
    if elapsed > perInputLimit { Issue.record("\(label) took \(elapsed):\n\(text)") }
}

@Suite struct ParserFuzzTests {
    @Test func theFixturesThemselvesParseAndEncode() throws {
        for (text, symbol) in [(Fixtures.silClamp, Fixtures.silClampSymbol), (Fixtures.silAverage, Fixtures.silAverageSymbol)] {
            let module = try SILModule(text: text)
            #expect(try module.function(symbol).parameterWidths.isEmpty == false)
        }
        for text in [Fixtures.llvmBranchy, Fixtures.llvmIntrinsic, Fixtures.llvmMemory] {
            let module = try LLVMModule(text: text)
            let function = try module.function("f")
            let c = CNFBuilder()
            _ = try LLVMEncoder(module: module, builder: c).encode(
                symbol: "f", arguments: function.parameterWidths.map { c.input(width: $0) })
        }
    }

    /// A repeated block label is a typed error in both readers, never a trap (KNOWN-ISSUES 3, plan item V2).
    @Test func aRepeatedBlockLabelIsATypedError() throws {
        let sil = Fixtures.silClamp.replacingOccurrences(of: "bb3:\n", with: "bb1:\n")
        #expect(throws: SILError.self) {
            _ = try SILVerifier.prove(Fixtures.silClampSymbol, in: try SILModule(text: sil), conflictBudget: 2_000)
        }
        let llvm = Fixtures.llvmBranchy.replacingOccurrences(of: "e:\n", with: "t:\n")
        #expect(throws: LLVMError.self) {
            let module = try LLVMModule(text: llvm)
            let c = CNFBuilder()
            _ = try LLVMEncoder(module: module, builder: c).encode(
                symbol: "f", arguments: try module.function("f").parameterWidths.map { c.input(width: $0) })
        }
    }

    @Test(
        .timeLimit(.minutes(2)),
        arguments: [(Fixtures.silClamp, Fixtures.silClampSymbol), (Fixtures.silAverage, Fixtures.silAverageSymbol)])
    func damagedSILIsAParsedOrATypedError(_ fixture: (text: String, symbol: String)) {
        for (label, text) in fuzzInputs(of: fixture.text, fixture: UInt64(fixture.symbol.utf8.count)) {
            attempt(label, text: text, errors: SILError.self) {
                let module = try SILModule(text: text)
                _ = try SILVerifier.prove(fixture.symbol, in: module, conflictBudget: 2_000)
            }
        }
    }

    /// Real `-emit-sil -Onone` output of this repository's examples, cut to a few functions each (plan item V9;
    /// `Scripts/make-fuzz-seeds.py`). Every function a seed defines is proved on every damaged copy.
    @Test(.timeLimit(.minutes(2)), arguments: GeneratedSeeds.names)
    func damagedCompilerOutputIsAParsedOrATypedError(_ name: String) throws {
        let text = try GeneratedSeeds.text(name)
        let symbols = GeneratedSeeds.definedSymbols(text)
        #expect(!symbols.isEmpty)
        // The seed itself reads: each function is proved, refuted, undecided or a typed refusal.
        let module = try SILModule(text: text)
        for symbol in symbols {
            attempt("\(name) \(symbol)", text: text, errors: SILError.self) {
                _ = try SILVerifier.proveAggregate(symbol, in: module, conflictBudget: 100)
            }
        }
        // Every 61st prefix and a fifth of the rounds: the seeds are kilobytes long, and the fast lane runs this.
        let inputs = fuzzInputs(of: text, fixture: GeneratedSeeds.fixtureNumber(name), prefixStride: 61, rounds: max(1, rounds / 5))
        for (label, damaged) in inputs {
            var module: SILModule?
            attempt("\(name): \(label)", text: damaged, errors: SILError.self) { module = try SILModule(text: damaged) }
            guard let module else { continue }
            // Plan item H9: reading a function throws `SILError` and nothing else, checked by the compiler here.
            for symbol in symbols { _ = Result { () throws(SILError) in try module.function(symbol) } }
            for symbol in symbols {
                attempt("\(name): \(label), \(symbol)", text: damaged, errors: SILError.self) {
                    _ = try SILVerifier.proveAggregate(symbol, in: module, conflictBudget: 100)
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: [Fixtures.llvmBranchy, Fixtures.llvmIntrinsic, Fixtures.llvmMemory])
    func damagedLLVMIsAParsedOrATypedError(_ fixture: String) {
        for (label, text) in fuzzInputs(of: fixture, fixture: UInt64(fixture.utf8.count)) {
            attempt(label, text: text, errors: LLVMError.self) {
                let module = try LLVMModule(text: text)
                let function = try module.function("f")
                let c = CNFBuilder()
                _ = try LLVMEncoder(module: module, builder: c).encode(
                    symbol: "f", arguments: function.parameterWidths.map { c.input(width: $0) })
            }
        }
    }
}

@Suite struct ProofCheckerFuzzTests {
    /// A small unsatisfiable formula (the four clauses over two variables) and its LRAT proof text.
    private static let square = CNF(numVars: 2, clauses: [[1, 2], [-1, 2], [1, -2], [-1, -2]])

    @Test(.timeLimit(.minutes(2)))
    func damagedProofTextIsParsedOrATypedErrorAndNeverVouchesForASatisfiableFormula() throws {
        guard case .unsat(let log) = Solver.solveLRAT(Self.square) else {
            Issue.record("the square must be unsatisfiable")
            return
        }
        let text = LRATProof(log).text(originalCount: Self.square.clauses.count)
        #expect(LRATChecker.check(cnf: Self.square, proof: try LRATProof.parse(text)))
        // The same proof text against satisfiable formulas must never check.
        let satisfiable = [
            CNF(numVars: 2, clauses: [[1, 2], [-1, 2], [1, -2]]),
            CNF(numVars: 2, clauses: [[1, 2], [-1, 2]]),
            CNF(numVars: 3, clauses: []),
        ]
        for (label, damaged) in fuzzInputs(of: text, fixture: 77) {
            attempt(label, text: damaged, errors: LRATError.self) {
                let proof = try LRATProof.parse(damaged)
                for cnf in satisfiable where LRATChecker.check(cnf: cnf, proof: proof) {
                    Issue.record("the LRAT checker accepted a proof of satisfiable \(cnf.clauses) (\(label)):\n\(damaged)")
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func randomRUPProofsOfSatisfiableFormulasNeverCheck() {
        for seed in 0..<UInt64(rounds * 4) {
            var rng = SplitMix64(seed: seed)
            let numVars = Int.random(in: 1...6, using: &rng)
            let model = (0..<numVars).map { _ in Bool.random(using: &rng) }
            // Every clause holds under `model`, so the formula is satisfiable by construction.
            var clauses: [Clause] = []
            for _ in 0..<Int.random(in: 0...12, using: &rng) {
                var clause: Clause = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                    let variable = Int32.random(in: 1...Int32(numVars), using: &rng)
                    return Bool.random(using: &rng) ? variable : -variable
                }
                if !clause.contains(where: { ($0 > 0) == model[Int(abs($0)) - 1] }) { clause.append(model[0] ? 1 : -1) }
                clauses.append(clause)
            }
            let cnf = CNF(numVars: numVars, clauses: clauses)
            let proof: [Clause] =
                (0..<Int.random(in: 0...6, using: &rng)).map { _ in
                    (0..<Int.random(in: 0...3, using: &rng)).map { _ in
                        let variable = Int32.random(in: 1...Int32(numVars), using: &rng)
                        return Bool.random(using: &rng) ? variable : -variable
                    }
                } + [[]]
            #expect(
                !RUPChecker.check(cnf: cnf, proof: proof),
                "RUP checker accepted a proof of a satisfiable formula: seed \(seed), \(cnf.clauses), proof \(proof)")
        }
    }
}
