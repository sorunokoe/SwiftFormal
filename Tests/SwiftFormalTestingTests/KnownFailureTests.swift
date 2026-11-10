import SwiftFormal
@testable import SwiftFormalTesting
import Testing

/// Ordinals as the app wrote them: only 1, 2 and 3 get their own suffix.
private func placement(_ number: Int) -> String {
    switch number {
    case 1: "1st"
    case 2: "2nd"
    case 3: "3rd"
    default: "\(number)th"
    }
}

private func ordinal(_ number: Int) -> String {
    if (11...13).contains(number % 100) { return "\(number)th" }
    return switch number % 10 {
    case 1: "\(number)st"
    case 2: "\(number)nd"
    case 3: "\(number)rd"
    default: "\(number)th"
    }
}

/// A known issue is a parameter of the walk, not a `withKnownIssue { … }` around it.
@Suite struct KnownFailureTests {
    @Test func aKnownFailurePassesWhileTheDefectIsThere() {
        Prove("placement(_:)", it: placement, over: .int(1...30), knownIssue: "21th, 22th, 23th") {
            Satisfies("English ordinal") { number, text in text == ordinal(number) }
        }
    }

    @Test func aKnownFailureThatNoLongerFailsFailsTheTest() {
        withKnownIssue("the walk passes, so the known issue was not recorded") {
            Prove("ordinal(_:)", it: ordinal, over: .int(1...30), knownIssue: "fixed already") {
                Satisfies("English ordinal") { number, text in text == ordinal(number) }
            }
        } matching: {
            $0.description.contains("Known issue was not recorded")
        }
    }

    @Test func aFailureOnAnInputTheKnownIssueDoesNotNameIsAnOrdinaryFailure() {
        withKnownIssue {
            Prove(
                "placement(_:)", it: placement, over: .int(1...30),
                knownIssue: KnownFailure("only 22 is known", inputs: [22])
            ) {
                Satisfies("English ordinal") { number, text in text == ordinal(number) }
            }
        } matching: {
            $0.description.contains("does not name: 21")
        }
    }

    @Test func theNamedInputsMatchAsTheReportPrintsThem() {
        Prove(
            "placement(_:)", it: placement, over: .int(21...23), reporting: .everyFailure,
            knownIssue: KnownFailure("21th, 22th, 23th", inputs: [21, 22, 23])
        ) {
            Satisfies("English ordinal") { number, text in text == ordinal(number) }
        }
    }

    @Test func proveTakesAKnownIssueToo() {
        Prove(it: placement, over: .int(1...30), knownIssue: "21th, 22th, 23th") {
            Satisfies("English ordinal") { number, text in text == ordinal(number) }
        }
    }
}
