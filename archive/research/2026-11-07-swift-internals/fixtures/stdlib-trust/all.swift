public enum RE: String { case a }
public struct P: CustomStringConvertible, Hashable { public var x: Int; public var description: String { "p" } }
public struct Q: CustomStringConvertible, TextOutputStreamable { public var description: String { "q" }; public func write<T: TextOutputStream>(to t: inout T) {} }
@inline(never) public func use<T>(_ t: T) {}
public func all(_ s: String, _ t: String, _ a: [Int], _ i: Int, _ h: inout Hasher, _ p: P, _ q: Q) {
    var s2 = String(); s2 += s; use(s + t); use(s == t); use(s < t); use(s.count); use(s.isEmpty)
    use(s.lowercased()); use(s.uppercased()); use(s.hasPrefix(t)); use(s.hasSuffix(t))
    let c: Character = "x"; use(c)
    use("a\(i)b\(p)c\(q)d\(RE.a)"); use(String(describing: p)); use(String(i)); use(i.description)
    use(min(i, 2)); use(max(i, 2)); h.combine(i); RE.a.hash(into: &h)
    var b = a; use(b.count); use(b.startIndex); use(b.endIndex); use(b[i]); b.append(i); b += a; use(a + b)
    use([1, 2]); use([Int]()); use(Array(repeating: 0, count: i)); b.removeAll(); b.removeAll(keepingCapacity: true)
    use(b.remove(at: i)); b.insert(1, at: i); use(a == b); use(a.isEmpty); use(a.first); use(a.last)
    use(b.removeLast()); use(b.popLast()); use(a.contains(i)); use(a.firstIndex(of: i)); b[i] = 3
}
