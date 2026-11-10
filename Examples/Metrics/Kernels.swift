// Fixed kernels for `Scripts/metrics.py`. They measure the prover's deterministic cost (solver conflicts, formula
// size); they are not examples to copy. Changing a body changes the baseline in `Scripts/baseline/metrics.json`.
// `metrics.py` scans this file alone, without building the `@Verify` macro, so each contract is written as the peers
// `@Verify` writes and placed where the compiler places them (the `#sourceLocation` lines): Scan reads a contract only
// from there. In your own code write `@Verify`, `#requires` and `#ensures` instead.

/// Adders and comparisons: the cheap case.
public func adder(_ a: UInt8, _ b: UInt8) -> UInt8 { a &+ b }
#sourceLocation(file:"@__swiftmacro_7Metrics5adder6VerifyfMp_.swift",line:1)
public func adder_ensures(_ a: UInt8, _ b: UInt8, _ r: UInt8) -> Bool { r == b &+ a }
#sourceLocation()

/// Branches: clamping keeps the result inside the range.
public func clamp(_ x: Int8, _ lo: Int8, _ hi: Int8) -> Int8 {
    if x < lo { return lo }
    if x > hi { return hi }
    return x
}
#sourceLocation(file:"@__swiftmacro_7Metrics5clamp6VerifyfMp_.swift",line:1)
public func clamp_requires(_ x: Int8, _ lo: Int8, _ hi: Int8) -> Bool { lo <= hi }
public func clamp_ensures(_ x: Int8, _ lo: Int8, _ hi: Int8, _ r: Int8) -> Bool { r >= lo && r <= hi }
#sourceLocation()

/// One multiplication and one division by a constant.
public func discount(_ price: UInt8, _ percent: UInt8) -> UInt8 {
    let p = percent > 100 ? 100 : UInt16(percent)
    return UInt8(UInt16(price) * (100 - p) / 100)
}
#sourceLocation(file:"@__swiftmacro_7Metrics8discount6VerifyfMp_.swift",line:1)
public func discount_ensures(_ price: UInt8, _ percent: UInt8, _ r: UInt8) -> Bool { r <= price }
#sourceLocation()

/// Bit tricks without a loop (loops are outside the supported subset).
public func popcount8(_ x: UInt8) -> UInt8 {
    var v = x
    v = (v & 0x55) &+ ((v >> 1) & 0x55)
    v = (v & 0x33) &+ ((v >> 2) & 0x33)
    return (v & 0x0F) &+ (v >> 4)
}
#sourceLocation(file:"@__swiftmacro_7Metrics9popcount86VerifyfMp_.swift",line:1)
public func popcount8_ensures(_ x: UInt8, _ r: UInt8) -> Bool { r <= 8 }
#sourceLocation()

/// Row-major index with clamped coordinates: two multiplications' worth of arithmetic at 8 bits.
public func cellIndex(_ x: Int8, _ y: Int8, _ width: Int8, _ height: Int8) -> Int8 {
    let cx = x < 0 ? 0 : (x >= width ? width - 1 : x)
    let cy = y < 0 ? 0 : (y >= height ? height - 1 : y)
    return cy * width + cx
}
#sourceLocation(file:"@__swiftmacro_7Metrics9cellIndex6VerifyfMp_.swift",line:1)
public func cellIndex_requires(_ x: Int8, _ y: Int8, _ width: Int8, _ height: Int8) -> Bool {
    width > 0 && height > 0 && width <= 11 && height <= 11
}
public func cellIndex_ensures(_ x: Int8, _ y: Int8, _ width: Int8, _ height: Int8, _ r: Int8) -> Bool {
    r >= 0 && r < width * height
}
#sourceLocation()

/// True for every input, but the solver has to reason about two exact 32-bit products: undecided at the default budget by design.
public func mulCommutes32(_ a: Int32, _ b: Int32) -> Int32 { a &* b }
#sourceLocation(file:"@__swiftmacro_7Metrics13mulCommutes326VerifyfMp_.swift",line:1)
public func mulCommutes32_ensures(_ a: Int32, _ b: Int32, _ r: Int32) -> Bool { r == b &* a }
#sourceLocation()
