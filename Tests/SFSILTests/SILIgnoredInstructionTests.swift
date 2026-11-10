import SFSIL
import Testing

/// Plan item H1: the instructions logic ignores are an allow-list. Adding one changes this test, so it is reviewed.
@Suite struct SILIgnoredInstructionTests {
    @Test func theIgnoredInstructionsAreExactlyTheReviewedOnes() {
        let matches = IgnoredInstruction.reviewed.map(\.match)
        #expect(
            matches == [
                .prefix("debug_value "), .line("debug_step"), .prefix("dealloc_stack "), .prefix("destroy_addr "),
                .prefix("end_access "), .prefix("strong_release "), .prefix("fix_lifetime "), .prefix("dealloc_ref "),
                .prefix("dealloc_stack_ref "), .prefix("retain_value "), .prefix("release_value "), .prefix("strong_retain "),
                .contains(" = builtin \"willThrow\"("), .prefix("alloc_global "),
            ])
        #expect(IgnoredInstruction.reviewed.allSatisfy { $0.reason.count > 10 })
    }

    @Test func onlyThoseAreIgnored() {
        #expect(IgnoredInstruction.matches("strong_release %3 : $Box"))
        #expect(IgnoredInstruction.matches("debug_step"))
        #expect(!IgnoredInstruction.matches("debug_step_into"))
        #expect(!IgnoredInstruction.matches("cond_fail %4 : $Builtin.Int1, \"arithmetic overflow\""))
        #expect(!IgnoredInstruction.matches("%5 = builtin \"sadd_with_overflow_Int8\"(%1, %2, %3)"))
    }
}
