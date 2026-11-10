public struct Guard: ~Copyable {
    public var x: Int32
    public init(x: Int32) { self.x = x }
    deinit { precondition(x > 0) }
}
public func consume(_ g: consuming Guard) -> Int32 { 1 }
