// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 14: Foundation values in a mapper. A struct with two `UUID`s whose mapper swaps them, a
// tie rounded the wrong way, a "-0" from rounding, a NaN that slips past a range check, a due date one day early, and
// a `Decimal` sum that a `Double` model would get wrong.

import Foundation

struct Booking {
    let id: UUID
    let guestID: UUID
    let link: URL
    let seats: Int8
}

struct BookingRow: Equatable {
    let id: UUID
    let guestID: UUID
    let link: URL
    let seats: Int8
}

/// The planted bug swaps the booking's id and the guest's.
func bookingRowBuggy(_ booking: Booking) -> BookingRow {
    BookingRow(id: booking.guestID, guestID: booking.id, link: booking.link, seats: booking.seats)
}

func bookingRowFixed(_ booking: Booking) -> BookingRow {
    BookingRow(id: booking.id, guestID: booking.guestID, link: booking.link, seats: booking.seats)
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs15bookingRowBuggy6VerifyfMp_.swift", line: 1)
func bookingRowBuggy_ensures(_ booking: Booking, _ row: BookingRow) -> Bool {
    row.id == booking.id && row.guestID == booking.guestID && row.link == booking.link
}
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs15bookingRowFixed6VerifyfMp_.swift", line: 1)
func bookingRowFixed_ensures(_ booking: Booking, _ row: BookingRow) -> Bool {
    row.id == booking.id && row.guestID == booking.guestID && row.link == booking.link
}
#sourceLocation()

/// Needs what is inside the URL: never proved, whatever the mapper does.
func bookingLinkText(_ booking: Booking) -> String { booking.link.absoluteString }
#sourceLocation(file: "@__swiftmacro_11PlantedBugs15bookingLinkText6VerifyfMp_.swift", line: 1)
func bookingLinkText_ensures(_ booking: Booking, _ text: String) -> Bool { !text.isEmpty }
#sourceLocation()

/// Half points round up (2.5 is 3), the house rule. The planted bug rounds ties to even, so 2.5 is 2.
func halfPointsBuggy(_ points: Double) -> Double { points.rounded(.toNearestOrEven) }
func halfPointsFixed(_ points: Double) -> Double { points.rounded() }

#sourceLocation(file: "@__swiftmacro_11PlantedBugs15halfPointsBuggy6VerifyfMp_.swift", line: 1)
func halfPointsBuggy_requires(_ points: Double) -> Bool { points >= 0 && points <= 1_000 }
func halfPointsBuggy_ensures(_ points: Double, _ result: Double) -> Bool {
    result == points.rounded(.toNearestOrAwayFromZero)
}
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs15halfPointsFixed6VerifyfMp_.swift", line: 1)
func halfPointsFixed_requires(_ points: Double) -> Bool { points >= 0 && points <= 1_000 }
func halfPointsFixed_ensures(_ points: Double, _ result: Double) -> Bool {
    result == points.rounded(.toNearestOrAwayFromZero)
}
#sourceLocation()

/// Rounds half away from zero, also below zero. The planted bug is `floor(x + 0.5)`: -0.5 gives 0 and -2.5 gives -2,
/// and 0.49999997 + 0.5 is 1 in `Float`.
func signedRoundBuggy(_ x: Float) -> Float { (x + 0.5).rounded(.down) }
func signedRoundFixed(_ x: Float) -> Float { x.rounded(.toNearestOrAwayFromZero) }

#sourceLocation(file: "@__swiftmacro_11PlantedBugs16signedRoundBuggy6VerifyfMp_.swift", line: 1)
func signedRoundBuggy_requires(_ x: Float) -> Bool { x >= -1_000 && x <= 1_000 }
func signedRoundBuggy_ensures(_ x: Float, _ result: Float) -> Bool { result == x.rounded() }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs16signedRoundFixed6VerifyfMp_.swift", line: 1)
func signedRoundFixed_requires(_ x: Float) -> Bool { x >= -1_000 && x <= 1_000 }
func signedRoundFixed_ensures(_ x: Float, _ result: Float) -> Bool { result == x.rounded() }
#sourceLocation()

/// A temperature rounded for display must never be "-0": -0.4 rounds to -0.0.
func displayCelsiusBuggy(_ celsius: Double) -> Double { celsius.rounded() }
func displayCelsiusFixed(_ celsius: Double) -> Double {
    let rounded = celsius.rounded()
    return rounded == 0 ? 0 : rounded
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs19displayCelsiusBuggy6VerifyfMp_.swift", line: 1)
func displayCelsiusBuggy_requires(_ celsius: Double) -> Bool { celsius > -100 && celsius < 100 }
func displayCelsiusBuggy_ensures(_ celsius: Double, _ result: Double) -> Bool { !(result == 0 && result.sign == .minus) }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs19displayCelsiusFixed6VerifyfMp_.swift", line: 1)
func displayCelsiusFixed_requires(_ celsius: Double) -> Bool { celsius > -100 && celsius < 100 }
func displayCelsiusFixed_ensures(_ celsius: Double, _ result: Double) -> Bool { !(result == 0 && result.sign == .minus) }
#sourceLocation()

/// Whole minutes of a duration in seconds. The planted range check `!(x >= max || x <= min)` lets NaN through, and
/// `Int(_:)` of NaN traps.
func wholeMinutesBuggy(_ seconds: Double) -> Int {
    guard !(seconds >= 1e9 || seconds <= -1e9) else { return 0 }
    return Int(seconds.rounded(.towardZero)) / 60
}

func wholeMinutesFixed(_ seconds: Double) -> Int {
    guard seconds < 1e9 && seconds > -1e9 else { return 0 }
    return Int(seconds.rounded(.towardZero)) / 60
}

/// A reminder `days` days after `start` (whole seconds since 1970); it must fall after the start. The planted bug
/// counts the first day twice, so a one-day reminder fires at the start.
func dueDateBuggy(_ start: Int32, _ days: Int16) -> Date {
    Date(timeIntervalSince1970: Double(start)).addingTimeInterval(Double(days - 1) * 86_400)
}

func dueDateFixed(_ start: Int32, _ days: Int16) -> Date {
    Date(timeIntervalSince1970: Double(start)).addingTimeInterval(Double(days) * 86_400)
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs12dueDateBuggy6VerifyfMp_.swift", line: 1)
func dueDateBuggy_requires(_ start: Int32, _ days: Int16) -> Bool { start >= 0 && days >= 1 && days <= 3_650 }
func dueDateBuggy_ensures(_ start: Int32, _ days: Int16, _ due: Date) -> Bool {
    due > Date(timeIntervalSince1970: Double(start))
}
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs12dueDateFixed6VerifyfMp_.swift", line: 1)
func dueDateFixed_requires(_ start: Int32, _ days: Int16) -> Bool { start >= 0 && days >= 1 && days <= 3_650 }
func dueDateFixed_ensures(_ start: Int32, _ days: Int16, _ due: Date) -> Bool {
    due > Date(timeIntervalSince1970: Double(start))
}
#sourceLocation()

/// A bill split three ways. In `Decimal`, 1 / 3 * 3 is 0.999…9, not 1; in `Double` it is exactly 1. Logic must not
/// read `Decimal` arithmetic as `Double`'s.
func shareBuggy(_ total: Decimal) -> Decimal { total / 3 }
#sourceLocation(file: "@__swiftmacro_11PlantedBugs10shareBuggy6VerifyfMp_.swift", line: 1)
func shareBuggy_ensures(_ total: Decimal, _ share: Decimal) -> Bool { share * 3 == total }
#sourceLocation()
