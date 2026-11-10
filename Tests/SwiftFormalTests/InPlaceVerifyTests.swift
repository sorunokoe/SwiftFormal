import SwiftFormal
import Testing

// `@Verify` written in place, compiled for real with `import SwiftFormal`: on computed properties, on functions with
// nothing to walk (Scan proves those), and on functions of 0 to 6 parameters. A function written here with the name
// `verify_<name>` shows that `@Verify` wrote none: two would not compile.

// MARK: Computed properties

private struct Rule {
    var title: String
    var points: Int8

    /// The getter's code is in the braces: `@Verify` applies to the getter.
    @Verify
    var body: String {
        #requires(!title.isEmpty)
        #ensures { result in result.hasPrefix(title) }
        title + "."
    }

    @Verify(checks: .always)
    var isBonus: Bool {
        #ensures { $0 == (points > 10) }
        return points > 10
    }

    /// With a setter the getter is a `get`; `@Verify` goes on it (it warns that no peers can be written there).
    var label: String {
        @Verify get {
            #ensures { !$0.isEmpty }
            return title.isEmpty ? "untitled" : title
        }
        set { title = newValue }
    }
}

private enum Limits {
    @Verify
    static var maximum: Int8 {
        #ensures { $0 > 0 }
        100
    }
}

extension Rule {
    @Verify
    var doubled: Int8 {
        #requires(points >= -64 && points <= 63)
        #ensures { $0 == points * 2 }
        points * 2
    }
}

private enum Surface: CaseIterable, Finite { case grass, sand }

/// A user type that is not `Finite`: the macro cannot tell from the source, so it writes a walk that compiles and is
/// never proved (`Domain.ofParameterType`).
private struct Player { var name: String }

// MARK: Nothing to walk

@Verify
private func greeting(for name: String) -> String {
    #ensures { !$0.isEmpty }
    name.isEmpty ? "Hello" : "Hello, " + name
}
private func verify_greeting() -> Int { 0 }

@Verify
private func zero() -> Int8 {
    #ensures { $0 == 1 }
    1
}
private func verify_zero() -> Int { 0 }

/// The shape of the pre-release bug: five parameters, some not `Finite`.
private enum JoinAction { case join, leave }
@Verify
private func joinTitle(_ code: String?, name: String, team: String?, isOpen: Bool, action: JoinAction?) -> String {
    #ensures { !$0.isEmpty }
    action == .leave ? "Leave " + name : isOpen ? "Join " + name : "Closed"
}
private func verify_joinTitle() -> Int { 0 }

@Verify
private func bump(_ x: inout Int8, by step: Int8 = 1) -> Bool {
    #requires(step > 0)
    guard x <= Int8.max - step else { return false }
    x += step
    return true
}
private func verify_bump() -> Int { 0 }

@Verify
private func greet(_ player: Player) -> String {
    #ensures { !$0.isEmpty }
    player.name.isEmpty ? "Hi" : player.name
}

// MARK: 1 to 6 parameters

@Verify
private func one(_ a: Bool) -> Bool {
    #ensures { $0 == !a }
    !a
}

@Verify
private func two(_ a: Bool, and b: Surface) -> Bool {
    #ensures { $0 == (a && b == .grass) }
    a && b == .grass
}

@Verify
private func three(_ a: Bool, _ b: Surface?, c: Int8) -> Int8 {
    #requires(c < 100)
    #ensures { $0 > c }
    c + (a ? 2 : 1) + (b == nil ? 0 : 1)
}

@Verify
private func four(a: Bool, b: Bool, c: Bool, d: Surface) -> Int8 {
    #ensures { $0 >= 0 && $0 <= 4 }
    (a ? 1 : 0) + (b ? 1 : 0) + (c ? 1 : 0) + (d == .sand ? 1 : 0)
}

@Verify
private func five(_ a: Bool, b: Bool, c: Surface?, _ d: Surface, e: UInt8) -> Int {
    #requires(e < 200)
    #ensures { $0 >= Int(e) }
    Int(e) + (a ? 1 : 0) + (b ? 1 : 0) + (c == .grass ? 1 : 0) + (d == .sand ? 1 : 0)
}

// Six parameters on purpose: the walk of every arity up to six.
// swiftlint:disable function_parameter_count
@Verify
private func six(_ a: Bool, _ b: Bool, _ c: Bool, _ d: Bool, _ e: Bool, f: Bool = false) -> Int {
    #ensures { $0 >= 0 && $0 <= 6 }
    [a, b, c, d, e, f].filter { $0 }.count
}

