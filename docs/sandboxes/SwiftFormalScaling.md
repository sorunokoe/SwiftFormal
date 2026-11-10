# SwiftFormalScaling: scaling curves for the engine (developer-only)

**Job (Inspector view):** measures how per-element time changes with input size for domains, the walk, the CNF builder, the solver, the checkers and the SIL front end, with apple/swift-collections-benchmark. Exists only when `SWIFTFORMAL_BENCH` is set.
**Raw input → typed → result:** sizes from the command line and generated inputs (CNF, proofs, SIL files in `SCALING_SIL_DIR`) → timed tasks → a results JSON and PNG charts.
**Depends on:** SwiftFormal, SwiftFormalTesting, SFCNF, SFSAT, SFCheck, SFBV, SFProve, SFSIL, SFVerifyKit. **Must not depend on:** anything users build; nothing depends on it.
**Fast loop:** `SWIFTFORMAL_BENCH=1 Scripts/sandbox.py SwiftFormalScaling` (builds the product). **Connected loop:** none.
**Real consumers:** `Scripts/scaling.sh`, run by hand.
**Platforms (verified):** macOS only (swift-collections-benchmark needs macOS 15; the package floor is raised under the variable only).
**Known gaps:** `@testable import` needs `-Xswiftc -enable-testing`; `SwiftFormalTesting` links Testing.framework, so the executable needs an rpath to the platform's Developer/Library/Frameworks.
