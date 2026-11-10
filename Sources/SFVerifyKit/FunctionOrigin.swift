import Foundation

extension FunctionInfo {
    /// Where the code came from when nobody wrote it in a source file: `macro` (a macro expansion buffer,
    /// `@__swiftmacro_…`) or `build` (a file SwiftPM or Xcode generates, such as `resource_bundle_accessor.swift`, or
    /// a build-tool plugin's output). Nil for code written by hand. Decided from the file the compiler names, never from
    /// the function's name. Code under any `.build` folder is not enough: a package can live there (a dependency
    /// checkout, a clone), and code marked `build` is not counted, so its broken contract would not fail the run.
    public var origin: String? {
        guard let file = location?.file else { return nil }
        if (file as NSString).lastPathComponent.hasPrefix("@__swiftmacro_") { return "macro" }
        if file.contains("/DerivedSources/") || file.contains("/plugins/outputs/") { return "build" }
        return nil
    }

    /// Written by `@Verify` next to the function it is attached to (`clamp_requires`, `clamp_ensures`): the compiler
    /// places such a peer in the expansion buffer of `@Verify`'s peer role, `@__swiftmacro_<context><name>6VerifyfMp_.swift`.
    /// A function written by hand is placed in its own file, so this is how Scan tells the contract `@Verify` wrote
    /// from a hand-written function with the same name. No place (no debug info) is never a peer: the contract is
    /// then not read (fail closed).
    var isVerifyPeer: Bool {
        guard let file = location?.file else { return false }
        let name = (file as NSString).lastPathComponent
        guard name.hasPrefix("@__swiftmacro_"), name.hasSuffix(".swift") else { return false }
        return name.dropLast(".swift".count).contains(/6VerifyfMp[0-9]*_$/)
    }
}
