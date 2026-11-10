import SwiftFormal

/// Index of the cell at (x, y) in a row-major tile of at most 11 x 11, clamped so it can never go out of range.
/// (Kept to 8 bits on purpose: the SAT prover decides 8-bit multiplication in milliseconds, 16-bit often not.)
@Verify
public func cellIndex(_ x: Int8, _ y: Int8, _ width: Int8, _ height: Int8) -> Int8 {
    #requires(width > 0 && height > 0 && width <= 11 && height <= 11)
    #ensures { $0 >= 0 && $0 < width * height }
    let cx = x < 0 ? 0 : (x >= width ? width - 1 : x)
    let cy = y < 0 ? 0 : (y >= height ? height - 1 : y)
    return cy * width + cx
}

/// `part` as a percentage of `whole`, at most 100. `@Verify` without a contract asks for a proof that it cannot trap.
@Verify
public func percent(_ part: UInt16, _ whole: UInt16) -> UInt16 {
    if whole == 0 { return 0 }
    let value = UInt32(part) * 100 / UInt32(whole)
    return value > 100 ? 100 : UInt16(value)
}
