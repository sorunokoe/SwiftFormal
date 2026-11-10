import SFBV
import SFProve
import SwiftFormal
import Testing

/// The classic traps, as claims a person might plausibly write. Each is labelled with its truth; see `Truth`.
enum Zoo {
    static let int32Min = Int(Int32.min)

    static let walkCases: [ZooCase] = [
        // Off-by-one at the top of the range: `x + 1 > x` traps at Int.max.
        walk("x + 1 > x near Int.max", .falseClaim, over: .int((Int.max - 4)...Int.max)) { x in
            let (next, overflow) = x.addingReportingOverflow(1)
            return !overflow && next > x
        },
        // abs(Int.min) has no representable answer.
        walk("abs(x) >= 0 near Int.min", .falseClaim, over: .union([.int(Int.min...Int.min + 3), .int(-3...3)])) { x in
            if x >= 0 { return true }
            let (negated, overflow) = (0).subtractingReportingOverflow(x)
            return !overflow && negated >= 0
        },
        walk("abs(x) >= 0 away from Int.min", .trueClaim, over: .int(-4...4)) { x in
            let (negated, overflow) = (0).subtractingReportingOverflow(x)
            return !overflow && (x >= 0 ? x : negated) >= 0
        },
        // Signed and unsigned orderings disagree as soon as the top bit is set.
        walk("a < b is the same signed and unsigned", .falseClaim, over: .product(.int(-3...3), .int(-3...3))) { pair in
            (pair.0 < pair.1) == (UInt(bitPattern: pair.0) < UInt(bitPattern: pair.1))
        },
        // Swift's `<<` on a shift amount of at least the width gives 0, not a masked shift.
        walk("1 << n is never 0", .falseClaim, over: .int(0...70)) { n in (1 as UInt32) << n != 0 },
        walk("1 << n is never 0 for n < 32", .trueClaim, over: .int(0...31)) { n in (1 as UInt32) << n != 0 },
        // INT_MIN / -1 overflows; division by zero traps. Int8 keeps the domain complete (65,280 pairs).
        walk(
            "a / b never overflows (Int8, b != 0)", .falseClaim,
            over: Domain<(Int, Int)>.product(.int(-128...127), .int(-128...127)).filter { $0.1 != 0 }
        ) { pair in
            !Int8(pair.0).dividedReportingOverflow(by: Int8(pair.1)).overflow
        },
        // The midpoint bug: (a + b) / 2 overflows for large operands.
        walk("(a + b) / 2 is between a and b (Int8)", .falseClaim, over: .product(.int(-128...127), .int(-128...127))) { pair in
            let (a, b) = (Int8(pair.0), Int8(pair.1))
            let (sum, overflow) = a.addingReportingOverflow(b)
            return !overflow && sum / 2 >= min(a, b) && sum / 2 <= max(a, b)
        },
        walk("a * b does not overflow (Int8)", .falseClaim, over: .product(.int(-128...127), .int(-128...127))) { pair in
            !Int8(pair.0).multipliedReportingOverflow(by: Int8(pair.1)).overflow
        },
        // A truncating conversion only round-trips inside the target's range.
        walk("Int(Int8(truncatingIfNeeded: x)) == x", .falseClaim, over: .int(-300...300)) { x in Int(Int8(truncatingIfNeeded: x)) == x },
        walk("Int(Int8(truncatingIfNeeded: x)) == x in range", .trueClaim, over: .int(-128...127)) { x in
            Int(Int8(truncatingIfNeeded: x)) == x
        },
        // Unsigned wrap-around.
        walk("a &+ b >= a (UInt8)", .falseClaim, over: .product(.int(0...255), .int(0...255))) { pair in
            UInt8(pair.0) &+ UInt8(pair.1) >= UInt8(pair.0)
        },
        walk("a &+ b == b &+ a (UInt8)", .trueClaim, over: .product(.int(0...255), .int(0...255))) { pair in
            UInt8(pair.0) &+ UInt8(pair.1) == UInt8(pair.1) &+ UInt8(pair.0)
        },
        walk("x & (x - 1) clears the lowest set bit (UInt8)", .trueClaim, over: .int(1...255)) { n in
            let x = UInt8(n)
            return (x & (x &- 1)).nonzeroBitCount == x.nonzeroBitCount - 1
        },
        // The empty collection.
        walk("an array has a maximum", .falseClaim, over: .arrays(of: .int(0...2), maxLength: 3)) { xs in xs.max() != nil },
        // Floating point: NaN is not equal to itself and 1 / -0.0 is negative infinity.
        walk("x == x for a Double", .falseClaim, over: .of([0.0, -0.0, 1.5, -2.0, .infinity, .nan])) { x in x == x },
        walk("1 / x > 0 when x == 0", .falseClaim, over: .of([0.0, -0.0, 1.5])) { x in x != 0 || 1 / x > 0 },
        // One bad input in a big domain: a complete walk finds it; a sample may not, and must then not say proved.
        walk("one bad input among 200,000 (complete walk)", .falseClaim, over: .int(0...199_999)) { x in x != 123_457 },
        walk(
            "one bad input among 200,000 (1,000-evaluation budget)", .falseClaimBeyondBudget, over: .int(0...199_999),
            budget: Budget(maxEvaluations: 1_000, seed: 1)
        ) { x in x != 123_457 },
        walk("one bad input in an evenly spaced sample", .falseClaimBeyondBudget, over: Domain.int(0...9_999).evenlySpaced(100)) { x in
            x != 4_321
        },
        walk(
            "a large product against a small budget", .falseClaimBeyondBudget, over: .product(.int(0...999), .int(0...999)),
            budget: Budget(maxEvaluations: 5_000, seed: 7)
        ) { pair in
            !(pair.0 == 999 && pair.1 == 999)
        },
        walk(
            "a true claim over a sample is not refuted", .trueClaimBeyondBudget, over: .int(0...199_999),
            budget: Budget(maxEvaluations: 1_000, seed: 3)
        ) { x in x &* 2 == x &+ x },
    ]

