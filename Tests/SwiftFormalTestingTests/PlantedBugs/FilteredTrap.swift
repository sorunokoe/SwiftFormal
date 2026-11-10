// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 2: a trap in a branch that only a filtering caller avoids.

enum Payment: CaseIterable {
    case card, cash, voucher, refund
}

/// Callers drop refunds first, but nothing says so: alone, `.refund` traps.
func feePercentBuggy(_ payment: Payment) -> Int8 {
    switch payment {
    case .card: 2
    case .cash: 0
    case .voucher: 1
    case .refund: fatalError("refunds are filtered out by the caller")
    }
}

/// The same body, with the caller's filter written as a precondition.
func feePercentFixed(_ payment: Payment) -> Int8 {
    switch payment {
    case .card: 2
    case .cash: 0
    case .voucher: 1
    case .refund: fatalError("refunds are filtered out by the caller")
    }
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs15feePercentFixed6VerifyfMp_.swift", line: 1)
func feePercentFixed_requires(_ payment: Payment) -> Bool { payment != .refund }
#sourceLocation()

/// The filtering caller: it never passes a refund on.
func fee(for payment: Payment) -> Int8 { payment == .refund ? 0 : feePercentFixed(payment) }
