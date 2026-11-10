// Independent oracle for the S0 table: calls the compiler's own `Builtin.*` operations directly.
// Build: swiftc -parse-stdlib -Onone oracle.swift -o oracle
// Output, one line per case: `<builtin name> <a> <b> <result[,flag]>` with raw unsigned values, in decimal.
// Cases whose precondition is violated (LLVM poison / UB) are skipped: the S0 table calls those `undefined`.
import Swift

@inline(never) func int8Cases(_ a: Int8, _ b: Int8) {
    let (x, y) = (a._value, b._value)
    let (ra, rb) = (UInt8(bitPattern: a), UInt8(bitPattern: b))
    func out(_ name: String, _ r: String) { print("\(name) \(ra) \(rb) \(r)") }
    func v(_ r: Builtin.Int8) -> String { "\(UInt8(bitPattern: Int8(r)))" }
    func w(_ r: Builtin.Int64) -> String { "\(UInt64(bitPattern: Int64(r)))" }
    func f(_ r: Builtin.Int1) -> String { Bool(r) ? "1" : "0" }
    func vf(_ r: (Builtin.Int8, Builtin.Int1)) -> String { v(r.0) + "," + f(r.1) }
    out("add_Int8", v(Builtin.add_Int8(x, y)))
    out("sub_Int8", v(Builtin.sub_Int8(x, y)))
    out("mul_Int8", v(Builtin.mul_Int8(x, y)))
    out("and_Int8", v(Builtin.and_Int8(x, y)))
    out("or_Int8", v(Builtin.or_Int8(x, y)))
    out("xor_Int8", v(Builtin.xor_Int8(x, y)))
    out("int_expect_Int8", v(Builtin.int_expect_Int8(x, y)))
    if rb != 0 {
        out("udiv_Int8", v(Builtin.udiv_Int8(x, y)))
        out("urem_Int8", v(Builtin.urem_Int8(x, y)))
        if !(a == Int8.min && b == -1) {
            out("sdiv_Int8", v(Builtin.sdiv_Int8(x, y)))
            out("srem_Int8", v(Builtin.srem_Int8(x, y)))
        }
    }
    if rb < 8 {
        out("shl_Int8", v(Builtin.shl_Int8(x, y)))
        out("lshr_Int8", v(Builtin.lshr_Int8(x, y)))
        out("ashr_Int8", v(Builtin.ashr_Int8(x, y)))
    }
    out("sadd_with_overflow_Int8", vf(Builtin.sadd_with_overflow_Int8(x, y, false._value)))
    out("uadd_with_overflow_Int8", vf(Builtin.uadd_with_overflow_Int8(x, y, false._value)))
    out("ssub_with_overflow_Int8", vf(Builtin.ssub_with_overflow_Int8(x, y, false._value)))
    out("usub_with_overflow_Int8", vf(Builtin.usub_with_overflow_Int8(x, y, false._value)))
    out("smul_with_overflow_Int8", vf(Builtin.smul_with_overflow_Int8(x, y, false._value)))
    out("umul_with_overflow_Int8", vf(Builtin.umul_with_overflow_Int8(x, y, false._value)))
    out("cmp_eq_Int8", f(Builtin.cmp_eq_Int8(x, y)))
    out("cmp_ne_Int8", f(Builtin.cmp_ne_Int8(x, y)))
    out("cmp_slt_Int8", f(Builtin.cmp_slt_Int8(x, y)))
    out("cmp_sle_Int8", f(Builtin.cmp_sle_Int8(x, y)))
    out("cmp_sgt_Int8", f(Builtin.cmp_sgt_Int8(x, y)))
    out("cmp_sge_Int8", f(Builtin.cmp_sge_Int8(x, y)))
    out("cmp_ult_Int8", f(Builtin.cmp_ult_Int8(x, y)))
    out("cmp_ule_Int8", f(Builtin.cmp_ule_Int8(x, y)))
    out("cmp_ugt_Int8", f(Builtin.cmp_ugt_Int8(x, y)))
    out("cmp_uge_Int8", f(Builtin.cmp_uge_Int8(x, y)))
    out("sextOrBitCast_Int8_Int64", w(Builtin.sextOrBitCast_Int8_Int64(x)))
    out("zextOrBitCast_Int8_Int64", w(Builtin.zextOrBitCast_Int8_Int64(x)))
    // One-operand operations: printed once per `a` (with b = 0, the "zero is not undefined" flag of ctlz/cttz).
    guard rb == 0 else { return }
    out("sext_Int8_Int64", w(Builtin.sext_Int8_Int64(x)))
    out("zext_Int8_Int64", w(Builtin.zext_Int8_Int64(x)))
    out("int_ctlz_Int8", v(Builtin.int_ctlz_Int8(x, false._value)))
    out("int_cttz_Int8", v(Builtin.int_cttz_Int8(x, false._value)))
    out("int_ctpop_Int8", v(Builtin.int_ctpop_Int8(x)))
    if a >= 0 { out("assumeNonNegative_Int8", v(Builtin.assumeNonNegative_Int8(x))) }
}

