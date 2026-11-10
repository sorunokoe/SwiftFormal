import Foundation
import SwiftFormal
import SwiftFormalTesting
import Testing

/// The planted-bug suite, walk side (docs/TESTING.md, "Planted-bug suite"). Each shape in `PlantedBugs/` has a
/// buggy mapper and a fixed one. The buggy one must fail its walk at the planted input; the fixed one must prove.
/// `PlantedBugScanTests` checks the same files with logic. A shape whose bug is a trap is caught by logic only: an
/// in-process walk cannot survive a trap.
@Suite struct PlantedBugWalkTests {
    private struct NoValue: Error {}

    private static func value<T>(_ optional: T?) throws -> T {
        guard let optional else { throw NoValue() }
        return optional
    }

    private static func expectCaught(
        _ report: Report, _ property: String, input: String? = nil, detail: String...,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(!report.isProved, "the planted bug was not caught", sourceLocation: sourceLocation)
        let found = report.counterexamples.first { $0.property == property }?.counterexample
        for part in detail { #expect(found?.detail.contains(part) == true, "\(report)", sourceLocation: sourceLocation) }
        if let input { #expect(found?.input == input, "\(report)", sourceLocation: sourceLocation) }
    }

    @Test func shape1TwoCasesWithTheSameText() {
        let buggy = runWalk("deltaTextBuggy", deltaTextBuggy, over: .allCases) { Injective() }
        Self.expectCaught(buggy, "injective", input: "plusTwo", detail: "Delta.minusTwo and ", "Delta.plusTwo both give \"2\"")
        Prove(it: deltaTextFixed, over: .allCases) {
            Injective()
            RoundTrip(through: { try Self.value(parseDelta($0)) })
        }
    }

    @Test func shape2TheFilteringCallerNeverTraps() {
        Prove(it: fee(for:), over: .allCases) { Outputs(within: [0, 1, 2]) }
        Prove(it: feePercentFixed, over: Domain<Payment>.allCases.filter(feePercentFixed_requires)) {
            Outputs(exactly: [0, 1, 2])
        }
    }

    private static let prices = Domain.product(.int(0...1_000), .of(["en_US", "de_DE"])).map { Price(cents: $0.0, localeID: $0.1) }

    @Test func shape3ParseOfFormatForEveryLocale() {
        let buggy = runWalk("formatPrice", formatPrice, over: Self.prices) {
            RoundTrip(through: { try Self.value(parsePriceBuggy($0)) })
        }
        Self.expectCaught(buggy, "round trip", detail: "inverse threw")
        #expect(buggy.counterexamples.first?.counterexample.input?.contains("de_DE") == true, "\(buggy)")
        Prove(it: formatPrice, over: Self.prices) { RoundTrip(through: { try Self.value(parsePriceFixed($0)) }) }
    }

    @Test func shape4TheFixedPercentNeverTrapsOnSpecialValues() {
        Prove(it: wholePercentFixed, over: .samples([-.infinity, -1, 0, 0.4, 0.5, 99.6, 100, 101, .infinity, .nan]), allowBounded: true) {
            Outputs(within: Set(0...100))
        }
    }

    @Test func shape5NoNegativeZero() {
        let tenths = Domain.int(-200...200).map { Int16($0) }
        let buggy = runWalk("degreesTextBuggy", degreesTextBuggy, over: tenths) { Satisfies("never -0") { _, text in text != "-0" } }
        Self.expectCaught(buggy, "never -0", detail: "gave \"-0\"")
        Prove(it: degreesTextFixed, over: tenths) { Satisfies("never -0") { _, text in text != "-0" } }

        let celsius = Domain.int(-30...30).map { Double($0) / 10 }.asSample
        let buggyFormat = runWalk("temperatureTextBuggy", temperatureTextBuggy, over: celsius) {
            Satisfies("never -0") { _, text in text != "-0" }
        }
        Self.expectCaught(buggyFormat, "never -0", detail: "gave \"-0\"")
        Prove(it: temperatureTextFixed, over: celsius, allowBounded: true) { Satisfies("never -0") { _, text in text != "-0" } }
    }

    @Test func shape6ADefaultArmTakesACase() {
        let table: KeyValuePairs<OrderStatus, Badge> = [
            .draft: .none, .submitted: .pending, .approved: .success, .rejected: .failure, .archived: .none,
        ]
        let buggy = runWalk("badgeBuggy", badgeBuggy, over: .allCases) {
            Matches(table: table)
            Outputs(exactly: [.none, .pending, .success, .failure])
        }
        Self.expectCaught(buggy, "matches table", input: "submitted", detail: "expected ", "Badge.pending, got ", "Badge.none")
        Self.expectCaught(buggy, "image equals expected set", detail: "never produced: ", "Badge.pending")
        Prove(it: badgeFixed, over: .allCases) {
            Matches(table: table)
            Outputs(exactly: [.none, .pending, .success, .failure])
        }
    }

    @Test func shape7ALossyRoundTrip() {
        let buggy = runWalk("storedCodeBuggy", storedCodeBuggy, over: .allCases) {
            RoundTrip(through: { try Self.value(DistanceUnit(rawValue: $0)) })
        }
        Self.expectCaught(buggy, "round trip", input: "feet", detail: "DistanceUnit.feet -> \"yd\" -> ", "DistanceUnit.yards")
        Prove(it: storedCodeFixed, over: .allCases) { RoundTrip(through: { try Self.value(DistanceUnit(rawValue: $0)) }) }
    }

    /// The inputs of each output as one range, in order: the partition the mapper draws.
    private static func bands(_ level: @escaping (Int) -> BatteryLevel) -> [String] {
        runPartition(level, over: .int(0...100)).groups.map { "\($0.output): \($0.inputs.first ?? -1)...\($0.inputs.last ?? -1)" }
    }

    @Test func shape8AnOffByOneBoundary() {
        let expected = ["low: 0...20", "medium: 21...79", "high: 80...100"]
        #expect(Self.bands(batteryLevelBuggy) == ["low: 0...19", "medium: 20...79", "high: 80...100"])
        #expect(Self.bands(batteryLevelBuggy) != expected)
        #expect(Self.bands(batteryLevelFixed) == expected)
        let levels = Domain.int(0...100)
        let spec = { (percent: Int, level: BatteryLevel) in batteryLevelFixed_ensures(percent, level) }
        let buggy = runWalk("batteryLevelBuggy", batteryLevelBuggy, over: levels) { Satisfies("bands", spec) }
        Self.expectCaught(buggy, "bands", input: "20", detail: "gave ", "BatteryLevel.medium")
        Prove(it: batteryLevelFixed, over: levels) { Satisfies("bands", spec) }
    }

    @Test func shape9AWrongArmOverAnEnumFromABinaryFramework() {
        // `SignalStrength` is only `CaseIterable`, so its own `domain` is a sample: nothing proves an `allCases`
        // complete. `.signalStrength`, generated by `sfgen domains` (GeneratedBinaryDomains.swift), checks `allCases`
        // against the cases the compiler declares, so the fixed mapper proves over it.
        let spec = { (signal: SignalStrength, bars: Int) in barsFixed_ensures(signal, bars) }
        let buggy = runWalk("barsBuggy", barsBuggy, over: SignalStrength.domain) { Satisfies("bars", spec) }
        Self.expectCaught(buggy, "bars", input: "fair", detail: "gave 3")
        #expect(!runWalk("barsFixed", barsFixed, over: SignalStrength.domain) { Satisfies("bars", spec) }.isProved)
        Prove(it: barsFixed, over: .signalStrength) { Satisfies("bars", spec) }
        // `Volume.allCases` is hand-written and forgets a case: the generated domain is then a sample.
        #expect(Domain<Volume>.volume.count == 2)
        #expect(!Domain<Volume>.volume.complete)
    }

    @Test func shape10AForgottenSubclassOfASealedHierarchy() {
        // `.reward` is generated by `sfgen domains` (GeneratedBinaryDomains.swift): every case of the hierarchy, each
        // built from its own fields.
        let spec = { (reward: Reward, text: String) in rewardTextFixed_ensures(reward, text) }
        let buggy = runWalk("rewardTextBuggy", rewardTextBuggy, over: .reward) { Satisfies("only none reads as none", spec) }
        Self.expectCaught(
            buggy, "only none reads as none", input: "SwiftFormalTestingTests.RewardVoucher", detail: "gave \"no reward\"")
        Prove(it: rewardTextFixed, over: .reward) { Satisfies("only none reads as none", spec) }
    }

    @Test func shape12ClosuresOverRows() {
        let three = { (_: CardUnit, shown: [Int16]) in shown.count == 3 }
        let card = runWalk("cardDistancesBuggy", cardDistancesBuggy, over: .allCases) { Satisfies("three distances", three) }
        Self.expectCaught(card, "three distances", input: "yards", detail: "gave [54, 109]")
        Prove(it: cardDistancesFixed, over: .allCases) { Satisfies("three distances", three) }

        let drives = Domain.int(151...249).map { Int16($0) }
        let tee = { (drive: Int16, tee: Int16?) in teeForDriveFixed_ensures(drive, tee) }
        let buggyTee = runWalk("teeForDriveBuggy", teeForDriveBuggy, over: drives) { Satisfies("nearest tee", tee) }
        Self.expectCaught(buggyTee, "nearest tee", input: "200", detail: "gave Optional(250)")
        Prove(it: teeForDriveFixed, over: drives) { Satisfies("nearest tee", tee) }

        let pars = Domain.int(3...5).map { Int8($0) }
        let holes = { (par: Int8, count: Int) in holesOfParFixed_ensures(par, count) }
        let buggyHoles = runWalk("holesOfParBuggy", holesOfParBuggy, over: pars) { Satisfies("holes of par", holes) }
        Self.expectCaught(buggyHoles, "holes of par", input: "3", detail: "gave 6")
        Prove(it: holesOfParFixed, over: pars) { Satisfies("holes of par", holes) }

        let speeds = Domain.optional(Domain.int(-128...127).map { Int8($0) })
        let wind = { (speed: Int8?, wind: Wind?) in windFixed_ensures(speed, wind) }
        let buggyWind = runWalk("windBuggy", windBuggy, over: speeds) { Satisfies("wind", wind) }
        Self.expectCaught(buggyWind, "wind", detail: "Wind.breeze")
        Prove(it: windFixed, over: speeds) { Satisfies("wind", wind) }

        // A trap ends a walk, so only the fixed count is walked: an 18-hole round always fits.
        let rounds = Domain.samples([Array(repeating: Int8(-1), count: 18), Array(repeating: 0, count: 18)])
        Prove(it: underParCountFixed, over: rounds, allowBounded: true) { Outputs(within: [0, 18]) }
    }

    @Test func shape13Text() {
        // The test bundle has no catalogue, so a localized text is its key: two tees with the same key share a text.
        let buggy = runWalk("teeTitleBuggy", teeTitleBuggy, over: .allCases) { Injective() }
        Self.expectCaught(buggy, "injective", detail: "Tee.back and ", "Tee.middle both give \"tee.back\"")
        Prove(it: teeTitleFixed, over: .allCases) { Injective() }

        // The buggy format reads memory it was not given: logic only (PlantedBugScanTests).
        let counts = Domain.product(Domain.int(0...18), .of([9, 18])).map { (Int32($0.0), Int32($0.1)) }
        Prove(it: { (counts: (Int32, Int32)) in holesTextFixed(counts.0, counts.1) }, over: counts) {
            Satisfies("not empty") { _, text in !text.isEmpty }
        }

        let scores = Domain.int(-10...10).map { Int8($0) }
        let buggyPar = runWalk("parTextBuggy", parTextBuggy, over: scores) { Satisfies("E for even par", parTextBuggy_ensures) }
        Self.expectCaught(buggyPar, "E for even par", input: "0", detail: "gave \"+0\"")
        Prove(it: parTextFixed, over: scores) { Satisfies("E for even par", parTextFixed_ensures) }
    }

    /// Shape 15: the walks are over samples, so they are bounded; `swiftformal check` proves or refutes the
    /// `Injective`, `RoundTrip` and `Agrees` claims for every input with logic (RelationalProofTests).
    @Test func shape15MappedCorrectly() {
        let seats = Domain.samples((0..<4).flatMap { row in [0, 1, 99, 127].map { Seat(row: row, number: $0) } })
        // The broken code collides only at seat 128 and up, which the samples do not reach: the walk cannot tell.
        #expect(runWalk("seatCodeBroken", seatCodeBroken, over: seats) { Injective() }.hasNoCounterexample)
        Prove(it: seatCodeFixed, over: seats, allowBounded: true) { Injective() }

        let cards = Domain.samples([Card(strokes: 72, putts: 30), Card(strokes: 0, putts: 0), Card(strokes: 255, putts: 99)])
        #expect(runWalk("cardCode", cardCode, over: cards) { RoundTrip(through: cardFromCodeBroken) }.hasNoCounterexample)
        let rare = runWalk("cardCode", cardCode, over: .samples([Card(strokes: 72, putts: 100)])) { RoundTrip(through: cardFromCodeBroken) }
        Self.expectCaught(rare, "round trip", detail: "putts: 99")
        Prove(it: cardCode, over: cards, allowBounded: true) { RoundTrip(through: cardFromCodeFixed) }

        let ratings = Domain.int(-128...127).map { Int8($0) }
        let band = runWalk("bandBroken", bandBroken, over: ratings) { Agrees(with: bandReference) }
        Self.expectCaught(band, "agrees with other rule", input: "20", detail: "Band.middle, got ", "Band.high")
        Prove(it: bandFixed, over: ratings) { Agrees("same bands as the reference", with: bandReference) }

        let rawKey = NeverOutputs<Weather, String>("a raw key", where: { _, text in text.hasPrefix("weather.") })
        let weather = runWalk("weatherTextBroken", weatherTextBroken, over: .allCases) { rawKey }
        Self.expectCaught(weather, "never outputs a raw key", input: "rainy", detail: "gave \"weather.rainy\"")
        Prove(it: weatherTextFixed, over: .allCases) {
            rawKey
            NeverOutputs("")
        }
    }

    @Test func injectiveExceptListedMerges() {
        let codes: (Band) -> Int = { $0 == .high ? 1 : 0 }
        let unlisted = runWalk("codes", codes, over: .of([.low, .middle, .high])) { Injective(except: []) }
        Self.expectCaught(
            unlisted, "injective except listed merges", detail: "Band.low and ", "Band.middle both give 0, and the pair is not listed")
        Prove(it: codes, over: .of([.low, .middle, .high])) { Injective(except: [(.middle, .low)]) }
        let stale = runWalk("codes", codes, over: .of([.low, .middle, .high])) { Injective(except: [(.middle, .low), (.low, .high)]) }
        Self.expectCaught(
            stale, "injective except listed merges", detail: "Band.low and ", "Band.high are listed as merged but give 0 and 1")
        let relation = runWalk("bandFixed", bandFixed, over: .of([0, 20, 21])) {
            Agrees(with: { Int($0) }, where: { band, number in (band == .high) == (number > 20) })
        }
        #expect(relation.isProved, "\(relation)")
    }
}
