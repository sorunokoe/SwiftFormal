import Testing

@testable import SFSIL

/// `containsText` replaces `contains` in whole-module searches whose answers gate soundness (deinits that run code,
/// issue reporters, `willThrow`): it must answer exactly what `contains` answers.
@Suite struct TextSearchTests {
    private static let lines = [
        "  %5 = builtin \"willThrow\"(%4 : $any Error) : $()",
        "  %3 = function_ref @$sScT6cancelyyF : $@convention(method) <τ_0_0, τ_0_1> (@guaranteed Task<τ_0_0, τ_0_1>) -> ()",
        "  // withTaskCancellationHandler(operation:onCancel:isolation:)",
        "  %2 = string_literal utf8 \"IssueReporter\u{301}s é 🙂 onTermination\"",
        "  %9 = string_literal utf8 \"\u{301}IssueReporters\"",
        "willThrow", "", "é", "IssueReporte", "onTerminatio n",
    ]
    private static let needles = [
        " = builtin \"willThrow\"(", "TaskCancellationHandler", "onTermination", "IssueReporter", "willThrow", "é",
    ]

    @Test func answersWhatContainsAnswers() {
        for line in Self.lines {
            for needle in Self.needles {
                #expect(line.containsText(needle) == line.contains(needle), "\(needle) in \(line)")
                let tail = line.dropFirst(min(4, line.count))
                #expect(tail.containsText(needle) == tail.contains(needle), "\(needle) in \(tail)")
            }
        }
    }
}
