import Testing
import SFBV
import SFProve

@Suite struct NarrowingTests {
    /// Two 32-bit signed values multiplied at 64 bits can never overflow. The range is in the circuit, so no
    /// multiplier is built and the proof is immediate.
    @Test func product32x32CannotOverflowAt64Bits() throws {
        let c = CNFBuilder()
        let x = c.input(width: 64, signedBits: 32), y = c.input(width: 64, signedBits: 32)
        #expect(c.signedMulOverflows(x, y) == c.falseLit)
        #expect(c.signedMulOverflows(x, y, narrowing: false) != c.falseLit)

        let verdict = try prove(inputWidths: [32, 32]) { c, v in
            let (a, b) = (c.signExtend(v[0], to: 64), c.signExtend(v[1], to: 64))
            return -c.signedMulOverflows(a, b)
        }
        #expect(verdict == .proved)
    }

    /// 33x32 bits can overflow, and the solver must find a replayable witness.
    @Test func product33x32CanOverflowAt64Bits() throws {
        let verdict = try prove(inputWidths: [33, 32]) { c, v in
            let (a, b) = (c.signExtend(v[0], to: 64), c.signExtend(v[1], to: 64))
            return -c.signedMulOverflows(a, b)
        }
        guard case .counterexample(let values) = verdict else { Issue.record("expected counterexample"); return }
        let x = Int64(Int33Sign(values[0])), y = Int64(Int32(truncatingIfNeeded: values[1]))
        #expect(x.multipliedReportingOverflow(by: y).overflow)
    }

    /// Narrowed and plain circuits agree for every operation, proved symbolically for narrow-range inputs.
    @Test func narrowedCircuitsEqualPlainCircuits() throws {
        for (n, ka, kb) in [(12, 5, 4), (8, 4, 5), (8, 3, 6), (7, 1, 7), (10, 6, 3)] {
            let verdict = try prove(inputWidths: [ka, kb]) { c, v in
                let (a, b) = (c.signExtend(v[0], to: n), c.signExtend(v[1], to: n))
                let checks = [
                    c.eq(c.mul(a, b), c.mul(a, b, narrowing: false)),
                    -c.xor(c.signedMulOverflows(a, b), c.signedMulOverflows(a, b, narrowing: false)),
                    c.eq(c.addSigned(a, b), c.add(a, b).sum),
                    c.eq(c.subSigned(a, b), c.sub(a, b).difference),
                    -c.xor(c.signedAddOverflows(a, b), c.signedAddOverflows(a, b, narrowing: false)),
                    -c.xor(c.signedSubOverflows(a, b), c.signedSubOverflows(a, b, narrowing: false)),
                ]
                return checks.dropFirst().reduce(checks[0]) { c.and($0, $1) }
            }
            #expect(verdict == .proved, "n=\(n) ka=\(ka) kb=\(kb)")
        }
    }

    /// Chained adds keep the narrow range, so a later multiply stays small.
    @Test func rangePropagatesThroughAdds() {
        let c = CNFBuilder()
        let a = c.input(width: 64, signedBits: 16), b = c.input(width: 64, signedBits: 16)
        let sum = c.addSigned(a, b)
        #expect(c.signedWidth(sum) <= 17)
        let product = c.mul(sum, sum)
        #expect(c.signedWidth(product) <= 34)
    }
}

private func Int33Sign(_ v: UInt64) -> Int64 {
    let low = v & ((1 << 33) - 1)
    return low >= (1 << 32) ? Int64(low) - (1 << 33) : Int64(low)
}
