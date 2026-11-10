/// Which `assert`s a build keeps. A debug build traps on a failed `assert`; a release build removes the `assert`, and
/// with it any side effect of its condition, so a function can trap in one and not the other (plan item R5).
public enum BuildConfiguration: String, Codable, Sendable, CaseIterable {
    /// `-assert-config Debug`: what `-Onone` builds by default.
    case debug
    /// `-assert-config Release`: what `-O` builds by default. At `-Onone` the SIL stays as readable as in a debug build.
    case release
}
