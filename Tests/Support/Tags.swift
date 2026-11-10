import Testing

/// The lanes of docs/decisions/0004-test-lanes.md, as Swift Testing tags.
/// `swift test` cannot select tags yet, so `Scripts/test-lane.sh` selects lanes by name; the tags say which lane a test belongs to.
extension Tag {
    /// Takes more than 2 seconds in a debug build: large SAT instances, exhaustive sweeps.
    @Tag package static var slow: Self
    /// Starts `swiftc` or a native binary and compares the result with ours.
    @Tag package static var oracle: Self
}
