# Releasing

Nothing here tags, pushes or publishes by itself. The owner does each release by hand.

## Decisions

| Item | Choice |
|---|---|
| License | Apache-2.0, standard text in `LICENSE`. |
| Contact (security, Code of Conduct) | GitHub private reporting: `Security` tab, `Report a vulnerability`. |
| CI | On pull requests to `main` only, drafts skipped. No nightly run: the slow checks are run by hand before a release (below). |
| CI runner | GitHub's `xcode-27` image, Xcode 27.0 selected with `DEVELOPER_DIR` (the [pinned compiler](guides/compilers.md)). |

## One-time GitHub settings

- **Settings → Code security:** turn on **Private vulnerability reporting**.
- **Settings → Actions → General:** for fork pull requests, choose **Require approval for all external contributors**,
  so CI runs on someone else's pull request only after you approve it.

## Checklist

Run from the repository root, on the pinned compiler (`swiftc --version`, see [compilers](guides/compilers.md)).

1. **Clean clone is green.** Commit first; a clone has only what is committed.
   ```sh
   rm -rf .build/clean && mkdir -p .build/clean
   git clone . .build/clean/SwiftFormal
   (cd .build/clean/SwiftFormal && Scripts/safety-net.sh)
   ```
   It must end with `SAFETY NET GREEN`.
2. **Slow checks pass.** CI does not run these. A skipped oracle lane is not a pass.
   ```sh
   Scripts/test-lane.sh slow
   Scripts/test-lane.sh oracle
   Scripts/check-golden.sh
   python3 Scripts/metrics.py
   ```
   Optional, slower: `Scripts/sanitize.sh address fast`, `python3 Scripts/measure-coverage.py`,
   `python3 Scripts/mutation-lane.py`, `Scripts/strict-memory-safety.sh`.
3. **Examples run:** `Scripts/check-examples.sh`.
4. **Docs build without warnings:**
   ```sh
   for target in SwiftFormal SwiftFormalTesting SFProve; do
     SWIFTFORMAL_DOCS=1 swift package generate-documentation --target "$target" --warnings-as-errors
   done
   ```
5. **API changes are in the CHANGELOG:** `Scripts/check-api.sh` (compares with the previous release tag).
6. **No private data:** `python3 Scripts/check-release-hygiene.py` is ok.
7. **No open soundness bug:** the first entry of [KNOWN-ISSUES](KNOWN-ISSUES.md) is not a wrong verdict.
8. **CHANGELOG:** give the version its date.
9. **Pull request:** open one to `main` and wait for CI to be green. Merge it.
10. **Tag and push:** `git tag -a 0.1.0 -m "0.1.0" && git push origin 0.1.0`.
11. **Prebuilt `swiftformal`:** run `Release artifact` on the tag (below), then create the GitHub release with the
    zip and its SHA-256.

## The prebuilt `swiftformal`

A release can ship a release build of `swiftformal`, so users and CI jobs do not build it from source.

- `Scripts/release-artifactbundle.sh <version> [out-dir]` builds a universal release `swiftformal` and writes
  `swiftformal.artifactbundle.zip` and its `.sha256`. The build is reproducible: the same commit and compiler give the
  same bytes (verified on one machine for the earlier `sfverify` bundle; not yet on two machines).
- The `Release artifact` workflow builds it twice in two folders and fails if the checksums differ. It publishes
  nothing.
- Check: on your Mac, `git checkout <tag> && Scripts/release-artifactbundle.sh <tag>` prints the same SHA-256 as the
  workflow.

## After the release

Open a new `[Unreleased]` section in the CHANGELOG. Deprecated names stay for one minor version ([versioning](../CHANGELOG.md#versioning)).
