import Foundation
import SFVerifyKit
import Testing

/// The planted-bug suite, logic side (docs/TESTING.md, "Planted-bug suite"). Scan reads the mappers of
/// `Tests/SwiftFormalTestingTests/PlantedBugs/`, the same files the walks of `PlantedBugWalkTests` run. Each shape has
/// a buggy mapper that logic must catch (`contractFails` or `mayTrap` at the planted input) and a fixed one it must
/// prove. A shape logic cannot read yet is a known gap: its buggy mapper must still never be a pass, and the catch
/// it should give is a known issue, so the test fails (and must be updated) on the day Scan catches it.
@Suite struct PlantedBugScanTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SwiftFormalTestingTests/PlantedBugs")

    static let report = Result {
        let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path).filter { $0.hasSuffix(".swift") }.sorted()
        let files = names.map { fixtures.appendingPathComponent($0).path }
        return try SFVerify.run(CompileOptions(files: files, moduleName: "PlantedBugs"), VerifyOptions())
    }

    static func function(_ name: String) throws -> FunctionReport {
        try #require(try report.get().functions.first { $0.name == name }, "no \(name) in the scan")
    }

    static func inputs(_ function: FunctionReport) -> String { function.counterexample?.inputs.joined(separator: ", ") ?? "" }

    /// The buggy mapper is caught with `status` at `input`, and the fixed one proves.
    static func expectCaught(
        _ buggy: String, _ status: ScanStatus, at input: String, fixed: String, proves: ScanStatus = .contractHolds,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) throws {
        let caught = try function(buggy)
        #expect(caught.status == status, "\(caught.detail ?? "")", sourceLocation: sourceLocation)
        #expect(inputs(caught) == input, sourceLocation: sourceLocation)
        let proved = try function(fixed)
        #expect(proved.status == proves, "\(proved.detail ?? "")", sourceLocation: sourceLocation)
    }

    /// A buggy mapper logic cannot read yet: never a pass, and not read for the reason given.
    static func expectGap(
        _ name: String, _ status: ScanStatus, because reason: String, sourceLocation: Testing.SourceLocation = #_sourceLocation
    )
        throws -> FunctionReport
    {
        let gap = try function(name)
        #expect(gap.status == status, sourceLocation: sourceLocation)
        #expect(gap.detail?.contains(reason) == true, "\(gap.detail ?? "")", sourceLocation: sourceLocation)
        return gap
    }

    /// The soundness floor of the suite: no buggy mapper, read or not, is ever `safe` or `contractHolds`.
    @Test func noBuggyMapperIsEverAPass() throws {
        let buggy = try Self.report.get().functions.filter { $0.name.contains("Buggy(") }
        #expect(buggy.count == 27)
        for function in buggy {
            #expect(function.status != .safe && function.status != .contractHolds, "\(function.name) passed")
        }
    }

    @Test func shape1TwoCasesWithTheSameText() throws {
        try Self.expectCaught("deltaTextBuggy(_:)", .contractFails, at: "delta = .minusTwo", fixed: "deltaTextFixed(_:)")
    }

    @Test func shape2ATrapOnlyAFilteringCallerAvoids() throws {
        try Self.expectCaught("feePercentBuggy(_:)", .mayTrap, at: "payment = .refund", fixed: "feePercentFixed(_:)")
        #expect(try Self.function("fee(for:)").status == .safe)
    }

    @Test func shape3ParseOfFormatForOneLocale() throws {
        // `Locale.decimalSeparator` is an assumed call (KNOWN-ISSUES 22); the text code after it is not read.
        let buggy = try Self.expectGap("priceRoundTripBuggy(_:_:)", .unsupported, because: "split(separator:")
        let fixed = try Self.expectGap("priceRoundTripFixed(_:_:)", .unsupported, because: "Character.init")
        withKnownIssue("Scan holds a Locale as an opaque value and cannot read String.split or Int(String)") {
            #expect(buggy.status == ScanStatus.contractFails)
        }
        withKnownIssue("the same: the fixed round trip cannot be proved either") { #expect(fixed.status == ScanStatus.contractHolds) }
    }

    @Test func shape4ATrapOnNaN() throws {
        let buggy = try Self.function("wholePercentBuggy(_:)")
        #expect(buggy.status == .mayTrap)
        // `percent = Double.nan`, or a NaN written as its bits.
        let input = Self.inputs(buggy)
        let bits = input.split(separator: "0x").last.flatMap { UInt64($0.prefix { $0.isHexDigit }, radix: 16) }
        #expect(input == "percent = Double.nan" || bits.map { Double(bitPattern: $0).isNaN } == true, "\(input)")
        #expect(try Self.function("wholePercentFixed(_:)").status == .safe)
    }

    @Test func shape5NegativeZero() throws {
        // "-" before an integer's text is "-0" exactly when the integer is 0 (`SILTextSplits.swift`).
        let interpolation = try Self.function("degreesTextBuggy(_:)")
        #expect(interpolation.status == .contractFails, "\(interpolation.detail ?? "")")
        let tenths = Self.inputs(interpolation).split(separator: " = ").last.flatMap { Int($0) }
        #expect(tenths.map { (-9)...(-1) ~= $0 } == true, "\(Self.inputs(interpolation))")
        // An integer's own text is modelled, and it is never "-0".
        #expect(try Self.function("degreesTextFixed(_:)").status == .contractHolds)

        let format = try Self.expectGap("temperatureTextBuggy(_:)", .undecided, because: "String(format:_:)")
        let fixed = try Self.expectGap("temperatureTextFixed(_:)", .unsupported, because: "String(format:_:)")
        withKnownIssue("Scan does not model the text %.0f prints for a Double") {
            #expect(format.status == ScanStatus.contractFails)
        }
        withKnownIssue("the same: the fixed String(format:) cannot be proved either") { #expect(fixed.status == ScanStatus.contractHolds) }
    }

    @Test func shape6ADefaultArmTakesACase() throws {
        try Self.expectCaught("badgeBuggy(_:)", .contractFails, at: "status = .submitted", fixed: "badgeFixed(_:)")
    }

    @Test func shape7ALossyRoundTrip() throws {
        try Self.expectCaught("storedCodeBuggy(_:)", .contractFails, at: "unit = .feet", fixed: "storedCodeFixed(_:)")
    }

    @Test func shape8AnOffByOneBoundary() throws {
        try Self.expectCaught("batteryLevelBuggy(_:)", .contractFails, at: "percent = 20", fixed: "batteryLevelFixed(_:)")
    }

    @Test func shape9AWrongArmOverAnEnumFromABinaryFramework() throws {
        try Self.expectCaught("barsBuggy(_:)", .contractFails, at: "signal = .fair", fixed: "barsFixed(_:)")
    }

    @Test func shape10AForgottenSubclassOfASealedHierarchy() throws {
        // A walk over the generated domain catches it (PlantedBugWalkTests); logic does not read class hierarchies yet.
        let buggy = try Self.expectGap("rewardTextBuggy(_:)", .unsupported, because: "class Reward")
        let fixed = try Self.expectGap("rewardTextFixed(_:)", .unsupported, because: "class Reward")
        withKnownIssue("Scan holds a class instance as unsupported, so it cannot tell the subclasses apart") {
            #expect(buggy.status == ScanStatus.contractFails)
        }
        // The fixed switch is never refuted: a correct mapper gets no counterexample.
        #expect(fixed.status != .contractFails)
        #expect(fixed.counterexample == nil)
    }

    @Test func shape12ClosuresOverRows() throws {
        try Self.expectCaught("cardDistancesBuggy(_:)", .contractFails, at: "unit = .yards", fixed: "cardDistancesFixed(_:)")
        try Self.expectCaught("teeForDriveBuggy(_:)", .contractFails, at: "drive = 200", fixed: "teeForDriveFixed(_:)")
        let par = try Self.function("holesOfParBuggy(_:)")
        #expect(par.status == .contractFails, "\(par.detail ?? "")")
        #expect(["par = 3", "par = 4"].contains(Self.inputs(par)), "\(Self.inputs(par))")
        #expect(try Self.function("holesOfParFixed(_:)").status == .contractHolds)
        // Any calm speed shows the wrong arm.
        let wind = try Self.function("windBuggy(_:)")
        #expect(wind.status == .contractFails, "\(wind.detail ?? "")")
        let speed = Self.inputs(wind).split(separator: " = ").last.flatMap { Int8($0) }
        #expect(speed.map { $0 < 10 } == true, "\(Self.inputs(wind))")
        #expect(try Self.function("windFixed(_:)").status == .contractHolds)
        // An array of unknown length: proved only up to 8 elements, never for all; a length the contract fixes proves.
        let unknown = try Self.function("underParCountBuggy(_:)")
        #expect(unknown.status == .undecided && unknown.category == "bounded", "\(unknown.status) \(unknown.detail ?? "")")
        #expect(unknown.bounded == ["filter over Array<Int8> (n ≤ 8)"], "\(unknown.bounded ?? [])")
        #expect(try Self.function("underParCountFixed(_:)").status == .contractHolds)
    }

    /// Shape 12b: destroying a row may run the deinit of the tracker its closure captured, which traps. Its own scan,
    /// so the trapping deinit does not reach the other shapes: `Fixtures/PlantedDeinit`.
    static func deinitReport(opaqueCalls: Bool) throws -> ScanReport {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PlantedDeinit/CapturedTracker.swift")
        var options = VerifyOptions()
        options.configurations = [.debug]
        options.opaqueCalls = opaqueCalls
        return try SFVerify.run(CompileOptions(files: [fixture.path], moduleName: "PlantedDeinit"), options)
    }

    @Test func shape12bAClosureWhoseCaptureMayTrapWhenDestroyed() throws {
        let assumed = try #require(try Self.deinitReport(opaqueCalls: true).functions.first { $0.name == "rowScore(_:)" })
        // A pass only while it says what it took on trust: the deinit, named by its class.
        if assumed.status == .safe || assumed.status == .contractHolds {
            #expect(
                assumed.assumptions?.contains { $0.contains("deinit of TapTracker does not trap") } == true, "\(assumed.assumptions ?? [])")
        }
        #expect(assumed.status == .contractHolds, "\(assumed.status) \(assumed.detail ?? "")")
        // With `--no-opaque-calls` nothing is taken on trust, so it is no pass.
        let strict = try #require(try Self.deinitReport(opaqueCalls: false).functions.first { $0.name == "rowScore(_:)" })
        #expect(strict.status == .unsupported || strict.status == .mayTrap, "\(strict.status)")
        #expect(strict.assumptions == nil)
        #expect(strict.detail?.contains("TapTracker") == true, "\(strict.detail ?? "")")
    }

    @Test func shape12bAnUnreadSuperclassDeinitIsNeverTrustedSilently() throws {
        func scan(opaqueCalls: Bool) throws -> FunctionReport {
            var options = VerifyOptions()
            options.configurations = [.debug]
            options.opaqueCalls = opaqueCalls
            let report = try SFVerify.run(try BinaryFixture.client(["VendorCache.swift"], moduleName: "PlantedVendorCache"), options)
            return try #require(report.functions.first { $0.name == "cachedScore(_:)" })
        }
        let assumed = try scan(opaqueCalls: true)
        #expect(assumed.status == .contractHolds, "\(assumed.status) \(assumed.detail ?? "")")
        #expect(assumed.assumptions?.contains { $0.contains("deinit of VendorBase does not trap") } == true, "\(assumed.assumptions ?? [])")
        let strict = try scan(opaqueCalls: false)
        #expect(strict.status == .unsupported || strict.status == .mayTrap, "\(strict.status)")
        #expect(strict.detail?.contains("VendorBase") == true, "\(strict.detail ?? "")")
    }

    @Test func shape13Text() throws {
        // The same key gives the same text whatever the catalogue says (docs/KNOWN-ISSUES.md #21).
        let sameKey = try Self.function("teeTitleBuggy(_:)")
        #expect(sameKey.status == .contractFails, "\(sameKey.detail ?? "")")
        #expect(Self.inputs(sameKey) == "tee = .middle")
        #expect(sameKey.assumptions?.contains { $0.contains("localization is deterministic") } == true)
        // Different keys may still have the same text in some language: never proved.
        let fixedKeys = try Self.function("teeTitleFixed(_:)")
        #expect(fixedKeys.status == .undecided, "\(fixedKeys.detail ?? "")")
        withKnownIssue("different keys may have the same text: only a walk over the real catalogue shows they do not") {
            #expect(fixedKeys.status == ScanStatus.contractHolds)
        }

        let format = try Self.function("holesTextBuggy(_:_:)")
        #expect(format.status == .mayTrap, "\(format.detail ?? "")")
        #expect(
            format.counterexample?.failure.contains("String(format:_:) reads argument 2") == true, "\(format.counterexample?.failure ?? "")"
        )
        #expect(try Self.function("holesTextFixed(_:_:)").status == .contractHolds)

        try Self.expectCaught("parTextBuggy(_:)", .contractFails, at: "toPar = 0", fixed: "parTextFixed(_:)")

        let catalogue = Self.fixtures.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SFVerifyKitTests/Fixtures/Strings/PlantedShape13")
        let lint = StringsLint.run(paths: [catalogue.path])
        #expect(
            lint.problems.map { "\($0.kind.rawValue) \($0.key) \($0.language ?? "")" } == [
                "format holes.played da", "missing tee.forward da",
            ])
    }

    /// Shape 14: a `UUID` and a `URL` are held as opaque values, so a struct with them is read; swapping two ids is
    /// caught, and passing them through is proved. A contract about what is inside a `URL` is never proved.
    @Test func shape14FoundationValuesInAMapper() throws {
        let swapped = try Self.function("bookingRowBuggy(_:)")
        #expect(swapped.status == .contractFails, "\(swapped.detail ?? "")")
        #expect(Self.inputs(swapped).contains("<UUID "), "\(Self.inputs(swapped))")
        let fixed = try Self.function("bookingRowFixed(_:)")
        #expect(fixed.status == .contractHolds, "\(fixed.detail ?? "")")
        let contents = try Self.function("bookingLinkText(_:)")
        #expect(contents.status != .contractHolds && contents.status != .contractFails, "\(contents.status) \(contents.detail ?? "")")
    }

    /// Shape 14: rounding on `Double` is exact, ties and the sign of zero included.
    @Test func shape14RoundingTiesNegativeZeroAndNaN() throws {
        func value(_ name: String) throws -> Double {
            let input = Self.inputs(try Self.function(name))
            return try #require(Double(input.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""), "\(input)")
        }
        let tie = try Self.function("halfPointsBuggy(_:)")
        #expect(tie.status == .contractFails, "\(tie.detail ?? "")")
        let points = try value("halfPointsBuggy(_:)")
        #expect(points.rounded(.toNearestOrEven) != points.rounded(.toNearestOrAwayFromZero), "\(points)")
        #expect(try Self.function("halfPointsFixed(_:)").status == .contractHolds)

        let signed = try Self.function("signedRoundBuggy(_:)")
        #expect(signed.status == .contractFails, "\(signed.detail ?? "")")
        let x = Float(try value("signedRoundBuggy(_:)"))
        #expect((x + 0.5).rounded(.down) != x.rounded(), "\(x)")
        #expect(try Self.function("signedRoundFixed(_:)").status == .contractHolds)

        let zero = try Self.function("displayCelsiusBuggy(_:)")
        #expect(zero.status == .contractFails, "\(zero.detail ?? "")")
        let celsius = try value("displayCelsiusBuggy(_:)")
        #expect(celsius > -0.5 && celsius <= 0 && (celsius.sign == .minus || celsius < 0), "\(celsius)")
        #expect(try Self.function("displayCelsiusFixed(_:)").status == .contractHolds)

        let nan = try Self.function("wholeMinutesBuggy(_:)")
        #expect(nan.status == .mayTrap, "\(nan.detail ?? "")")
        let input = Self.inputs(nan)
        let bits = input.split(separator: "0x").last.flatMap { UInt64($0.prefix { $0.isHexDigit }, radix: 16) }
        #expect(input == "seconds = Double.nan" || bits.map { Double(bitPattern: $0).isNaN } == true, "\(input)")
        #expect(try Self.function("wholeMinutesFixed(_:)").status == .safe)
    }

    /// Shape 14: `Date` is the `Double` it wraps, so a due date one day early is caught; `Decimal` arithmetic is not
    /// read as `Double`'s, so the split bill is neither proved nor refuted.
    @Test func shape14ADueDateOneDayEarlyAndDecimal() throws {
        let due = try Self.function("dueDateBuggy(_:_:)")
        #expect(due.status == .contractFails, "\(due.detail ?? "")")
        #expect(try Self.function("dueDateFixed(_:_:)").status == .contractHolds)
        _ = try Self.expectGap("shareBuggy(_:)", .unsupported, because: "Decimal arithmetic")
    }

    /// Shape 11 reads types of a binary module (`BinaryFixture`), so it is its own scan: `Fixtures/BinaryTypes`.
    static let binaryReport = Result {
        var options = VerifyOptions()
        options.configurations = [.debug]
        return try SFVerify.run(try BinaryFixture.client(["PlantedBinaryTypes.swift"], moduleName: "PlantedBinaryTypes"), options)
    }

    static func binaryFunction(_ name: String) throws -> FunctionReport {
        try #require(try binaryReport.get().functions.first { $0.name == name }, "no \(name) in the scan")
    }

    @Test func shape11TypesOfABinaryModule() throws {
        let text = try Self.binaryFunction("surfaceTextBuggy(_:)")
        #expect(text.status == .contractFails, "\(text.detail ?? "")")
        #expect(Self.inputs(text) == "surface = .fast", "\(Self.inputs(text))")
        // A forgotten case and two cases mixed up: `onEnum(of:)` may return any case, so both are reached.
        for (name, input) in [("shotIconBuggy(_:)", ".drive"), ("shotTitleBuggy(_:)", ".putt")] {
            let caught = try Self.binaryFunction(name)
            #expect(caught.status == .contractFails, "\(name): \(caught.detail ?? "")")
            #expect(Self.inputs(caught).contains("onEnum(of:) returned \(input)"), "\(name): \(Self.inputs(caught))")
        }
        for name in ["surfaceTextFixed(_:)", "shotIconFixed(_:)", "shotTitleFixed(_:)"] {
            let fixed = try Self.binaryFunction(name)
            #expect(fixed.status == .contractHolds, "\(name): \(fixed.status) \(fixed.detail ?? "")")
        }
        // A proof through `onEnum(of:)`, which has no body, says what it took on trust; one over a plain enum does not.
        #expect(try Self.binaryFunction("surfaceTextFixed(_:)").assumptions == nil)
        for name in ["shotIconFixed(_:)", "shotTitleFixed(_:)"] {
            let assumptions = try Self.binaryFunction(name).assumptions
            #expect(assumptions?.isEmpty == false, "\(name)")
            #expect(assumptions?.contains { $0.contains("onEnum(of:)") } == true, "\(name): \(assumptions ?? [])")
        }
        let buggy = try Self.binaryReport.get().functions.filter { $0.name.contains("Buggy(") }
        #expect(buggy.count == 3)
        for function in buggy {
            #expect(function.status != .safe && function.status != .contractHolds, "\(function.name) passed")
        }
    }
}
