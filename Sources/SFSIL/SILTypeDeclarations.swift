// The printed declarations of the read structs and enums, for tools that write values of them as Swift source
// (concrete playback, `SFVerifyKit/PlaybackLiterals.swift`). Nothing here changes how a type is read or encoded.

import Foundation

/// A struct or enum declaration as the compiler printed it at the top of the SIL: `struct State : Equatable {` and the
/// member lines, trimmed (`@_hasStorage var index: Int { get set }`, `init(index: Int = 0)`, accessor lines). Members
/// of nested types and of extensions are not included.
package struct TypeDeclarationText: Sendable, Equatable {
    package let header: String
    package let members: [String]

    package init(header: String, members: [String]) {
        self.header = header
        self.members = members
    }
}

extension TypeContext {
    /// Keeps the printed declaration of `name` when it was read as a non-generic struct or enum.
    mutating func recordDeclaration(_ name: String, header: String, members: [String]) {
        guard structs[name] != nil || enums[name] != nil else { return }
        declarations[name] = TypeDeclarationText(header: header.trimmingCharacters(in: .whitespaces), members: members)
    }
}

extension SILModule {
    /// The declaration of the non-generic struct or enum `type` as the compiler printed it. Nil for other types and
    /// for a name declared more than once.
    package func declaration(of type: String) -> TypeDeclarationText? {
        types.declarations[type]
    }

    /// The stored properties of the non-generic struct `type`, in declaration order, with their type text.
    package func storedProperties(of type: String) -> [(name: String, type: String)]? {
        types.structs[type]
    }

    /// The cases of the non-generic enum `type`, with the payload type text of each.
    package func cases(of type: String) -> [(name: String, payload: String?)]? {
        types.enums[type]
    }
}
