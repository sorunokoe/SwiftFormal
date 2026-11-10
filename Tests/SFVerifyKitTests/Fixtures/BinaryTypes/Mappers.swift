// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Mappers over the binary modules `Kit` and `Seasons` (`BinaryTypeScanTests`).

import Kit
import Seasons

/// A frozen enum with a payload from the binary module: the payload is an opaque Objective-C object.
func sealedTitle(_ sealed: Skie.Shot.__Sealed) -> String {
    switch sealed {
    case .putt: "Putt"
    case .drive: "Drive"
    }
}
#sourceLocation(file: "@__swiftmacro_3App11sealedTitle6VerifyfMp_.swift", line: 1)
func sealedTitle_ensures(_ sealed: Skie.Shot.__Sealed, _ title: String) -> Bool {
    if case .putt = sealed { title == "Putt" } else { title == "Drive" }
}
#sourceLocation()

/// A non-frozen enum of a module built without library evolution is closed.
func teeColour(_ tee: Tee) -> Int {
    switch tee {
    case .red: 1
    case .white: 2
    case .blue: 3
    }
}
#sourceLocation(file: "@__swiftmacro_3App9teeColour6VerifyfMp_.swift", line: 1)
func teeColour_ensures(_ tee: Tee, _ colour: Int) -> Bool { colour > 0 && (colour == 1) == (tee == .red) }
#sourceLocation()

/// A non-frozen enum of a module built with library evolution is open: `@unknown default` is reachable.
func seasonMonth(_ season: Season) -> Int {
    switch season {
    case .spring: 3
    case .summer: 6
    case .autumn: 9
    case .winter: 12
    @unknown default: 0
    }
}
#sourceLocation(file: "@__swiftmacro_3App11seasonMonth6VerifyfMp_.swift", line: 1)
func seasonMonth_ensures(_ season: Season, _ month: Int) -> Bool { month > 0 }
#sourceLocation()

/// A frozen enum of the same module is closed.
func halfNumber(_ half: Half) -> Int {
    switch half {
    case .first: 1
    case .second: 2
    }
}
#sourceLocation(file: "@__swiftmacro_3App10halfNumber6VerifyfMp_.swift", line: 1)
func halfNumber_ensures(_ half: Half, _ number: Int) -> Bool { number > 0 }
#sourceLocation()

/// A getter with no body (`Surface.ordinal` forwards to the Objective-C object) may return any `Int32`.
func surfaceOrdinal(_ surface: Surface) -> Int32 { surface.ordinal }
#sourceLocation(file: "@__swiftmacro_3App14surfaceOrdinal6VerifyfMp_.swift", line: 1)
func surfaceOrdinal_ensures(_ surface: Surface, _ ordinal: Int32) -> Bool { ordinal >= 0 }
#sourceLocation()

/// Bridging both ways: to an opaque object, and from one to any case.
func surfaceObject(_ surface: Surface) -> __KitSurface { surface._bridgeToObjectiveC() }
func puttSurface(_ putt: KitPutt) -> Surface { putt.surface }
func puttSurfaceText(_ putt: KitPutt) -> Int {
    switch putt.surface {
    case .slow: 8
    case .medium: 10
    case .fast: 12
    }
}
#sourceLocation(file: "@__swiftmacro_3App15puttSurfaceText6VerifyfMp_.swift", line: 1)
func puttSurfaceText_ensures(_ putt: KitPutt, _ feet: Int) -> Bool { feet >= 8 && feet <= 12 }
#sourceLocation()

/// `==` on Objective-C objects calls `isEqual:`, which may give either answer, even for one object.
func sameShot(_ shot: KitShot) -> Bool { shot == shot }
#sourceLocation(file: "@__swiftmacro_3App8sameShot6VerifyfMp_.swift", line: 1)
func sameShot_ensures(_ shot: KitShot, _ same: Bool) -> Bool { same }
#sourceLocation()

/// `===` on one value is its identity.
func identicalShot(_ shot: KitShot) -> Bool { shot === shot }
#sourceLocation(file: "@__swiftmacro_3App13identicalShot6VerifyfMp_.swift", line: 1)
func identicalShot_ensures(_ shot: KitShot, _ same: Bool) -> Bool { same }
#sourceLocation()

/// Two calls of `onEnum(of:)` may differ: no purity is assumed.
func twoLooks(_ shot: KitShot) -> Bool {
    let first = sealedTitle(onEnum(of: shot))
    let second = sealedTitle(onEnum(of: shot))
    return first == second
}
#sourceLocation(file: "@__swiftmacro_3App8twoLooks6VerifyfMp_.swift", line: 1)
func twoLooks_ensures(_ shot: KitShot, _ same: Bool) -> Bool { same }
#sourceLocation()

/// A payload's getter is an Objective-C call.
func shotDistance(_ shot: KitShot) -> Int32 {
    switch onEnum(of: shot) {
    case .putt(let putt): putt.feet
    case .drive(let drive): drive.yards
    }
}
