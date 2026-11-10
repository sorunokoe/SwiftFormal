import Testing
import SFBV
import SFCNF
import SFSAT
import SFSemantics
import SFTestSupport

/// Swift's own checked-arithmetic APIs as the native oracle for the operations in the S0 table.
private func native<T: FixedWidthInteger & SignedInteger>(
    _ op: S0Op, _ a: UInt64, _ b: UInt64, as: T.Type
) -> S0Outcome where T.Magnitude: FixedWidthInteger & UnsignedInteger {
    typealias U = T.Magnitude
    func raw<X: FixedWidthInteger>(_ x: X) -> UInt64 { UInt64(truncatingIfNeeded: U(truncatingIfNeeded: x)) }
    let (x, y) = (T(truncatingIfNeeded: a), T(truncatingIfNeeded: b))
    let (ux, uy) = (U(truncatingIfNeeded: a), U(truncatingIfNeeded: b))
    func flag(_ p: Bool) -> UInt64 { p ? 1 : 0 }
    switch op {
    case .add: return .values([raw(x &+ y)])
    case .sub: return .values([raw(x &- y)])
    case .mul: return .values([raw(x &* y)])
    case .and: return .values([raw(x & y)])
    case .or: return .values([raw(x | y)])
    case .xor: return .values([raw(x ^ y)])
    case .udiv: return uy == 0 ? .undefined : .values([raw(ux / uy)])
    case .urem: return uy == 0 ? .undefined : .values([raw(ux % uy)])
    case .sdiv:
        let r = x.dividedReportingOverflow(by: y)
        return y == 0 || r.overflow ? .undefined : .values([raw(r.partialValue)])
    case .srem:
        let r = x.remainderReportingOverflow(dividingBy: y)
        return y == 0 || r.overflow ? .undefined : .values([raw(r.partialValue)])
    case .shl: return uy >= U(T.bitWidth) ? .undefined : .values([raw(x &<< y)])
    case .lshr: return uy >= U(T.bitWidth) ? .undefined : .values([raw(ux &>> uy)])
    case .ashr: return uy >= U(T.bitWidth) ? .undefined : .values([raw(x &>> y)])
    case .saddOverflow:
        let r = x.addingReportingOverflow(y)
        return .values([raw(r.partialValue), flag(r.overflow)])
    case .ssubOverflow:
        let r = x.subtractingReportingOverflow(y)
        return .values([raw(r.partialValue), flag(r.overflow)])
    case .smulOverflow:
        let r = x.multipliedReportingOverflow(by: y)
        return .values([raw(r.partialValue), flag(r.overflow)])
    case .uaddOverflow:
        let r = ux.addingReportingOverflow(uy)
        return .values([raw(r.partialValue), flag(r.overflow)])
    case .usubOverflow:
        let r = ux.subtractingReportingOverflow(uy)
        return .values([raw(r.partialValue), flag(r.overflow)])
    case .umulOverflow:
        let r = ux.multipliedReportingOverflow(by: uy)
        return .values([raw(r.partialValue), flag(r.overflow)])
    case .eq: return .values([flag(x == y)])
    case .ne: return .values([flag(x != y)])
    case .slt: return .values([flag(x < y)])
    case .sle: return .values([flag(x <= y)])
    case .sgt: return .values([flag(x > y)])
    case .sge: return .values([flag(x >= y)])
    case .ult: return .values([flag(ux < uy)])
    case .ule: return .values([flag(ux <= uy)])
    case .ugt: return .values([flag(ux > uy)])
    case .uge: return .values([flag(ux >= uy)])
    case .intExpect: return .values([raw(x)])
    case .trunc, .zext, .sext, .ctlz, .cttz, .ctpop, .bswap, .assumeNonNegative:
        fatalError("one-operand operations are tested separately (bitOperationsMatchNative)")
    }
}

private let bitOps: [S0Op] = [.ctlz, .cttz, .ctpop, .bswap, .assumeNonNegative]
private let binaryOps = S0Op.allCases.filter { ![.trunc, .zext, .sext].contains($0) && !bitOps.contains($0) }

/// The same operation through Swift's own integer APIs (`leadingZeroBitCount`, `byteSwapped`, ...).
private func nativeBit<T: FixedWidthInteger & SignedInteger>(_ op: S0Op, _ a: UInt64, zeroIsUndefined: Bool, as: T.Type) -> S0Outcome
where T.Magnitude: FixedWidthInteger & UnsignedInteger {
    let x = T.Magnitude(truncatingIfNeeded: a)
    switch op {
    case .ctlz: return x == 0 && zeroIsUndefined ? .undefined : .values([UInt64(x.leadingZeroBitCount)])
    case .cttz: return x == 0 && zeroIsUndefined ? .undefined : .values([UInt64(x.trailingZeroBitCount)])
    case .ctpop: return .values([UInt64(x.nonzeroBitCount)])
    case .bswap: return .values([UInt64(x.byteSwapped)])
    case .assumeNonNegative: return T(truncatingIfNeeded: a) < 0 ? .undefined : .values([UInt64(x)])
    default: fatalError("not a bit operation")
    }
}

