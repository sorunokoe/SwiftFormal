import Shop
import Testing

@Test func discountStaysInRange() {
    #expect(verify_discounted().isProved)
}

/// A getter has no inputs to walk, so `@Verify` writes no `verify_label()`: `swiftformal check` proves its promise.
/// `label_ensures` is the promise as `@Verify` wrote it, callable like any function.
@Test func theBasketLabelKeepsItsPromise() {
    #expect(Basket(items: 0).label == "Empty basket")
    #expect(Basket(items: 2).label_ensures("Basket"))
}
