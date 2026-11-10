// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 1: two cases map to the same text because the sign is dropped.
//
// Every file in this folder is compiled twice: into this test target, where the walks of `PlantedBugWalkTests` run
// it, and alone by Scan in `PlantedBugScanTests`. So it imports only Foundation, and its contracts are the
// `_requires` / `_ensures` peers that `@Verify` writes for `#requires` / `#ensures`, placed by `#sourceLocation` in
// the file the compiler gives `@Verify`'s peers, since Scan reads a contract only from there.

enum Delta: CaseIterable {
    case minusTwo, minusOne, zero, plusOne, plusTwo
}

func deltaTextBuggy(_ delta: Delta) -> String {
    switch delta {
    case .minusTwo: "2"
    case .minusOne: "-1"
    case .zero: "0"
    case .plusOne: "1"
    case .plusTwo: "2"
    }
}

func deltaTextFixed(_ delta: Delta) -> String {
    switch delta {
    case .minusTwo: "-2"
    case .minusOne: "-1"
    case .zero: "0"
    case .plusOne: "1"
    case .plusTwo: "2"
    }
}

func parseDelta(_ text: String) -> Delta? {
    switch text {
    case "-2": .minusTwo
    case "-1": .minusOne
    case "0": .zero
    case "1": .plusOne
    case "2": .plusTwo
    default: nil
    }
}

// No two cases share a text: the text reads back as the case it came from.
#sourceLocation(file: "@__swiftmacro_11PlantedBugs14deltaTextBuggy6VerifyfMp_.swift", line: 1)
func deltaTextBuggy_ensures(_ delta: Delta, _ text: String) -> Bool { parseDelta(text) == delta }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs14deltaTextFixed6VerifyfMp_.swift", line: 1)
func deltaTextFixed_ensures(_ delta: Delta, _ text: String) -> Bool { parseDelta(text) == delta }
#sourceLocation()
