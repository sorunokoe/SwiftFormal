// A binary module built with library evolution: its non-frozen enums may gain cases, its frozen ones may not.

import Foundation

/// Built with library evolution: a client must allow cases added later.
public enum Season { case spring, summer, autumn, winter }
@frozen public enum Half { case first, second }

/// An app's own localization helpers, as a client sees them: calls with no body.
extension String {
    public func localized() -> String { NSLocalizedString(self, comment: "") }
    public func localized(_ arguments: [any CVarArg]) -> String { String(format: localized(), arguments: arguments) }
}

/// A base class a vendor framework ships: a subclass's deinit calls its deinit, which the client has no body of.
open class VendorBase {
    public init() {}
}
