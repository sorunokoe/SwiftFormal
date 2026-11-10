/// The combination set of the Scan zoo (round-6 soundness review): each entry crosses two or more features that were
/// built and tested on their own (array literals with known elements, `static let` globals, `Optional.map` closures,
/// generics, `inout`, throwing calls, loops, string facts, raw-value enum tags, exact floating point, `CGFloat`,
/// Foundation values, dictionary and set counts, contracts). Run by `ScanZooTests` like every other entry; the true
/// ones are swept natively and every refutation is replayed.
extension ScanZoo {
    static let combinationSource = """
        public enum ComboKind: String { case chess, tennis }
        public enum ComboNum: String { case one = "1", minus = "-128" }
        public enum ComboInt: Int { case a = 1, b = 5 }
        public enum ComboP: Int { case a = 5, b = 1, c = -3 }
        public enum ComboU8: UInt8 { case lo = 0, hi = 255 }
        public enum ComboBig: String { case c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16, c17 }
        public enum ComboCase: String { case upper = "A", lower = "a" }
        public enum ComboAccent: String { case acute = "\\u{E9}", plain = "e" }
        public enum ComboError: Error { case negative }
        public enum ComboPayload { case list([Int8]), empty }
        public struct ComboHolder { public var a: [Int8]; public var k: Int8 }
        public enum ComboGlobals {
            public static let arr: [Int8] = [1, 2]
            public static let zeros: [Int8] = [0, 1]
            public static let text = "CHESS"
            public static let half = 0.5
            public static let tag = ComboP(rawValue: -3)!
            public static let ids = [UUID(), UUID()]
            public static let k: Int8 = 0
            public static let names = ["chess", "tennis"]
            public static let broken: Int8 = [Int8]()[0]
            public static let built: [Int8] = { var a = [Int8](); a.append(1); return a }()
            public static let derived: Int8 = ComboGlobals.arr[1] * 60
            public static let overflowing: Int8 = ComboGlobals.arr[1] * 64
        }
        public let comboTopRows: [Int8] = [0, 1]
        func comboMk<T>(_ a: T, _ b: T) -> [T] { [a, b] }
        func comboFirstOf<T>(_ a: [T]) -> T { a[0] }
        func comboSetFirst<T>(_ a: inout [T], _ v: T) { a[0] = v }
        func comboPick<T>(_ a: [T], _ i: Int) -> T { a[i] }
        func comboZeroFirst(_ a: inout [Int8]) { a[0] = 0 }
        func comboKeep(_ a: inout [Int8]) {}
        func comboReplace(_ a: inout [Int8]) { a = [0, 0] }
        func comboMake(_ x: Int8) throws -> [Int8] { if x < 0 { throw ComboError.negative }; return [x, 1] }
        func comboThrower(_ v: Int8) throws -> Int8 { if v < 0 { throw ComboError.negative }; return v + 1 }
        func comboInner() -> Int8 { let b: [Int8] = [1, 5]; return b[1] }
        func comboInner2(_ k: Int8) -> Int8 { let b: [Int8] = [1, k]; return b[1] }

        // Array literals with known elements, through Optional.map, generics, inout, throws, structs, enums, closures.
        public func litMapZero(_ x: Int8) -> Int8 { let o: [Int8]? = [0, 1]; return o.map { x / $0[0] } ?? 0 }
        public func litMapTwo(_ x: Int8) -> Int8 { let o: [Int8]? = [2, 1]; return o.map { x / $0[0] } ?? 0 }
        public func litMapCaptured(_ x: Int8) -> Int8 { let a: [Int8] = [0, 1]; let o: Int8? = x; return o.map { $0 / a[0] } ?? 0 }
        public func litMapCapturedSafe(_ x: Int8) -> Int8 { let a: [Int8] = [3, 1]; let o: Int8? = x; return o.map { $0 / a[0] } ?? 0 }
        public func litFlatMap(_ x: Int8) -> Int8 {
            let a: [Int8] = [0, 1]; let o: Int8? = x
            return o.flatMap { v in a.first.map { d in v / d } } ?? 0
        }
        public func litGeneric(_ x: Int8) -> Int8 { x / comboPick([1, 0], 1) }
        public func litGenericSafe(_ x: Int8) -> Int8 { x / comboPick([1, 0], 0) }
        public func litInout(_ x: Int8) -> Int8 { var a: [Int8] = [1, 2]; comboZeroFirst(&a); return x / a[0] }
        public func litInoutReplace(_ x: Int8) -> Int8 { var a: [Int8] = [1, 2]; comboReplace(&a); return x / a[0] }
        public func litInoutKeep(_ x: Int8) -> Int8 { var a: [Int8] = [1, 2]; comboKeep(&a); return x / a[0] }
        public func litThrow(_ x: Int8) -> Int8 { let a = (try? comboMake(x)) ?? [1]; return 10 / a[0] }
        public func litThrowLast(_ x: Int8) -> Int8 { let a = (try? comboMake(x)) ?? [1]; return 10 / a[a.count - 1] }
        public func litStruct(_ x: Int8) -> Int8 { var h = ComboHolder(a: [1, 2], k: 0); h.a[0] = 0; return x / h.a[0] }
        public func litStructCopy(_ x: Int8) -> Int8 { var h = ComboHolder(a: [1, 2], k: 0); let g = h; h.a[0] = 0; return x / g.a[0] }
        public func litStructOther(_ x: Int8) -> Int8 { var h = ComboHolder(a: [1, 2], k: 0); h.k = 0; return x / h.a[0] }
        public func litEnum(_ x: Int8) -> Int8 { let p = ComboPayload.list([0, 2]); if case .list(let a) = p { return x / a[0] }; return 0 }
        public func litEnumSafe(_ x: Int8) -> Int8 { let p = ComboPayload.list([3, 2]); if case .list(let a) = p { return x / a[0] }; return 0 }
        public func litEnumRewritten(_ x: Int8) -> Int8 {
            var p = ComboPayload.list([3, 2])
            if case .list(var a) = p { a[0] = 0; p = .list(a) }
            if case .list(let b) = p { return x / b[0] }
            return 0
        }
        public func litClosure(_ x: Int8) -> Int8 { let a: [Int8] = [0, 1]; let f = { a[0] }; return x / f() }
        public func litNested(_ x: Int8) -> Int8 { let a: [Int8] = [0, comboInner()]; return x / a[0] }
        public func litNestedArgument(_ x: Int8) -> Int8 { let a: [Int8] = [0, comboInner2(x)]; return x / a[0] }

        // Array literals and loops: a write in one iteration is seen by the next.
        public func litForInLast(_ x: Int8) -> Int8 { let a: [Int8] = [1, 0]; var s: Int8 = 1; for v in a { s = v }; return x / s }
        public func litForInSafe(_ x: Int8) -> Int8 { let a: [Int8] = [1, 2]; var s: Int8 = 1; for v in a { s = v }; return x / s }
        public func litIndicesWrite(_ x: Int8) -> Int8 { var a: [Int8] = [1, 2]; for i in a.indices { a[i] = 0 }; return x / a[0] }
        public func litLoopUnchanged(_ n: Int8) -> Int8 {
            let a: [Int8] = [1, 2]; var i: Int8 = 0; var s: Int8 = 0
            while i < n { s = 10 / a[0]; i += 1 }
            return s
        }
        public func litReadThenWrite(_ n: Int8) -> Int8 {
            var a: [Int8] = [1, 2]; var r: Int8 = 0
            for _ in 0..<2 { r = 10 / a[0]; a[0] = 0 }
            return r &+ n
        }
        public func litWhileReadThenWrite(_ n: Int8) -> Int8 {
            var a: [Int8] = [1, 2]; var r: Int8 = 0; var i: Int8 = 0
            while i < n { r = 10 / a[0]; a[0] = 0; i += 1 }
            return r
        }
        public func litRepeatReadThenWrite(_ n: Int8) -> Int8 {
            var a: [Int8] = [1, 2]; var r: Int8 = 0; var i: Int8 = 0
            repeat { r = 10 / a[0]; a[0] = 0; i += 1 } while i < n
            return r
        }
        public func litStructLoop(_ n: Int8) -> Int8 {
            var h = ComboHolder(a: [1, 2], k: 0); var r: Int8 = 0; var i: Int8 = 0
            while i < n { r = 10 / h.a[0]; h.a[0] = 0; i += 1 }
            return r
        }

        // `static let` globals holding literal arrays, texts, floats and enum values.
        public func globalCopyWritten(_ x: Int8) -> Int8 { var b = ComboGlobals.arr; b[0] = 0; return x / ComboGlobals.arr[0] }
        public func globalCopyRead(_ x: Int8) -> Int8 { var b = ComboGlobals.arr; b[0] = 0; return x / b[0] }
        public func globalElement(_ x: Int8) -> Int8 { x / ComboGlobals.arr[0] }
        public func globalZero(_ x: Int8) -> Int8 { x / ComboGlobals.zeros[0] }
        public func globalText(_ x: Int8) -> Int8 { ComboGlobals.text.lowercased() == "chess" ? x + 127 : x }
        public func globalHalf(_ x: Int8) -> Int8 { ComboGlobals.half * 2 == 1 ? x + 1 : x }
        public func globalTag(_ x: Int8) -> Int8 { ComboGlobals.tag == .c ? x + 127 : x }
        public func globalIds(_ x: Int8) -> Int8 { ComboGlobals.ids[0] == ComboGlobals.ids[1] ? x + 1 : x }
        public func globalInMap(_ x: Int8) -> Int8 { Optional(x).map { $0 / ComboGlobals.k } ?? 0 }
        public func globalNames(_ x: Int8) -> Int8 { ComboGlobals.names[0].uppercased() == "CHESS" ? x + 127 : x }
        public func globalNamesSafe(_ x: Int8) -> Int8 { ComboGlobals.names[1] == "chess" ? x + 127 : x }
        public func globalBroken(_ x: Int8) -> Int8 { x > 0 ? ComboGlobals.broken : 0 }
        public func globalBuilt(_ x: Int8) -> Int8 { x / ComboGlobals.built[0] }
        public func globalTopLevel(_ x: Int8) -> Int8 { x / comboTopRows[0] }
        public func globalDerived(_ x: Int8) -> Int8 { x > 7 ? 0 : x + ComboGlobals.derived }
        public func globalOverflowing(_ x: Int8) -> Int8 { x > 0 ? ComboGlobals.overflowing : 0 }

        // Array literals built and read in generic functions read at the call's types.
        public func genericMade(_ x: Int8) -> Int8 { let a = comboMk(Int8(0), Int8(1)); return x / a[0] }
        public func genericMadeSafe(_ x: Int8) -> Int8 { let a = comboMk(Int8(2), Int8(0)); return x / a[0] }
        public func genericFirst(_ x: Int8) -> Int8 { x / comboFirstOf([Int8(3), 0]) }
        public func genericSetFirst(_ x: Int8) -> Int8 { var a: [Int8] = [1, 2]; comboSetFirst(&a, 0); return x / a[0] }
        public func genericSwapped(_ x: Int8) -> Int8 { let a = comboMk(Int8(1), Int8(2)); let b = comboMk(a[1], a[0]); return x / (b[0] - 2) }

        // Dictionary and Set counts with literal arrays, float keys and texts.
        public func setDuplicate(_ x: Int8) -> Int8 { let s: Set<Int8> = [1, 1]; return x / Int8(s.count - 1) }
        public func setMaybeDuplicate(_ x: Int8) -> Int8 { let s: Set<Int8> = [x, 1]; return 10 / Int8(s.count - 1) }
        public func uniqueDuplicate(_ x: Int8) -> Int { Dictionary(uniqueKeysWithValues: [(1, 1), (1, 2)]).count }
        public func uniqueLet(_ x: Int8) -> Int { let p: [(Int8, Int8)] = [(1, 1), (x, 2)]; return Dictionary(uniqueKeysWithValues: p).count }
        public func uniqueLetSafe(_ x: Int8) -> Int { let p: [(Int8, Int8)] = [(1, 1), (2, 2)]; return Dictionary(uniqueKeysWithValues: p).count }
        public func uniqueReassigned(_ x: Int8) -> Int {
            var p: [(Int8, Int8)] = [(1, 1), (2, 2)]; p = [(1, 1), (1, 2)]
            return Dictionary(uniqueKeysWithValues: p).count
        }
        public func uniqueAppended(_ x: Int8) -> Int {
            var p: [(Int8, Int8)] = [(1, 1), (2, 2)]; p.append((1, 3))
            return Dictionary(uniqueKeysWithValues: p).count
        }
        public func setSignedZeros(_ x: Int8) -> Int8 { let s: Set<Double> = [0.0, -0.0]; return x / Int8(s.count - 1) }
        public func setTwoNaNs(_ x: Int8) -> Int8 { let z = 0.0; let s: Set<Double> = [z / z, z / z]; return x / Int8(s.count - 1) }
        public func dictSignedZeros(_ x: Int8) -> Int { let d: [Double: Int8] = [0.0: 1, -0.0: 2]; return d.count }
        public func dictTwoNaNs(_ x: Int8) -> Int { let z = 0.0; let d: [Double: Int8] = [z / z: 1, z / z: 2]; return d.count }
        public func setFloatZeros(_ x: Int8) -> Int8 { let s: Set<Float> = [0.0, -0.0]; return x / Int8(s.count - 1) }
        public func setSameText(_ x: Int8) -> Int8 { let s: Set<String> = ["a", "a"]; return x / Int8(s.count - 1) }
        public func dictCountRepeated(_ x: Int8) -> Int8 {
            let d: [Int8: Int8] = [1: 5, 2: 7]; let b = [Int8](repeating: 0, count: d.count); return x / b[0]
        }
        public func setCountRepeated(_ x: Int8) -> Int8 { let s: Set<Int8> = [5, 7]; let b = [Int8](repeating: 0, count: s.count); return x / b[0] }

        // String facts with raw-value enum tags, decimal texts, case conversion and Unicode equivalence.
        public func decimalMin(_ x: Int8) -> Int8 { "\\(x)" == "-128" ? x - 1 : x }
        public func decimalMinGuarded(_ x: Int8) -> Int8 { "\\(x)" == "-128" ? x + 1 : (x == -128 ? 0 : x) }
        public func decimalU8(_ x: UInt8) -> UInt8 { String(x) == "255" ? x + 1 : x }
        public func decimalI64(_ x: Int64) -> Int64 { x.description == "-9223372036854775808" ? -x : x }
        public func decimalOfDouble(_ d: Double, _ x: Int8) -> Int8 { "\\(d)" == "1" ? x + 127 + 1 : x }
        public func decimalOfDoubleOne(_ d: Double, _ x: Int8) -> Int8 { "\\(d)" == "1.0" ? x + 127 + 1 : x }
        public func decimalOfCGFloat(_ n: Int8) -> Int8 { "\\(CGFloat(n))" == "5" ? n + 127 : n }
        public func decimalOfBool(_ n: Int8) -> Int8 { "\\(n > 0)" == "1" ? n + 127 + 1 : n }
        public func kindLowered(_ n: Int8) -> Int8 { ComboKind(rawValue: (n == 1 ? "CHESS" : "Ten").lowercased()) == .chess ? n + 127 : n }
        public func kindLoweredSafe(_ n: Int8) -> Int8 { ComboKind(rawValue: (n == 1 ? "TENNIS" : "Ten").lowercased()) == .chess ? n + 127 : n }
        public func kindOfDecimal(_ n: Int8) -> Int8 { ComboKind(rawValue: "\\(n)") == nil ? n &+ 1 : n + 127 + 1 }
        public func numOfDecimal(_ n: Int8) -> Int8 { ComboNum(rawValue: "\\(n)") == .minus ? n - 1 : n }
        public func numOfDecimalSafe(_ n: Int8) -> Int8 { ComboNum(rawValue: "\\(n)") == .one ? n + 126 : n }
        public func intRaw(_ n: Int) -> Int8 { ComboInt(rawValue: n) == .b ? Int8(n) * 100 : 0 }
        public func intRawSafe(_ n: Int) -> Int8 { ComboInt(rawValue: n) == .b ? Int8(n) * 20 : 0 }
        public func pRaw(_ n: Int, _ x: Int8) -> Int8 { ComboP(rawValue: n) == .b ? x + 127 : x }
        public func pRawSafe(_ n: Int, _ x: Int8) -> Int8 { ComboP(rawValue: n) == .b ? (n == 1 ? x &+ 1 : x + 127 + 1) : x }
        public func pRawValue(_ x: Int8) -> Int8 { let p: ComboP = x > 0 ? .a : .c; return x / Int8(p.rawValue + 3) }
        public func pDiffers(_ x: Int8) -> Int8 { let p: ComboP = x > 0 ? .a : .b; return p != .a ? x + 127 : x }
        public func u8Raw(_ n: UInt8, _ x: Int8) -> Int8 { ComboU8(rawValue: n) == .hi ? x + 127 : x }
        public func bigTag(_ x: Int8) -> Int8 { let b: ComboBig = x > 0 ? .c17 : .c1; return b == .c17 ? x + 127 : x }
        public func bigTagSafe(_ x: Int8) -> Int8 { let b: ComboBig = x > 0 ? .c17 : .c1; return b == .c1 ? x + 127 : x }
        public func optionalTag(_ x: Int8) -> Int8 { let p: ComboP? = x > 0 ? nil : .a; return p == nil ? x + 1 : x }
        public func optionalTagSafe(_ x: Int8) -> Int8 { let p: ComboP? = x == 127 ? nil : .a; return p == nil ? x &+ 1 : x + 1 }
        public func tagPattern(_ x: Int8) -> Int8 { let p: ComboP = x > 0 ? .a : .b; if case .a = p { return x + 127 }; return x }
        public func tagSwitch(_ x: Int8) -> Int8 { let p: ComboP = x > 0 ? .a : .b; switch p { case ComboP.a: return x + 127; default: return x } }
        public func tagInLiteral(_ x: Int8) -> Int8 { let a: [ComboP] = [.a, .b]; return a[1] == .b ? x + 127 : x }
        public func tagInLiteralSafe(_ x: Int8) -> Int8 { let a: [ComboP] = [.a, .b]; return a[0] == .b ? x + 127 : x }
        public func tagRoundTrip(_ x: Int8) -> Int8 { let p: ComboP = x > 0 ? .a : .c; return ComboP(rawValue: p.rawValue) == p ? x &+ 1 : x + 127 + 1 }
        public func rawCaseSensitive(_ x: Int8) -> Int8 { ComboCase(rawValue: "a") == .upper ? x + 127 + 1 : x }
        public func rawUppercased(_ x: Int8) -> Int8 { ComboCase(rawValue: "a".uppercased()) == .upper ? x + 127 + 1 : x }
        public func canonicalEqual(_ x: Int8) -> Int8 { "\\u{E9}" == "e\\u{301}" ? x + 1 : x }
        public func canonicalDiffer(_ x: Int8) -> Int8 { "\\u{E9}" != "e\\u{301}" ? x + 1 : x }
        public func kelvinLowered(_ x: Int8) -> Int8 { "\\u{212A}".lowercased() == "k" ? x + 1 : x }
        public func accentRaw(_ x: Int8) -> Int8 { ComboAccent(rawValue: "e\\u{301}") == .acute ? x + 1 : x }

        // Exact floating point and CGFloat in literal arrays.
        public func nanElement(_ x: Int8, _ z: Double) -> Int8 { let a: [Double] = [z / z, 1]; return a[0] == a[0] ? x &+ 1 : x + 1 }
        public func nanElementZero(_ x: Int8) -> Int8 { let zero = 0.0; let a: [Double] = [zero / zero, 1]; return a[0] == a[0] ? x + 127 + 1 : x }
        public func nanElementDiffers(_ x: Int8) -> Int8 { let zero = 0.0; let a: [Double] = [zero / zero, 1]; return a[0] != a[0] ? x + 127 + 1 : x }
        public func signedZeroElements(_ x: Int8) -> Int8 { let a: [Double] = [-0.0, 0.0]; return a[0] == a[1] ? x + 127 + 1 : x }
        public func signedZeroSigns(_ x: Int8) -> Int8 { let a: [Double] = [-0.0, 0.0]; return a[0].sign == a[1].sign ? x + 127 + 1 : x }
        public func cgElementsInexact(_ x: Int8) -> Int8 { let a: [CGFloat] = [0.1, 0.2]; return a[0] + a[1] == 0.3 ? x + 127 + 1 : x }
        public func cgElementsExact(_ x: Int8) -> Int8 { let a: [CGFloat] = [0.5, 0.25]; return a[0] + a[1] == 0.75 ? x + 127 + 1 : x }
        public func floatElements(_ x: Int8) -> Int8 { let a: [Float] = [0.1, 0.2]; return a[0] + a[1] == 0.3 ? x + 127 + 1 : x }
        public func float16Elements(_ x: Int8) -> Int8 { let a: [Float16] = [0.1, 0.2]; return a[0] + a[1] == 0.3 ? x + 127 + 1 : x }
        public func hugeElement(_ x: Int8) -> Int { let a: [Double] = [1e300, 1]; return Int(a[Int(x & 1)]) }
        public func roundedElements(_ x: Int8) -> Int8 { let a: [Double] = [2.5, -2.5]; return a[0].rounded() == 3 && a[1].rounded() == -3 ? x + 127 + 1 : x }
        public func roundedEvenElement(_ x: Int8) -> Int8 { let a: [Double] = [2.5, -2.5]; return a[0].rounded(.toNearestOrEven) == 2 ? x + 127 + 1 : x }
        public func cgMaxNaN(_ x: Int8) -> Int8 { let zero: CGFloat = 0; let n = zero / zero; return max(n, 1) == 1 ? x + 127 + 1 : x }
        public func minFirstNaN(_ x: Int8) -> Int8 { let zero = 0.0; let n = zero / zero; return min(n, 1).isNaN ? x + 127 + 1 : x }
        public func minSecondNaN(_ x: Int8) -> Int8 { let zero = 0.0; let n = zero / zero; return min(1, n).isNaN ? x + 127 + 1 : x }
        public func cgOfFloat(_ x: Int8) -> Int8 { let f: Float = 0.1; return CGFloat(f) == 0.1 ? x + 127 + 1 : x }
        public func floatOfCG(_ x: Int8) -> Int8 { let c: CGFloat = 0.1; return Float(c) == Float(0.1) ? x + 127 + 1 : x }
        public func cgMagnitudeSign(_ x: Int8) -> Int8 { let c: CGFloat = -0.0; return c.magnitude.sign == .plus ? x + 127 + 1 : x }
        public func cgRoundedHalf(_ x: Int8) -> Int8 { let c: CGFloat = 0.5; return c.rounded() == 1 ? x + 127 + 1 : x }
        public func cgRoundedToInt(_ d: Double) -> Int { Int(CGFloat(d).rounded()) }
        public func doubleRoundTrip(_ n: Int) -> Int { Int(Double(n)) }
        public func cgRoundTrip(_ n: Int) -> Int { Int(CGFloat(n)) }
        public func cgRoundTripU64(_ n: UInt64) -> UInt64 { UInt64(CGFloat(n)) }
        public func floatRoundTrip32(_ n: Int32) -> Int32 { Int32(Float(n)) }
        public func cgRoundTrip32(_ n: Int32) -> Int32 { Int32(CGFloat(n)) }
        public func cgHalfUp8(_ n: Int8) -> Int8 { Int8(CGFloat(n) + 0.5) }
        public func cgHalfOfU8(_ n: UInt8) -> Int8 { Int8(CGFloat(n) / 2) }

        // Optional.map and flatMap closures with traps, nesting, throwing calls, texts, enums, floats and globals.
        public func mapOfNil(_ x: Int8) -> Int8 { let o: Int8? = nil; let z: Int8 = 0; return o.map { $0 / z } ?? x }
        public func mapNested(_ x: Int8) -> Int8 { Optional(x).map { a in Optional(a).map { $0 + 1 } ?? 0 } ?? 0 }
        public func mapNestedSafe(_ x: Int8) -> Int8 { Optional(x).map { a in Optional(a).map { $0 &+ 1 } ?? 0 } ?? 0 }
        public func flatMapPositive(_ x: Int8) -> Int8 { Optional(x).flatMap { $0 > 0 ? $0 : nil }.map { 100 / $0 } ?? 0 }
        public func flatMapNonNegative(_ x: Int8) -> Int8 { Optional(x).flatMap { $0 >= 0 ? $0 : nil }.map { 100 / $0 } ?? 0 }
        public func mapTryInside(_ x: Int8) -> Int8 { Optional(x).map { v in (try? comboThrower(v)) ?? 0 } ?? 0 }
        public func mapUUIDSelf(_ x: Int8) -> Int8 { let u: UUID? = UUID(); return u.map { $0 == $0 } == true ? x &+ 1 : x + 1 }
        public func mapLowered(_ x: Int8) -> Int8 { let s: String? = x == 3 ? "CHESS" : nil; return s.map { $0.lowercased() } == "chess" ? x + 125 : x }
        public func flatMapRaw(_ x: Int8) -> Int8 { let s: String? = x == 3 ? "tennis" : nil; return s.flatMap { ComboKind(rawValue: $0) } == .tennis ? x + 125 : x }
        public func mapToLiteral(_ x: Int8) -> Int8 { let o: Int8? = x; let a: [Int8] = o.map { [$0, 0] } ?? [1, 1]; return 10 / a[1] }
        public func mapToLiteralSafe(_ x: Int8) -> Int8 { let o: Int8? = x; let a: [Int8] = o.map { [$0, 1] } ?? [1, 1]; return 10 / a[1] }
        public func mapToInt(_ d: Double) -> Int { Optional(d).map { Int($0) } ?? 0 }
        public func mapCGGuarded(_ d: Double) -> Int { Optional(CGFloat(d)).map { $0.isFinite && abs($0) < 100 ? Int($0) : 0 } ?? 0 }

        // Foundation values in literal arrays.
        public func uuidElement(_ x: Int8) -> Int8 { let u = UUID(); let a = [u, UUID()]; return a[0] == u ? x &+ 1 : x + 1 }
        public func uuidElements(_ x: Int8) -> Int8 { let a = [UUID(), UUID()]; return a[0] == a[1] ? x + 1 : x }

        """

