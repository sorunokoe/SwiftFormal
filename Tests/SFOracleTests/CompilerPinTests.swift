import Testing

@Suite struct CompilerPinTests {
    @Test func theEnvironmentCanSayWhetherTheCompilerIsPinned() {
        _ = OracleEnvironment.isPinnedCompiler
    }

    @Test(.requiresPinnedCompiler) func theTraitRunsWhenTheCompilerIsPinned() {
        #expect(OracleEnvironment.isPinnedCompiler)
    }
}
