// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 5: "-0" for a value that rounds to zero.

import Foundation

/// Tenths of a degree as whole degrees: -0.5 degrees prints "-0".
func degreesTextBuggy(_ tenths: Int16) -> String {
    tenths < 0 ? "-\(-(tenths / 10))" : "\(tenths / 10)"
}

func degreesTextFixed(_ tenths: Int16) -> String {
    "\(tenths / 10)"
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs16degreesTextBuggy6VerifyfMp_.swift", line: 1)
func degreesTextBuggy_ensures(_ tenths: Int16, _ text: String) -> Bool { text != "-0" }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs16degreesTextFixed6VerifyfMp_.swift", line: 1)
func degreesTextFixed_ensures(_ tenths: Int16, _ text: String) -> Bool { text != "-0" }
#sourceLocation()

/// The same bug through `String(format:)`: -0.4 prints "-0".
func temperatureTextBuggy(_ celsius: Double) -> String {
    String(format: "%.0f", celsius)
}

func temperatureTextFixed(_ celsius: Double) -> String {
    let rounded = celsius.rounded()
    return String(format: "%.0f", rounded == 0 ? 0 : rounded)
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs20temperatureTextBuggy6VerifyfMp_.swift", line: 1)
func temperatureTextBuggy_requires(_ celsius: Double) -> Bool { celsius > -100 && celsius < 100 }
func temperatureTextBuggy_ensures(_ celsius: Double, _ text: String) -> Bool { text != "-0" }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs20temperatureTextFixed6VerifyfMp_.swift", line: 1)
func temperatureTextFixed_requires(_ celsius: Double) -> Bool { celsius > -100 && celsius < 100 }
func temperatureTextFixed_ensures(_ celsius: Double, _ text: String) -> Bool { text != "-0" }
#sourceLocation()