/// Every value at 8 and 16 bits; edges and random samples at 32 and 64.
private func bitSamples(_ width: Int) -> [UInt64] {
    let m: UInt64 = width == 64 ? ~0 : (1 << UInt64(width)) - 1
    if width <= 16 { return Array(0...m) }
    var rng = SystemRandomNumberGenerator()
    return [0, 1, m, 1 << UInt64(width - 1), 0x0123_4567_89AB_CDEF & m] + (0..<300).map { _ in .random(in: 0...m, using: &rng) }
}

/// Why `inst` on `a` disagrees with Swift or with its own circuit, or nil when all three agree.
private func bitMismatch(_ inst: S0Instance, _ a: UInt64, flag: Bool) -> String? {
    let want: S0Outcome
    switch inst.width {
    case 8: want = nativeBit(inst.op, a, zeroIsUndefined: flag, as: Int8.self)
    case 16: want = nativeBit(inst.op, a, zeroIsUndefined: flag, as: Int16.self)
    case 32: want = nativeBit(inst.op, a, zeroIsUndefined: flag, as: Int32.self)
    default: want = nativeBit(inst.op, a, zeroIsUndefined: flag, as: Int64.self)
    }
    let args = bitArgs(inst, a, flag: flag)
    guard inst.evaluate(args) == want else { return "\(inst.builtinName)(\(args)): \(inst.evaluate(args)) != native \(want)" }
    let c = CNFBuilder()
    let (out, undefined) = inst.encode(c, zip(args, inst.operandWidths).map { c.constant($0, width: $1) })
    let got: S0Outcome? =
        undefined == c.trueLit ? .undefined : (undefined == c.falseLit ? c.constantValue(out[0]).map { .values([$0]) } : nil)
    return got == want ? nil : "encode \(inst.builtinName)(\(args)): \(String(describing: got)) != \(want)"
}

/// Arguments of a one-operand bit operation (plus the zero-is-undefined flag of ctlz/cttz).
private func bitArgs(_ inst: S0Instance, _ a: UInt64, flag: Bool) -> [UInt64] { inst.arity == 2 ? [a, flag ? 1 : 0] : [a] }

private func args(_ inst: S0Instance, _ a: UInt64, _ b: UInt64) -> [UInt64] {
    inst.arity == 3 ? [a, b, 0] : [a, b]
}

/// Evaluate the circuit for constant inputs; constants fold, so every literal is fixed.
private func encodeConstant(_ inst: S0Instance, _ a: UInt64, _ b: UInt64) -> S0Outcome? {
    let c = CNFBuilder()
    var inputs = [c.constant(a, width: inst.width), c.constant(b, width: inst.width)]
    if inst.arity == 3 { inputs.append(c.constant(0, width: 1)) }
    let (values, undefined) = inst.encode(c, inputs)
    guard undefined == c.trueLit || undefined == c.falseLit else { return nil }
    if undefined == c.trueLit { return .undefined }
    var out: [UInt64] = []
    for v in values {
        guard let x = c.constantValue(v) else { return nil }
        out.append(x)
    }
    return .values(out)
}

@Suite struct S0Tests {
    @Test func parsesSILBuiltinNamesAndFailsClosed() {
        let cases: [(String, S0Op, Int, Int)] = [
            ("sadd_with_overflow_Int8", .saddOverflow, 8, 8), ("cmp_slt_Int64", .slt, 64, 64),
            ("sextOrBitCast_Int8_Int64", .sext, 8, 64), ("truncOrBitCast_Int64_Int8", .trunc, 64, 8),
            ("sdiv_Int8", .sdiv, 8, 8), ("int_expect_Int1", .intExpect, 1, 1), ("ashr_Int32", .ashr, 32, 32),
        ]
        for (name, op, w, r) in cases {
            let inst = S0Instance(builtinName: name)
            #expect(inst?.op == op && inst?.width == w && inst?.resultWidth == r, "\(name)")
            #expect(inst?.builtinName == name)
        }
        for name in [
            "fadd_FPIEEE64", "sdiv_exact_Int8", "add_Int7", "add_Word", "ptrtoint_Word", "sextOrBitCast_Int64_Int8",
            "truncOrBitCast_Int8_Int64", "add_Int8_Int8", "cmp_slt_Int", "foo_Int8", "", "sdiv_Int1",
        ] {
            #expect(S0Instance(builtinName: name) == nil, "\(name) must be rejected")
        }
    }

