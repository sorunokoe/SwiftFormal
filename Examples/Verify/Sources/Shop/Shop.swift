import SwiftFormal

/// The price after a discount. The promise: never negative, never more than the price.
@Verify(over: .product(.int(0...1_000), .int(0...100)))
public func discounted(price: Int, percent: Int) -> Int {
    #requires(price >= 0 && price <= 1_000_000 && percent >= 0 && percent <= 100)
    #ensures { $0 >= 0 && $0 <= price }
    return price - price * percent / 100
}

/// A basket of the shop. A computed property keeps its promise in the getter, the same way.
public struct Basket {
    public var items: Int

    public init(items: Int) { self.items = items }

    @Verify
    public var label: String {
        #ensures { !$0.isEmpty }
        items == 0 ? "Empty basket" : "Basket"
    }
}
