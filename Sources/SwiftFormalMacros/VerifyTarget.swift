import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// What `@Verify` is attached to, read the same way for its two roles: a function, or the getter of a computed
// property. The body role sees a function or the getter (an accessor whose property is the innermost lexical
// context); the peer role sees the function or the property.

/// A function, or the getter of a computed property, with what the expansion needs from it.
struct VerifyTarget {
    enum Kind {
        case function
        /// The getter of a computed property: no parameters, the property's type as result.
        case getter
    }

    let kind: Kind
    /// The function's or the property's name.
    let name: String
    let parameters: [Parameter]
    /// The result type as written, `Void` when there is none.
    let returnType: String
    /// `throws` or `throws(E)` as written; nil when it cannot throw.
    let throwsClause: String?
    let isMutating: Bool
    /// The modifiers the peers copy (access, `static`, `class`), with a space after them, or "".
    let peerPrefix: String
    let body: CodeBlockSyntax
    /// The function itself, for the shape checks of a walk; nil for a getter.
    let function: FunctionDeclSyntax?

    var returnsValue: Bool { !["Void", "()"].contains(returnType) }

    /// A function with an `inout` parameter (other than a `mutating` method's `self`): Scan gives it no `ensures`,
    /// because the contract would see the value before the call.
    var hasInoutParameter: Bool { parameters.contains(where: \.isInout) }

    // MARK: Reading the declaration

    /// The target of the body role: the function, or the getter whose property is the innermost lexical context.
    static func forBody(_ declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws -> VerifyTarget {
        if let function = declaration.as(FunctionDeclSyntax.self) { return try Self.function(function) }
        if let accessor = declaration.as(AccessorDeclSyntax.self) {
            guard let variable = context.lexicalContext.first?.as(VariableDeclSyntax.self) else {
                throw ContractError("@Verify applies to a getter of a property")
            }
            guard let body = accessor.body else { throw ContractError("@Verify applies to a getter with a body") }
            return try getter(of: variable, accessor: accessor, body: body)
        }
        throw ContractError("@Verify applies to a function or to a computed property")
    }

    /// The target of the peer role: the function or the computed property. Nil for `@Verify` on a `get` accessor,
    /// which can add no declarations next to the property (the compiler would put them inside the accessor list); a
    /// warning says so.
    static func forPeers(_ declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws -> VerifyTarget? {
        if let function = declaration.as(FunctionDeclSyntax.self) { return try Self.function(function) }
        if let variable = declaration.as(VariableDeclSyntax.self) {
            let binding = try onlyBinding(of: variable)
            switch binding.accessorBlock?.accessors {
            case .getter(let statements)?:
                return try getter(of: variable, accessor: nil, body: CodeBlockSyntax(statements: statements))
            case .accessors?:
                let message =
                    "@Verify on a property applies to its getter: write the getter's code directly (`var x: T { … }`), "
                    + "or, with a setter, put @Verify on the `get`"
                throw DiagnosticsError(diagnostics: [Diagnostic(node: variable, message: VerifyDiagnostic(message: message))])
            case nil:
                throw ContractError("@Verify applies to a function or to a computed property, not to a stored property")
            }
        }
        if declaration.is(AccessorDeclSyntax.self) {
            let name =
                (context.lexicalContext.first?.as(VariableDeclSyntax.self)).flatMap { try? onlyBinding(of: $0) }
                .flatMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text } ?? "x"
            let message =
                "@Verify on a `get` checks the contract in the getter, but cannot write `\(name)_requires()` and "
                + "`\(name)_ensures(_:)` next to the property, so Scan sees it only as those checks; on a property without "
                + "a setter write `@Verify var \(name): T { … }` instead"
            context.diagnose(Diagnostic(node: declaration, message: VerifyDiagnostic(message: message, severity: .warning)))
            return nil
        }
        throw ContractError("@Verify applies to a function or to a computed property")
    }

    private static func function(_ function: FunctionDeclSyntax) throws -> VerifyTarget {
        guard let body = function.body else { throw ContractError("@Verify applies to a function with a body") }
        let effects = function.signature.effectSpecifiers
        if effects?.asyncSpecifier != nil { throw ContractError("@Verify does not support async functions yet") }
        return VerifyTarget(
            kind: .function, name: function.name.text,
            parameters: function.signature.parameterClause.parameters.map(Parameter.init),
            returnType: function.signature.returnClause?.type.trimmedDescription ?? "Void",
            throwsClause: effects?.throwsClause?.trimmedDescription,
            isMutating: function.modifiers.contains { $0.name.tokenKind == .keyword(.mutating) },
            peerPrefix: peerPrefix(function.modifiers), body: body, function: function)
    }

    /// The getter of `variable`: `accessor` is the `get` (nil for a property whose braces hold the getter's code).
    private static func getter(of variable: VariableDeclSyntax, accessor: AccessorDeclSyntax?, body: CodeBlockSyntax) throws
        -> VerifyTarget
    {
        let binding = try onlyBinding(of: variable)
        if let accessor {
            let specifier = accessor.accessorSpecifier
            guard specifier.presence == .missing || specifier.tokenKind == .keyword(.get) else {
                throw ContractError("@Verify applies to a getter, not to `\(specifier.text)`")
            }
            if accessor.effectSpecifiers?.asyncSpecifier != nil { throw ContractError("@Verify does not support async getters yet") }
        }
        guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
            throw ContractError("@Verify applies to a property with a plain name")
        }
        guard let type = binding.typeAnnotation?.type.trimmedDescription else {
            throw ContractError("@Verify needs the type of '\(name)' written out (`var \(name): T`)")
        }
        return VerifyTarget(
            kind: .getter, name: name, parameters: [], returnType: type,
            throwsClause: accessor?.effectSpecifiers?.throwsClause?.trimmedDescription, isMutating: false,
            peerPrefix: peerPrefix(variable.modifiers), body: body, function: nil)
    }

