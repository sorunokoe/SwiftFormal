import SFLLVM
import SFSIL

/// The running tool as the proof cache names it: the UUIDs of the loaded images that hold the encoder, the semantics,
/// the prover, the LLVM cross-check and this module (`ScanToolImages`), read from memory. Each command line tool reads
/// it first thing, before any build it runs could replace its executable; a library reads it when first needed, from
/// the images it is linked into. Nil (the cache is not used) when an image has no UUID.
package enum ScanToolIdentity {
    /// The images' UUIDs, sorted and comma-separated; nil when unknown.
    package static let current: String? = ScanToolImages.identity(
        of: ScanToolImages.encoderTypes() + [LLVMEncoder.self, Verifier.self, ScanProofCache.self])

    /// The tool's versions a key includes (`ScanKeyContext.versions(tool:)` of `current`); takes seconds the first
    /// time in a debug build (`SemanticsDigest.current`).
    package static let versions: String? = ScanKeyContext.versions(tool: current)
}
