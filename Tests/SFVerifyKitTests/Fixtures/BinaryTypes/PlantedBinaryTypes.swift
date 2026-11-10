// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 11: mappers over types of a binary module (a Kotlin enum and a sealed class as SKIE exports
// them, `Kit.swift`). The module has no SIL bodies: the cases come from the compiler, `onEnum(of:)` may return any case.

import Kit

enum ShotIcon: Hashable {
    case none, flag, tee
}

/// One case of a binary enum gets the text of another.
func surfaceTextBuggy(_ surface: Surface) -> String {
    switch surface {
    case .slow: "Slow"
    case .medium: "Medium"
    case .fast: "Medium"
    }
}

func surfaceTextFixed(_ surface: Surface) -> String {
    switch surface {
    case .slow: "Slow"
    case .medium: "Medium"
    case .fast: "Fast"
    }
}

#sourceLocation(file: "@__swiftmacro_11PlantedBugs16surfaceTextBuggy6VerifyfMp_.swift", line: 1)
func surfaceTextBuggy_ensures(_ surface: Surface, _ text: String) -> Bool { (text == "Fast") == (surface == .fast) }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs16surfaceTextFixed6VerifyfMp_.swift", line: 1)
func surfaceTextFixed_ensures(_ surface: Surface, _ text: String) -> Bool { (text == "Fast") == (surface == .fast) }
#sourceLocation()

/// A switch over `onEnum(of:)` forgets a case: the `default:` arm takes drives.
func shotIconBuggy(_ shot: KitShot) -> ShotIcon {
    switch onEnum(of: shot) {
    case .putt: .flag
    default: .none
    }
}

func shotIconFixed(_ shot: KitShot) -> ShotIcon {
    switch onEnum(of: shot) {
    case .putt: .flag
    case .drive: .tee
    }
}

// Every shot has an icon.
#sourceLocation(file: "@__swiftmacro_11PlantedBugs13shotIconBuggy6VerifyfMp_.swift", line: 1)
func shotIconBuggy_ensures(_ shot: KitShot, _ icon: ShotIcon) -> Bool { icon != .none }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs13shotIconFixed6VerifyfMp_.swift", line: 1)
func shotIconFixed_ensures(_ shot: KitShot, _ icon: ShotIcon) -> Bool { icon != .none }
#sourceLocation()

/// A switch over `onEnum(of:)` mixes two cases up: a putt gets the drive's title.
func shotTitleBuggy(_ shot: KitShot) -> (icon: ShotIcon, title: String) {
    switch onEnum(of: shot) {
    case .putt: (.flag, "Drive")
    case .drive: (.tee, "Putt")
    }
}

func shotTitleFixed(_ shot: KitShot) -> (icon: ShotIcon, title: String) {
    switch onEnum(of: shot) {
    case .putt: (.flag, "Putt")
    case .drive: (.tee, "Drive")
    }
}

// The flag is the putt's icon.
#sourceLocation(file: "@__swiftmacro_11PlantedBugs14shotTitleBuggy6VerifyfMp_.swift", line: 1)
func shotTitleBuggy_ensures(_ shot: KitShot, _ result: (icon: ShotIcon, title: String)) -> Bool {
    (result.icon == .flag) == (result.title == "Putt")
}
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs14shotTitleFixed6VerifyfMp_.swift", line: 1)
func shotTitleFixed_ensures(_ shot: KitShot, _ result: (icon: ShotIcon, title: String)) -> Bool {
    (result.icon == .flag) == (result.title == "Putt")
}
#sourceLocation()