    static let combinationEntries: [Entry] = [
        // Array literals through Optional.map, generics, inout, throwing calls, structs, enum payloads, closures.
        Entry(name: "litMapZero", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "litMapTwo", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "litMapCaptured", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "litMapCapturedSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "litFlatMap", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "litGeneric", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "litGenericSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "litInout", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "litInoutReplace", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "litInoutKeep", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "litThrow", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "litThrowLast", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "litStruct", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "litStructCopy", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "litStructOther", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "litEnum", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "litEnumSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "litEnumRewritten", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "litClosure", parameterTypes: ["Int8"], expectation: .traps),
        // A literal built while another literal is under construction (`[0, inner()]`): each keeps its own elements.
        Entry(name: "litNested", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "litNestedArgument", parameterTypes: ["Int8"], expectation: .traps),
        // Loops: a header gets fresh values, so an element written in one pass is never read as the literal's next pass.
        Entry(name: "litForInLast", parameterTypes: ["Int8"], expectation: .undecided, trapsAt: ["1"]),
        Entry(name: "litForInSafe", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "litIndicesWrite", parameterTypes: ["Int8"], expectation: .undecided, trapsAt: ["1"]),
        Entry(name: "litLoopUnchanged", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "litReadThenWrite", parameterTypes: ["Int8"], expectation: .undecided, trapsAt: ["0"]),
        Entry(name: "litWhileReadThenWrite", parameterTypes: ["Int8"], expectation: .undecided, trapsAt: ["2"]),
        Entry(name: "litRepeatReadThenWrite", parameterTypes: ["Int8"], expectation: .undecided, trapsAt: ["2"]),
        Entry(name: "litStructLoop", parameterTypes: ["Int8"], expectation: .undecided, trapsAt: ["2"]),
        // `static let` globals: a written copy forgets the elements of the global too (never wrongly known).
        Entry(name: "globalCopyWritten", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "globalCopyRead", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "globalElement", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "globalZero", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "globalText", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "globalHalf", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "globalTag", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "globalIds", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "globalInMap", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "globalNames", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "globalNamesSafe", parameterTypes: ["Int8"], expectation: .safe),
        // An initializer that always traps makes every read trap.
        Entry(name: "globalBroken", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "globalBuilt", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "globalTopLevel", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "globalDerived", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "globalOverflowing", parameterTypes: ["Int8"], expectation: .traps),
        // Generic functions read at the call's types build and read literals like any other function.
        Entry(name: "genericMade", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "genericMadeSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "genericFirst", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "genericSetFirst", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "genericSwapped", parameterTypes: ["Int8"], expectation: .traps),
        // Dictionary and Set counts: equal keys are kept once (Set) or trap (Dictionary); float keys compare by `==`.
        Entry(name: "setDuplicate", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "setMaybeDuplicate", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "uniqueDuplicate", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "uniqueLet", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "uniqueLetSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "uniqueReassigned", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "uniqueAppended", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "setSignedZeros", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "setTwoNaNs", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "dictSignedZeros", parameterTypes: ["Int8"], expectation: .undecided, trapsAt: ["0"]),
        Entry(name: "dictTwoNaNs", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "setFloatZeros", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "setSameText", parameterTypes: ["Int8"], expectation: .notSafe),
        // A dictionary's or set's count made into an array's count keeps no literal's elements.
        Entry(name: "dictCountRepeated", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "setCountRepeated", parameterTypes: ["Int8"], expectation: .notSafe),
        // String facts × raw-value enum tags × decimal texts; non-ASCII texts stay unknown (Unicode equivalence).
        Entry(name: "decimalMin", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "decimalMinGuarded", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "decimalU8", parameterTypes: ["UInt8"], expectation: .traps),
        Entry(name: "decimalI64", parameterTypes: ["Int64"], expectation: .traps),
        Entry(name: "decimalOfDouble", parameterTypes: ["Double", "Int8"], expectation: .notRefuted),
        Entry(name: "decimalOfDoubleOne", parameterTypes: ["Double", "Int8"], expectation: .undecided, trapsAt: ["1.0", "0"]),
        Entry(name: "decimalOfCGFloat", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "decimalOfBool", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "kindLowered", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "kindLoweredSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "kindOfDecimal", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "numOfDecimal", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "numOfDecimalSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "intRaw", parameterTypes: ["Int"], expectation: .traps),
        Entry(name: "intRawSafe", parameterTypes: ["Int"], expectation: .safe),
        Entry(name: "pRaw", parameterTypes: ["Int", "Int8"], expectation: .traps),
        Entry(name: "pRawSafe", parameterTypes: ["Int", "Int8"], expectation: .safe),
        Entry(name: "pRawValue", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "pDiffers", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "u8Raw", parameterTypes: ["UInt8", "Int8"], expectation: .traps),
        Entry(name: "bigTag", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "bigTagSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "optionalTag", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "optionalTagSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "tagPattern", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "tagSwitch", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "tagInLiteral", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "tagInLiteralSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "tagRoundTrip", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "rawCaseSensitive", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "rawUppercased", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "canonicalEqual", parameterTypes: ["Int8"], expectation: .undecided, trapsAt: ["127"]),
        Entry(name: "canonicalDiffer", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "kelvinLowered", parameterTypes: ["Int8"], expectation: .undecided, trapsAt: ["127"]),
        Entry(name: "accentRaw", parameterTypes: ["Int8"], expectation: .undecided, trapsAt: ["127"]),
        // Exact floating point and CGFloat in literal arrays and conversions.
        Entry(name: "nanElement", parameterTypes: ["Int8", "Double"], expectation: .traps),
        Entry(name: "nanElementZero", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "nanElementDiffers", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "signedZeroElements", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "signedZeroSigns", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "cgElementsInexact", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "cgElementsExact", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "floatElements", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "float16Elements", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "hugeElement", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "roundedElements", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "roundedEvenElement", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "cgMaxNaN", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "minFirstNaN", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "minSecondNaN", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "cgOfFloat", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "floatOfCG", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "cgMagnitudeSign", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "cgRoundedHalf", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "cgRoundedToInt", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "doubleRoundTrip", parameterTypes: ["Int"], expectation: .traps),
        Entry(name: "cgRoundTrip", parameterTypes: ["Int"], expectation: .traps),
        Entry(name: "cgRoundTripU64", parameterTypes: ["UInt64"], expectation: .traps),
        Entry(name: "floatRoundTrip32", parameterTypes: ["Int32"], expectation: .traps),
        Entry(name: "cgRoundTrip32", parameterTypes: ["Int32"], expectation: .safe),
        Entry(name: "cgHalfUp8", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "cgHalfOfU8", parameterTypes: ["UInt8"], expectation: .safe),
        // Optional.map and flatMap closures.
        Entry(name: "mapOfNil", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "mapNested", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "mapNestedSafe", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "flatMapPositive", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "flatMapNonNegative", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "mapTryInside", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "mapUUIDSelf", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "mapLowered", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "flatMapRaw", parameterTypes: ["Int8"], expectation: .traps),
        Entry(name: "mapToLiteral", parameterTypes: ["Int8"], expectation: .notSafe),
        Entry(name: "mapToLiteralSafe", parameterTypes: ["Int8"], expectation: .notRefuted),
        Entry(name: "mapToInt", parameterTypes: ["Double"], expectation: .traps),
        Entry(name: "mapCGGuarded", parameterTypes: ["Double"], expectation: .safe),
        // Foundation values in literal arrays: an element is the value stored, two fresh UUIDs are of unknown equality.
        Entry(name: "uuidElement", parameterTypes: ["Int8"], expectation: .safe),
        Entry(name: "uuidElements", parameterTypes: ["Int8"], expectation: .notRefuted),
    ]
}
