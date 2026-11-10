import SFSIL
import SFTestSupport
import Testing

enum OracleEnvironment {
    /// True when the installed `swiftc` is one the SIL reader was validated against (`SILFrontendVersion.verifiedCompilers`).
    static let isPinnedCompiler: Bool = (try? PinnedCompiler.check()) != nil
}

extension Trait where Self == ConditionTrait {
    /// Skips (and prints why) on a compiler outside the pin, instead of failing in a way that looks like a bug here.
    static var requiresPinnedCompiler: Self {
        .enabled(
            if: OracleEnvironment.isPinnedCompiler,
            "needs the pinned compiler; see docs/guides/compilers.md and docs/decisions/0004-test-lanes.md")
    }
}
