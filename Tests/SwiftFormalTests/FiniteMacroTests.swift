import SwiftFormal
import Testing

@Finite enum Plan { case free, pro }

@Finite enum Payment: Equatable {
    case cash
    case card(Plan)
    case voucher(code: Bool, plan: Plan?)
}

@Finite private struct Order {
    @Values(.int(0...3)) var quantity: Int
    var express: Bool
    var payment: Payment
    var note = "default"
}

@Finite struct Empty {}

@Suite struct FiniteMacroTests {
    @Test func enumWithoutPayloadsListsItsCases() {
        #expect(Plan.domain.count == 2)
        #expect(Plan.domain.complete)
    }

    @Test func payloadEnumIsTheUnionOfItsCases() {
        // cash (1) + card (2) + voucher (2 * 3)
        #expect(Payment.domain.count == 1 + 2 + 6)
        let all = (0..<Payment.domain.count).map { Payment.domain[$0] }
        #expect(all.contains(.cash))
        #expect(all.contains(.card(.pro)))
        #expect(all.contains(.voucher(code: true, plan: nil)))
        #expect(Set(all.map { "\($0)" }).count == all.count)
    }

    @Test func structIsTheProductOfItsFields() {
        // quantity 4 * express 2 * payment 9
        #expect(Order.domain.count == 4 * 2 * 9)
        #expect(Order.domain.complete)
        #expect(Order.domain[0].note == "default")
        let quantities = Set((0..<Order.domain.count).map { Order.domain[$0].quantity })
        #expect(quantities == [0, 1, 2, 3])
    }

    @Test func emptyStructHasOneValue() {
        #expect(Empty.domain.count == 1)
    }

    @Test func derivedDomainsFeedVerify() {
        let report = runWalk("express orders never lose items", { (order: Order) in order.quantity }) {
            Property.satisfies("non-negative") { _, quantity in quantity >= 0 }
        }
        #expect(report.isProved)
        #expect(report.evaluated == 72)
    }
}