    static let signedA: [ZooCase] = [
        signed("x + 1 > x", .falseClaim, widths: [32], claim: { v in v[0] + 1 > v[0] }) { v in
            let (next, overflow) = v[0].addingReportingOverflow(1)
            return overflow || !(next > v[0])
        },
        signed("abs(x) >= 0", .falseClaim, widths: [32], claim: { v in (v[0] < 0).then(-v[0], else: v[0]) >= 0 }) { v in
            v[0] == .min
        },
        signed(
            "abs(x) >= 0 when x > Int32.min", .trueClaim, widths: [32], requires: { v in v[0] > int32Min },
            claim: { v in
                (v[0] < 0).then(-v[0], else: v[0]) >= 0
            }
        ) { _ in false },
    ]

    static let signedB: [ZooCase] = [
        signed(
            "(a + b) / 2 is between a and b when a <= b", .falseClaim, requires: { v in v[0] <= v[1] },
            claim: { v in
                let mid = (v[0] + v[1]) / 2
                return mid >= v[0] && mid <= v[1]
            }
        ) { v in v[0] <= v[1] && v[0].addingReportingOverflow(v[1]).overflow },
        signed(
            "a + (b - a) / 2 is between a and b when 0 <= a <= b", .trueClaim, widths: [16, 16],
            requires: { v in v[0] >= 0 && v[0] <= v[1] },
            claim: { v in
                let mid = v[0] + (v[1] - v[0]) / 2
                return mid >= v[0] && mid <= v[1]
            }
        ) { _ in false },
    ]

    static let signedC: [ZooCase] = [
        signed(
            "clamp stays within [lo, hi] when lo <= hi", .trueClaim, widths: [16, 16, 16], requires: { v in v[1] <= v[2] },
            claim: { v in
                let clamped = (v[0] < v[1]).then(v[1], else: (v[0] > v[2]).then(v[2], else: v[0]))
                return clamped >= v[1] && clamped <= v[2]
            }
        ) { _ in false },
        // Division circuits are hard for the solver, so these cases use narrow widths (5 and 8 bits); the replay is on Int8.
        signed(
            "x / y * y == x (5 bits)", .falseClaim, widths: [5, 5], requires: { v in v[1] != 0 && v[1] != -1 },
            claim: { v in v[0] / v[1] * v[1] == v[0] }
        ) { v in
            let (x, y) = (Int8(truncatingIfNeeded: v[0]), Int8(truncatingIfNeeded: v[1]))
            return y != 0 && y != -1 && x / y &* y != x
        },
    ]

