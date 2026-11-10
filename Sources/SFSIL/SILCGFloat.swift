// Reading guide
// `CGFloat` (CoreGraphics, declared in CoreFoundation's overlay) read as the `Double` it wraps (app study round 6: the type
// blocked 126 functions of a production iOS app). On 64-bit Apple platforms `CGFloat` is `struct CGFloat { var native:
// Double }`, and almost every operation on it is `@_transparent`, so `-Onone` code already holds the `Double`
// builtins (`struct_extract %x, #CGFloat.native`, `fadd_FPIEEE64`, `struct $CGFloat (%d)`): logic gives the type that
// one-field layout and the float circuits do the rest. The calls that stay calls are the generic `abs`, `min`, `max`
// (their floating-point summaries take `CGFloat` like `Double`) and `CGFloat.init<A: BinaryInteger>(_:)`, whose body
// (Swift 6.4 SDK, read from `-emit-sil`) is `Double(n)` for an integer of at most 64 bits: its row is in
// `SILFloatSummaries.swift`, pinned with the standard-library rows (`Scripts/check-summary-pin.py`).
//
// SIL prints the bare name, so the layout is used only after the package-type compile probe confirms, with the
// code's own imports and compiler arguments, that `CGFloat` means `CoreFoundation.CGFloat` and that its `native` is a
// `Double` (on a 32-bit target it is a `Float`, and the probe fails); a read module that declares its own `CGFloat`
// wins. Even unconfirmed, a 32-bit layout could not pass silently: `#Float._value` of a 64-bit leaf is a width error.
// Tests: Tests/SFSILTests/SILCGFloatTests.swift, Tests/SFVerifyKitTests/CGFloatScanTests.swift.

import SFSemantics

extension TypeContext {
    /// The layout of `CGFloat` on a 64-bit target: one `Double` field, `native`.
    static let cgFloat = ValueType.aggregate(name: "CGFloat", fields: [.init(name: "native", type: .scalar(64))])

    /// `cgFloat` for `CGFloat` once the probe confirmed the name and no read module declares one; nil otherwise.
    func cgFloatType(_ text: String) -> ValueType? {
        var t = text
        for module in ["CoreGraphics.", "CoreFoundation."] where t.hasPrefix(module) { t.removeFirst(module.count) }
        guard t == "CGFloat", confirmedPackageTypes.contains(t) else { return nil }
        let declared = structs[t] != nil || enums[t] != nil || generics[t] != nil || rejected[t] != nil || ambiguous.contains(t)
        return declared ? nil : Self.cgFloat
    }
}

extension SILModule {
    /// What the package-type probe checks of `name` besides its module, as the body of a function that takes a value of
    /// the bare name and returns it: for `CGFloat`, that its `native` is a `Double` (a 64-bit target). Nil for others.
    package static func packageProbeBody(_ name: String) -> String? {
        name == "CGFloat" ? "let _: Double = x.native; return x" : nil
    }

    /// `CGFloat`, when some read module imports a module besides the standard library and mentions the name.
    var cgFloatCandidates: [(name: String, module: String)] {
        let standard: Set<String> = ["Builtin", "Swift", "SwiftShims"]
        guard imports.contains(where: { !standard.contains($0) && !$0.hasPrefix("_") }) else { return [] }
        return mentionedNames(["CGFloat"]).isEmpty ? [] : [("CGFloat", "CoreFoundation")]
    }
}
