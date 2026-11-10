// Planted-bug suite, shape 4: `Int(_:)` of a `Double` traps on NaN.

/// The clamp keeps infinities in 0...100 but lets NaN through (`max(.nan, 0)` is NaN), and `Int(.nan)` traps.
func wholePercentBuggy(_ percent: Double) -> Int {
    Int(min(max(percent, 0), 100).rounded())
}

func wholePercentFixed(_ percent: Double) -> Int {
    guard !percent.isNaN else { return 0 }
    return Int(min(max(percent, 0), 100).rounded())
}
