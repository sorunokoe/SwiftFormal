import SFBV
import SFCNF
import SwiftFormal
import SwiftFormalTesting
import SFTestSupport
import Testing

/// Every 8-bit operand pair (65,536) through a bit-vector operation, against the Swift operator on `UInt8` / `Int8`.
/// This compares the circuits with the language, not with another copy of the circuits.
enum EightBit {
    static let pairs = Domain<(Int, Int)>.product(.int(0...255), .int(0...255))

    static func wide(_ x: Int) -> UInt64 { UInt64(x) }

    static func word(_ name: String, _ operation: @escaping (CNFBuilder, BV, BV) -> BV, _ oracle: @escaping (UInt8, UInt8) -> UInt8) {
        Prove(
            name,
            it: { (p: (Int, Int)) in Circuit.fold(8, wide(p.0), wide(p.1), operation) },
            over: pairs
        ) {
            Property.matches("Swift operator") { p in UInt64(oracle(UInt8(p.0), UInt8(p.1))) }
        }
    }

    static func flag(_ name: String, _ operation: @escaping (CNFBuilder, BV, BV) -> Int32, _ oracle: @escaping (UInt8, UInt8) -> Bool) {
        Prove(
            name,
            it: { (p: (Int, Int)) in Circuit.foldFlag(8, wide(p.0), wide(p.1), operation) },
            over: pairs
        ) {
            Property.matches("Swift operator") { p in oracle(UInt8(p.0), UInt8(p.1)) }
        }
    }
}

@Suite struct BitVectorSelfTests {
    private static func wide(_ x: Int) -> UInt64 { EightBit.wide(x) }

    @Test func comparisonsAreSignedAndUnsignedLikeSwift() {
        EightBit.flag("eq", { $0.eq($1, $2) }, { $0 == $1 })
        EightBit.flag("ult", { $0.ult($1, $2) }, { $0 < $1 })
        EightBit.flag("ule", { $0.ule($1, $2) }, { $0 <= $1 })
        EightBit.flag("slt", { $0.slt($1, $2) }, { Int8(bitPattern: $0) < Int8(bitPattern: $1) })
        EightBit.flag("sle", { $0.sle($1, $2) }, { Int8(bitPattern: $0) <= Int8(bitPattern: $1) })
    }

    /// For amounts below the width the three shifts are Swift's `&<<` / `&>>`; for larger amounts the out-of-range flag is set.
    @Test func shiftsMatchSwiftAndFlagOutOfRangeAmounts() {
        Prove(
            "shifts",
            it: { (p: (Int, Int)) -> [UInt64?] in
                [
                    Circuit.fold(8, Self.wide(p.0), Self.wide(p.1)) { $0.shiftLeft($1, by: $2) },
                    Circuit.fold(8, Self.wide(p.0), Self.wide(p.1)) { $0.logicalShiftRight($1, by: $2) },
                    Circuit.fold(8, Self.wide(p.0), Self.wide(p.1)) { $0.arithmeticShiftRight($1, by: $2) },
                    Circuit.foldFlag(8, Self.wide(p.0), Self.wide(p.1)) { $0.shiftAmountOutOfRange($1, $2) } == true ? 1 : 0,
                ]
            },
            over: Domain<(Int, Int)>.product(.int(0...255), .int(0...7))
        ) {
            Property.matches("&<<, >> and the range flag") { p in
                let (x, n) = (UInt8(p.0), UInt8(p.1))
                return [UInt64(x << n), UInt64(x >> n), UInt64(UInt8(bitPattern: Int8(bitPattern: x) >> Int8(n))), 0]
            }
        }
        Prove(
            "out-of-range amounts are flagged",
            it: { (p: (Int, Int)) in Circuit.foldFlag(8, Self.wide(p.0), Self.wide(p.1)) { $0.shiftAmountOutOfRange($1, $2) } },
            over: Domain<(Int, Int)>.product(.int(0...255), .int(0...255))
        ) {
            Property.matches("amount >= width") { p in p.1 >= 8 }
        }
    }
}