    /// Reference interpreter against Swift's native arithmetic: every operation, every Int8 pair.
    @Test func interpreterMatchesNativeExhaustivelyAt8Bits() {
        for op in binaryOps {
            let inst = S0Instance(op: op, width: 8)!
            for a in 0..<256 as Range<UInt64> {
                for b in 0..<256 as Range<UInt64> {
                    let got = inst.evaluate(args(inst, a, b)), want = native(op, a, b, as: Int8.self)
                    if got != want { Issue.record("\(inst.builtinName)(\(a), \(b)): \(got) != native \(want)"); return }
                }
            }
        }
    }

    /// Same at 16, 32 and 64 bits on edge values and random samples.
    @Test func interpreterMatchesNativeAtWiderWidths() {
        var rng = SystemRandomNumberGenerator()
        for op in binaryOps {
            for width in [16, 32, 64] {
                let inst = S0Instance(op: op, width: width)!
                let m: UInt64 = width == 64 ? ~0 : (1 << UInt64(width)) - 1
                let edges: [UInt64] = [
                    0, 1, 2, m, m - 1, 1 << UInt64(width - 1), (1 << UInt64(width - 1)) - 1, UInt64(width), UInt64(width - 1),
                ]
                var pairs = edges.flatMap { a in edges.map { (a, $0) } }
                pairs += (0..<500).map { _ in (UInt64.random(in: 0...m, using: &rng), UInt64.random(in: 0...m, using: &rng)) }
                for (a, b) in pairs {
                    let got = inst.evaluate(args(inst, a, b))
                    let want: S0Outcome
                    switch width {
                    case 16: want = native(op, a, b, as: Int16.self)
                    case 32: want = native(op, a, b, as: Int32.self)
                    default: want = native(op, a, b, as: Int64.self)
                    }
                    if got != want { Issue.record("\(inst.builtinName)(\(a), \(b)): \(got) != native \(want)"); return }
                }
            }
        }
    }

    /// Plan item L8: bit counting, byte swaps and `assumeNonNegative`, interpreter against Swift and circuit against the
    /// interpreter, every Int8 and Int16 value and samples at 32 and 64 bits.
    @Test func bitOperationsMatchNativeAndTheirCircuits() {
        for op in bitOps {
            for width in [8, 16, 32, 64] {
                guard let inst = S0Instance(op: op, width: width) else {
                    #expect(op == .bswap && width == 8, "\(op) at \(width) must exist")
                    continue
                }
                for a in bitSamples(width) {
                    for flag in inst.arity == 2 ? [false, true] : [false] {
                        if let problem = bitMismatch(inst, a, flag: flag) {
                            Issue.record(Comment(rawValue: problem))
                            return
                        }
                    }
                }
            }
        }
        for name in [
            "int_ctlz_Int32", "int_cttz_Int8", "int_ctpop_Int64", "int_bswap_Int32", "assumeNonNegative_Int64", "trunc_Int64_Int32",
            "zext_Int1_Int64", "sext_Int32_Int64",
        ] {
            #expect(S0Instance(builtinName: name) != nil, "\(name)")
        }
        for name in ["int_bswap_Int8", "assumeNonNegative_Int1", "trunc_Int32_Int64", "zext_Int64_Int8"] {
            #expect(S0Instance(builtinName: name) == nil, "\(name) must be rejected")
        }
    }

    @Test func castsMatchNative() {
        let values: [UInt64] = [0, 1, 0x7F, 0x80, 0xFF, 0x1234, 0x8000, 0xFFFF, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, ~0, 1 << 63]
        for v in values {
            let i8 = Int8(truncatingIfNeeded: v), u8 = UInt8(truncatingIfNeeded: v)
            let i16 = Int16(truncatingIfNeeded: v), i32 = Int32(truncatingIfNeeded: v)
            #expect(S0Instance(builtinName: "sextOrBitCast_Int8_Int64")!.evaluate([v]) == .values([UInt64(bitPattern: Int64(i8))]))
            #expect(S0Instance(builtinName: "zextOrBitCast_Int8_Int64")!.evaluate([v]) == .values([UInt64(u8)]))
            #expect(S0Instance(builtinName: "truncOrBitCast_Int64_Int8")!.evaluate([v]) == .values([UInt64(u8)]))
            #expect(
                S0Instance(builtinName: "sextOrBitCast_Int16_Int32")!.evaluate([v]) == .values([UInt64(UInt32(bitPattern: Int32(i16)))]))
            #expect(S0Instance(builtinName: "sextOrBitCast_Int32_Int64")!.evaluate([v]) == .values([UInt64(bitPattern: Int64(i32))]))
            #expect(
                S0Instance(builtinName: "truncOrBitCast_Int32_Int16")!.evaluate([v]) == .values([UInt64(UInt16(truncatingIfNeeded: v))]))
        }
    }
}

