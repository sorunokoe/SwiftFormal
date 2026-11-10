public struct Key: Hashable { public var k: Int
  public func hash(into h: inout Hasher) { h.combine(k + 1) } }
public struct RR: RawRepresentable, Hashable {
    public var rawValue: Key
    public init(rawValue: Key) { self.rawValue = rawValue }
}
public struct Outer: Hashable { public var r: RR }
var h = Hasher()
Outer(r: RR(rawValue: Key(k: Int.max))).hash(into: &h)
print("no trap")
