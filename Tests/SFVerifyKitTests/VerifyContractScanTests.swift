import Foundation
import SFSIL
import SFVerifyKit
import Testing

/// The app `VerifyContractScanTests` scans: what `@Verify` writes, and contracts written by hand.
private let verifyContractApp = """
    import SwiftFormal

    func discount(price: Int8, percent: Int8) -> Int8 {
        if !(price >= 0) { SwiftFormal.Contract.requiresFailed("price >= 0") }
        if !(percent >= 0 && percent <= 100) { SwiftFormal.Contract.requiresFailed("percent >= 0 && percent <= 100") }
        let __sf_result: Int8 = { () -> Int8 in
            return price - price / 100 * percent
        }()
        if !(({ $0 >= 0 && $0 <= price })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 >= 0 && $0 <= price }") }
        return __sf_result
    }
    #sourceLocation(file: "@__swiftmacro_3App8discount6VerifyfMp_.swift", line: 1)
    func discount_requires(_ price: Int8, _ percent: Int8) -> Bool { (price >= 0) && (percent >= 0 && percent <= 100) }
    func discount_ensures(_ price: Int8, _ percent: Int8, _ __sf_result: Int8) -> Bool { ({ $0 >= 0 && $0 <= price })(__sf_result) }
    #sourceLocation()

    func unbounded(price: Int8, percent: Int8) -> Int8 {
        if !(percent >= 0 && percent <= 100) { SwiftFormal.Contract.requiresFailed("percent >= 0 && percent <= 100") }
        let __sf_result: Int8 = { () -> Int8 in
            return price - price / 100 * percent
        }()
        if !(({ $0 >= 0 && $0 <= price })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 >= 0 && $0 <= price }") }
        return __sf_result
    }
    #sourceLocation(file: "@__swiftmacro_3App9unbounded6VerifyfMp_.swift", line: 1)
    func unbounded_requires(_ price: Int8, _ percent: Int8) -> Bool { (percent >= 0 && percent <= 100) }
    func unbounded_ensures(_ price: Int8, _ percent: Int8, _ __sf_result: Int8) -> Bool { ({ $0 >= 0 && $0 <= price })(__sf_result) }
    #sourceLocation()

    func halve(_ x: Int8) -> Int8 {
        if !(x >= 0) { SwiftFormal.Contract.requiresFailed("x >= 0") }
        return x / 2
    }

    struct Bag {
        var base: Int8
        static func atLeast(_ x: Int8) -> Int8 {
            let __sf_result: Int8 = { () -> Int8 in
                return x < 10 ? 10 : x
            }()
            if !(({ $0 >= x })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 >= x }") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App7atLeast6VerifyfMp_.swift", line: 1)
        static func atLeast_ensures(_ x: Int8, _ __sf_result: Int8) -> Bool { ({ $0 >= x })(__sf_result) }
        #sourceLocation()

        func raised(_ by: Int8) -> Int8 {
            let __sf_result: Int8 = { () -> Int8 in
                return base &+ by
            }()
            if !(({ $0 == base &+ by })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 == base &+ by }") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App6raised6VerifyfMp_.swift", line: 1)
        func raised_ensures(_ by: Int8, _ __sf_result: Int8) -> Bool { ({ $0 == base &+ by })(__sf_result) }
        #sourceLocation()

        func lowered(_ by: Int8) -> Int8 {
            let __sf_result: Int8 = { () -> Int8 in
                return base &- by
            }()
            if !(({ $0 <= base })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 <= base }") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App7lowered6VerifyfMp_.swift", line: 1)
        func lowered_ensures(_ by: Int8, _ __sf_result: Int8) -> Bool { ({ $0 <= base })(__sf_result) }
        #sourceLocation()

        // False for every `by != 0`; with `self` and the result swapped it would read as always true.
        func grown(_ by: Int8) -> Bag { Bag(base: base &+ by) }
        #sourceLocation(file: "@__swiftmacro_3App5grown6VerifyfMp_.swift", line: 1)
        func grown_ensures(_ by: Int8, _ r: Bag) -> Bool { base == r.base &+ by }
        #sourceLocation()
    }

    // What `@Verify` writes for a computed property: the getter's code in a closure called at once, then the checks,
    // and the peers `<name>_requires()` / `<name>_ensures(_:)` next to the property.
    struct Card {
        var points: Int8
        var bonus: Int8 {
            if !(points >= 0) { SwiftFormal.Contract.requiresFailed("points >= 0") }
            let __sf_result: Int8 = { () -> Int8 in
                points > 10 ? points - 10 : 0
            }()
            if !(({ $0 >= 0 && $0 <= points })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 >= 0 && $0 <= points }") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App5bonus6VerifyfMp_.swift", line: 1)
        func bonus_requires() -> Bool { (points >= 0) }
        func bonus_ensures(_ __sf_result: Int8) -> Bool { ({ $0 >= 0 && $0 <= points })(__sf_result) }
        #sourceLocation()

        // Broken at points = 127, where the result wraps.
        var next: Int8 {
            let __sf_result: Int8 = { () -> Int8 in
                points &+ 1
            }()
            if !(({ $0 > points })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 > points }") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App4next6VerifyfMp_.swift", line: 1)
        func next_ensures(_ __sf_result: Int8) -> Bool { ({ $0 > points })(__sf_result) }
        #sourceLocation()

        static var cap: Int8 {
            let __sf_result: Int8 = { () -> Int8 in
                100
            }()
            if !(({ $0 > 0 })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ $0 > 0 }") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App3cap6VerifyfMp_.swift", line: 1)
        static func cap_ensures(_ __sf_result: Int8) -> Bool { ({ $0 > 0 })(__sf_result) }
        #sourceLocation()
    }

    // What `@Verify` writes for an `inout` parameter: `_requires` keeps `inout`, the form Scan pairs, and no `_ensures`.
    func bump(_ x: inout Int8, by step: Int8) -> Bool {
        if !(step > 0) { SwiftFormal.Contract.requiresFailed("step > 0") }
        guard x <= Int8.max - step else { return false }
        x += step
        return true
    }
    #sourceLocation(file: "@__swiftmacro_3App4bump6VerifyfMp_.swift", line: 1)
    func bump_requires(_ x: inout Int8, _ step: Int8) -> Bool { (step > 0) }
    #sourceLocation()

    // Another `inout` parameter: `_ensures` would see its value before the call, so it is not paired.
    func countDown(_ x: inout Int8) -> Int8 {
        x = x &- 1
        return 0
    }
    #sourceLocation(file: "@__swiftmacro_3App9countDown6VerifyfMp_.swift", line: 1)
    func countDown_ensures(_ x: Int8, _ r: Int8) -> Bool { x >= 0 }
    #sourceLocation()

    // `mutating`: `_requires` reads `self` before the call; in `_ensures`, `self` is after and `old` before.
    struct Meter {
        var label = ""
        var value: Int8
        var limit: Int8

        mutating func bump(_ by: Int8) {
            if by > 0 { value = by > limit &- value ? limit : value &+ by }
        }
        #sourceLocation(file: "@__swiftmacro_3App4bump6VerifyfMp_.swift", line: 1)
        func bump_requires(_ by: Int8) -> Bool { value >= 0 && value <= limit }
        func bump_ensures(_ by: Int8, old: Meter) -> Bool { value >= old.value && value <= limit && limit == old.limit }
        #sourceLocation()

        // Holds only with `old` and `self` in this order.
        mutating func step() { value = value &+ 1 }
        #sourceLocation(file: "@__swiftmacro_3App4step6VerifyfMp_.swift", line: 1)
        func step_ensures(old: Meter) -> Bool { value == old.value &+ 1 }
        #sourceLocation()

        mutating func take() -> Int8 {
            let taken = value
            value = 0
            return taken
        }
        #sourceLocation(file: "@__swiftmacro_3App4take6VerifyfMp_.swift", line: 1)
        func take_ensures(_ taken: Int8, old: Meter) -> Bool { taken == old.value && value == 0 }
        #sourceLocation()

        // -3 / 2 is -1, which is more than -3.
        mutating func shrink() { value = value / 2 }
        #sourceLocation(file: "@__swiftmacro_3App6shrink6VerifyfMp_.swift", line: 1)
        func shrink_ensures(old: Meter) -> Bool { value <= old.value }
        #sourceLocation()

        // A computed property is checked through its getter.
        var room: Int8 { limit &- value }
        #sourceLocation(file: "@__swiftmacro_3App4room6VerifyfMp_.swift", line: 1)
        func room_requires() -> Bool { value >= 0 && value <= limit }
        func room_ensures(_ room: Int8) -> Bool { room >= 0 && room <= limit }
        #sourceLocation()

        var half: Int8 { value / 2 }
        #sourceLocation(file: "@__swiftmacro_3App4half6VerifyfMp_.swift", line: 1)
        func half_ensures(_ half: Int8) -> Bool { half <= value }
        #sourceLocation()
    }

    // What `@Verify` writes for a `mutating` method: `__sf_old` keeps `self` before the call.
    struct Strokes {
        var count: UInt8

        mutating func add(_ extra: UInt8) -> Bool {
            let __sf_old = self
            let __sf_result: Bool = { () -> Bool in
                guard extra <= UInt8.max - count else { return false }
                count += extra
                return extra > 0
            }()
            if !(({ added, old in added == (count > old.count) })(__sf_result, __sf_old)) { SwiftFormal.Contract.ensuresFailed("added") }
            if !(({ _, old in count >= old.count })(__sf_result, __sf_old)) { SwiftFormal.Contract.ensuresFailed("grows") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App3add6VerifyfMp_.swift", line: 1)
        func add_ensures(_ extra: UInt8, _ __sf_result: Bool, old: Self) -> Bool {
            ({ added, old in added == (count > old.count) })(__sf_result, old) && ({ _, old in count >= old.count })(__sf_result, old)
        }
        #sourceLocation()

        mutating func addWrong(_ extra: UInt8) {
            let __sf_old = self
            let __sf_result: Void = { () -> Void in
                count = count &+ extra
            }()
            if !(({ old in count >= old.count })(__sf_old)) { SwiftFormal.Contract.ensuresFailed("count >= old.count") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App8addWrong6VerifyfMp_.swift", line: 1)
        func addWrong_ensures(_ extra: UInt8, old: Self) -> Bool { ({ old in count >= old.count })(old) }
        #sourceLocation()
    }
    """

