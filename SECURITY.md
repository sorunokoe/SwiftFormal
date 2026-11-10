# Security policy

SwiftFormal is a verification tool. People trust its verdicts, so **a wrong verdict is a security-relevant bug**, not
only a correctness bug.

## What to report privately

- A false `proved` (Walk or Prove), a false `safe` or `contractHolds` (Scan), or a `proved` that rests on a proof the
  checker should have rejected.
- A bad proof that `LRATChecker` or `RUPChecker` accepts.
- A `ProofCache` entry accepted as `proved` although `Trust.recheck` should reject it. (Known limit: anyone who can
  write to the cache directory can forge an entry, see [ADR 0007](docs/decisions/0007-type-driven-audit.md). That is
  why `Trust.recheck` exists.)
- A way to make `swiftformal` (or the maintainers' `sfverify`) run code or write files it should not (for example
  through a crafted package, a cache file or the JSON output).

What counts as a soundness bug, and what each tool is trusted for: [docs/TRUST.md](docs/TRUST.md). Policy:
[ADR 0006](docs/decisions/0006-soundness-policy.md).

**Not** a soundness bug (report as an ordinary issue):

- a crash or hang on malformed input ([docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md));
- `unsupported` or `unknown` for something SwiftFormal does not understand (the tool declines to answer);
- a slow proof.

## How to report

Report privately: [Report a vulnerability](https://github.com/sorunokoe/SwiftFormal/security/advisories/new) (the
repository's **Security** tab). Do not post details in a public issue.

Include: the tool, the verdict you got, why it is wrong, the smallest program that shows it, the compiler version
(`swift --version`) and the platform.

A wrong `proved` that does not involve a vulnerability in someone's system can go in the public **Soundness bug**
issue template instead. Not sure? Use the private route.

## What to expect

- A small group maintains SwiftFormal, so there is no guaranteed response time.
- We try to acknowledge within about a week, say whether we can reproduce it, and keep you informed.
- A confirmed false `proved` is the highest-priority bug ([ADR 0006](docs/decisions/0006-soundness-policy.md)). The fix
  comes with a regression test and is listed in the [CHANGELOG](CHANGELOG.md).
- We credit you if you want.

## Supported versions

Only the latest `0.x` release is supported. Before 1.0, fixes go into a new release of the latest minor version and
are not backported ([versioning](CHANGELOG.md#versioning)).
