import SwiftFormal
@testable import SwiftFormalTesting
import Testing

/// A format string's arguments as `%d`/`%@` letters, a stand-in for a translation audit.
private let english: [String: String] = ["moved": "%@ moved", "count": "%d items", "title": "My items"]
private let translations: [String: [String: String]] = [
    "de": ["moved": "%@ verschoben", "count": "%d Elemente", "title": "Meine Sachen"],
    "zh-Hant": ["moved": "%1$d %2$d 已移至", "count": "%d 支", "title": "我的物品"],
    "ja": ["moved": "%@ 移動", "count": "%@ 本", "title": "マイアイテム"],
]

private struct KeyInLanguage: CustomStringConvertible {
    let key: String
    let language: String
    var description: String { "\(language): \(key)" }
}

private let everyKey: Domain<KeyInLanguage> = .of(
    translations.keys.sorted().flatMap { language in english.keys.sorted().map { KeyInLanguage(key: $0, language: language) } })

private func arguments(_ text: String) -> [Character] {
    var found: [Character] = []
    var rest = Substring(text)
    while let percent = rest.firstIndex(of: "%") {
        rest = rest[rest.index(after: percent)...].drop { $0.isNumber || $0 == "$" }
        if let letter = rest.first { found.append(letter == "@" ? "@" : "d") }
    }
    return found
}

/// `reporting: .everyFailure` lists every failing input, which `partition` and a loop of prints did before.
@Suite struct EveryFailureTests {
    @Test func everyFailingInputIsListed() {
        let found = everyCounterexample(
            of: { (input: KeyInLanguage) in translations[input.language]?[input.key] ?? "" }, over: everyKey,
            properties: [
                .satisfies("same arguments as English") { input, shown in arguments(shown) == arguments(english[input.key] ?? "") }
            ])
        #expect(found.map(\.counterexample.input) == ["ja: count", "zh-Hant: moved"])
        #expect(found.allSatisfy { $0.property == "same arguments as English" })
    }

    @Test func aPropertyThatFailsAtTheEndIsListedOnceWithoutAnInput() {
        let found = everyCounterexample(
            of: { (value: Bool) in value }, over: .bool,
            properties: [Outputs(exactly: [true, false]).property, .satisfies("true") { _, output in output }])
        #expect(found.map(\.counterexample.input) == ["false"])
        let missing = everyCounterexample(of: { (_: Bool) in true }, over: .bool, properties: [Outputs(exactly: [true, false]).property])
        #expect(missing.count == 1 && missing[0].counterexample.input == nil)
    }

    @Test func theIssueListsEveryFailureAndTheKnownOnesPass() {
        Prove(
            "translation(_:)", it: { (input: KeyInLanguage) in translations[input.language]?[input.key] ?? "" }, over: everyKey,
            reporting: .everyFailure,
            knownIssue: KnownFailure("zh-Hant and ja take other arguments", failingInputs: ["ja: count", "zh-Hant: moved"])
        ) {
            Satisfies("same arguments as English") { input, shown in arguments(shown) == arguments(english[input.key] ?? "") }
        }
    }

    @Test func aKnownInputThatNoLongerFailsIsAFailure() {
        withKnownIssue {
            Prove(
                "translation(_:)", it: { (input: KeyInLanguage) in translations[input.language]?[input.key] ?? "" }, over: everyKey,
                reporting: .everyFailure,
                knownIssue: KnownFailure("three known", failingInputs: ["ja: count", "zh-Hant: moved", "de: count"])
            ) {
                Satisfies("same arguments as English") { input, shown in arguments(shown) == arguments(english[input.key] ?? "") }
            }
        } matching: {
            $0.description.contains("names de: count, which no longer fails")
        }
    }

    @Test func theIssueTextListsEveryFailure() {
        withKnownIssue {
            Prove(
                "translation(_:)", it: { (input: KeyInLanguage) in translations[input.language]?[input.key] ?? "" }, over: everyKey,
                reporting: .everyFailure
            ) {
                Satisfies("same arguments as English") { input, shown in arguments(shown) == arguments(english[input.key] ?? "") }
            }
        } matching: { issue in
            issue.description.contains("every failure (2):") && issue.description.contains("for input zh-Hant: moved")
        }
    }

    /// Over budget, the walk draws a sample: a named input it did not draw is not said to pass now (that would be an
    /// issue of its own here, and fail the test).
    @Test func aSampledWalkListsTheFailuresAmongItsSample() {
        let odd = (0...999).filter { !$0.isMultiple(of: 2) }
        Prove(
            "half(_:)", it: { (value: Int) in value / 2 }, over: .int(0...999), budget: Budget(maxEvaluations: 100, seed: 7),
            reporting: .everyFailure, knownIssue: KnownFailure("odd numbers", inputs: odd)
        ) {
            Satisfies("exact") { value, half in half * 2 == value }
        }
        let header = WalkIssue.list(EveryFailure(failures: [], sampledInputs: 100))
        #expect(header == "every failure among 100 sampled inputs (0):")
    }

    @Test func proveKeepsEveryFailure() {
        var failing: [String?] = []
        withKnownIssue {
            let prove = Prove(
                "translation(_:)", it: { (input: KeyInLanguage) in translations[input.language]?[input.key] ?? "" }, over: everyKey,
                reporting: .everyFailure
            ) {
                Satisfies("same arguments as English") { input, shown in arguments(shown) == arguments(english[input.key] ?? "") }
            }
            failing = prove.failures.map(\.counterexample.input)
        }
        #expect(failing == ["ja: count", "zh-Hant: moved"])
    }
}