    static let signedD: [ZooCase] = [
        signed("x / y is defined (8 bits)", .falseClaim, widths: [8, 8], claim: { v in v[0] / v[1] == v[0] / v[1] }) { v in
            let (x, y) = (Int8(truncatingIfNeeded: v[0]), Int8(truncatingIfNeeded: v[1]))
            return y == 0 || (x == .min && y == -1)
        }
    ]

    static let signedE: [ZooCase] = [
        signed(
            "INT_MIN / -1 (8 bits)", .falseClaim, widths: [8, 8], requires: { v in v[1] != 0 }, claim: { v in v[0] / v[1] == v[0] / v[1] }
        ) { v in
            let (x, y) = (Int8(truncatingIfNeeded: v[0]), Int8(truncatingIfNeeded: v[1]))
            return y != 0 && x == .min && y == -1
        },
        signed(
            "a * b / b == a (8 bits)", .falseClaim, widths: [8, 8], requires: { v in v[1] != 0 }, claim: { v in v[0] * v[1] / v[1] == v[0] }
        ) { v in
            let (x, y) = (Int8(truncatingIfNeeded: v[0]), Int8(truncatingIfNeeded: v[1]))
            return y != 0 && (x.multipliedReportingOverflow(by: y).overflow || (x &* y == .min && y == -1))
        },
    ]

    static let signedF: [ZooCase] = [
        signed("a - b is smaller than a when b > 0", .falseClaim, requires: { v in v[1] > 0 }, claim: { v in v[0] - v[1] < v[0] }) { v in
            v[1] > 0 && v[0].subtractingReportingOverflow(v[1]).overflow
        },
        signed(
            "a - b is smaller than a when b > 0 and a >= 0", .trueClaim, requires: { v in v[1] > 0 && v[0] >= 0 },
            claim: { v in v[0] - v[1] < v[0] }
        ) { _ in false },
    ]

    static let bitCases: [ZooCase] = [
        bits(
            "a < b is the same signed and unsigned (32 bits)", .falseClaim, widths: [32, 32],
            claim: { c, v in
                c.eq(BV(bits: [c.ult(v[0], v[1])]), BV(bits: [c.slt(v[0], v[1])]))
            }
        ) { v in
            (UInt32(truncatingIfNeeded: v[0]) < UInt32(truncatingIfNeeded: v[1]))
                != (Int32(truncatingIfNeeded: v[0]) < Int32(truncatingIfNeeded: v[1]))
        },
        bits("a &+ b >= a (UInt32)", .falseClaim, widths: [32, 32], claim: { c, v in c.ule(v[0], c.add(v[0], v[1]).sum) }) { v in
            UInt32(truncatingIfNeeded: v[0]) &+ UInt32(truncatingIfNeeded: v[1]) < UInt32(truncatingIfNeeded: v[0])
        },
        // Swift's `<<` gives 0 for an amount of at least the width (it is not masked): model that, then claim the result is never 0.
        bits(
            "1 << n is never 0 (UInt32, n up to 2^32)", .falseClaim, widths: [32],
            claim: { c, v in
                let one = c.constant(1, width: 32)
                let shifted = c.select(c.shiftAmountOutOfRange(one, v[0]), c.constant(0, width: 32), c.shiftLeft(one, by: v[0]))
                return -c.eq(shifted, c.constant(0, width: 32))
            }
        ) { v in (1 as UInt32) << UInt32(truncatingIfNeeded: v[0]) == 0 },
        bits(
            "a &+ b == b &+ a (UInt32)", .trueClaim, widths: [32, 32], claim: { c, v in c.eq(c.add(v[0], v[1]).sum, c.add(v[1], v[0]).sum) }
        ) { _ in false },
        bits(
            "a < b implies a <= b (unsigned, 32 bits)", .trueClaim, widths: [32, 32],
            claim: { c, v in c.or(-c.ult(v[0], v[1]), c.ule(v[0], v[1])) }
        ) { _ in false },
        // A conflict budget of 1 gives the solver no room: the verdict is `unknown`, and `unknown` is never a proof.
        bits(
            "a * b == b * a (UInt16) with a conflict budget of 1", .trueClaimBeyondBudget, widths: [16, 16], conflictBudget: 1,
            claim: { c, v in
                c.eq(c.mul(v[0], v[1]), c.mul(v[1], v[0]))
            }
        ) { _ in false },
        bits(
            "a * b == b * a + 1 (UInt16) with a conflict budget of 1", .falseClaimBeyondBudget, widths: [16, 16], conflictBudget: 1,
            claim: { c, v in
                c.eq(c.mul(v[0], v[1]), c.add(c.mul(v[1], v[0]), c.constant(1, width: 16)).sum)
            }
        ) { v in
            UInt16(truncatingIfNeeded: v[0]) &* UInt16(truncatingIfNeeded: v[1]) != UInt16(truncatingIfNeeded: v[1])
                &* UInt16(truncatingIfNeeded: v[0]) &+ 1
        },
    ]

