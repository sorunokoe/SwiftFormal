import Shop
import Testing

@Test func discountStaysInRange() {
    #expect(verify_discounted().isProved)
}

@Test func theBasketLabelKeepsItsPromise() {
    #expect(Basket(items: 0).label == "Empty basket")
    #expect(Basket(items: 2).label_ensures("Basket"))
}
