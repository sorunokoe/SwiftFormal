import SwiftFormal
import Testing

enum IntegrationSurface: CaseIterable, Finite { case grass, gravel, sand, pondCenter, pondEdge }

@Verify(over: .product(.int(0...1_000), .int(-5...105)))
func discounted(price: Int, percent: Int) -> Int {
    #requires(percent >= 0 && percent <= 100)
    #ensures { $0 >= 0 && $0 <= price }
    return price - price * percent / 100
}

@Verify(over: .product(.int(0...20), .int(0...100)))
func brokenDiscount(_ price: Int, rate percent: Int) -> Int {
    #requires(percent <= 100)
    #ensures { $0 <= price }
    #ensures { $0 >= 0 }
    return percent == 77 ? -1 : price - price * percent / 100
}

@Verify
func label(_ surface: IntegrationSurface?) -> String {
    #ensures { !$0.isEmpty }
    switch surface {
    case .pondCenter?, .pondEdge?: return "pond"
    case .grass?: return "grass"
    case .gravel?: return "gravel"
    case .sand?: return "sand"
    case nil: return "none"
    }
}

@Verify
func firstDigit(_ values: Bool) throws -> Int {
    #ensures { $0 == 0 || $0 == 1 }
    return values ? 1 : 0
}

// The same broken contract with the checks in every build and only in debug builds: the walk finds it either way, also
// in a release test build (`swift test -c release`), where the debug-only checks are compiled out.
@Verify(over: .int(0...20), checks: .always)
func brokenAlways(_ price: Int) -> Int {
    #ensures { $0 <= price }
    return price == 13 ? price + 1 : price
}

@Verify(checks: .debugOnly)
func brokenDebugOnly(_ flag: Bool) -> Bool {
    #ensures { $0 == flag }
    return true
}

struct Strokes {
    var taken: UInt8

    @Verify
    mutating func add(_ extra: UInt8) -> Bool {
        #ensures { added, old in added == (taken > old.taken) }
        #ensures { _, old in taken >= old.taken }
        guard extra <= UInt8.max - taken else { return false }
        taken += extra
        return extra > 0
    }

    @Verify
    mutating func reset() {
        #ensures { _ in taken == 0 }
        taken = 0
    }
}

@Suite struct VerifyMacroIntegrationTests {
    @Test func provesAContractOverAnIntegerGrid() {
        let report = verify_discounted()
        #expect(report.isProved, "\(report)")
        #expect(report.excluded == 1_001 * 10)
    }

    @Test func reportsTheBrokenInputWithItsRealValue() throws {
        let report = verify_brokenDiscount()
        let failure = try #require(report.counterexamples.first)
        #expect(failure.counterexample.input?.hasSuffix(", 77)") == true, "\(report)")
        #expect(failure.counterexample.detail.contains("$0 <= price") || failure.counterexample.detail.contains("$0 >= 0"))
    }

    @Test func finiteParametersNeedNoDomain() {
        let report = verify_label()
        #expect(report.isProved, "\(report)")
        #expect(report.evaluated == 6)
    }

    @Test func theWalkFindsABrokenContractWhicheverBuildsCompileTheChecks() throws {
        let always = try #require(verify_brokenAlways().counterexamples.first)
        #expect(always.counterexample.input == "13", "\(always)")
        let debugOnly = try #require(verify_brokenDebugOnly().counterexamples.first)
        #expect(debugOnly.counterexample.input == "false", "\(debugOnly)")
        #expect(debugOnly.counterexample.detail.contains("$0 == flag"))
    }

    @Test func throwingFunctionsAreSupported() {
        #expect(verify_firstDigit().isProved)
    }

    @Test func theContractIsAlsoPlainFunctionsForScan() {
        #expect(discounted_requires(10, 50))
        #expect(!discounted_requires(10, 101))
        #expect(discounted_ensures(10, 50, 5))
        #expect(!discounted_ensures(10, 50, 11))
        #expect(!brokenDiscount_ensures(20, 77, -1))
        #expect(label_ensures(nil, "none"))
    }

    @Test func aMutatingMethodComparesWithTheValueBeforeTheCall() {
        var strokes = Strokes(taken: 250)
        let added = strokes.add(5)
        let overflowed = !strokes.add(1)
        #expect(added && overflowed)
        #expect(strokes.taken == 255)
        strokes.reset()
        #expect(strokes.taken == 0)

        let before = Strokes(taken: 3)
        #expect(Strokes(taken: 5).add_ensures(2, true, old: before))
        #expect(!Strokes(taken: 2).add_ensures(0, false, old: before))
        #expect(Strokes(taken: 0).reset_ensures(old: before))
        #expect(!Strokes(taken: 1).reset_ensures(old: before))
    }

    @Test func theFunctionStillWorksNormally() {
        #expect(discounted(price: 200, percent: 25) == 150)
        #expect(label(.sand) == "sand")
    }
}
