import SFSIL

// Reading guide
// The two passes over a closure-taking call on an array of unknown length (`map`, `filter`, `first(where:)`, …;
// `Sources/SFSIL/SILClosureCollections.swift`). The claim is solved first with `CollectionBounds` `exact`: an array
// longer than `CollectionBounds.iterations` may fail there, so only a claim whose `requires` bounds the length is
// proved, and that proof holds for every input; a claim with a `requires` that this pass does not prove gets a second
// exact pass up to `CollectionBounds.widened` elements (`xs.count == 18`). When no exact pass proves and they met
// such a call, it is solved again `bounded`, with longer arrays assumed away: a proof there is `undecided`, category `bounded`, its calls in
// `FunctionReport.bounded` (`bounded (n ≤ 8)`), never safe and never cached; a counterexample there is real (it has at
// most 8 elements) and is reported as any other.
// Tests: Tests/SFVerifyKitTests/ClosureCollectionScanTests.swift.

extension Verifier {
    /// `FunctionReport.category` of a function proved only for arrays of at most `CollectionBounds.iterations` elements.
    package static let boundedCategory = "bounded"

    /// Answers the claim from the cache or solves it, reading arrays of unknown length (see the top of this file).
    static func solveReadingCollections(
        _ report: inout FunctionReport, _ subject: RefutedFunction, options: VerifyOptions, claim: Claim, cached: CachedClaim?
    ) throws {
        try CollectionBounds.$current.withValue(CollectionBounds(.exact)) {
            if let cached, try answerFromCache(&report, cached, subject: subject, options: options, claim: claim) { return }
            try solve(&report, subject, options: options, claim: claim, cached: cached)
        }
    }

    /// After an `exact` pass that did not prove and met an array of unknown length, the next pass: the widened exact
    /// one for a claim with a `requires`, else the `bounded` one. True when it ran.
    static func solveBounded(
        _ report: inout FunctionReport, _ subject: RefutedFunction, options: VerifyOptions, claim: Claim, cached: CachedClaim?
    ) throws -> Bool {
        guard let exact = CollectionBounds.current, exact.mode == .exact, !exact.notes.isEmpty else { return false }
        let widens = subject.specs.requires != nil && exact.limit < CollectionBounds.widened
        let next = widens ? CollectionBounds(.exact, limit: CollectionBounds.widened) : CollectionBounds(.bounded)
        try CollectionBounds.$current.withValue(next) {
            try solve(&report, subject, options: options, claim: claim, cached: cached)
        }
        return true
    }

    /// For a proof of the `bounded` pass: records it as `bounded` (true); false for any other proof.
    static func reportBounded(_ report: inout FunctionReport) -> Bool {
        guard let bounds = CollectionBounds.current, bounds.mode == .bounded, !bounds.notes.isEmpty else { return false }
        let k = CollectionBounds.iterations
        report.status = .undecided
        report.category = boundedCategory
        report.bounded = bounds.notes
        report.detail = "bounded (n ≤ \(k)): proved only for arrays of at most \(k) elements, not for every input"
        report.hint = hint(forCategory: boundedCategory)
        return true
    }
}
