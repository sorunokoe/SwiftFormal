public func g(_ x: Int) -> Int {
    var a = [x]
    assert(a.popLast() != nil)
    return a.count == 0 ? 0 : 10 / (a.count - 1)
}
