import SwiftFormal
import Testing

// `import SwiftFormal` alone gives the macros (`@Verify`, `#requires`, `#ensures`, `@Finite`, `@Values`) and
// `ContractChecks`; pre-release builds needed `import SwiftFormalContracts` for them, a module that no longer exists.

@Finite private struct Order {
    @Values(.int(0...3)) var quantity: Int
    var express: Bool
}

@Verify(checks: .always)
private func shippingDays(_ order: Order) -> Int {
    #requires(order.quantity >= 0)
    #ensures { $0 >= 1 && $0 <= 5 }
    order.express ? 1 : 2 + order.quantity
}

@Suite struct OneImportTests {
    @Test func theMacrosComeWithImportSwiftFormal() {
        let report = verify_shippingDays()
        #expect(report.isProved, "\(report)")
        #expect(report.evaluated == 8)
        #expect(shippingDays_requires(Order(quantity: 2, express: false)))
        #expect(shippingDays_ensures(Order(quantity: 3, express: false), 5))
        let checks: ContractChecks = .debugOnly
        #expect(checks != .always)
    }
}
