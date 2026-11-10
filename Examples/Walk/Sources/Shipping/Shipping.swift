public enum Speed: CaseIterable, Sendable {
    case standard, express, overnight
}

/// The label shown at checkout for each delivery speed.
public func label(for speed: Speed) -> String {
    switch speed {
    case .standard: "Standard (3-5 days)"
    case .express: "Express (1-2 days)"
    case .overnight: "Overnight"
    }
}

/// The basket screen's state: how many items the customer picked.
public struct Basket: Equatable, Sendable {
    public var quantity = 1

    public init() {}
}

/// What the basket screen's buttons send.
public enum BasketAction: CaseIterable, Sendable {
    case add, remove
}

/// Applies one button tap to the basket: between 1 and 9 items.
public struct BasketReducer {
    public init() {}

    public func reduce(into basket: inout Basket, action: BasketAction) {
        switch action {
        case .add: basket.quantity = min(basket.quantity + 1, 9)
        case .remove: basket.quantity = max(basket.quantity - 1, 1)
        }
    }
}

/// The delivery days of a speed, by its index in the checkout list.
public func deliveryDays(_ index: Int) -> Int {
    [5, 2, 1][index]
}
