/// The round-6 coverage set of the Scan zoo, run by `ScanZooTests` like every other entry: `==` on a raw-value enum,
/// `CGFloat` read as its `Double`, `static let` values, the elements
/// of an array literal, `Optional.map` with a closure literal.
extension ScanZoo {
    static let coverageSource = """
        public func clubIsIron(_ n: Int8) -> Int8 { (n == 5 ? ZooClub.iron : .putter) == .iron ? n + 123 : n }
        public func clubGuarded(_ n: Int8) -> Int8 { let c: ZooClub = n > 100 ? .driver : .iron; return c == .iron ? n + 27 : n }
        public func clubRawDiffers(_ n: Int8) -> Int8 { ZooClub(rawValue: n == 1 ? "iron" : "wood") != .iron ? n &+ 1 : n + 127 }
        public func cgScaled(_ x: Double) -> Int { let c = CGFloat(x); return c.isFinite && abs(c) < 1e6 ? Int(c * 100) : 0 }
        public func cgOverflow(_ x: Double) -> Int { let c = CGFloat(x); return c.isFinite && abs(c) < 1e300 ? Int(c * 100) : 0 }
        public func cgFromCount(_ n: Int) -> Int { Int(CGFloat(n) * 2) }
        public func cgFromSmall(_ n: Int8) -> Int { Int(CGFloat(n) * 2) }
        public struct ZooBounds { public var lo: Int8; public var hi: Int8 }
        public enum ZooConfig {
            public static let bounds = ZooBounds(lo: -100, hi: 100)
            public static let broken = ZooBounds(lo: ZooConfig.bounds.lo - ZooConfig.bounds.hi, hi: 0)
        }
        public func boundedBump(_ x: Int8) -> Int8 { x > 20 ? 0 : x + ZooConfig.bounds.hi }
        public func unboundedBump(_ x: Int8) -> Int8 { x > 30 ? 0 : x + ZooConfig.bounds.hi }
        public func brokenBound(_ x: Int8) -> Int8 { x &+ ZooConfig.broken.hi }
        public func literalPick(_ i: Int) -> Int8 { let a: [Int8] = [10, 20, 30]; return i >= 0 && i < 3 ? a[i] + 97 : 0 }
        public func literalOver(_ i: Int) -> Int8 { let a: [Int8] = [10, 31, 20]; return i >= 0 && i < 3 ? a[i] + 97 : 0 }
        public func literalWritten(_ x: Int8) -> Int8 { var a: [Int8] = [1, 2]; a[0] = 0; return x / a[0] }
        public func literalRepeated(_ x: Int8) -> Int8 { let a: [Int8] = [1, 2]; let b = [Int8](repeating: 0, count: a.count); return x / b[0] }
        public func mapGuarded(_ n: Int8) -> Int8 { let o: Int8? = n > 100 ? nil : n; return o.map { $0 + 27 } ?? 0 }
        public func mapOver(_ n: Int8) -> Int8 { let o: Int8? = n > 110 ? nil : n; return o.map { $0 + 27 } ?? 0 }
        public func mapCaptured(_ n: Int8, _ k: Int8) -> Int8 {
            let o: Int8? = n > 0 && n < 100 ? n : nil
            return k > 0 && k < 28 ? (o.map { $0 + k } ?? 0) : 0
        }
        """

    static let coverageEntries: [Entry] = [
        // `==` and `!=` on a raw-value enum (`getEnumTag`, `SILEnumTags.swift`): exact, so the trap is found at its input.
        Entry(name: "clubIsIron", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "clubGuarded", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "clubRawDiffers", parameterTypes: ["Int8"], expectation: .traps),
        // `CGFloat` (`SILCGFloat.swift`): the same IEEE results as `Double`, so the guarded scale is safe and the others trap.
        Entry(name: "cgScaled", parameterTypes: ["Double"], expectation: .safe),
        Entry(name: "cgOverflow", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "cgFromCount", parameterTypes: ["Int"], expectation: .traps),
        Entry(name: "cgFromSmall", parameterTypes: ["Int8"], expectation: .safe),
        // `static let` (`SILGlobals.swift`): the initializer's value, and its trap (-100 - 100) on the first read.
        Entry(name: "boundedBump", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "unboundedBump", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "brokenBound", parameterTypes: ["Int8"], expectation: .traps),
        // Array literal elements (`SILArrayLiterals.swift`): exact reads; a write through the subscript forgets them.
        Entry(name: "literalPick", parameterTypes: ["Int"], expectation: .safe),
        Entry(name: "literalOver", parameterTypes: ["Int"], expectation: .traps),
        Entry(name: "literalWritten", parameterTypes: ["Int8"], expectation: .notSafe),
        // A literal's count read as an `Int` names no array: `b` is zeros, never the literal's elements.
        Entry(name: "literalRepeated", parameterTypes: ["Int8"], expectation: .notSafe),
        // `Optional.map` with a closure literal (`SILOptionalMap.swift`): the body's trap only when there is a value.
        Entry(name: "mapGuarded", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "mapOver", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "mapCaptured", parameterTypes: ["Int8", "Int8"], expectation: .safe),
    ]
}