/// The encoder checks that take seconds even in a release build; `Scripts/test-lane.sh` leaves this suite out of the fast lane.
@Suite(.tags(.slow)) struct S0SlowTests {
    /// The circuit builder, folded on constants, agrees with the interpreter on every Int8 pair for every operation.
    @Test func encoderMatchesInterpreterExhaustivelyAt8Bits() {
        for op in binaryOps {
            let inst = S0Instance(op: op, width: 8)!
            for a in 0..<256 as Range<UInt64> {
                for b in 0..<256 as Range<UInt64> {
                    let got = encodeConstant(inst, a, b), want = inst.evaluate(args(inst, a, b))
                    if got != want { Issue.record("encode \(inst.builtinName)(\(a), \(b)): \(String(describing: got)) != \(want)"); return }
                }
            }
        }
    }

    @Test func encoderMatchesInterpreterOnCastsAndWideValues() {
        var rng = SystemRandomNumberGenerator()
        for op in binaryOps {
            for width in [16, 32, 64] {
                let inst = S0Instance(op: op, width: width)!
                let m: UInt64 = width == 64 ? ~0 : (1 << UInt64(width)) - 1
                let edges: [UInt64] = [0, 1, m, 1 << UInt64(width - 1), (1 << UInt64(width - 1)) - 1, UInt64(width), UInt64(width - 1)]
                var pairs = edges.flatMap { a in edges.map { (a, $0) } }
                pairs += (0..<40).map { _ in (UInt64.random(in: 0...m, using: &rng), UInt64.random(in: 0...m, using: &rng)) }
                for (a, b) in pairs {
                    let got = encodeConstant(inst, a, b), want = inst.evaluate(args(inst, a, b))
                    if got != want { Issue.record("encode \(inst.builtinName)(\(a), \(b)): \(String(describing: got)) != \(want)"); return }
                }
            }
        }
        for (name, v) in [
            ("sextOrBitCast_Int8_Int64", UInt64(0x80)), ("zextOrBitCast_Int8_Int64", 0x80), ("truncOrBitCast_Int64_Int8", 0x1FF),
            ("sextOrBitCast_Int32_Int64", 0x8000_0000),
        ] {
            let inst = S0Instance(builtinName: name)!
            let c = CNFBuilder()
            let (values, _) = inst.encode(c, [c.constant(v, width: inst.width)])
            #expect(.values([c.constantValue(values[0])!]) == inst.evaluate([v]), "\(name)")
        }
    }

    /// Through the real solver with symbolic 8-bit inputs and random pairs, every operation. Exercises the generated clauses.
    @Test func encoderMatchesInterpreterThroughSolverOnSamples() throws {
        for op in binaryOps {
            let inst = S0Instance(op: op, width: 8)!
            let c = CNFBuilder()
            let x = c.input(width: 8), y = c.input(width: 8)
            var inputs = [x, y]
            if inst.arity == 3 { inputs.append(c.input(width: 1)) }
            let (values, undefined) = inst.encode(c, inputs)
            let base = c.cnf
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<60 {
                let a = UInt64.random(in: 0...255, using: &rng), b = UInt64.random(in: 0...255, using: &rng)
                var cnf = base
                for i in 0..<8 {
                    cnf.clauses.append([(a >> UInt64(i)) & 1 == 1 ? x.bits[i] : -x.bits[i]])
                    cnf.clauses.append([(b >> UInt64(i)) & 1 == 1 ? y.bits[i] : -y.bits[i]])
                }
                if inst.arity == 3 { cnf.clauses.append([-inputs[2].bits[0]]) }
                guard case .sat(let model) = Solver.solve(cnf) else { Issue.record("expected sat for \(inst.builtinName)"); return }
                let isUndefined = model[Int(abs(undefined)) - 1] == (undefined > 0)
                let got: S0Outcome = isUndefined ? .undefined : .values(values.map { c.value(of: $0, in: model) })
                let want = inst.evaluate(args(inst, a, b))
                if got != want { Issue.record("solver \(inst.builtinName)(\(a), \(b)): \(got) != \(want)"); return }
            }
        }
    }
}
