import Testing
import SFBV
import SFProve

@Suite struct ProveTests {
    @Test func additionCommutesAt16Bits() throws {
        let verdict = try prove(inputWidths: [16, 16]) { c, v in c.eq(c.add(v[0], v[1]).sum, c.add(v[1], v[0]).sum) }
        #expect(verdict == .proved)
    }

    @Test func provePicksItsStrategyWithAnArgumentNotAnotherFunctionName() throws {
        let commutes: (CNFBuilder, [BV]) -> Int32 = { c, v in c.eq(c.mul(v[0], v[1]), c.mul(v[1], v[0])) }
        let exact = try prove(inputWidths: [6, 6], claim: commutes)
        let refined = try prove(inputWidths: [6, 6], strategy: .refiningMultipliers, claim: commutes)
        #expect(exact == .proved)
        #expect(refined == .proved)

        let refuted = try prove(inputWidths: [6], strategy: .refiningMultipliers) { c, v in
            c.eq(c.mul(v[0], c.constant(3, width: 6)), c.add(v[0], v[0]).sum)
        }
        guard case .counterexample(let values) = refuted else { Issue.record("expected counterexample"); return }
        let x = UInt8(values[0])
        #expect((x &* 3) & 0x3F != (x &+ x) & 0x3F)
    }

    @Test func falseClaimGivesReplayableCounterexample() throws {
        let verdict = try prove(inputWidths: [16]) { c, v in
            c.eq(c.mul(v[0], c.constant(3, width: 16)), c.add(v[0], v[0]).sum)
        }
        guard case .counterexample(let values) = verdict else { Issue.record("expected counterexample"); return }
        let x = UInt16(values[0])
        #expect(x &* 3 != x &+ x)
    }

    /// clamp(x, lo, hi) stays inside [lo, hi] when lo <= hi, for all 64-bit signed values.
    @Test func clampStaysInRangeAt64Bits() throws {
        let start = ContinuousClock.now
        let verdict = try prove(inputWidths: [64, 64, 64]) { c, v in
            let (x, lo, hi) = (v[0], v[1], v[2])
            let clamped = c.select(c.slt(x, lo), lo, c.select(c.slt(hi, x), hi, x))
            let inRange = c.and(c.sle(lo, clamped), c.sle(clamped, hi))
            return c.or(c.slt(hi, lo), inRange)
        }
        print("clamp64 proof time:", ContinuousClock.now - start)
        #expect(verdict == .proved)
    }

    /// Without the lo <= hi precondition the claim is false and must yield a counterexample.
    @Test func clampWithoutPreconditionFails() throws {
        let verdict = try prove(inputWidths: [64, 64, 64]) { c, v in
            let (x, lo, hi) = (v[0], v[1], v[2])
            let clamped = c.select(c.slt(x, lo), lo, c.select(c.slt(hi, x), hi, x))
            return c.and(c.sle(lo, clamped), c.sle(clamped, hi))
        }
        guard case .counterexample(let values) = verdict else { Issue.record("expected counterexample"); return }
        let (x, lo, hi) = (Int64(bitPattern: values[0]), Int64(bitPattern: values[1]), Int64(bitPattern: values[2]))
        let clamped = x < lo ? lo : (hi < x ? hi : x)
        #expect(!(lo <= clamped && clamped <= hi))
    }

    /// The solver's overflow condition for 64-bit signed add matches Swift's own flag.
    @Test func signedAddOverflowAt64BitsMatchesNative() throws {
        let verdict = try prove(inputWidths: [64, 64]) { c, v in
            // Claim: overflow is impossible. Must be refuted.
            -c.signedAddOverflows(v[0], v[1])
        }
        guard case .counterexample(let values) = verdict else { Issue.record("expected counterexample"); return }
        let (x, y) = (Int64(bitPattern: values[0]), Int64(bitPattern: values[1]))
        #expect(x.addingReportingOverflow(y).overflow)
    }

    @Test func noOverflowWhenBothInSafeRange() throws {
        let verdict = try prove(inputWidths: [64, 64]) { c, v in
            let bound = c.constant(1 << 62, width: 64)
            let negBound = c.constant(UInt64(bitPattern: -(1 << 62)), width: 64)
            let safe = c.and(
                c.and(c.slt(v[0], bound), c.sle(negBound, v[0])),
                c.and(c.slt(v[1], bound), c.sle(negBound, v[1])))
            return c.or(-safe, -c.signedAddOverflows(v[0], v[1]))
        }
        #expect(verdict == .proved)
    }
}
