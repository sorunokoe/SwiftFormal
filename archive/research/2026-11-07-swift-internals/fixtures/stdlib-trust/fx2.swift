public func makeCount(_ n: Int) -> Int {
    let a = Array(repeating: 0, count: n)
    return a.count
}
func makeCount_requires(_ n: Int) -> Bool { n >= 0 }
func makeCount_ensures(_ n: Int, _ r: Int) -> Bool { r == n }
public func appendWrap(_ n: Int) -> Int {
    var a = Array(repeating: 0, count: n)
    a.append(1)
    return a.count
}
func appendWrap_requires(_ n: Int) -> Bool { n >= 0 }
func appendWrap_ensures(_ n: Int, _ r: Int) -> Bool { r > 0 }
public struct Key: Hashable { public var k: Int
  public func hash(into h: inout Hasher) { h.combine(k + 1) } }
public struct RR: RawRepresentable, Hashable {
    public var rawValue: Key
    public init(rawValue: Key) { self.rawValue = rawValue }
}
public func hashRR(_ k: Int) -> Int {
    var h = Hasher()
    h.combine(RR(rawValue: Key(k: k)))
    return 0
}
