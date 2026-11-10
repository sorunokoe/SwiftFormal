// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 12: closures over rows. A mapper runs a closure over a literal array of rows (`map`,
// `compactMap`, `filter`, `first(where:)`) or over an optional (`Optional.map`), and the closure is wrong for some
// input; or the array has no known length, where no answer may be a proof for every input.

enum CardUnit: CaseIterable {
    case metres, yards
}

/// The distances a range card shows for targets at 50, 100 and 150 metres, in the player's unit. The planted bug's
/// closure drops a distance over the card's old 150 limit, so a yards card loses its last target.
func cardDistancesBuggy(_ unit: CardUnit) -> [Int16] {
    ([50, 100, 150] as [Int16]).compactMap { metres in
        let shown = unit == .metres ? metres : metres * 109 / 100
        return shown > 150 ? nil : shown
    }
}

func cardDistancesFixed(_ unit: CardUnit) -> [Int16] {
    ([50, 100, 150] as [Int16]).map { metres in unit == .metres ? metres : metres * 109 / 100 }
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs18cardDistancesBuggy6VerifyfMp_.swift", line: 1)
func cardDistancesBuggy_ensures(_ unit: CardUnit, _ shown: [Int16]) -> Bool { shown.count == 3 }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs18cardDistancesFixed6VerifyfMp_.swift", line: 1)
func cardDistancesFixed_ensures(_ unit: CardUnit, _ shown: [Int16]) -> Bool { shown.count == 3 }
#sourceLocation()

/// The tee for a drive: the shortest of the 200, 250 and 300 tees that the drive does not pass. The planted bug's
/// `>` for `>=` sends a drive of exactly 200 to the 250 tee.
func teeForDriveBuggy(_ drive: Int16) -> Int16? {
    ([200, 250, 300] as [Int16]).first { $0 > drive }
}

func teeForDriveFixed(_ drive: Int16) -> Int16? {
    ([200, 250, 300] as [Int16]).first { $0 >= drive }
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs16teeForDriveBuggy6VerifyfMp_.swift", line: 1)
func teeForDriveBuggy_requires(_ drive: Int16) -> Bool { drive > 150 && drive < 250 }
func teeForDriveBuggy_ensures(_ drive: Int16, _ tee: Int16?) -> Bool {
    guard let tee else { return false }
    return tee >= drive && tee - drive < 50
}
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs16teeForDriveFixed6VerifyfMp_.swift", line: 1)
func teeForDriveFixed_requires(_ drive: Int16) -> Bool { drive > 150 && drive < 250 }
func teeForDriveFixed_ensures(_ drive: Int16, _ tee: Int16?) -> Bool {
    guard let tee else { return false }
    return tee >= drive && tee - drive < 50
}
#sourceLocation()

/// How many holes of a six-hole course have par `par`. The planted bug's filter keeps every hole of at least that par.
func holesOfParBuggy(_ par: Int8) -> Int {
    ([3, 4, 4, 5, 3, 4] as [Int8]).filter { $0 >= par }.count
}

func holesOfParFixed(_ par: Int8) -> Int {
    ([3, 4, 4, 5, 3, 4] as [Int8]).filter { $0 == par }.count
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs15holesOfParBuggy6VerifyfMp_.swift", line: 1)
func holesOfParBuggy_requires(_ par: Int8) -> Bool { par >= 3 && par <= 5 }
func holesOfParBuggy_ensures(_ par: Int8, _ count: Int) -> Bool { count == (par == 3 ? 2 : par == 4 ? 3 : 1) }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs15holesOfParFixed6VerifyfMp_.swift", line: 1)
func holesOfParFixed_requires(_ par: Int8) -> Bool { par >= 3 && par <= 5 }
func holesOfParFixed_ensures(_ par: Int8, _ count: Int) -> Bool { count == (par == 3 ? 2 : par == 4 ? 3 : 1) }
#sourceLocation()

enum Wind: Equatable {
    case calm, breeze, gale
}

/// The wind for an optional speed reading: none without a reading. The planted bug's closure returns the breeze arm
/// for a calm speed.
func windBuggy(_ speed: Int8?) -> Wind? {
    speed.map { $0 >= 30 ? .gale : $0 >= 10 ? .breeze : .breeze }
}

func windFixed(_ speed: Int8?) -> Wind? {
    speed.map { $0 >= 30 ? .gale : $0 >= 10 ? .breeze : .calm }
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs9windBuggy6VerifyfMp_.swift", line: 1)
func windBuggy_ensures(_ speed: Int8?, _ wind: Wind?) -> Bool { windFixed_ensures(speed, wind) }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs9windFixed6VerifyfMp_.swift", line: 1)
func windFixed_ensures(_ speed: Int8?, _ wind: Wind?) -> Bool {
    guard let speed else { return wind == nil }
    switch wind {
    case .calm: return speed < 10
    case .breeze: return speed >= 10 && speed < 30
    case .gale: return speed >= 30
    case nil: return false
    }
}
#sourceLocation()

/// How many of a player's scores are under par, as a small integer. `Int8(_:)` traps from 128 kept scores on: an
/// array of no known length must never be proved, whatever holds for short ones.
func underParCountBuggy(_ scores: [Int8]) -> Int8 {
    Int8(scores.filter { $0 < 0 }.count)
}

/// An 18-hole round: the length is known, so the count is proved to fit.
func underParCountFixed(_ scores: [Int8]) -> Int8 {
    Int8(scores.filter { $0 < 0 }.count)
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs18underParCountFixed6VerifyfMp_.swift", line: 1)
func underParCountFixed_requires(_ scores: [Int8]) -> Bool { scores.count == 18 }
#sourceLocation()
