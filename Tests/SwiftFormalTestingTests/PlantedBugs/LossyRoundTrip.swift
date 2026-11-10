// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 7: enum -> stored code -> enum loses a case.

enum DistanceUnit: String, CaseIterable {
    case meters = "m"
    case yards = "yd"
    case feet = "ft"
}

/// Feet are stored as yards, so they read back as yards.
func storedCodeBuggy(_ unit: DistanceUnit) -> String {
    switch unit {
    case .meters: "m"
    case .yards: "yd"
    case .feet: "yd"
    }
}

func storedCodeFixed(_ unit: DistanceUnit) -> String {
    switch unit {
    case .meters: "m"
    case .yards: "yd"
    case .feet: "ft"
    }
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs15storedCodeBuggy6VerifyfMp_.swift", line: 1)
func storedCodeBuggy_ensures(_ unit: DistanceUnit, _ code: String) -> Bool { DistanceUnit(rawValue: code) == unit }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs15storedCodeFixed6VerifyfMp_.swift", line: 1)
func storedCodeFixed_ensures(_ unit: DistanceUnit, _ code: String) -> Bool { DistanceUnit(rawValue: code) == unit }
#sourceLocation()
