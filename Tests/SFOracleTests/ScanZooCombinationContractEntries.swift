/// The contracts of the combination set of the Scan zoo (`ScanZooCombinationEntries.swift`): `requires`/`ensures` over
/// array literals, decimal texts, raw-value enums, tuples, floating point and `CGFloat`.
extension ScanZoo {
    static let combinationContractSource = """
        // Contracts over literal arrays, decimal texts, raw-value enums, tuples and floats.
        public func rows() -> [Int8] { [1, 2, 3] }
        #sourceLocation(file: "@__swiftmacro_3App4rows6VerifyfMp_.swift", line: 1)
        public func rows_requires() -> Bool { true }
        public func rows_ensures(_ r: [Int8]) -> Bool { r.count == 3 && r[0] == 1 && r[2] == 3 }
        #sourceLocation()
        public func rowsWrong() -> [Int8] { [1, 2, 3] }
        #sourceLocation(file: "@__swiftmacro_3App9rowsWrong6VerifyfMp_.swift", line: 1)
        public func rowsWrong_requires() -> Bool { true }
        public func rowsWrong_ensures(_ r: [Int8]) -> Bool { r.count == 3 && r[1] == 1 }
        #sourceLocation()
        public func rowsOutOfRange() -> [Int8] { [1, 2, 3] }
        #sourceLocation(file: "@__swiftmacro_3App14rowsOutOfRange6VerifyfMp_.swift", line: 1)
        public func rowsOutOfRange_requires() -> Bool { true }
        public func rowsOutOfRange_ensures(_ r: [Int8]) -> Bool { r[5] == 3 }
        #sourceLocation()
        public func rowsSingle() -> [Int8] { [7] }
        #sourceLocation(file: "@__swiftmacro_3App10rowsSingle6VerifyfMp_.swift", line: 1)
        public func rowsSingle_requires() -> Bool { true }
        public func rowsSingle_ensures(_ r: [Int8]) -> Bool { r[3] == 7 }
        #sourceLocation()
        public func rowsIndexed(_ x: Int8) -> [Int8] { [1, 2, 3] }
        #sourceLocation(file: "@__swiftmacro_3App11rowsIndexed6VerifyfMp_.swift", line: 1)
        public func rowsIndexed_requires(_ x: Int8) -> Bool { true }
        public func rowsIndexed_ensures(_ x: Int8, _ r: [Int8]) -> Bool { r[Int(x)] >= 1 }
        #sourceLocation()
        public func rowsWritten() -> [Int8] { var a: [Int8] = [1, 2, 3]; a[0] = 9; return a }
        #sourceLocation(file: "@__swiftmacro_3App11rowsWritten6VerifyfMp_.swift", line: 1)
        public func rowsWritten_requires() -> Bool { true }
        public func rowsWritten_ensures(_ r: [Int8]) -> Bool { r[0] == 1 }
        #sourceLocation()
        public func rowsInserted() -> [Int8] { var a: [Int8] = [1, 2, 3]; a.insert(0, at: 0); return a }
        #sourceLocation(file: "@__swiftmacro_3App12rowsInserted6VerifyfMp_.swift", line: 1)
        public func rowsInserted_requires() -> Bool { true }
        public func rowsInserted_ensures(_ r: [Int8]) -> Bool { r[0] == 1 }
        #sourceLocation()
        public func rowsRemovedFirst() -> [Int8] { var a: [Int8] = [1, 2, 3]; _ = a.remove(at: 0); return a }
        #sourceLocation(file: "@__swiftmacro_3App16rowsRemovedFirst6VerifyfMp_.swift", line: 1)
        public func rowsRemovedFirst_requires() -> Bool { true }
        public func rowsRemovedFirst_ensures(_ r: [Int8]) -> Bool { r[0] == 1 }
        #sourceLocation()
        public func rowsRemovedLast() -> [Int8] { var a: [Int8] = [1, 2, 3]; a.removeLast(); return a }
        #sourceLocation(file: "@__swiftmacro_3App15rowsRemovedLast6VerifyfMp_.swift", line: 1)
        public func rowsRemovedLast_requires() -> Bool { true }
        public func rowsRemovedLast_ensures(_ r: [Int8]) -> Bool { r.last == 3 }
        #sourceLocation()
        public func rowsPrefixed() -> [Int8] { let a: [Int8] = [1, 2]; return [0] + a }
        #sourceLocation(file: "@__swiftmacro_3App12rowsPrefixed6VerifyfMp_.swift", line: 1)
        public func rowsPrefixed_requires() -> Bool { true }
        public func rowsPrefixed_ensures(_ r: [Int8]) -> Bool { r[0] == 1 }
        #sourceLocation()
        public func rowsRefilled() -> [Int8] { var a: [Int8] = [1, 2]; a.removeAll(); a.append(7); return a }
        #sourceLocation(file: "@__swiftmacro_3App12rowsRefilled6VerifyfMp_.swift", line: 1)
        public func rowsRefilled_requires() -> Bool { true }
        public func rowsRefilled_ensures(_ r: [Int8]) -> Bool { r[0] == 1 }
        #sourceLocation()
        public func rowsSwappedByTuple() -> [Int8] { var a: [Int8] = [1, 2]; (a[0], a[1]) = (a[1], a[0]); return a }
        #sourceLocation(file: "@__swiftmacro_3App18rowsSwappedByTuple6VerifyfMp_.swift", line: 1)
        public func rowsSwappedByTuple_requires() -> Bool { true }
        public func rowsSwappedByTuple_ensures(_ r: [Int8]) -> Bool { r[0] == 1 }
        #sourceLocation()
        public func rowsCopyWritten() -> [Int8] { let a: [Int8] = [1, 2]; var b = a; b[0] = 0; return a }
        #sourceLocation(file: "@__swiftmacro_3App15rowsCopyWritten6VerifyfMp_.swift", line: 1)
        public func rowsCopyWritten_requires() -> Bool { true }
        public func rowsCopyWritten_ensures(_ r: [Int8]) -> Bool { r[0] == 1 }
        #sourceLocation()
        public func rowsFilled() -> [Int8] { var a: [Int8] = [1, 2]; for i in 0..<2 { a[i] = 0 }; return a }
        #sourceLocation(file: "@__swiftmacro_3App10rowsFilled6VerifyfMp_.swift", line: 1)
        public func rowsFilled_requires() -> Bool { true }
        public func rowsFilled_ensures(_ r: [Int8]) -> Bool { r[0] == 1 }
        #sourceLocation()
        public func label(_ n: Int8) -> String { "\\(n)" }
        #sourceLocation(file: "@__swiftmacro_3App5label6VerifyfMp_.swift", line: 1)
        public func label_requires(_ n: Int8) -> Bool { true }
        public func label_ensures(_ n: Int8, _ r: String) -> Bool { r != "-0" && (n != 18 || r == "18") }
        #sourceLocation()
        public func labelWrong(_ n: Int8) -> String { "\\(n)" }
        #sourceLocation(file: "@__swiftmacro_3App10labelWrong6VerifyfMp_.swift", line: 1)
        public func labelWrong_requires(_ n: Int8) -> Bool { true }
        public func labelWrong_ensures(_ n: Int8, _ r: String) -> Bool { r != "-128" }
        #sourceLocation()
        public func kindPicked(_ n: Int8) -> ComboKind? { ComboKind(rawValue: (n == 1 ? "CHESS" : "Tennis").lowercased()) }
        #sourceLocation(file: "@__swiftmacro_3App10kindPicked6VerifyfMp_.swift", line: 1)
        public func kindPicked_requires(_ n: Int8) -> Bool { true }
        public func kindPicked_ensures(_ n: Int8, _ r: ComboKind?) -> Bool { n != 1 || r == .chess }
        #sourceLocation()
        public func kindPickedWrong(_ n: Int8) -> ComboKind? { ComboKind(rawValue: (n == 1 ? "CHESS" : "Tennis").lowercased()) }
        #sourceLocation(file: "@__swiftmacro_3App15kindPickedWrong6VerifyfMp_.swift", line: 1)
        public func kindPickedWrong_requires(_ n: Int8) -> Bool { true }
        public func kindPickedWrong_ensures(_ n: Int8, _ r: ComboKind?) -> Bool { r == .chess }
        #sourceLocation()
        public func pairOf(_ x: Int8) -> (Int8, Int8) { (x, 0) }
        #sourceLocation(file: "@__swiftmacro_3App6pairOf6VerifyfMp_.swift", line: 1)
        public func pairOf_requires(_ x: Int8) -> Bool { true }
        public func pairOf_ensures(_ x: Int8, _ r: (Int8, Int8)) -> Bool { r.0 == x && r.1 == 0 }
        #sourceLocation()
        public func pairSwapped(_ x: Int8) -> (Int8, Int8) { (x, 0) }
        #sourceLocation(file: "@__swiftmacro_3App11pairSwapped6VerifyfMp_.swift", line: 1)
        public func pairSwapped_requires(_ x: Int8) -> Bool { true }
        public func pairSwapped_ensures(_ x: Int8, _ r: (Int8, Int8)) -> Bool { r.1 == x }
        #sourceLocation()
        public func halvedDouble(_ x: Double) -> Double { x / 2 }
        #sourceLocation(file: "@__swiftmacro_3App12halvedDouble6VerifyfMp_.swift", line: 1)
        public func halvedDouble_requires(_ x: Double) -> Bool { x.isFinite }
        public func halvedDouble_ensures(_ x: Double, _ r: Double) -> Bool { r * 2 == x }
        #sourceLocation()
        public func cgHalved(_ x: Double) -> Double { Double(CGFloat(x) / 2) }
        #sourceLocation(file: "@__swiftmacro_3App8cgHalved6VerifyfMp_.swift", line: 1)
        public func cgHalved_requires(_ x: Double) -> Bool { x.isFinite }
        public func cgHalved_ensures(_ x: Double, _ r: Double) -> Bool { r * 2 == x }
        #sourceLocation()
        public func cgHalvedNormal(_ x: Double) -> Double { Double(CGFloat(x) / 2) }
        #sourceLocation(file: "@__swiftmacro_3App14cgHalvedNormal6VerifyfMp_.swift", line: 1)
        public func cgHalvedNormal_requires(_ x: Double) -> Bool { x.isFinite && abs(x) >= 1 }
        public func cgHalvedNormal_ensures(_ x: Double, _ r: Double) -> Bool { r * 2 == x }
        #sourceLocation()
        """

