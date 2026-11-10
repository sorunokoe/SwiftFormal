// A binary module shaped like a Kotlin Multiplatform framework that SKIE exports: Swift code over the Objective-C
// classes of `Kit/` (`-import-underlying-module`). `BinaryFixture` compiles it into a `.swiftmodule` and a static
// library, without library evolution and without a `.swiftinterface`: the scanned client sees no SIL bodies.

import Foundation

/// A Kotlin enum as SKIE exports it: a frozen Swift enum bridged to its Objective-C class.
@frozen public enum Surface: Hashable, CaseIterable, _ObjectiveCBridgeable {
    case slow, medium, fast

    public typealias _ObjectiveCType = __KitSurface

    public var ordinal: Int32 { (self as _ObjectiveCType).ordinal }

    public func _bridgeToObjectiveC() -> __KitSurface {
        switch self {
        case .slow: __KitSurface.slow as __KitSurface
        case .medium: __KitSurface.medium as __KitSurface
        case .fast: __KitSurface.fast as __KitSurface
        }
    }

    public static func _forceBridgeFromObjectiveC(_ source: __KitSurface, result: inout Surface?) { result = fromObjectiveC(source) }

    public static func _conditionallyBridgeFromObjectiveC(_ source: __KitSurface, result: inout Surface?) -> Bool {
        result = fromObjectiveC(source)
        return true
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: __KitSurface?) -> Surface { fromObjectiveC(source) }

    private static func fromObjectiveC(_ source: __KitSurface?) -> Surface {
        guard let source else { fatalError("Couldn't map value of Surface from nil") }
        if source == __KitSurface.slow as __KitSurface {
            return .slow
        } else if source == __KitSurface.medium as __KitSurface {
            return .medium
        } else if source == __KitSurface.fast as __KitSurface {
            return .fast
        } else {
            fatalError("Couldn't map value of Surface from \(source)")
        }
    }
}

/// Not frozen, but this module is built without library evolution: clients know every case.
public enum Tee { case red, white, blue }

/// A Kotlin sealed class as SKIE exports it.
public enum Skie {
    public enum Shot {
        @frozen public enum __Sealed: Hashable {
            case putt(KitPutt)
            case drive(KitDrive)
        }
    }
}

public func onEnum<__Sealed: KitShot>(of sealed: __Sealed) -> Skie.Shot.__Sealed {
    if let sealed = sealed as? KitPutt {
        return .putt(sealed)
    } else if let sealed = sealed as? KitDrive {
        return .drive(sealed)
    } else {
        fatalError("Unknown subtype \(sealed)")
    }
}
