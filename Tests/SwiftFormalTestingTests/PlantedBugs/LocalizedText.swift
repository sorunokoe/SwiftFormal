// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 13: text. Two cases pick the same localization key, a format is given too few arguments,
// and an interpolation prints the text of a case it does not stand for. A key missing in one language is the
// catalogue half of the shape: `Tests/SFVerifyKitTests/Fixtures/Strings/PlantedShape13`, checked by
// `swiftformal strings`.

import Foundation

enum Tee: CaseIterable {
    case back, middle, forward
}

/// The middle tee was copied from the back one: both show the back tee's name, in every language.
func teeTitleBuggy(_ tee: Tee) -> String {
    switch tee {
    case .back: NSLocalizedString("tee.back", comment: "")
    case .middle: NSLocalizedString("tee.back", comment: "")
    case .forward: NSLocalizedString("tee.forward", comment: "")
    }
}

func teeTitleFixed(_ tee: Tee) -> String {
    switch tee {
    case .back: NSLocalizedString("tee.back", comment: "")
    case .middle: NSLocalizedString("tee.middle", comment: "")
    case .forward: NSLocalizedString("tee.forward", comment: "")
    }
}

// No tee shows the back tee's name but the back tee.
#sourceLocation(file: "@__swiftmacro_11PlantedBugs13teeTitleBuggy6VerifyfMp_.swift", line: 1)
func teeTitleBuggy_ensures(_ tee: Tee, _ title: String) -> Bool { tee == .back || title != teeTitleBuggy(.back) }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs13teeTitleFixed6VerifyfMp_.swift", line: 1)
func teeTitleFixed_ensures(_ tee: Tee, _ title: String) -> Bool { tee == .back || title != teeTitleFixed(.back) }
#sourceLocation()

/// Two conversions, one argument: `String(format:)` reads a second one it was not given.
func holesTextBuggy(_ played: Int32, _ total: Int32) -> String {
    String(format: "%d of %d", played)
}

func holesTextFixed(_ played: Int32, _ total: Int32) -> String {
    String(format: "%d of %d", played, total)
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs14holesTextFixed6VerifyfMp_.swift", line: 1)
func holesTextFixed_ensures(_ played: Int32, _ total: Int32, _ text: String) -> Bool { !text.isEmpty }
#sourceLocation()

/// A score to par: even par is "E". The buggy one forgets it and prints "+0".
func parTextBuggy(_ toPar: Int8) -> String {
    toPar >= 0 ? "+\(toPar)" : "\(toPar)"
}

func parTextFixed(_ toPar: Int8) -> String {
    toPar == 0 ? "E" : toPar > 0 ? "+\(toPar)" : "\(toPar)"
}

// "E" exactly for even par: no score prints as it.
#sourceLocation(file: "@__swiftmacro_11PlantedBugs12parTextBuggy6VerifyfMp_.swift", line: 1)
func parTextBuggy_ensures(_ toPar: Int8, _ text: String) -> Bool { (toPar == 0) == (text == "E") }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs12parTextFixed6VerifyfMp_.swift", line: 1)
func parTextFixed_ensures(_ toPar: Int8, _ text: String) -> Bool { (toPar == 0) == (text == "E") }
#sourceLocation()
