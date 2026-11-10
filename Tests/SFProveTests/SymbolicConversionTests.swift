import SFBV
import Testing
@testable import SFProve

/// Width conversions, `min`/`max` and Boolean equality, each compared with native Swift on every 8-bit value (and every
/// 16-bit value where a narrowing conversion can trap). Constant inputs fold every gate, so the circuit evaluates.
@Suite struct SymbolicConversionTests {
    /// A fresh context and `value` as a constant of `width` bits.
    private func constant(_ value: Int, width: Int) -> (SymbolicContext, SymbolicInt) {
        let context = SymbolicContext(builder: CNFBuilder())
        return (context, context.literal(value, width: width))
    }

    /// The signed value of a folded `SymbolicInt`.
    private func value(_ x: SymbolicInt) throws -> Int64 {
        let raw = try #require(x.context.builder.constantValue(x.bits))
        let shift = UInt64(64 - x.width)
        return Int64(bitPattern: raw << shift) >> Int64(shift)
    }

    private func traps(_ context: SymbolicContext) -> Bool { context.trapped == context.builder.trueLit }

    @Test func wideningExtendsTheSignLikeSwift() throws {
        for x in Int(Int8.min)...Int(Int8.max) {
            let (context, symbolic) = constant(x, width: 8)
            #expect(try value(SymbolicInt(symbolic, width: 16)) == Int64(Int16(Int8(x))))
            #expect(try value(SymbolicInt(symbolic, width: 64)) == Int64(Int8(x)))
            #expect(try value(SymbolicInt(truncatingIfNeeded: symbolic, width: 32)) == Int64(Int32(truncatingIfNeeded: Int8(x))))
            #expect(try value(SymbolicInt(zeroExtending: symbolic, width: 16)) == Int64(UInt8(bitPattern: Int8(x))))
            #expect(try value(SymbolicInt(zeroExtending: symbolic, width: 8)) == Int64(x))
            #expect(!traps(context))
        }
    }

    /// `Int8(x)` traps exactly when `Int8(exactly: x)` is nil; `Int8(truncatingIfNeeded:)` never does.
    @Test func narrowingTrapsExactlyWhereSwiftDoes() throws {
        for x in Int(Int16.min)...Int(Int16.max) {
            let (checkedContext, checkedInput) = constant(x, width: 16)
            let checked = SymbolicInt(checkedInput, width: 8)
            let exact = Int8(exactly: x)
            #expect(traps(checkedContext) == (exact == nil), "Int8(\(x))")
            if let exact { #expect(try value(checked) == Int64(exact)) }

            let (wrappingContext, wrappingInput) = constant(x, width: 16)
            #expect(try value(SymbolicInt(truncatingIfNeeded: wrappingInput, width: 8)) == Int64(Int8(truncatingIfNeeded: x)))
            #expect(!traps(wrappingContext))
        }
    }

    @Test func minAndMaxMatchSwift() throws {
        for x in Int(Int8.min)...Int(Int8.max) {
            for y in Int(Int8.min)...Int(Int8.max) {
                let context = SymbolicContext(builder: CNFBuilder())
                let (a, b) = (context.literal(x, width: 8), context.literal(y, width: 8))
                #expect(try value(min(a, b)) == Int64(min(x, y)))
                #expect(try value(max(a, b)) == Int64(max(x, y)))
                #expect(try value(min(a, y)) == Int64(min(x, y)))
                #expect(try value(max(a, y)) == Int64(max(x, y)))
                #expect(!traps(context))
            }
        }
        // Swift's own `min`/`max` still apply to other types in a file that imports SFProve.
        #expect(min(3, 4) == 3 && max(2.5, 1.0) == 2.5)
    }

    @Test func booleanEqualityMatchesSwift() {
        for (p, q) in [(false, false), (false, true), (true, false), (true, true)] {
            let context = SymbolicContext(builder: CNFBuilder())
            let (a, b) = (
                SymbolicBool(context: context, literal: context.builder.constant(p)),
                SymbolicBool(context: context, literal: context.builder.constant(q))
            )
            #expect((a == b).literal == context.builder.constant(p == q))
            #expect((a != b).literal == context.builder.constant(p != q))
        }
    }

    /// The app study case: an `Int32` input converted to `Int` needs no 64-bit input with a range `requires`.
    @Test func proofsUseTheConversions() throws {
        let widened = try proveSigned(widths: [32]) { v in
            let count = SymbolicInt(v[0], width: 64)
            return count * 2 >= count.literal(2 * Int(Int32.min))
        }
        #expect(widened == .proved)

        // The example in docs/guides/prove.md.
        let capped = try proveSigned(widths: [32]) { v in
            let count = SymbolicInt(v[0], width: 64)
            let capped = min(count * 2, count.literal(1_000))
            return capped <= 1_000
        }
        #expect(capped == .proved)

        let narrowed = try proveSigned(widths: [64]) { v in SymbolicInt(v[0], width: 32) == SymbolicInt(v[0], width: 32) }
        guard case .mayTrap(let values) = narrowed else { Issue.record("expected mayTrap, got \(narrowed)"); return }
        #expect(Int32(exactly: values[0]) == nil)

        let clamped = try proveSigned(widths: [16]) { v in
            let x = min(max(v[0], 0), 100)
            return x >= 0 && x <= 100 && (v[0] < 0 || v[0] > 100 || x == v[0])
        }
        #expect(clamped == .proved)

        let symmetric = try proveSigned(widths: [8, 8]) { v in (v[0] < v[1]) == (v[1] > v[0]) }
        #expect(symmetric == .proved)
        let different = try proveSigned(widths: [8, 8]) { v in (v[0] < v[1]) != (v[1] < v[0]) }
        guard case .claimFails(let equal) = different else { Issue.record("expected claimFails, got \(different)"); return }
        #expect(equal[0] == equal[1])
    }
}
