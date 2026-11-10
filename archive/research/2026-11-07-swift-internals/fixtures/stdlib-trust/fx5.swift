public func interp(_ n: Int) -> Int {
    let d = DefaultStringInterpolation(literalCapacity: n, interpolationCount: 1)
    return String(stringInterpolation: d).isEmpty ? 0 : 1
}
