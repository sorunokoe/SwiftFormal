package import Foundation
import SFBV
import SFCNF
import SFProve
import SFSemantics

// MARK: - compiler pin

/// The set of compilers the frontend was validated against. Comparing the first line of `swiftc --version`
/// (the `Target:` line differs by architecture and does not change the SIL grammar).
package struct CompilerPin: Codable, Sendable, Equatable {
    package var acceptedVersions: [String]

    package init(acceptedVersions: [String]) {
        self.acceptedVersions = acceptedVersions.map(Self.normalized)
    }

    /// The compilers listed in `SILFrontendVersion.verifiedCompilers`.
    package static let verified = CompilerPin(acceptedVersions: SILFrontendVersion.verifiedCompilers)

    private static func normalized(_ line: String) -> String {
        CompilerToolchain(swiftcVersion: line, sdkVersion: "").versionLine
    }

    package func accepts(_ toolchain: CompilerToolchain) -> Bool { acceptedVersions.contains(toolchain.versionLine) }

    /// A pin that also accepts `version` (any `swiftc --version` output; only its first line is kept).
    package func adding(_ version: String) -> CompilerPin { CompilerPin(acceptedVersions: acceptedVersions + [version]) }

    package static func load(from url: URL) throws -> CompilerPin {
        try JSONDecoder().decode(CompilerPin.self, from: Data(contentsOf: url))
    }

    package func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

package enum PinnedCompiler {
    /// Throws `ProofCacheError.unpinnedCompiler` unless the toolchain is in the pin or `allowUnpinned` is set.
    @discardableResult
    package static func check(pin: CompilerPin = .verified, toolchain: CompilerToolchain? = nil, allowUnpinned: Bool = false) throws
        -> CompilerToolchain
    {
        let found = try toolchain ?? .installed()
        guard allowUnpinned || pin.accepts(found) else {
            throw ProofCacheError.unpinnedCompiler(found: found.versionLine, accepted: pin.acceptedVersions)
        }
        return found
    }

    /// `SILCompiler.module`, but only with a pinned compiler.
    package static func module(
        source: String, name: String = "Fixture", optimization: Optimization,
        pin: CompilerPin = .verified, allowUnpinned: Bool = false,
        toolchain: CompilerToolchain? = nil
    ) throws -> SILModule {
        try check(pin: pin, toolchain: toolchain, allowUnpinned: allowUnpinned)
        return try SILCompiler.module(source: source, name: name, optimization: optimization)
    }
}