/// `@Verify` writes its contract as plain `if` checks that call `Contract.requiresFailed` / `ensuresFailed`, plus
/// `<name>_requires` / `<name>_ensures` peers. These tests scan that exact shape (see `VerifyMacroExpansionTests`)
/// against a stand-in `SwiftFormal` module whose `Contract` functions mangle like the real ones.
@Suite struct VerifyContractScanTests {
    static let stub = """
        public enum Contract {
            @inline(never) public static func requiresFailed(_ text: StaticString, file: StaticString = #fileID, line: UInt = #line) {}
            @inline(never) public static func ensuresFailed(_ text: StaticString, file: StaticString = #fileID, line: UInt = #line) {}
        }
        """

    static let app = verifyContractApp

    /// `app` as `@Verify` writes it by default: each check, and the copy of `self`, inside `#if DEBUG` (each is one line).
    static var debugOnlyApp: String {
        app.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.contains("Failed(\"") || line.contains("let __sf_old = self") ? "#if DEBUG\n\(line)\n#endif" : String(line)
        }.joined(separator: "\n")
    }

    static func scan(_ source: String = app, arguments: [String] = []) throws -> ScanReport {
        let dir = NSTemporaryDirectory() + "sfv-contract-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stubFile = dir + "/SwiftFormal.swift"
        let appFile = dir + "/App.swift"
        try stub.write(toFile: stubFile, atomically: true, encoding: .utf8)
        try source.write(toFile: appFile, atomically: true, encoding: .utf8)
        let module = Process()
        module.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        module.arguments = [
            "swiftc", "-emit-module", "-parse-as-library", "-module-name", "SwiftFormal", stubFile,
            "-emit-module-path", dir + "/SwiftFormal.swiftmodule",
        ]
        try module.run()
        module.waitUntilExit()
        try #require(module.terminationStatus == 0)
        return try SFVerify.run(CompileOptions(files: [appFile], moduleName: "App", extraArguments: ["-I", dir] + arguments))
    }

    /// The checks in the body are only in builds that define `DEBUG` (app study round 6, L23). The verdicts come from the
    /// `_requires` / `_ensures` peers, so a scan with and without `DEBUG` agrees; only the failure text differs.
    @Test func aVerifyContractHasTheSameVerdictWithoutTheDebugChecks() throws {
        let withChecks = try Self.scan(Self.debugOnlyApp, arguments: ["-D", "DEBUG"])
        let withoutChecks = try Self.scan(Self.debugOnlyApp)
        // `halve` is written by hand without a `_requires` peer, which `@Verify` always writes with a `#requires`: without
        // `DEBUG` it has no check left to trap.
        func statuses(_ report: ScanReport) -> [String: ScanStatus] {
            Dictionary(report.functions.filter { !$0.name.hasPrefix("halve(") }.map { ($0.name, $0.status) }) { first, _ in first }
        }
        #expect(statuses(withChecks) == statuses(try Self.scan()))
        #expect(statuses(withoutChecks) == statuses(withChecks))
        #expect(statuses(withoutChecks)["unbounded(price:percent:)"] == .contractFails)

        let failure = { (report: ScanReport) in report.functions.first { $0.name.hasPrefix("unbounded(") }?.counterexample?.failure ?? "" }
        #expect(failure(withChecks).hasPrefix("ensures failed: { $0 >= 0 && $0 <= price }"), "\(failure(withChecks))")
        #expect(failure(withoutChecks).hasPrefix("ensures is false: "), "\(failure(withoutChecks))")
    }

    @Test func aVerifyContractIsProvedOrBrokenOnTheCompiledFunction() throws {
        let report = try Self.scan()
        func fn(_ name: String) throws -> FunctionReport {
            try #require(report.functions.first { $0.name.hasPrefix(name + "(") || $0.name.hasSuffix(" " + name + "(_:)") })
        }

        #expect(try fn("discount").status == .contractHolds)

        // A walk over prices >= 0 misses it; over every Int8 the contract is missing `price >= 0`.
        let unbounded = try fn("unbounded")
        #expect(unbounded.status == .contractFails)
        #expect(unbounded.counterexample?.failure.hasPrefix("ensures failed: { $0 >= 0 && $0 <= price }") == true)

        // Without a `_requires` peer the precondition check is a reachable trap, named as such.
        let halve = try fn("halve")
        #expect(halve.status == .mayTrap)
        #expect(halve.counterexample?.failure == "requires failed: x >= 0")

        // Methods: `self` is the last SIL parameter, so it follows the result in `_ensures`.
        #expect(try fn("static Bag.atLeast").status == .contractHolds)
        #expect(try fn("Bag.raised").status == .contractHolds)
        let lowered = try fn("Bag.lowered")
        #expect(lowered.status == .contractFails)
        #expect(try fn("Bag.grown").status == .contractFails)

        #expect(try fn("Meter.bump").status == .contractHolds)
        #expect(try fn("Meter.step").status == .contractHolds)
        #expect(try fn("Meter.take").status == .contractHolds)
        #expect(try fn("Meter.shrink").status == .contractFails)
        #expect(try fn("Strokes.add").status == .contractHolds)
        let wrong = try fn("Strokes.addWrong")
        #expect(wrong.status == .contractFails, "\(wrong)")
        let getter = { (name: String) in report.functions.first { $0.name == "Meter.\(name).getter" }?.status }
        #expect(getter("room") == .contractHolds)
        #expect(getter("half") == .contractFails)

        // `@Verify` on a computed property: Scan pairs the peers with the getter, instance and `static`.
        let card = { (name: String) in report.functions.first { $0.name.hasSuffix("Card.\(name).getter") } }
        #expect(card("bonus")?.status == .contractHolds, "\(String(describing: card("bonus")))")
        #expect(card("next")?.status == .contractFails)
        #expect(card("next")?.counterexample?.failure.hasPrefix("ensures failed: { $0 > points }") == true)
        #expect(card("cap")?.status == .contractHolds)
        #expect(card("cap")?.name == "static Card.cap.getter")
        #expect(try fn("bump").status == .contractHolds || (try fn("bump").status) == .safe)

        // Not paired, and so not checked: never `safe` with the contract left out.
        let countDown = try fn("countDown")
        #expect(countDown.status == .unsupported)
        #expect(countDown.category == Verifier.contractNotReadCategory)
        #expect(countDown.hasContract)
        #expect(report.functions.contains { $0.name.hasPrefix("countDown_ensures(") })
        #expect(
            !report.functions.contains {
                ($0.name.contains("_requires(") || $0.name.contains("_ensures(")) && !$0.name.hasPrefix("countDown_")
            })
    }
}
