import Shipping
import SwiftFormal
import SwiftFormalTesting
import Testing

@Test func everySpeedHasItsLabel() {
    Prove(it: { label(for: $0) }, over: .allCases) {
        Deterministic()
        Matches(table: [
            .standard: "Standard (3-5 days)",
            .express: "Express (1-2 days)",
            .overnight: "Overnight",
        ])
        Satisfies("never blank") { _, text in !text.isEmpty }
    }
}

@Test func everyTapKeepsTheBasketInRange() {
    Prove(it: { BasketReducer().reduce(into: &$0, action: $1) }, over: .sessions(from: Basket(), actions: .allCases, upTo: 4)) {
        Always("1 to 9 items") { (1...9).contains($0.quantity) }
    }
}

/// The function and its inputs, as a type: the walk runs in a child process, so a trap fails only that walk.
enum DeliveryDays: ExitTestWalk {
    static let inputs: Domain<Int> = .int(0...2)
    static func call(_ index: Int) -> Int { deliveryDays(index) }
}

@Test func deliveryDaysNeverTraps() async {
    await Prove(neverTraps: DeliveryDays.self)
}
