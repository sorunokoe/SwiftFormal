import SwiftFormalTesting
import Testing

/// `price - price * percent / 100` stays between 0 and the price, for every 16-bit price of 0...300 and percent of
/// 0...100: proved for all of them at once, on a copy of the formula written with `SymbolicInt`.
@Test func discountStaysInRange() throws {
    let verdict = try proveSigned(
        widths: [16, 16],
        requires: { $0[0] >= 0 && $0[0] <= 300 && $0[1] >= 0 && $0[1] <= 100 }
    ) { v in
        let result = v[0] - v[0] * v[1] / 100
        return result >= 0 && result <= v[0]
    }
    #expect(verdict == .proved, "\(verdict)")
}
