// Planted-bug suite, shape 15: mapped correctly. Each broken mapper is wrong only on a pair of inputs, or one input,
// that a sampled walk does not reach: a packed code where two inputs collide, a decoder that loses a rare value, a rule
// that disagrees with its sibling at one boundary, and a text rule that shows its raw key. Logic proves the first three
// claims for every input (`Injective`, `RoundTrip`, `Agrees` in `swiftformal check`); the walk catches the raw key.

import Foundation

struct Seat: Equatable {
    var row: UInt8
    var number: UInt8
}

/// The row is shifted by 7 bits, not 8: seat 128 of a row has the code of seat 0 of the next row.
func seatCodeBroken(_ seat: Seat) -> UInt16 {
    UInt16(seat.row) << 7 | UInt16(seat.number)
}

func seatCodeFixed(_ seat: Seat) -> UInt16 {
    UInt16(seat.row) << 8 | UInt16(seat.number)
}

struct Card: Equatable {
    var strokes: UInt8
    var putts: UInt8
}

func cardCode(_ card: Card) -> UInt16 {
    UInt16(card.strokes) << 8 | UInt16(card.putts)
}

/// Putts above 99 are read back as 99: no real card has them, but a corrupt one does.
func cardFromCodeBroken(_ code: UInt16) -> Card {
    let putts = UInt8(truncatingIfNeeded: code)
    return Card(strokes: UInt8(truncatingIfNeeded: code >> 8), putts: putts > 99 ? 99 : putts)
}

func cardFromCodeFixed(_ code: UInt16) -> Card {
    Card(strokes: UInt8(truncatingIfNeeded: code >> 8), putts: UInt8(truncatingIfNeeded: code))
}

enum Band: Equatable {
    case low, middle, high
}

/// The rule the others must agree with: below 10 is low, up to and including 20 is middle.
func bandReference(_ rating: Int8) -> Band {
    rating < 10 ? .low : rating <= 20 ? .middle : .high
}

/// Rewritten with `<` where the reference has `<=`: a rating of exactly 20 is high.
func bandBroken(_ rating: Int8) -> Band {
    if rating <= 9 { return .low }
    if rating < 20 { return .middle }
    return .high
}

func bandFixed(_ rating: Int8) -> Band {
    if rating <= 9 { return .low }
    if rating < 21 { return .middle }
    return .high
}

enum Weather: CaseIterable {
    case sunny, cloudy, rainy
}

/// The rainy case returns its key, not the text the key stands for.
func weatherTextBroken(_ weather: Weather) -> String {
    switch weather {
    case .sunny: NSLocalizedString("weather.sunny", value: "Sunny", comment: "")
    case .cloudy: NSLocalizedString("weather.cloudy", value: "Cloudy", comment: "")
    case .rainy: "weather.rainy"
    }
}

func weatherTextFixed(_ weather: Weather) -> String {
    switch weather {
    case .sunny: NSLocalizedString("weather.sunny", value: "Sunny", comment: "")
    case .cloudy: NSLocalizedString("weather.cloudy", value: "Cloudy", comment: "")
    case .rainy: NSLocalizedString("weather.rainy", value: "Rainy", comment: "")
    }
}
