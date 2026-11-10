import Testing
import SFProve
import SFTestSupport

@Suite(.tags(.slow)) struct SymbolicTests {
    /// `abs` written the obvious way traps for `Int32.min`; the verifier finds that exact input.
    @Test func naiveAbsTrapsAtMinimum() throws {
        let verdict = try proveSigned(widths: [32]) { v in
            let x = v[0]
            return x.isNegativeThen(-x, else: x) >= 0
        }
        #expect(verdict == .mayTrap([Int64(Int32.min)]))
        #expect((0 as Int32).subtractingReportingOverflow(Int32.min).overflow)
    }

    @Test func guardedAbsNeverTrapsAndIsNonNegative() throws {
        let verdict = try proveSigned(widths: [32]) { v in
            let x = v[0]
            let magnitude = (x == Int(Int32.min)).then(x.literal(Int(Int32.max)), else: x.isNegativeThen(-x, else: x))
            return magnitude >= 0
        }
        #expect(verdict == .proved)
    }

    /// The classic midpoint bug: `(a + b) / 2` overflows for large values. The witness replays natively.
    @Test func midpointOverflowIsFoundAndReplays() throws {
        let verdict = try proveSigned(widths: [32, 32]) { v in (v[0] + v[1]) / 2 <= Int(Int32.max) }
        guard case .mayTrap(let values) = verdict else { Issue.record("expected mayTrap, got \(verdict)"); return }
        let (a, b) = (Int32(values[0]), Int32(values[1]))
        #expect(a.addingReportingOverflow(b).overflow)
    }

    @Test func safeMidpointIsProved() throws {
        let verdict = try proveSigned(widths: [32, 32], requires: { $0[0] <= $0[1] }) { v in
            let (lo, hi) = (v[0], v[1])
            let middle = lo + (hi - lo) / 2
            return lo <= middle && middle <= hi
        }
        // `hi - lo` can still overflow when lo < 0 < hi, and the verifier must say so.
        guard case .mayTrap(let values) = verdict else { Issue.record("expected mayTrap, got \(verdict)"); return }
        let (lo, hi) = (Int32(values[0]), Int32(values[1]))
        #expect(lo <= hi && hi.subtractingReportingOverflow(lo).overflow)

        let bounded = try proveSigned(widths: [32, 32], requires: { $0[0] >= 0 && $0[0] <= $0[1] }) { v in
            let (lo, hi) = (v[0], v[1])
            let middle = lo + (hi - lo) / 2
            return lo <= middle && middle <= hi
        }
        #expect(bounded == .proved)
    }

    /// A wrong claim without a trap is reported as such, with a replayable input.
    @Test func falseClaimIsDistinguishedFromTrap() throws {
        let verdict = try proveSigned(widths: [16]) { v in v[0] &* v[0].literal(2) > v[0] }
        guard case .claimFails(let values) = verdict else { Issue.record("expected claimFails, got \(verdict)"); return }
        let x = Int16(values[0])
        #expect(!(x &* 2 > x))
    }

    /// Branch guards: a trap in the branch that is not taken does not count.
    @Test func trapInUntakenBranchIsIgnored() throws {
        let verdict = try proveSigned(widths: [16, 16]) { v in
            let (a, b) = (v[0], v[1])
            let guarded = (b > 0).then(a / b, else: a)
            return guarded == guarded
        }
        #expect(verdict == .proved)
        let unguarded = try proveSigned(widths: [16, 16]) { v in (v[0] / v[1]) == (v[0] / v[1]) }
        guard case .mayTrap(let values) = unguarded else { Issue.record("expected mayTrap"); return }
        #expect(values[1] == 0 || (values[0] == Int64(Int16.min) && values[1] == -1))
    }

    /// Discount: `price - price * percent / 100`. Overflows without a range; proved with one.
    @Test func discountNeedsARangeAndThenIsProved() throws {
        let body: ([SymbolicInt]) -> SymbolicBool = { v in
            let (price, percent) = (v[0], v[1])
            let result = price - price * percent / 100
            return result >= 0 && result <= price
        }
        let open = try proveSigned(widths: [16, 16], claim: body)
        guard case .mayTrap = open else { Issue.record("expected mayTrap, got \(open)"); return }

        let ranged = try proveSigned(
            widths: [16, 16],
            requires: { $0[0] >= 0 && $0[0] <= 300 && $0[1] >= 0 && $0[1] <= 100 },
            claim: body
        )
        #expect(ranged == .proved)
    }
}

private extension SymbolicInt {
    func isNegativeThen(_ whenNegative: @autoclosure () -> SymbolicInt, else other: @autoclosure () -> SymbolicInt) -> SymbolicInt {
        (self < 0).then(whenNegative(), else: other())
    }
}
