/// The floating-point set of the Scan zoo (plan item R6-3), run by `ScanZooTests` like every other entry.
extension ScanZoo {
    /// Every function of the zoo, and what Scan must say about each.
    static let source =
        baseSource + "\n" + floatSource + "\n" + coverageSource + "\n" + combinationSource + "\n"
        + combinationContractSource + "\n" + contractSource
    static let entries =
        baseEntries + floatEntries + coverageEntries + combinationEntries + combinationContractEntries + contractEntries

    static let floatSource = """
        public func scaledBound(_ x: Double) -> Int { Int((abs(x) * 10.0).rounded()) }
        public func guardedScaled(_ x: Double) -> Int {
            guard x.isFinite, x > -1000, x < 1000 else { return 0 }
            return Int((x < 0 ? 0 - x : x) * 10.0)
        }
        public func guardedRounded(_ x: Double) -> Int { guard x.isFinite, abs(x) < 1000 else { return 0 }; return Int((abs(x) * 10.0).rounded()) }
        public func doubledGreater(_ x: Double) -> Int { precondition(x * 2.0 > x); return 0 }
        public func cancelIsPositiveZero(_ x: Double) -> Int { precondition(!(x.isFinite && (x - x).sign == .minus)); return 0 }
        public func negativeTimesZero(_ x: Double) -> Int { precondition(!(x < 0 && x.isFinite && (x * 0).sign == .plus)); return 0 }
        public func halfOfTiniest(_ x: Double) -> Int { precondition(!(x > 0 && x * 0.5 == 0)); return 0 }
        public func subnormalDouble(_ x: Double) -> Int { precondition(!(x.isSubnormal && (x + x) - x != x)); return 0 }
        public func subnormalScaled(_ x: Double) -> Int { x.isSubnormal ? Int(x * 1e300 * 1e300) : 0 }
        public func nanNotEqual(_ x: Double) -> Int { precondition((x + 1) == (x + 1)); return 0 }
        public func infinityMinusItself(_ x: Double) -> Int { precondition(!(x.isInfinite && (x - x) == (x - x))); return 0 }
        public func nanPayload(_ x: Double) -> Int { precondition((x * 0).bitPattern != 0x7FF8_0000_0000_0000); return 0 }
        public func overflowToInfinity(_ x: Double) -> Int { x > 1e308 ? Int(x + x) : 0 }
        public func divideByZero(_ x: Double) -> Int { x != 0 && x.isFinite ? Int(1 / x) : 0 }
        public func ratio(_ a: Double, _ b: Double) -> Int { a.isFinite && b.isFinite && abs(a) <= 100 && abs(b) >= 1 ? Int(a / b) : 0 }
        public func fromCount(_ n: Int) -> Int { Int(Double(n) * 0.5) }
        public func fromCountDoubled(_ n: Int) -> Int { Int(Double(n) * 2) }
        public func clampThenConvert(_ x: Double) -> Int { Int(min(max(x, -100), 100)) }
        public func clampNaNAway(_ x: Double) -> Int { Int(max(-100, min(100, x))) }
        public func floatScaled(_ x: Float) -> Int32 { x.isFinite && abs(x) < 1e6 ? Int32(x * 100) : 0 }
        public func floatOverflow(_ x: Float) -> Int32 { x.isFinite && abs(x) < 1e8 ? Int32(x * 100) : 0 }
        """

    static let floatEntries: [Entry] = [
        // The app study's unguarded bound and its two guarded forms; facts false for NaN
        // or negative values; -0.0, subnormals, NaN (comparisons and an unspecified payload) and infinities.
        Entry(name: "scaledBound", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "guardedScaled", parameterTypes: ["Double"], expectation: .safe),
        Entry(name: "guardedRounded", parameterTypes: ["Double"], expectation: .safe),
        Entry(name: "doubledGreater", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "cancelIsPositiveZero", parameterTypes: ["Double"], expectation: .safe),
        Entry(name: "negativeTimesZero", parameterTypes: ["Double"], expectation: .safe),
        Entry(name: "halfOfTiniest", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "subnormalDouble", parameterTypes: ["Double"], expectation: .safe),
        Entry(name: "subnormalScaled", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "nanNotEqual", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "infinityMinusItself", parameterTypes: ["Double"], expectation: .safe),
        // The hardware's NaN for 0 * inf has a fixed payload, the model's has none: never safe, and not refuted either.
        Entry(name: "nanPayload", parameterTypes: ["Double"], expectation: .notSafe),
        Entry(name: "overflowToInfinity", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "divideByZero", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "ratio", parameterTypes: ["Double", "Double"], expectation: .safe),
        Entry(name: "fromCount", parameterTypes: ["Int"], expectation: .safe),
        Entry(name: "fromCountDoubled", parameterTypes: ["Int"], expectation: .traps),
        Entry(name: "clampThenConvert", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "clampNaNAway", parameterTypes: ["Double"], expectation: .safe),
        Entry(name: "floatScaled", parameterTypes: ["Float"], expectation: .safe),
        Entry(name: "floatOverflow", parameterTypes: ["Float"], expectation: .traps),
    ]

    /// The native driver's edge values and argument parser for `Float`.
    static let floatDriver = """
        func edge(_: Float.Type) -> [Float] {
            [0, -0.0, 1, -1, 0.5, 1e6, -1e6, 1e8, .infinity, -.infinity, .nan, .greatestFiniteMagnitude, .leastNonzeroMagnitude]
        }
        func parse(_: Float.Type, _ s: String) -> Float {
            switch s {
            case "Float.nan": return .nan
            case "Float.infinity": return .infinity
            case "-Float.infinity": return -.infinity
            default:
                if s.hasPrefix("Float(bitPattern: 0x") { return Float(bitPattern: UInt32(s.dropFirst(20).dropLast(), radix: 16)!) }
                return Float(s)!
            }
        }
        """
}