    static let signedCases: [ZooCase] = signedA + signedB + signedC + signedD + signedE + signedF

    static let all: [ZooCase] = walkCases + signedCases + bitCases
}

@Suite struct SoundnessZooTests {
    @Test(arguments: Zoo.all)
    func noWrongClaimIsEverProvedAndEveryRefutationReplays(_ zooCase: ZooCase) throws {
        let answer = try zooCase.run()
        if let problem = judge(zooCase.truth, answer) {
            Issue.record("\(zooCase.name): \(problem) (answer: \(answer))")
        }
    }

    /// The harness must itself be hard to fool: a fake `proved` on a wrong claim, or an unreplayable counterexample, is a failure.
    @Test func theJudgeRejectsAFakeProofAndAFakeCounterexample() {
        #expect(judge(.falseClaim, .proved) != nil)
        #expect(judge(.falseClaimBeyondBudget, .proved) != nil)
        #expect(judge(.falseClaim, .refuted(replays: false)) != nil)
        #expect(judge(.trueClaim, .refuted(replays: true)) != nil)
        #expect(judge(.trueClaim, .inconclusive("unknown")) != nil)
        #expect(judge(.falseClaim, .inconclusive("unknown")) != nil)
        #expect(judge(.falseClaim, .refuted(replays: true)) == nil)
        #expect(judge(.trueClaim, .proved) == nil)
        #expect(judge(.falseClaimBeyondBudget, .inconclusive("bounded")) == nil)
    }

    /// The zoo holds wrong claims for each tool and true controls: a zoo with only one kind would prove nothing.
    @Test func theZooHasWrongClaimsAndTrueControlsForEveryTool() {
        for prefix in ["Walk:", "Prove (signed):", "Prove (bits):"] {
            let cases = Zoo.all.filter { $0.name.hasPrefix(prefix) }
            #expect(cases.contains { if case .falseClaim = $0.truth { true } else { false } }, "\(prefix) has no wrong claim")
            #expect(cases.contains { if case .trueClaim = $0.truth { true } else { false } }, "\(prefix) has no true control")
        }
        #expect(Set(Zoo.all.map(\.name)).count == Zoo.all.count, "case names must be unique")
    }

    /// A tool that wrongly proves everything is caught by the zoo: here a deliberately broken tool is run through the judge.
    @Test func aToolThatProvesEverythingFailsTheZoo() {
        let wrongClaims = Zoo.all.filter { if case .falseClaim = $0.truth { true } else { false } }
        #expect(wrongClaims.count >= 15)
        #expect(wrongClaims.allSatisfy { judge($0.truth, .proved) != nil })
    }
}