/// Exhaustive 8-bit sweeps that take several seconds each in a debug build: the slow lane.
@Suite(.tags(.slow)) struct BitVectorSelfSlowTests {
    private static func wide(_ x: Int) -> UInt64 { EightBit.wide(x) }
    private static let word = EightBit.word
    private static let flag = EightBit.flag

    @Test func addSubMultiplyWrapLikeSwift() {
        Self.word("add", { $0.add($1, $2).sum }, { $0 &+ $1 })
        Self.word("sub", { $0.sub($1, $2).difference }, { $0 &- $1 })
        Self.word("mul", { $0.mul($1, $2) }, { $0 &* $1 })
    }

    /// The overflow flags are exactly what `addingReportingOverflow` and friends report: this is what makes `+` trap in Swift.
    @Test func overflowFlagsAreSwiftsOverflowFlags() {
        Self.flag("unsigned add overflows", { $0.unsignedAddOverflows($1, $2) }, { $0.addingReportingOverflow($1).overflow })
        Self.flag("unsigned sub overflows", { $0.unsignedSubOverflows($1, $2) }, { $0.subtractingReportingOverflow($1).overflow })
        Self.flag("unsigned mul overflows", { $0.unsignedMulOverflows($1, $2) }, { $0.multipliedReportingOverflow(by: $1).overflow })
        let s = { (x: UInt8) in Int8(bitPattern: x) }
        Self.flag("signed add overflows", { $0.signedAddOverflows($1, $2) }, { s($0).addingReportingOverflow(s($1)).overflow })
        Self.flag("signed sub overflows", { $0.signedSubOverflows($1, $2) }, { s($0).subtractingReportingOverflow(s($1)).overflow })
        Self.flag("signed mul overflows", { $0.signedMulOverflows($1, $2) }, { s($0).multipliedReportingOverflow(by: s($1)).overflow })
    }

    @Test func negateAndDivisionMatchSwift() {
        Prove(
            "negate",
            it: { (p: (Int, Int)) in Circuit.fold(8, Self.wide(p.0), 0) { c, a, _ in c.negate(a) } },
            over: Domain<(Int, Int)>.product(.int(0...255), .just(0))
        ) {
            Property.matches("0 &- x") { p in UInt64(0 &- UInt8(p.0)) }
        }
        let divisors = Domain<(Int, Int)>.product(.int(0...255), .int(1...255))
        Prove(
            "unsigned divide",
            it: { (p: (Int, Int)) -> [UInt64?] in
                [
                    Circuit.fold(8, Self.wide(p.0), Self.wide(p.1)) { $0.unsignedDivide($1, $2).quotient },
                    Circuit.fold(8, Self.wide(p.0), Self.wide(p.1)) { $0.unsignedDivide($1, $2).remainder },
                ]
            },
            over: divisors
        ) {
            Property.matches("/ and %") { p in [UInt64(UInt8(p.0) / UInt8(p.1)), UInt64(UInt8(p.0) % UInt8(p.1))] }
        }
        // `Int8.min / -1` overflows in Swift (a trap), so that pair is outside the comparison.
        Prove(
            "signed divide",
            it: { (p: (Int, Int)) -> [UInt64?] in
                [
                    Circuit.fold(8, Self.wide(p.0), Self.wide(p.1)) { $0.signedDivide($1, $2).quotient },
                    Circuit.fold(8, Self.wide(p.0), Self.wide(p.1)) { $0.signedDivide($1, $2).remainder },
                ]
            },
            over: divisors.filter { !(Int8(bitPattern: UInt8($0.0)) == .min && Int8(bitPattern: UInt8($0.1)) == -1) }
        ) {
            Property.matches("/ and % on Int8") { p in
                let (a, b) = (Int8(bitPattern: UInt8(p.0)), Int8(bitPattern: UInt8(p.1)))
                return [UInt64(UInt8(bitPattern: a / b)), UInt64(UInt8(bitPattern: a % b))]
            }
        }
    }
}