@Verify(over: .product(.bool, .bool, .bool, .bool, .int(0...3)))
private func fiveOver(_ a: Bool, _ b: Bool, _ c: Bool, _ d: Bool, _ e: Int) -> Int {
    #requires(e >= 0)
    #ensures { $0 >= e }
    e + (a ? 1 : 0) + (b ? 1 : 0) + (c ? 1 : 0) + (d ? 1 : 0)
}

@Verify(over: .product(.bool, .bool, .bool, .bool, .bool, .int(0...2)))
private func sixOver(_ a: Bool, _ b: Bool, _ c: Bool, _ d: Bool, _ e: Bool, _ f: Int) -> Int {
    #ensures { $0 >= f }
    f + [a, b, c, d, e].filter { $0 }.count
}
// swiftlint:enable function_parameter_count

@Suite struct InPlaceVerifyTests {
    @Test func aGetterRunsAndHasTheContractScanProves() {
        let rule = Rule(title: "Par", points: 12)
        #expect(rule.body == "Par.")
        #expect(rule.isBonus)
        #expect(rule.doubled == 24)
        #expect(rule.body_requires() && !Rule(title: "", points: 0).body_requires())
        #expect(rule.body_ensures("Par.") && !rule.body_ensures("Bogey"))
        #expect(rule.isBonus_ensures(true) && !rule.isBonus_ensures(false))
        #expect(rule.doubled_requires() && !Rule(title: "", points: 100).doubled_requires())
        #expect(rule.doubled_ensures(24) && !rule.doubled_ensures(25))
        #expect(Limits.maximum == 100 && Limits.maximum_ensures(100) && !Limits.maximum_ensures(0))
    }

    @Test func aGetOfAPropertyWithASetterKeepsItsChecks() {
        var rule = Rule(title: "", points: 0)
        #expect(rule.label == "untitled")
        rule.label = "Eagle"
        #expect(rule.label == "Eagle")
    }

    @Test func nothingToWalkMeansNoWalkOnlyTheScanContract() {
        #expect(greeting(for: "Ana") == "Hello, Ana" && greeting_ensures("Ana", "Hello, Ana"))
        #expect(zero() == 1 && zero_ensures(1) && !zero_ensures(0))
        #expect(joinTitle(nil, name: "Ana", team: nil, isOpen: true, action: nil) == "Join Ana")
        #expect(joinTitle_ensures(nil, "Ana", nil, true, .leave, "Leave Ana"))
        var x: Int8 = 126
        #expect(bump(&x) && x == 127 && !bump(&x))
        var step: Int8 = 0
        #expect(!bump_requires(&step, 0) && bump_requires(&step, 1))
        #expect(verify_greeting() + verify_zero() + verify_joinTitle() + verify_bump() == 0, "the functions written here")
    }

    /// A walk over a parameter type that is not `Finite` compiles and is never proved: nothing was walked.
    @Test func aWalkOverATypeThatIsNotFiniteIsNeverProved() {
        let report = verify_greet()
        #expect(!report.isProved, "\(report)")
        #expect(report.evaluated == 0 && !report.domainComplete)
        #expect(report.results.allSatisfy { if case .bounded = $0.verdict { true } else { false } }, "\(report)")
    }

    @Test func oneToSixParametersAreWalked() {
        let reports = [verify_one(), verify_two(), verify_three(), verify_four(), verify_five(), verify_six()]
        for report in reports { #expect(report.isProved, "\(report)") }
        #expect(reports.map(\.domainSize) == [2, 4, 2 * 3 * 256, 16, 2 * 2 * 3 * 2 * 256, 64])
        #expect(verify_five().excluded == 2 * 2 * 3 * 2 * 56)
        #expect(verify_fiveOver().isProved && verify_fiveOver().domainSize == 64)
        #expect(verify_sixOver().isProved && verify_sixOver().domainSize == 96)
        #expect(six(true, true, false, false, false) == 2 && six(true, true, true, true, true, f: true) == 6)
    }

    /// The 5- and 6-way products give the values of the nested pairs, in the same order.
    @Test func theFiveAndSixWayProductsListEveryTupleInOrder() {
        let five = Domain.product(.bool, .bool, .bool, .bool, .int(0...2))
        let nested = Domain.product(.bool, .product(.bool, .product(.bool, .product(.bool, .int(0...2)))))
        #expect(five.count == nested.count && five.complete)
        for index in 0..<five.count {
            let (a, b) = (five[index], nested[index])
            #expect(a.0 == b.0 && a.1 == b.1.0 && a.2 == b.1.1.0 && a.3 == b.1.1.1.0 && a.4 == b.1.1.1.1)
        }
        let six = Domain.product(.bool, .bool, .bool, .bool, .bool, .int(0...2))
        #expect(six.count == 96 && six[95] == (true, true, true, true, true, 2) && six[0] == (false, false, false, false, false, 0))
    }
}
