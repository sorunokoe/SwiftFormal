public func clampedDiscount(_ subtotal: Int64, _ discount: Int64) -> Int64 {
    if discount > subtotal {
        return 0
    }
    return subtotal - discount
}

public func rawDiscount(_ subtotal: Int64, _ discount: Int64) -> Int64 {
    subtotal - discount
}

public func alwaysZero(_ subtotal: Int64, _ discount: Int64) -> Int64 {
    0
}

public func increment(_ value: Int64) -> Int64 {
    value + 1
}

public func wrappingIncrement(_ value: Int64) -> Int64 {
    value &+ 1
}

public func effectfulDiscount(_ subtotal: Int64, _ discount: Int64) -> Int64 {
    print("effect")
    return clampedDiscount(subtotal, discount)
}

public struct Amount {
    public let value: Int64

    public init(_ value: Int64) {
        self.value = value
    }

    public static func - (lhs: Amount, rhs: Amount) -> Amount {
        Amount(42)
    }
}

public func customSubtract(_ lhs: Amount, _ rhs: Amount) -> Int64 {
    (lhs - rhs).value
}