    private static func onlyBinding(of variable: VariableDeclSyntax) throws -> PatternBindingSyntax {
        guard variable.bindings.count == 1, let binding = variable.bindings.first else {
            throw ContractError("@Verify applies to one property at a time")
        }
        return binding
    }

    private static func peerPrefix(_ modifiers: DeclModifierListSyntax) -> String {
        let kept = modifiers.map(\.name.text)
            .filter { ["public", "package", "internal", "fileprivate", "private", "static", "class"].contains($0) }
        return kept.isEmpty ? "" : kept.joined(separator: " ") + " "
    }
}

// MARK: - Whether a walk needs `over:`

extension Parameter {
    /// The names of standard library and Foundation types that are not `Finite`: a parameter of one of these needs
    /// `@Verify(over:)` to be walked. Any other name may be a `Finite` type of the user's.
    static let typesThatAreNotFinite: Set<String> = [
        "String", "Substring", "Character", "Unicode", "Int", "Int16", "Int32", "Int64", "Int128", "UInt", "UInt16",
        "UInt32", "UInt64", "UInt128", "Double", "Float", "Float16", "Float80", "CGFloat", "Decimal", "Date", "URL",
        "UUID", "Data", "Array", "ContiguousArray", "ArraySlice", "Dictionary", "Set", "Range", "ClosedRange",
        "Result", "Error", "AnyHashable", "Any", "AnyObject", "Locale", "TimeZone", "Calendar", "DateComponents",
        "TimeInterval", "Measurement", "IndexPath", "NSNumber", "NSString", "NSObject",
    ]

    /// Whether this parameter's type is surely not `Finite`, read from the source: one of `typesThatAreNotFinite`, an
    /// optional of one, an array, dictionary, tuple, function, `some`/`any` or metatype, or an `inout` or variadic
    /// parameter, which a walk cannot pass. Unknown names (the user's own types) are not.
    var isSurelyNotFinite: Bool { isInout || isVariadic || Self.isSurelyNotFinite(syntax.type) }

    private static func isSurelyNotFinite(_ type: TypeSyntax) -> Bool {
        if let attributed = type.as(AttributedTypeSyntax.self) { return isSurelyNotFinite(attributed.baseType) }
        if let optional = type.as(OptionalTypeSyntax.self) { return isSurelyNotFinite(optional.wrappedType) }
        if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return isSurelyNotFinite(optional.wrappedType) }
        if let tuple = type.as(TupleTypeSyntax.self) {
            // `(T)` is `T`; a real tuple cannot conform to a protocol.
            guard tuple.elements.count == 1, let only = tuple.elements.first, only.firstName == nil else { return true }
            return isSurelyNotFinite(only.type)
        }
        if type.is(ArrayTypeSyntax.self) || type.is(DictionaryTypeSyntax.self) || type.is(FunctionTypeSyntax.self)
            || type.is(SomeOrAnyTypeSyntax.self) || type.is(MetatypeTypeSyntax.self) || type.is(CompositionTypeSyntax.self)
        {
            return true
        }
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            let name = identifier.name.text
            if name == "Optional", let wrapped = identifier.genericArgumentClause?.arguments.first {
                return isSurelyNotFinite(TypeSyntax("\(raw: wrapped.argument.trimmedDescription)"))
            }
            return typesThatAreNotFinite.contains(name)
        }
        if let member = type.as(MemberTypeSyntax.self), let base = member.baseType.as(IdentifierTypeSyntax.self),
            ["Swift", "Foundation", "CoreGraphics"].contains(base.name.text)
        {
            return typesThatAreNotFinite.contains(member.name.text)
        }
        return false
    }
}
