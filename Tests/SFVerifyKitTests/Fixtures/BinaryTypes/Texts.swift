// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Localization through a binary module's `localized` methods (`TextScanTests.binaryLocalization`).

import Foundation
import Seasons

public enum Tee { case back, middle, forward }

// Two tees pick the same key: the same text, whatever the method does.
public func teeTitle(_ tee: Tee) -> String {
    switch tee {
    case .back: "tee.back".localized()
    case .middle: "tee.back".localized()
    case .forward: "tee.forward".localized()
    }
}
#sourceLocation(file: "@__swiftmacro_3App8teeTitle6VerifyfMp_.swift", line: 1)
public func teeTitle_ensures(_ tee: Tee, _ text: String) -> Bool { tee == .back || text != teeTitle(.back) }
#sourceLocation()

// Standard numbers and strings as format arguments: the method can only print them.
public func holesPlayed(_ played: Int32, _ course: String) -> String { "holes.played".localized([played, course]) }

// Any CVarArg may be an object of this module, whose code the method could run.
public final class Marker: NSObject { deinit { print("gone") } }
public func anyArgument(_ value: any CVarArg) -> String { "holes.played".localized([value]) }
