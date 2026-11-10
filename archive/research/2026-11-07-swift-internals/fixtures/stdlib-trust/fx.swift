public func makeCount(_ n: Int) -> Int {
    let a = Array(repeating: 0, count: n)
    return a.count
}
public func appendThenCount(_ n: Int) -> Int {
    var a = Array(repeating: 0, count: n)
    a.append(1)
    return a.count
}
public func appendPlusOne(_ n: Int) -> Int {
    var a = Array(repeating: 0, count: n)
    a.append(1)
    return a.count &+ 1
}
public func doubled(_ n: Int) -> Int {
    let a = Array(repeating: 0, count: n)
    let b = a + a
    return b.count - a.count
}

public struct Bad: CustomStringConvertible {
    public var x: Int
    public var description: String { let y = x + 1; return "\(y)" }
}
public struct Wrap { public var bad: Bad }
public enum E { case one(Bad) }
public func describeWrap(_ x: Int) -> Int {
    let s = String(describing: Wrap(bad: Bad(x: x)))
    return s.isEmpty ? 0 : 1
}
public func describeEnum(_ x: Int) -> Int {
    let s = String(describing: E.one(Bad(x: x)))
    return s.isEmpty ? 0 : 1
}
public func interpWrap(_ x: Int) -> Int {
    let s = "\(Wrap(bad: Bad(x: x)))"
    return s.isEmpty ? 0 : 1
}
public func describeDirect(_ x: Int) -> Int {
    let s = String(describing: Bad(x: x))
    return s.isEmpty ? 0 : 1
}
public struct Reflect: CustomReflectable {
    public var x: Int
    public var customMirror: Mirror { let y = x + 1; return Mirror(self, children: ["y": y]) }
}
public func describeReflect(_ x: Int) -> Int {
    let s = String(describing: Reflect(x: x))
    return s.isEmpty ? 0 : 1
}

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
