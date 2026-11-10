import Foundation
import SFBV
import SFCNF
import SFProve
import SFSemantics

// MARK: - versions

package enum SILFrontendVersion {
    /// Manually bumped version of the frontend's semantics. Bump it whenever `SILParser`, `SILEncoder`, `SILVerify`,
    /// `Prove` or the S0 table change in a way that could change a verdict: a new instruction, a different trap or
    /// undefined-behaviour model, a different call-depth limit, different handling of `cond_fail`, and so on.
    /// Two automatic digests (`SemanticsDigest`) catch most such changes, but only for behaviour they exercise; this
    /// constant is the explicit, reviewable part. A stale cache after a bump is harmless, a stale hit is not.
    /// 37: merge of 36 (mapper verification) and 26 (one-way rework); the merged frontend is new.
    package static let semantics = 37

    /// First lines of `swiftc --version` for compilers whose SIL text the parser was validated against
    /// (see the grammar fixture test). `CompilerPin.verified` accepts exactly these.
    package static let verifiedCompilers: [String] = ["Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)"]
}

/// The version of Scan's claim, part of every Scan proof cache key.
package enum ScanClaimVersion {
    /// Manually bumped version of the claim Scan proves (`Verifier.claim` in SFVerifyKit) and of how its answer is
    /// read: what `requires`/`ensures` receive, how a counterexample is replayed, which statuses a proof becomes.
    /// Bump it with any such change; every Scan proof cache entry made before is then a miss (`ScanKeyContext`).
    /// 3: only the `_requires` / `_ensures` peers `@Verify` writes are a contract; a hand-written one is not read.
    /// 6: merge of 5 (mapper verification) and 3 (contracts only from `@Verify`): the merged claim is new.
    package static let current = 6
}

package enum ProofCacheError: Error, CustomStringConvertible {
    case toolFailed(String)
    case unpinnedCompiler(found: String, accepted: [String])

    package var description: String {
        switch self {
        case .toolFailed(let s): "TOOL FAILED: \(s)"
        case .unpinnedCompiler(let found, let accepted):
            "UNPINNED COMPILER: `\(found)` is not in the pin list \(accepted). The SIL parser, the encoder and every cached proof were "
                + "validated only against the pinned compilers. Re-run the SIL grammar fixture tests with this compiler, then add its "
                + "version line to the pin (CompilerPin.adding), or pass allowUnpinned: true to accept the risk for this call."
        }
    }
}
