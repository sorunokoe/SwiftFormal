import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - @Finite

/// Derives `Finite` for a struct (the product of its stored properties' domains) or an enum (the union of
/// its cases, each case being the product of its payload domains).
///
/// A stored property with a default value is left out: the memberwise initialiser's default is used.
/// `@Values(domain)` on a stored property replaces the domain taken from its type.
package struct FiniteMacro: ExtensionMacro {
    package static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let access = accessPrefix(of: declaration)
        let body: String
        if let structure = declaration.as(StructDeclSyntax.self) {
            try rejectGenerics(structure.genericParameterClause)
            body = try structDomain(structure)
        } else if let enumeration = declaration.as(EnumDeclSyntax.self) {
            try rejectGenerics(enumeration.genericParameterClause)
            body = try enumDomain(enumeration)
        } else {
            throw ContractError("@Finite applies to structs and enums")
        }

        let conformance = protocols.isEmpty ? "" : ": SwiftFormal.Finite"
        let source = """
            extension \(type.trimmedDescription)\(conformance) {
                \(access)static var domain: SwiftFormal.Domain<\(type.trimmedDescription)> {
                    \(body)
                }
            }
            """
        return [try ExtensionDeclSyntax("\(raw: source)")]
    }

    // MARK: Struct

    private static func structDomain(_ structure: StructDeclSyntax) throws -> String {
        var fields: [(name: String, domain: String)] = []
        for member in structure.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self), !isStatic(variable) else { continue }
            let override = valuesOverride(of: variable)
            for binding in variable.bindings {
                guard binding.accessorBlock == nil, binding.initializer == nil,
                    let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                else { continue }
                if let override {
                    fields.append((name, override))
                } else if let type = binding.typeAnnotation?.type {
                    fields.append((name, "\(type.trimmedDescription).domain"))
                } else {
                    throw ContractError("@Finite needs a type annotation on '\(name)'")
                }
            }
        }
        if fields.isEmpty { return "SwiftFormal.Domain<\(structure.name.text)>.just(\(structure.name.text)())" }
        let call =
            "\(structure.name.text)("
            + fields.enumerated().map { index, field in
                "\(field.name): \(nestedAccess(index, of: fields.count))"
            }.joined(separator: ", ") + ")"
        return "\(nestedProduct(fields.map(\.domain))).map { \(call) }"
    }

    // MARK: Enum

    private static func enumDomain(_ enumeration: EnumDeclSyntax) throws -> String {
        var parts: [String] = []
        for member in enumeration.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                let name = element.name.text
                guard let parameters = element.parameterClause?.parameters, !parameters.isEmpty else {
                    parts.append("SwiftFormal.Domain<Self>.just(.\(name))")
                    continue
                }
                let domains = parameters.map { "\($0.type.trimmedDescription).domain" }
                let arguments = parameters.enumerated().map { index, parameter -> String in
                    let access = nestedAccess(index, of: parameters.count)
                    guard let label = parameter.firstName, label.text != "_" else { return access }
                    return "\(label.text): \(access)"
                }.joined(separator: ", ")
                parts.append("\(nestedProduct(domains)).map { .\(name)(\(arguments)) }")
            }
        }
        return "SwiftFormal.Domain<Self>.union([\n\(parts.joined(separator: ",\n"))\n])"
    }

    // MARK: Helpers

    /// Up to four domains: one flat `product(a, b, c)`, whose values are `(a, b, c)`. More: nested pairs
    /// `product(a, product(b, product(c, ...)))`. Both enumerate and sample the same values in the same order (the
    /// flat product's index arithmetic equals the nested one's, and both draw a, then b, then c); the flat one avoids
    /// a closure layer per field on every input.
    static func nestedProduct(_ domains: [String]) -> String {
        guard let last = domains.last else { return "" }
        guard domains.count > 1 else { return last }
        if domains.count <= 4 { return "SwiftFormal.Domain.product(\(domains.joined(separator: ", ")))" }
        return domains.dropLast().reversed().reduce(last) { "SwiftFormal.Domain.product(\($1), \($0))" }
    }

    /// The accessor for element `index` of the tuple built by `nestedProduct`; `$0` is the tuple.
    static func nestedAccess(_ index: Int, of count: Int) -> String {
        guard count > 1 else { return "$0" }
        if count <= 4 { return "$0.\(index)" }
        let path = String(repeating: ".1", count: index)
        return "$0" + path + (index == count - 1 ? "" : ".0")
    }

    private static func valuesOverride(of variable: VariableDeclSyntax) -> String? {
        for element in variable.attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                attribute.attributeName.trimmedDescription == "Values",
                case let .argumentList(arguments)? = attribute.arguments,
                let first = arguments.first
            else { continue }
            return first.expression.trimmedDescription
        }
        return nil
    }

    private static func isStatic(_ variable: VariableDeclSyntax) -> Bool {
        variable.modifiers.contains { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }
    }

    private static func rejectGenerics(_ clause: GenericParameterClauseSyntax?) throws {
        if clause != nil { throw ContractError("@Finite does not support generic types yet") }
    }

    private static func accessPrefix(of declaration: some DeclGroupSyntax) -> String {
        for modifier in declaration.modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open): return "public "
            case .keyword(.package): return "package "
            default: continue
            }
        }
        return ""
    }
}

/// `@Values(domain)` on a stored property of a `@Finite` struct. It expands to nothing: `@Finite` reads it.
package struct ValuesMacro: PeerMacro {
    package static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
