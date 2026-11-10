# 0006: A false `proved` is a P0 bug

## Context

SwiftFormal exists to say `proved` only when it is true. A tool that is sometimes wrong in the other direction (it says `unknown`, `unsupported` or `bounded` when it could have proved) is only less useful. A tool that says `proved` for something false is worse than having no tool, because people stop testing. This was already the working rule ([TESTING.md](../TESTING.md), [ADR 0004](0004-test-lanes.md)); this ADR writes it down as a policy.

## Decision

- **Soundness bugs.** A *soundness bug* is a verdict that claims more than is true: a false `proved` (Walk, Prove), a false `safe` or `contractHolds` (Scan), or a proof that a checker accepts and should not. It is a **P0** bug: it comes before every feature, every performance task and every other bug, and a release is not made while one is open and unexplained.
- **Not soundness bugs.** `unknown`, `unsupported`, `undecided`, `bounded` and `counterexample` with a replayable input are the tools declining or being honest. A crash on malformed input is a robustness bug (see [KNOWN-ISSUES](../KNOWN-ISSUES.md)); it produces no verdict. A slow proof is a performance bug.
- **Every fix comes with a regression test, and the test comes first.** The test is a case in the [soundness zoo](../guides/soundness-zoo.md): a `Zoo` entry marked `.falseClaim` for Walk, `proveSigned` and bit-vector claims (fast lane), or a `ScanZoo` case in the oracle lane for Scan (`Tests/SFOracleTests/ScanZooTests.swift`), because only real execution settles a Scan verdict. A bug in the solver or a checker also gets a case in the differential or fuzz tests. A bug is fixed when that test fails on the old code and passes on the new.
- **Do not weaken the claim to make a failure go away.** If a self-check of the package (`Tests/SelfVerificationTests`) finds a real bug, it is this kind of bug. Narrow what the tool says (for example answer `unsupported`) only when that is the honest fix, and say so in the [CHANGELOG](../../CHANGELOG.md).
- **While it is open,** a confirmed soundness bug is listed first in [KNOWN-ISSUES](../KNOWN-ISSUES.md) with the input that shows it, and the test that reproduces it is marked `withKnownIssue` so the suite stays green and remembers it. When fixed, the entry moves to the CHANGELOG and the `withKnownIssue` is removed.
- **Reporting.** Reports go through the **Soundness bug** issue form or, when the report may also be a vulnerability, through private reporting ([SECURITY.md](../../SECURITY.md)). What each tool is trusted for: [TRUST.md](../TRUST.md).

## Consequences

- A contributor who finds a wrong `proved` knows what happens next, and a maintainer cannot defer it as "later".
- The soundness zoo grows by one case per report, and old reports stay guarded.
- Fixes can make the tool say less (more `unsupported`). That is accepted: the cost of a smaller claim is lower than the cost of a wrong one.
- The slow and oracle lanes stay required before a release ([ADR 0004](0004-test-lanes.md)), because those are where a false `safe` or `proved` on real compiler output would show.
