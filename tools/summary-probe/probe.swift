import CoreGraphics

// Calls every standard-library function in `StdlibSummary.table` (Sources/SFSIL/SILSummaries.swift) once, so that
// the compiler prints each one: its declaration at -Onone (plan item R9, the `[_semantics]` cross-check) and its
// linked body at -O after the performance linker (plan item R6, `Scripts/check-summary-pin.py`).
// The Composable Architecture entries are not standard library and are not called here.
public enum RE: String { case a }
public struct P: CustomStringConvertible, Hashable {
    public var x: Int
    public var description: String { "p" }
}
public struct Q: CustomStringConvertible, TextOutputStreamable {
    public var description: String { "q" }
    public func write<T: TextOutputStream>(to t: inout T) {}
}
/// Not `CustomStringConvertible`: `String(describing:)` takes its unconstrained overload.
public struct Plain { public var x: Int }
@inline(never) public func use<T>(_ t: T) {}

public func strings(_ s: String, _ t: String, _ i: Int, _ p: P, _ q: Q, _ plain: Plain) {
    var s2 = String()
    s2 += s
    use(s2)
    use(s + t)
    use(s == t)
    use(s < t)
    use(s.count)
    use(s.isEmpty)
    use(s.lowercased())
    use(s.uppercased())
    use(s.hasPrefix(t))
    use(s.hasSuffix(t))
    let c: Character = "x"
    use(c)
    use("a\(i)b\(p)c\(q)d\(RE.a)")
    use(String(describing: p))
    use(String(describing: plain))
    use(String(i))
    use(i.description)
    use(RE(rawValue: s))
}

public func numbers(_ i: Int, _ h: inout Hasher) -> Int {
    use(min(i, 2))
    use(max(i, 2))
    var g = Hasher()
    g.combine(i)
    RE.a.hash(into: &h)
    return g.finalize()
}

public func arrays(_ a: [Int], _ i: Int) {
    var b = a
    use(b.count)
    use(b.startIndex)
    use(b.endIndex)
    use(b[i])
    b.append(i)
    b += a
    use(a + b)
    use([1, 2])
    use([Int]())
    use(Array(repeating: 0, count: i))
    b.removeAll()
    b.removeAll(keepingCapacity: true)
    use(b.remove(at: i))
    b.insert(1, at: i)
    use(a == b)
    use(a.isEmpty)
    use(a.first)
    use(a.last)
    use(b.removeLast())
    use(b.popLast())
    use(a.contains(i))
    use(a.firstIndex(of: i))
    b[i] = 3
    for x in a { use(x) }
}

public func floats(_ d: Double, _ f: Float, _ rule: FloatingPointRoundingRule, _ i: Int, _ i32: Int32, _ u8: UInt8, _ u64: UInt64, _ u32: UInt32) {
    use(d.isFinite)
    use(d.isNaN)
    use(d.isInfinite)
    use(d.isZero)
    use(d.isNormal)
    use(d.isSubnormal)
    use(f.isFinite)
    use(f.isNaN)
    use(f.isInfinite)
    use(f.isZero)
    use(f.isNormal)
    use(f.isSubnormal)
    use(Double(f))
    use(Float(d))
    // Plan item R6-3: abs, magnitude, conversions from integers, and rounded(_:), whose `@unknown default` calls
    // `_roundSlowPath`.
    use(abs(d))
    use(abs(f))
    use(abs(i))
    use(d.magnitude)
    use(f.magnitude)
    use(Double(i32))
    use(Float(u8))
    use(CGFloat(i32))
    use(d.rounded(rule))
    use(f.rounded(rule))
    use(d.bitPattern)
    use(f.bitPattern)
    use(Double(bitPattern: u64))
    use(Float(bitPattern: u32))
}

public func dictionaries(_ a: [Int: Int], _ k: Int, _ s: Set<Int>) {
    var d = a
    use(d.count)
    use(d.isEmpty)
    use(d[k])
    d[k] = k
    use(d.updateValue(k, forKey: k))
    use(d.removeValue(forKey: k))
    use([1: 2])
    use([Int: Int]())
    use(Dictionary(uniqueKeysWithValues: [(k, k)]))
    d.removeAll()
    d.removeAll(keepingCapacity: true)
    use(a == d)
    var t = s
    use(t.count)
    use(t.isEmpty)
    use(t.contains(k))
    use(t.insert(k))
    use(t.remove(k))
    use([1, 2] as Set<Int>)
    use(Set<Int>())
    t.removeAll()
    t.removeAll(keepingCapacity: true)
    use(s == t)
}

public func iteration(_ a: [Int], _ i: Int) {
    for x in 0..<i { use(x) }
    for x in 0...i { use(x) }
    for x in stride(from: 0, to: i, by: 2) { use(x) }
    for x in stride(from: 0, through: i, by: 2) { use(x) }
    for (k, x) in a.enumerated() { use(k); use(x) }
    for k in a.indices { use(k) }
}

public struct Hashed: Hashable { public var x: Int }
public func hashValues(_ h: Hashed) -> Int { h.hashValue }

/// Integer ranges (`SILRanges.swift`).
public func ranges(_ a: Int, _ b: Int, _ x: Int) {
    use((a..<b).contains(x))
    use((a...b).contains(x))
    use((a..<b) ~= x)
    use((a..<b).isEmpty)
    use((a...b).isEmpty)
    use(a...)
    use(...b)
    use(..<b)
    use([a, b].indices)
}
/// `Range.contains` itself: for a `Strideable` bound a concrete call takes the `Collection` overload.
@_optimize(none) public func rangeContains<T: Comparable>(_ r: Range<T>, _ x: T) -> Bool { r.contains(x) }
public func rangesGeneric(_ a: Int, _ b: Int, _ x: Int) { use(rangeContains(a..<b, x)) }

/// `===` (`SILForeign.swift`, plan item R6-1).
public final class Ref {}
public func identity(_ a: Ref, _ b: Ref?) { use(a === b) }
