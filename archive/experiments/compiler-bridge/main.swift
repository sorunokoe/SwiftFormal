let arguments = CommandLine.arguments
guard arguments.count == 4,
    let a = Int64(arguments[2]),
    let b = Int64(arguments[3])
else {
    fatalError("Expected operation and two Int64 arguments")
}

switch arguments[1] {
case "clamped":
    print(clampedDiscount(a, b))
case "raw":
    print(rawDiscount(a, b))
case "zero":
    print(alwaysZero(a, b))
case "increment":
    print(increment(a))
case "wrapping":
    print(wrappingIncrement(a))
case "effectful":
    print(effectfulDiscount(a, b))
case "custom":
    print(customSubtract(Amount(a), Amount(b)))
default:
    fatalError("Unknown operation")
}