@inline(never) func int64Cases(_ a: Int64, _ b: Int64) {
    let (x, y) = (a._value, b._value)
    let (ra, rb) = (UInt64(bitPattern: a), UInt64(bitPattern: b))
    func out(_ name: String, _ r: String) { print("\(name) \(ra) \(rb) \(r)") }
    func v(_ r: Builtin.Int64) -> String { "\(UInt64(bitPattern: Int64(r)))" }
    func n(_ r: Builtin.Int8) -> String { "\(UInt8(bitPattern: Int8(r)))" }
    func f(_ r: Builtin.Int1) -> String { Bool(r) ? "1" : "0" }
    func vf(_ r: (Builtin.Int64, Builtin.Int1)) -> String { v(r.0) + "," + f(r.1) }
    out("add_Int64", v(Builtin.add_Int64(x, y)))
    out("sub_Int64", v(Builtin.sub_Int64(x, y)))
    out("mul_Int64", v(Builtin.mul_Int64(x, y)))
    out("and_Int64", v(Builtin.and_Int64(x, y)))
    out("or_Int64", v(Builtin.or_Int64(x, y)))
    out("xor_Int64", v(Builtin.xor_Int64(x, y)))
    if rb != 0 {
        out("udiv_Int64", v(Builtin.udiv_Int64(x, y)))
        out("urem_Int64", v(Builtin.urem_Int64(x, y)))
        if !(a == Int64.min && b == -1) {
            out("sdiv_Int64", v(Builtin.sdiv_Int64(x, y)))
            out("srem_Int64", v(Builtin.srem_Int64(x, y)))
        }
    }
    if rb < 64 {
        out("shl_Int64", v(Builtin.shl_Int64(x, y)))
        out("lshr_Int64", v(Builtin.lshr_Int64(x, y)))
        out("ashr_Int64", v(Builtin.ashr_Int64(x, y)))
    }
    out("sadd_with_overflow_Int64", vf(Builtin.sadd_with_overflow_Int64(x, y, false._value)))
    out("uadd_with_overflow_Int64", vf(Builtin.uadd_with_overflow_Int64(x, y, false._value)))
    out("ssub_with_overflow_Int64", vf(Builtin.ssub_with_overflow_Int64(x, y, false._value)))
    out("usub_with_overflow_Int64", vf(Builtin.usub_with_overflow_Int64(x, y, false._value)))
    out("smul_with_overflow_Int64", vf(Builtin.smul_with_overflow_Int64(x, y, false._value)))
    out("umul_with_overflow_Int64", vf(Builtin.umul_with_overflow_Int64(x, y, false._value)))
    out("cmp_slt_Int64", f(Builtin.cmp_slt_Int64(x, y)))
    out("cmp_ult_Int64", f(Builtin.cmp_ult_Int64(x, y)))
    out("cmp_sge_Int64", f(Builtin.cmp_sge_Int64(x, y)))
    out("cmp_ugt_Int64", f(Builtin.cmp_ugt_Int64(x, y)))
    out("truncOrBitCast_Int64_Int8", n(Builtin.truncOrBitCast_Int64_Int8(x)))
    guard rb == 0 else { return }
    out("trunc_Int64_Int8", n(Builtin.trunc_Int64_Int8(x)))
    out("int_ctlz_Int64", v(Builtin.int_ctlz_Int64(x, false._value)))
    out("int_cttz_Int64", v(Builtin.int_cttz_Int64(x, false._value)))
    out("int_ctpop_Int64", v(Builtin.int_ctpop_Int64(x)))
    out("int_bswap_Int64", v(Builtin.int_bswap_Int64(x)))
    if a >= 0 { out("assumeNonNegative_Int64", v(Builtin.assumeNonNegative_Int64(x))) }
}

for a in 0..<256 {
    for b in 0..<256 { int8Cases(Int8(truncatingIfNeeded: a), Int8(truncatingIfNeeded: b)) }
}

let edges: [Int64] = [0, 1, 2, 3, 7, 63, 64, 65, -1, -2, 255, 256, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF,
                      Int64.max, Int64.max - 1, Int64.min, Int64.min + 1, 0x1234_5678_9ABC_DEF0, -0x1234_5678_9ABC_DEF0,
                      3_037_000_499, 3_037_000_500, 1 << 62, -(1 << 62)]
for a in edges {
    for b in edges { int64Cases(a, b) }
}
