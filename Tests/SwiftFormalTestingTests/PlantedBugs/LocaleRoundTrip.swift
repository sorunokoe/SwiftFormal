// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 3: parse(format(x)) != x for one locale (the decimal separator).

import Foundation

struct Price: Equatable {
    var cents: Int
    var localeID: String
}

struct PriceText: Equatable {
    var text: String
    var localeID: String
}

/// "12.34" in English, "12,34" in German.
func formatPrice(_ price: Price) -> PriceText {
    let separator = Locale(identifier: price.localeID).decimalSeparator ?? "."
    let fraction = price.cents % 100
    let text = "\(price.cents / 100)\(separator)\(fraction < 10 ? "0" : "")\(fraction)"
    return PriceText(text: text, localeID: price.localeID)
}

/// Splits on "." whatever the locale: German text does not read back.
func parsePriceBuggy(_ price: PriceText) -> Price? {
    let parts = price.text.split(separator: ".")
    guard parts.count == 2, let whole = Int(parts[0]), let fraction = Int(parts[1]) else { return nil }
    return Price(cents: whole * 100 + fraction, localeID: price.localeID)
}

func parsePriceFixed(_ price: PriceText) -> Price? {
    let separator = Locale(identifier: price.localeID).decimalSeparator ?? "."
    let parts = price.text.split(separator: Character(separator))
    guard parts.count == 2, let whole = Int(parts[0]), let fraction = Int(parts[1]) else { return nil }
    return Price(cents: whole * 100 + fraction, localeID: price.localeID)
}

/// The round trip as one function, for Scan: the cents read back from the text of `cents`.
func priceRoundTripBuggy(_ cents: Int, _ localeID: String) -> Int? {
    parsePriceBuggy(formatPrice(Price(cents: cents, localeID: localeID)))?.cents
}

func priceRoundTripFixed(_ cents: Int, _ localeID: String) -> Int? {
    parsePriceFixed(formatPrice(Price(cents: cents, localeID: localeID)))?.cents
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs19priceRoundTripBuggy6VerifyfMp_.swift", line: 1)
func priceRoundTripBuggy_requires(_ cents: Int, _ localeID: String) -> Bool { cents >= 0 && cents <= 100_000 }
func priceRoundTripBuggy_ensures(_ cents: Int, _ localeID: String, _ result: Int?) -> Bool { result == cents }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs19priceRoundTripFixed6VerifyfMp_.swift", line: 1)
func priceRoundTripFixed_requires(_ cents: Int, _ localeID: String) -> Bool { cents >= 0 && cents <= 100_000 }
func priceRoundTripFixed_ensures(_ cents: Int, _ localeID: String, _ result: Int?) -> Bool { result == cents }
#sourceLocation()
