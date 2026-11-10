// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 8: an off-by-one range boundary (`<` for `<=`) in a bucket mapper.

enum BatteryLevel: Equatable {
    case low, medium, high
}

/// Low is 0...20, medium 21...79, high 80...100. The planted bug puts 20 in medium.
func batteryLevelBuggy(_ percent: Int) -> BatteryLevel {
    percent < 20 ? .low : percent < 80 ? .medium : .high
}

func batteryLevelFixed(_ percent: Int) -> BatteryLevel {
    percent <= 20 ? .low : percent < 80 ? .medium : .high
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs17batteryLevelBuggy6VerifyfMp_.swift", line: 1)
func batteryLevelBuggy_requires(_ percent: Int) -> Bool { percent >= 0 && percent <= 100 }
func batteryLevelBuggy_ensures(_ percent: Int, _ level: BatteryLevel) -> Bool {
    (level == .low) == (percent <= 20) && (level == .high) == (percent >= 80)
}
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs17batteryLevelFixed6VerifyfMp_.swift", line: 1)
func batteryLevelFixed_requires(_ percent: Int) -> Bool { percent >= 0 && percent <= 100 }
func batteryLevelFixed_ensures(_ percent: Int, _ level: BatteryLevel) -> Bool {
    (level == .low) == (percent <= 20) && (level == .high) == (percent >= 80)
}
#sourceLocation()