    static let combinationContractEntries: [Entry] = [
        // Contracts. An `ensures` that traps (an index out of range, also on a one-element literal) is broken.
        Entry(name: "rows", parameterTypes: [], expectation: .contractHolds, hasContract: true),
        Entry(name: "rowsWrong", parameterTypes: [], expectation: .fails, hasContract: true),
        Entry(name: "rowsOutOfRange", parameterTypes: [], expectation: .fails, hasContract: true),
        Entry(name: "rowsSingle", parameterTypes: [], expectation: .fails, hasContract: true),
        Entry(name: "rowsIndexed", parameterTypes: ["Int8"], expectation: .fails, hasContract: true),
        Entry(name: "rowsWritten", parameterTypes: [], expectation: .notSafe, hasContract: true),
        Entry(name: "rowsInserted", parameterTypes: [], expectation: .notSafe, hasContract: true),
        Entry(name: "rowsRemovedFirst", parameterTypes: [], expectation: .notSafe, hasContract: true),
        Entry(name: "rowsRemovedLast", parameterTypes: [], expectation: .notSafe, hasContract: true),
        Entry(name: "rowsPrefixed", parameterTypes: [], expectation: .notSafe, hasContract: true),
        Entry(name: "rowsRefilled", parameterTypes: [], expectation: .notSafe, hasContract: true),
        Entry(name: "rowsSwappedByTuple", parameterTypes: [], expectation: .notSafe, hasContract: true),
        Entry(name: "rowsCopyWritten", parameterTypes: [], expectation: .notRefuted, hasContract: true),
        Entry(name: "rowsFilled", parameterTypes: [], expectation: .notSafe, hasContract: true),
        Entry(name: "label", parameterTypes: ["Int8"], expectation: .contractHolds, hasContract: true),
        Entry(name: "labelWrong", parameterTypes: ["Int8"], expectation: .fails, hasContract: true),
        Entry(name: "kindPicked", parameterTypes: ["Int8"], expectation: .contractHolds, hasContract: true),
        Entry(name: "kindPickedWrong", parameterTypes: ["Int8"], expectation: .fails, hasContract: true),
        Entry(name: "pairOf", parameterTypes: ["Int8"], expectation: .contractHolds, hasContract: true),
        Entry(name: "pairSwapped", parameterTypes: ["Int8"], expectation: .fails, hasContract: true),
        Entry(name: "halvedDouble", parameterTypes: ["Double"], expectation: .fails, hasContract: true),
        Entry(name: "cgHalved", parameterTypes: ["Double"], expectation: .fails, hasContract: true),
        // True, but the solver does not decide it within the default budget: never refuted.
        Entry(name: "cgHalvedNormal", parameterTypes: ["Double"], expectation: .notRefuted, hasContract: true),
    ]
}
